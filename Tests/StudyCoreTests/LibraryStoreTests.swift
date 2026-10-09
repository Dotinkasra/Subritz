import Foundation
import Testing

@testable import StudyCore

struct LibraryStoreTests {
  @Test func historyIsUniqueRecentAndCappedAt100AcrossRestart() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    for i in 0..<105 {
      try await store.record(
        Video(id: "video\(i)", title: "Title \(i)", duration: 10),
        at: Date(timeIntervalSince1970: Double(i)))
    }
    var history = try await store.history()
    #expect(history.count == 100 && history.first?.id == "video104" && history.last?.id == "video5")
    let updated = Video(
      id: "video5", title: "Updated", duration: 12, thumbnailURL: "https://i.ytimg.com/new.jpg")
    try await store.record(updated, at: Date(timeIntervalSince1970: 200))
    let reopened = try LibraryStore(directory: root)
    history = try await reopened.history()
    #expect(history.count == 100 && history.first?.video.title == "Updated")
    #expect(history.filter { $0.id == "video5" }.count == 1)
    #expect(history.first?.video.thumbnailURL == updated.thumbnailURL)
    try await reopened.record(
      Video(id: "video5", title: "No thumbnail in old metadata", duration: 12),
      at: Date(timeIntervalSince1970: 300))
    #expect(try await reopened.history().first?.video.thumbnailURL == updated.thumbnailURL)
  }
  @Test func cacheMigrationRunsOnceAndDoesNotResurrectDeletedHistory() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try StudyStore(directory: root)
    let sentences = try CoreTests().parse("word_level")
    let raw = try CoreTests().fixture("word_level")
    let doc = StudyDocument(
      video: Video(id: "abcdefghijk", title: "Cached title", duration: 2), rawCaption: raw,
      sentences: sentences)
    try await cache.save(doc, fingerprint: "local-model", limit: 1_000_000)
    try await cache.save(doc, fingerprint: "codex-model", limit: 1_000_000)
    let recent = try await cache.recentHistory()
    #expect(recent.count == 1)
    let library = try LibraryStore(directory: root)
    try await library.seedHistoryIfNeeded(recent)
    #expect(try await library.history().first?.video.title == "Cached title")
    try await library.removeHistory("abcdefghijk")
    try await library.seedHistoryIfNeeded(recent)
    #expect(try await library.history().isEmpty)
  }
  @Test func favoritesPersistDefinitionAndDeduplicateCaseIndependentlyOfCache() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try LibraryStore(directory: root)
    var token = try CoreTests().parse("word_level")[0].tokens[0]
    token.surface = "Example"
    var word = FavoriteWord(
      token: token, entry: DictionaryEntry(definition: "詳細\n例文", shortGloss: "自作保存義A、自作保存義B"),
      video: Video(id: "abcdefghijk", title: "Video", duration: 2))
    try await library.saveFavorite(word)
    token.surface = "example"
    word = FavoriteWord(
      token: token, entry: DictionaryEntry(definition: "更新した詳細", shortGloss: "自作更新義"), video: nil)
    try await library.saveFavorite(word)
    let cache = try StudyStore(directory: root)
    try await cache.clear()
    let reopened = try LibraryStore(directory: root)
    let favorites = try await reopened.favorites()
    #expect(favorites.count == 1 && favorites[0].id == "example")
    #expect(favorites[0].shortGloss == "自作更新義" && favorites[0].definition == "更新した詳細")
    try await reopened.removeFavorite(" EXAMPLE ")
    #expect(try await reopened.favorites().isEmpty)
  }
  @Test func seedDoesNotOverwriteNewerUserHistoryAndCacheClearKeepsLibrary() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try LibraryStore(directory: root)
    let video = Video(id: "abcdefghijk", title: "New", duration: 2)
    try await library.record(video, at: Date(timeIntervalSince1970: 100))
    let old = VideoHistoryItem(
      video: Video(id: video.id, title: "Old", duration: 2),
      lastOpened: Date(timeIntervalSince1970: 1))
    try await library.seedHistoryIfNeeded([old])
    try await StudyStore(directory: root).clear()
    #expect(try await library.history().first?.video.title == "New")
  }
  @Test func oldMetadataAndThumbnailFallbackAreCompatible() throws {
    let old = try JSONDecoder().decode(
      Video.self, from: Data(#"{"id":"abcdefghijk","title":"Old","duration":2}"#.utf8))
    #expect(old.thumbnailURL == nil)
    #expect(
      old.thumbnailImageURL?.absoluteString == "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
    let probe = try JSONDecoder().decode(
      VideoProbe.self,
      from: Data(
        #"{"id":"abcdefghijk","title":"New","thumbnail":"https://i.ytimg.com/image.jpg"}"#.utf8))
    #expect(probe.video.thumbnailImageURL?.absoluteString == "https://i.ytimg.com/image.jpg")
    #expect(Video(id: "invalid-id/extra", title: "Bad", duration: 0).thumbnailImageURL == nil)
  }
}
