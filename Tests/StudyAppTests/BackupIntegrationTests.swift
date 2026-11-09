import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct BackupIntegrationTests {
  func authoredData() throws -> LibraryBackupData {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"A paper robot carries a blue lantern."}]}]}"#
        .utf8)
    let token = try #require(
      Timeline(try CaptionPipeline().parse(raw, videoID: "authored")).tokens.first {
        $0.surface == "lantern"
      })
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    let date = Date()
    return LibraryBackupData(
      history: [.init(video: video)], favorites: [.init(token: token, entry: nil, video: video)],
      timestamps: [.init(video: video, time: 80)],
      listening: [.init(start: date, end: date.addingTimeInterval(15), source: .video)])
  }
  func fixture() throws -> (StudyModel, URL) {
    let (model, defaults, _) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("destination"), withIntermediateDirectories: true)
    model.library = try LibraryStore(directory: root.appendingPathComponent("library"))
    model.backupRecoveryDirectoryOverride = root.appendingPathComponent("recovery")
    model.settings.cacheDirectory = root.appendingPathComponent("cache").path
    try FileManager.default.createDirectory(
      atPath: model.settings.cacheDirectory, withIntermediateDirectories: true)
    model.settings.save(defaults: defaults)
    return (model, root)
  }
  func cleanup(_ model: StudyModel, _ root: URL) {
    model.backupSchedule?.cancel()
    for key in ["settings", "backupPreferences", "lastRecoveryBackupPath"] {
      model.defaults.removeObject(forKey: key)
    }
    try? FileManager.default.removeItem(at: root)
  }
  @Test func manualBackupWaitsForQueuedWritesAndListeningAndRemembersItsDestination() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.chooseBackupDestination(root.appendingPathComponent("destination"))
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    model.mutateLibrary { try await $0.record(video) }
    model.setWorkspaceLayout(upper: 0.33, leading: 0.67)
    let date = Date()
    model.listeningBuffer.append(DateInterval(start: date, duration: 4), source: .video)
    model.backupNow()
    await model.backupTask?.value
    #expect(model.backupError == nil && model.backupPreferences.lastSavedAt != nil)
    let output = try #require(model.lastBackupURL)
    let archive = try await Task.detached { try BackupFiles.read(output) }.value
    #expect(archive.library.history.first?.video.id == video.id)
    #expect(archive.library.listening.reduce(0) { $0 + $1.seconds } == 4)
    #expect(
      archive.settings.workspaceUpperFraction == 0.33
        && archive.settings.workspaceLeadingFraction == 0.67)
    var preferences = BackupPreferences.load(model.defaults)
    #expect(!preferences.enabled)
    #expect(
      try preferences.resolve().resolvingSymlinksInPath().path
        == root.appendingPathComponent("destination").resolvingSymlinksInPath().path)
    let reloaded = StudyModel(prepareStorage: false, defaults: model.defaults)
    #expect(reloaded.settings.workspaceUpperFraction == 0.33)
  }
  @Test func restoreIsExplicitMakesRecoveryCopyAndPreservesThisMacBackupPreferences() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let original = try authoredData()
    try await model.library?.restoreBackupData(original)
    model.chooseBackupDestination(root.appendingPathComponent("destination"))
    model.setWorkspaceLayout(upper: 0.3, leading: 0.4)
    model.setSubtitleFontScale(1.2)
    model.setSubtitleWrapCharacters(55)
    model.setSubtitleRowSpacing(0.4)
    model.liveSpeechSessionID = UUID()
    model.setSubtitleFontScale(0.8)
    model.setSubtitleWrapCharacters(110)
    model.setSubtitleRowSpacing(0.2)
    model.liveSpeechSessionID = nil
    let archivedSettings = AppSettings.load(defaults: model.defaults)
    model.backupNow()
    await model.backupTask?.value
    let backup = try #require(model.lastBackupURL)
    try await model.library?.restoreBackupData(.init())
    model.resetWorkspaceLayout()
    model.setWorkspaceLayout(upper: 0.8, leading: 0.7)
    model.prepareBackupRestore(backup)
    await model.backupReadTask?.value
    #expect(model.pendingBackupRestore != nil && model.backupRestorePrompt != nil)
    #expect(try await model.library?.history().isEmpty == true)
    model.cancelBackupRestore()
    #expect(model.settings.workspaceUpperFraction == 0.8)
    model.prepareBackupRestore(backup)
    await model.backupReadTask?.value
    model.confirmBackupRestore()
    await model.backupRestoreTask?.value
    #expect(model.backupError == nil && !model.isRestoringBackup)
    #expect(
      model.settings.workspaceUpperFraction == 0.3 && model.settings.workspaceLeadingFraction == 0.4
    )
    #expect(AppSettings.load(defaults: model.defaults) == archivedSettings)
    #expect(model.settings.subtitleFontScale == 1.2 && model.settings.liveSubtitleFontScale == 0.8)
    #expect(
      model.settings.subtitleWrapCharacters == 55
        && model.settings.liveSubtitleWrapCharacters == 110)
    #expect(model.videoHistory.count == 1 && model.favoriteWords.count == 1)
    #expect(model.videoTimestamps.map(\.id) == original.timestamps.map(\.id))
    #expect(
      !model.backupPreferences.enabled
        && model.backupPreferences.directoryPath == root.appendingPathComponent("destination").path)
    let recovery = try #require(model.lastRecoveryURL)
    let prior = try await Task.detached { try BackupFiles.read(recovery) }.value
    #expect(prior.library.history.isEmpty && prior.settings.workspaceUpperFraction == 0.8)
    #expect(model.defaults.string(forKey: "lastRecoveryBackupPath") == recovery.path)
    let restored = try await model.library?.backupData()
    #expect(restored?.listening.reduce(0) { $0 + $1.seconds } == 15)
  }
  @Test func restoreFailureKeepsPreferencesAndRecordsAndProvidesRecoveryCopy() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let original = try authoredData()
    try await model.library?.restoreBackupData(original)
    let saved = model.settings
    try await model.library?.db.execute(
      "CREATE TRIGGER block_restore BEFORE INSERT ON favorite_words BEGIN SELECT RAISE(ABORT,'test'); END"
    )
    var replacement = saved
    replacement.advancedMode = !saved.advancedMode
    model.pendingBackupRestore = BackupArchive(settings: replacement, library: original)
    model.confirmBackupRestore()
    await model.backupRestoreTask?.value
    #expect(model.backupError != nil && model.settings == saved && !model.isRestoringBackup)
    #expect(AppSettings.load(defaults: model.defaults) == saved)
    #expect(try await model.library?.history().count == 1)
    #expect(model.lastRecoveryURL != nil)
  }
  @Test func automaticChangesCoalesceAndDisablingCancelsScheduledWork() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.backupDelayOverride = 0.03
    model.chooseBackupDestination(root.appendingPathComponent("destination"), enable: true)
    for _ in 0..<100 { model.markBackupChanged() }
    #expect(model.backupSchedule != nil)
    let cancelled = model.backupSchedule
    model.setAutomaticBackup(false)
    await cancelled?.value
    #expect(model.lastBackupURL == nil && model.backupSchedule == nil)
    model.setAutomaticBackup(true)
    await model.backupSchedule?.value
    await model.backupTask?.value
    #expect(model.backupError == nil && model.lastBackupURL != nil)
    let urls = try FileManager.default.contentsOfDirectory(
      at: BackupFiles.folder(in: root.appendingPathComponent("destination")),
      includingPropertiesForKeys: nil)
    #expect(urls.count == 1)
    model.setAutomaticBackup(false)
  }
  @Test func malformedRestoreDoesNotStopPlaybackOrChangeData() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let original = try authoredData()
    try await model.library?.restoreBackupData(original)
    let corrupt = root.appendingPathComponent("broken.subritzbackup")
    try Data("not a backup".utf8).write(to: corrupt)
    model.ready = true
    model.prepareBackupRestore(corrupt)
    await model.backupReadTask?.value
    #expect(model.backupError != nil && model.pendingBackupRestore == nil)
    #expect(model.ready && !model.isRestoringBackup)
    #expect(try await model.library?.favorites().count == 1)
  }
  @Test func quittingFlushesLatestListeningAndLeavesNoScheduledBackup() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.chooseBackupDestination(root.appendingPathComponent("destination"), enable: true)
    let date = Date()
    model.listeningBuffer.append(DateInterval(start: date, duration: 6), source: .speech)
    await model.finishBackupBeforeQuitting()
    #expect(model.backupTask == nil && model.backupSchedule == nil && model.backupError == nil)
    let output = try #require(model.lastBackupURL)
    let archive = try await Task.detached { try BackupFiles.read(output) }.value
    #expect(archive.library.listening.reduce(0) { $0 + $1.seconds } == 6)
    model.setAutomaticBackup(false)
  }

  @Test func subtitleLayoutChangesTriggerANewAutomaticBackup() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.backupDelayOverride = 0.01
    model.chooseBackupDestination(root.appendingPathComponent("destination"), enable: true)
    await model.backupSchedule?.value
    await model.backupTask?.value
    let first = try #require(model.lastBackupURL)
    model.setSubtitleFontScale(1.3)
    model.setSubtitleWrapCharacters(45)
    await model.backupSchedule?.value
    await model.backupTask?.value
    let last = try #require(model.lastBackupURL)
    #expect(first != last)
    let archive = try await Task.detached { try BackupFiles.read(last) }.value
    #expect(
      archive.settings.subtitleFontScale == 1.3 && archive.settings.subtitleWrapCharacters == 45)
    model.setAutomaticBackup(false)
  }

}
