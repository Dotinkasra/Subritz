import AppKit
import Foundation
import StudyCore

struct BackupPreferences: Codable {
  var enabled = false
  var directoryPath = ""
  var bookmark: Data?
  var scoped = false
  var lastSavedAt: Date?
  static func load(_ defaults: UserDefaults) -> Self {
    defaults.data(forKey: "backupPreferences").flatMap {
      try? JSONDecoder().decode(Self.self, from: $0)
    } ?? Self()
  }
  func save(_ defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(self), forKey: "backupPreferences")
  }
  mutating func choose(_ url: URL) throws {
    do {
      bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      scoped = true
    } catch {
      bookmark = try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      scoped = false
    }
    directoryPath = url.path
    lastSavedAt = nil
  }
  mutating func resolve() throws -> URL {
    guard let bookmark else { throw AppFailure("バックアップの保存先を選んでください。") }
    var stale = false
    let options: URL.BookmarkResolutionOptions =
      scoped ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
    let url = try URL(
      resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
      bookmarkDataIsStale: &stale)
    if stale { try choose(url) }
    return url
  }
}

extension StudyModel {
  var backupBusy: Bool { backupTask != nil || backupReadTask != nil || isRestoringBackup }
  var backupRecoveryRoot: URL {
    backupRecoveryDirectoryOverride
      ?? AppSettings.defaultCacheURL.appendingPathComponent("Before Restore", isDirectory: true)
  }
  func chooseBackupDestination(_ url: URL, enable: Bool = false) {
    guard !backupBusy else { return }
    do {
      try backupPreferences.choose(url)
      if enable { backupPreferences.enabled = true }
      backupPreferences.save(defaults)
      backupError = nil
      backupStatus = "バックアップの保存先を設定しました。"
      markBackupChanged(immediate: true)
    } catch { backupError = "保存先を記憶できませんでした：" + error.localizedDescription }
  }
  func setAutomaticBackup(_ enabled: Bool) {
    guard !backupBusy else { return }
    guard !enabled || backupPreferences.bookmark != nil else { return }
    backupPreferences.enabled = enabled
    backupPreferences.save(defaults)
    backupSchedule?.cancel()
    backupSchedule = nil
    if enabled { markBackupChanged(immediate: true) }
  }
  func markBackupChanged(immediate: Bool = false) {
    backupRevision &+= 1
    guard backupPreferences.enabled, !isRestoringBackup, !backupTerminating,
      pendingBackupRestore == nil,
      backupTask == nil, backupReadTask == nil, backupSchedule == nil
    else { return }
    // One scheduled task per batch, never one task/timer per playback sample.
    // Continuous listening checkpoints produce at most one backup per 5 minutes.
    let delay =
      backupDelayOverride
      ?? (immediate
        ? 1
        : max(2, 300 - (backupPreferences.lastSavedAt.map { Date().timeIntervalSince($0) } ?? 300)))
    backupSchedule = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      self.backupSchedule = nil
      self.backupNow(automatic: true)
    }
  }
  func currentBackupArchive() async throws -> BackupArchive {
    await libraryOperation?.value
    flushListeningRecords()
    await listeningSaveTask?.value
    if let error = historyPositionSaveError ?? libraryError ?? listeningSaveError { throw AppFailure(error) }
    let storage: LibraryStore
    if let library {
      storage = library
    } else if let libraryStartup {
      storage = try await libraryStartup.value
    } else {
      throw AppFailure("学習データの保存先を準備しています。少し待って再試行してください。")
    }
    let savedSettings = AppSettings.load(defaults: defaults)
    return try await BackupArchive(settings: savedSettings, library: storage.backupData())
  }
  func backupNow(automatic: Bool = false) {
    guard !backupBusy, backupPreferences.bookmark != nil,
      !automatic || (backupPreferences.enabled && pendingBackupRestore == nil)
    else { return }
    backupSchedule?.cancel()
    backupSchedule = nil
    backupError = nil
    backupStatus = "バックアップを作成しています…"
    backupTask = Task { [self] in
      var succeeded = false
      // Keep the pre-snapshot revision: edits during any await must remain dirty.
      let revision = backupRevision
      do {
        let archive = try await currentBackupArchive()
        let url = try backupPreferences.resolve()
        backupPreferences.save(defaults)
        let output = try await Task.detached(priority: .utility) {
          try BackupFiles.write(archive, to: url, automatic: automatic)
        }.value
        backupPreferences.lastSavedAt = Date()
        backupPreferences.save(defaults)
        backupSavedRevision = revision
        backupStatus = "バックアップを保存しました。iCloud Driveへの転送はmacOSが処理します。"
        lastBackupURL = output
        succeeded = true
      } catch {
        backupError = "バックアップを保存できませんでした：" + error.localizedDescription
        backupStatus = "前回のバックアップはそのまま残っています。"
      }
      backupTask = nil
      if succeeded, backupRevision != backupSavedRevision { markBackupChanged() }
    }
  }
  func prepareBackupRestore(_ url: URL) {
    guard !backupBusy else { return }
    backupSchedule?.cancel()
    backupSchedule = nil
    backupError = nil
    backupStatus = "バックアップを確認しています…"
    backupReadTask = Task { [self] in
      do {
        let archive = try await Task.detached(priority: .utility) { try BackupFiles.read(url) }
          .value
        pendingBackupRestore = archive
        backupRestorePrompt =
          archive.createdAt.formatted(.dateTime.year().month().day().hour().minute())
          + "のバックアップ\nお気に入り \(archive.library.favorites.count)語・動画履歴 \(archive.library.history.count)本"
          + "・タイムスタンプ \(archive.library.timestamps.count)件\n"
          + "学習時間 " + PlaybackTime.format(archive.library.listening.reduce(0) { $0 + $1.seconds })
          + "\n"
          + "現在の学習データ・設定・カラムのレイアウトを置き換えます。再生・音声認識中の場合は終了します。"
          + "復元前の状態は、このMacに退避します。"
        backupStatus = "復元する内容を確認してください。"
      } catch { backupError = "バックアップを読み込めませんでした：" + error.localizedDescription }
      backupReadTask = nil
      if pendingBackupRestore == nil { markBackupChanged() }
    }
  }
  func cancelBackupRestore() {
    let hadCandidate = pendingBackupRestore != nil
    pendingBackupRestore = nil
    backupRestorePrompt = nil
    if hadCandidate {
      backupStatus = "復元をキャンセルしました。"
      markBackupChanged()
    }
  }
  func confirmBackupRestore(_ candidate: BackupArchive? = nil) {
    guard !backupBusy, let archive = candidate ?? pendingBackupRestore else { return }
    do { try archive.validate() } catch {
      backupError = error.localizedDescription
      return
    }
    pendingBackupRestore = nil
    backupRestorePrompt = nil
    isRestoringBackup = true
    backupSchedule?.cancel()
    backupSchedule = nil
    backupError = nil
    backupStatus = "現在の状態を退避して復元しています…"
    closeVideo()
    backupRestoreTask = Task { [self] in
      defer {
        isRestoringBackup = false
        backupRestoreTask = nil
      }
      do {
        await liveSpeechShutdown?.value
        await cacheOperation?.value
        // Make a verified, local recovery copy before replacing any user data.
        let recovery = try await currentBackupArchive()
        let recoveryRoot = backupRecoveryRoot
        let recoveryURL = try await Task.detached(priority: .utility) {
          try BackupFiles.write(recovery, to: recoveryRoot, automatic: true)
        }.value
        lastRecoveryURL = recoveryURL
        defaults.set(recoveryURL.path, forKey: "lastRecoveryBackupPath")
        var restored = archive.settings
        var pathReset = false
        if !restored.cacheDirectory.isEmpty {
          var isDirectory: ObjCBool = false
          if !FileManager.default.fileExists(
            atPath: restored.cacheDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue
          {
            restored.cacheDirectory = ""
            pathReset = true
          }
        }
        let target = restored.cacheURL
        let newStore = try await Task.detached { try StudyStore(directory: target) }.value
        guard let library else { throw AppFailure("学習データの保存先を開けませんでした。") }
        try await library.restoreBackupData(archive.library)
        // The database transaction has committed; preference writes cannot fail.
        settings = restored
        videoShape.reset(template: restored.videoMaskTemplate)
        restored.save(defaults: defaults)
        store = newStore
        listeningBuffer = ListeningBuffer()
        listeningCheckpointUptime = nil
        liveTranscriptCache.setLimit(restored.liveSpeechCacheMB * 1024 * 1024)
        invalidateDictionary()
        do {
          try await refreshLibrary()
          await refreshStorage()
        } catch { libraryError = "復元済みですが表示を更新できませんでした：" + error.localizedDescription }
        backupStatus =
          "バックアップから復元しました。復元前の状態は「復元前のバックアップ」から確認できます。"
          + (pathReset ? " キャッシュの保存先が見つからないため、標準の保存先に戻しました。" : "")
        // Keep this Mac's backup destination, credentials and backup opt-in.
        isRestoringBackup = false
        markBackupChanged(immediate: true)
      } catch {
        backupError = "復元できませんでした：" + error.localizedDescription
        backupStatus = "学習データと設定は置き換えていません。"
      }
    }
  }
  func finishBackupBeforeQuitting() async {
    backupTerminating = true
    backupSchedule?.cancel()
    backupSchedule = nil
    await backupReadTask?.value
    await backupRestoreTask?.value
    await backupTask?.value
    cancelBackupRestore()
    if backupPreferences.enabled {
      backupNow(automatic: true)
      await backupTask?.value
    }
    backupTerminating = false
  }
}
