import Foundation
import Testing
@testable import StudyCore

private extension LibraryStore {
  func archiveTestSQL(_ sql: String) throws { try db.execute(sql) }
}
struct FavoriteArchiveTests {
  func word() throws -> FavoriteWord {
    try FavoriteExportTests().word("Lantern", at: Date(timeIntervalSince1970: 1_800_000_000),
      video: Video(id: "abcdefghijk", title: "Paper garden", duration: 120))
  }
  func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
  }
  @Test func archiveAndRestorePersistWithoutChangingRegistrationDictionaryOrOccurrences() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try word()
    try await store.saveFavorite(original)
    let timestamps = try await encoded(store.timestamps())
    let date = original.savedAt.addingTimeInterval(100)
    try await store.setFavoriteArchived(" LANTERN ", archived: true, at: date)
    let reopened = try LibraryStore(directory: root)
    var expected = original
    expected.archivedAt = date
    #expect(try await encoded(reopened.favorites().first) == encoded(Optional(expected)))
    #expect(try await encoded(reopened.timestamps()) == timestamps)
    try await reopened.setFavoriteArchived(original.id, archived: true, at: date.addingTimeInterval(50))
    #expect(try await reopened.favorites().first?.archivedAt == date) // Idempotent duplicate action.
    try await reopened.setFavoriteArchived(original.id, archived: false)
    let restored = try LibraryStore(directory: root)
    #expect(try await encoded(restored.favorites().first) == encoded(Optional(original)))
    #expect(try await encoded(restored.timestamps()) == timestamps)
  }
  @Test func failedArchiveAndMissingWordDoNotLoseOrRecreateAnyData() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try word()
    try await store.saveFavorite(original)
    try await store.archiveTestSQL("CREATE TRIGGER fail_archive BEFORE UPDATE ON favorite_words BEGIN SELECT RAISE(ABORT,'test'); END")
    await #expect(throws: (any Error).self) {
      try await store.setFavoriteArchived(original.id, archived: true)
    }
    #expect(try await encoded(store.favorites().first) == encoded(Optional(original)))
    #expect(try await store.timestamps().count == 1)
    try await store.archiveTestSQL("DROP TRIGGER fail_archive")
    try await store.setFavoriteArchived(original.id, archived: true)
    try await store.removeFavorite(original.id)
    await #expect(throws: (any Error).self) {
      try await store.setFavoriteArchived(original.id, archived: false)
    }
    #expect(try await store.favorites().isEmpty)
    #expect(try await store.timestamps().isEmpty)
  }
  @Test func archiveIsIncludedInBackupsAndOlderFavoritesDecodeAsActive() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try word()
    var old = try #require(JSONSerialization.jsonObject(with: encoded(original)) as? [String: Any])
    old.removeValue(forKey: "archivedAt")
    let decoded = try JSONDecoder().decode(FavoriteWord.self,
      from: JSONSerialization.data(withJSONObject: old))
    #expect(!decoded.isArchived && decoded.savedAt == original.savedAt)
    try await store.saveFavorite(original)
    try await store.setFavoriteArchived(original.id, archived: true)
    let before = try await store.backupData()
    let archive = try BackupArchive(settings: AppSettings(), library: before).encoded()
    try await store.restoreBackupData(.init())
    try await store.restoreBackupData(BackupArchive.decode(archive).library)
    let restored = try await store.backupData()
    #expect(try encoded(restored.favorites) == encoded(before.favorites))
    #expect(try encoded(restored.timestamps) == encoded(before.timestamps))
    var invalid = restored
    invalid.favorites[0].archivedAt = Date(timeIntervalSince1970: .infinity)
    #expect(throws: (any Error).self) { try invalid.validate() }
  }
}
