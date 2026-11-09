import CryptoKit
import Foundation
import Testing

@testable import StudyCore

struct BackupTests {
  func data() throws -> LibraryBackupData {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"A paper robot carries a blue lantern."}]}]}"#
        .utf8)
    let token = try #require(
      Timeline(try CaptionPipeline().parse(raw, videoID: "authored")).tokens.first {
        $0.surface == "lantern"
      })
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    let word = FavoriteWord(token: token, entry: nil, video: video)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    return LibraryBackupData(
      history: [.init(video: video, lastOpened: date)], favorites: [word],
      timestamps: [.init(video: video, time: 80, savedAt: date)],
      listening: [
        .init(start: date, end: date.addingTimeInterval(10), source: .video),
        .init(
          start: date.addingTimeInterval(30), end: date.addingTimeInterval(35), source: .speech),
      ])
  }
  @Test func roundTripPreservesIDsDeletedOccurrencesSettingsAndAllListeningRecords() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try data()
    try await store.restoreBackupData(original)
    try Data("PRIVATE_CACHE_SENTINEL".utf8).write(
      to: root.appendingPathComponent("video-cache.sqlite"))
    var settings = AppSettings()
    settings.advancedMode = true
    settings.workspaceUpperFraction = 0.32
    settings.workspaceLeadingFraction = 0.68
    settings.wordSpeechQuality = .premium
    let archive = try await BackupArchive(settings: settings, library: store.backupData())
    let bytes = try archive.encoded()
    #expect(bytes.range(of: Data("PRIVATE_CACHE_SENTINEL".utf8)) == nil)
    let decoded = try BackupArchive.decode(bytes)
    #expect(decoded.settings == settings)
    #expect(decoded.library.listening.map(\.id) == original.listening.map(\.id))
    #expect(decoded.library.favorites.first?.id == "lantern")
    try await store.restoreBackupData(.init())
    try await store.restoreBackupData(decoded.library)
    let reopened = try LibraryStore(directory: root)
    let restored = try await reopened.backupData()
    #expect(restored.history.first?.id == original.history.first?.id)
    #expect(restored.timestamps.map(\.id) == original.timestamps.map(\.id))  // Don't resurrect a deleted favorite occurrence.
    #expect(restored.listening.reduce(0) { $0 + $1.seconds } == 15)
    #expect(
      try String(contentsOf: root.appendingPathComponent("video-cache.sqlite"), encoding: .utf8)
        == "PRIVATE_CACHE_SENTINEL")
  }
  @Test func checksumAndFutureFormatsAreRejectedBeforeRestore() throws {
    let bytes = try BackupArchive(settings: AppSettings(), library: data()).encoded()
    var envelope = try #require(
      PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
    var payload = try #require(envelope["payload"] as? Data)
    payload[payload.startIndex] ^= 1
    envelope["payload"] = payload
    let damaged = try PropertyListSerialization.data(
      fromPropertyList: envelope, format: .binary, options: 0)
    #expect(throws: (any Error).self) { try BackupArchive.decode(damaged) }
    envelope["version"] = 999
    let future = try PropertyListSerialization.data(
      fromPropertyList: envelope, format: .binary, options: 0)
    #expect(throws: (any Error).self) { try BackupArchive.decode(future) }
    #expect(throws: (any Error).self) { try BackupArchive.decode(Data("not a backup".utf8)) }
  }
  @Test func invalidAndFailedRestoresLeaveEveryOriginalTableUntouched() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try data()
    try await store.restoreBackupData(original)
    var invalid = original
    invalid.listening.append(original.listening[0])
    await #expect(throws: (any Error).self) { try await store.restoreBackupData(invalid) }
    try await store.db.execute(
      "CREATE TRIGGER block_restore BEFORE INSERT ON favorite_words BEGIN SELECT RAISE(ABORT,'test'); END"
    )
    await #expect(throws: (any Error).self) { try await store.restoreBackupData(original) }
    let after = try await store.backupData()
    #expect(after.history.map(\.id) == original.history.map(\.id))
    #expect(after.favorites.map(\.id) == original.favorites.map(\.id))
    #expect(after.timestamps.map(\.id) == original.timestamps.map(\.id))
    #expect(after.listening.map(\.id) == original.listening.map(\.id))
  }
  @Test func fileRetentionKeepsFiveAutomaticGenerationsAndAllManualFiles() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try BackupArchive(settings: AppSettings(), library: data())
    let output = try await Task.detached {
      let manual = try BackupFiles.write(archive, to: root, automatic: false)
      var last = manual
      for _ in 0..<8 { last = try BackupFiles.write(archive, to: root, automatic: true) }
      return (manual, last)
    }.value
    let urls = try FileManager.default.contentsOfDirectory(
      at: BackupFiles.folder(in: root), includingPropertiesForKeys: nil)
    #expect(urls.count == 6)
    #expect(
      urls.map { $0.resolvingSymlinksInPath().path }.contains(
        output.0.resolvingSymlinksInPath().path)
        && urls.map { $0.resolvingSymlinksInPath().path }.contains(
          output.1.resolvingSymlinksInPath().path)
    )
    let decoded = try await Task.detached { try BackupFiles.read(output.1) }.value
    #expect(decoded.library.listening.count == 2)
    let blocker = root.appendingPathComponent("not-a-folder")
    try Data().write(to: blocker)
    await #expect(throws: (any Error).self) {
      try await Task.detached { try BackupFiles.write(archive, to: blocker, automatic: true) }.value
    }
    #expect(FileManager.default.fileExists(atPath: output.0.path))
  }
  @Test func olderBackupsUseDefaultSubtitleAppearanceWithoutLosingOtherSettings() throws {
    var settings = AppSettings()
    settings.advancedMode = true
    let data = try BackupArchive(settings: settings, library: data()).encoded()
    var envelope = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let originalPayload = try #require(envelope["payload"] as? Data)
    var payload = try #require(
      PropertyListSerialization.propertyList(from: originalPayload, format: nil) as? [String: Any])
    var oldSettings = try #require(payload["settings"] as? [String: Any])
    for key in [
      "subtitleFontScale", "liveSubtitleFontScale", "subtitleWrapCharacters",
      "liveSubtitleWrapCharacters",
    ] {
      oldSettings.removeValue(forKey: key)
    }
    payload["settings"] = oldSettings
    let bytes = try PropertyListSerialization.data(
      fromPropertyList: payload, format: .binary, options: 0)
    envelope["payload"] = bytes
    envelope["checksum"] = Data(SHA256.hash(data: bytes))
    let legacy = try PropertyListSerialization.data(
      fromPropertyList: envelope, format: .binary, options: 0)
    let restored = try BackupArchive.decode(legacy)
    #expect(restored.settings.advancedMode)
    #expect(
      restored.settings.subtitleFontScale == 1 && restored.settings.liveSubtitleFontScale == 1)
    #expect(
      restored.settings.subtitleWrapCharacters == 80
        && restored.settings.liveSubtitleWrapCharacters == 80)
  }

}
