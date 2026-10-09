import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct SettingsLifecycleTests {
  func isolatedModel() throws -> (StudyModel, UserDefaults, String) {
    let suite = "subritz-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (StudyModel(prepareStorage: false, defaults: defaults), defaults, suite)
  }
  @Test func autoSavePreservesProviderModelsAcrossReload() throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    var previous = model.settings
    model.settings.localModel = "local-model"
    model.saveSettings(previous: previous)
    previous = model.settings
    model.settings.provider = "codex"
    model.settings.codexModel = "gpt-6-luna"
    model.saveSettings(previous: previous)
    let reloaded = AppSettings.load(defaults: defaults)
    #expect(reloaded.localModel == "local-model")
    #expect(reloaded.codexModel == "gpt-6-luna")
    #expect(reloaded.provider == "codex")
  }
  @Test func invalidTimeoutDoesNotOverwriteSavedSettings() throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    model.settings.timeout = 60
    model.saveSettings(previous: model.settings)
    model.settings.timeout = 0
    model.saveSettings(previous: model.settings)
    #expect(AppSettings.load(defaults: defaults).timeout == 60)
    #expect(model.settingsMessage.contains("未保存"))
    model.settings.timeout = 90
    model.saveSettings(previous: model.settings)
    #expect(AppSettings.load(defaults: defaults).timeout == 90)
  }
  @Test func closeVideoCancelsWorkAndClearsPlaybackSelection() throws {
    let (model, words) = try DictionaryPinTests().fixture(realtime: false)
    model.pinDictionary(words[0])
    model.update(time: 1.1, duration: 2, state: 1)
    let session = model.session
    model.loadTask = Task { try? await Task.sleep(for: .seconds(60)) }
    model.backgroundTask = Task { try? await Task.sleep(for: .seconds(60)) }
    model.confirmCloseVideo = true
    #expect(model.hasOpenVideo)
    model.closeVideo()
    #expect(!model.hasOpenVideo)
    #expect(model.loadTask?.isCancelled == true)
    #expect(model.backgroundTask?.isCancelled == true)
    #expect(model.session != session)
    #expect(model.document == nil && model.timeline == nil)
    #expect(model.displayedToken == nil && model.dictionaryEntry == nil)
    #expect(!model.playing && !model.loading && !model.confirmCloseVideo)
    #expect(model.time == 0 && model.duration == 0)
    model.update(time: 1.5, duration: 2, state: 1)
    #expect(!model.playing)
  }
  @Test func loadingAlsoRequiresCloseConfirmation() throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!model.hasOpenVideo)
    model.loading = true
    #expect(model.hasOpenVideo)
    model.closeVideo()
    #expect(!model.hasOpenVideo)
  }
  @Test func importLocksImmediatelyAndFailureUnlocks() async throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    model.importDictionary(URL(fileURLWithPath: "/tmp/nonexistent-eijiro-" + UUID().uuidString))
    #expect(model.isImportingDictionary && model.dictionaryBusy)
    let firstOperation = model.dictionaryOperation
    model.removeDictionary()
    model.importDictionary(URL(fileURLWithPath: "/tmp/another-file"))
    #expect(!model.isRemovingDictionary)
    await firstOperation?.value
    #expect(!model.dictionaryBusy)
    #expect(model.dictionaryMessage.contains("インポートできませんでした"))
  }
  @Test func importCompletesAndRefreshesDictionary() async throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    model.eijiro = try EijiroProvider(directory: directory)
    let file = directory.appendingPathComponent("dictionary.txt")
    try "■sampleunit : {名} 自作インポート義\n".write(to: file, atomically: true, encoding: .utf8)
    model.importDictionary(file)
    await model.dictionaryOperation?.value
    #expect(!model.dictionaryBusy)
    #expect(model.eijiroCount == 1)
    #expect(model.dictionaryMessage.contains("1項目"))
  }
  @Test func cacheDirectoryChangesOnlyAfterSuccessfulOpen() async throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    model.eijiro = try EijiroProvider(directory: directory.appendingPathComponent("dictionary"))
    model.changeCacheDirectory(to: directory)
    #expect(model.isChangingCacheDirectory)
    await model.cacheOperation?.value
    #expect(!model.isChangingCacheDirectory)
    #expect(model.settings.cacheURL.path == directory.path)
    #expect(AppSettings.load(defaults: defaults).cacheURL.path == directory.path)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("video-cache.sqlite").path))
    let invalid = directory.appendingPathComponent("regular-file")
    try Data("not a directory".utf8).write(to: invalid)
    model.changeCacheDirectory(to: invalid)
    await model.cacheOperation?.value
    #expect(model.settings.cacheURL.path == directory.path)
    #expect(AppSettings.load(defaults: defaults).cacheURL.path == directory.path)
    #expect(model.cacheMessage.contains("変更できませんでした"))
  }
  @Test func cacheDirectoryChangePreservesLoadedVideoAndExistingCache() async throws {
    let (model, defaults, suite) = try isolatedModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (loaded, _) = try DictionaryPinTests().fixture(realtime: true)
    let document = try #require(loaded.document)
    model.document = document
    model.timeline = loaded.timeline
    model.ready = true
    model.fingerprint = "active-video"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try StudyStore(directory: root.appendingPathComponent("original"))
    model.store = original
    model.eijiro = try EijiroProvider(directory: root.appendingPathComponent("dictionary"))
    try await original.save(document, fingerprint: model.fingerprint, limit: 1_000_000)
    model.library = try LibraryStore(directory: root.appendingPathComponent("library"))
    try await model.library?.record(document.video)
    try await model.library?.saveFavorite(
      FavoriteWord(token: document.sentences[0].tokens[0], entry: nil, video: document.video))
    let session = model.session
    let destination = root.appendingPathComponent("destination")
    model.changeCacheDirectory(to: destination)
    await model.cacheOperation?.value
    let copied = try await model.store?.load(model.fingerprint)
    let retained = try await original.load(model.fingerprint)
    #expect(copied?.rawCaption == document.rawCaption)
    #expect(retained?.rawCaption == document.rawCaption)
    #expect(model.ready && model.session == session)
    #expect(model.document?.video.id == document.video.id)
    #expect(model.settings.cacheURL.path == destination.path)
    try await model.store?.clear()
    #expect(try await model.library?.history().count == 1)
    #expect(try await model.library?.favorites().count == 1)
  }
}
