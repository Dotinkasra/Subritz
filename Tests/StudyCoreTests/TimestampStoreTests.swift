import Foundation
import Testing
@testable import StudyCore

struct TimestampStoreTests {
  let video = Video(id: "abcdefghijk", title: "Copper tower", duration: 2000)
  @Test func globalCapDoesNotImposeAPerVideoLimitAndSurvivesRestartAndCacheClear() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    for i in 0..<1005 {
      try await store.saveTimestamp(VideoTimestamp(video: video, time: Double(i),
        savedAt: Date(timeIntervalSince1970: Double(i))))
    }
    let items = try await store.timestamps()
    #expect(items.count == 1000 && items.first?.time == 1004 && items.last?.time == 5)
    #expect(Set(items.map(\.id)).count == 1000 && Set(items.map { $0.video.id }).count == 1)
    #expect(items.first?.videoURL == video.watchURL)
    try await store.removeHistory(video.id)
    try await StudyStore(directory: root).clear()
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.timestamps().count == 1000)
    let first = try #require(items.first)
    try await reopened.removeTimestamp(first.id)
    #expect(try await reopened.timestamps().count == 999)
  }
  @Test func manualBookmarksAreIndependentAndResumeUpdatesOnlyItsOwnVideo() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    for _ in 0..<2 { try await store.saveTimestamp(VideoTimestamp(video: video, time: 12.25)) }
    try await store.saveTimestamp(VideoTimestamp(video: video, time: 20, kind: .resume))
    try await store.saveTimestamp(VideoTimestamp(video: video, time: 30.5, kind: .resume))
    let other = Video(id: "lmnopqrstuv", title: "Paper garden", duration: 100)
    try await store.saveTimestamp(VideoTimestamp(video: other, time: 9, kind: .resume))
    let items = try await store.timestamps()
    #expect(items.count == 4)
    #expect(items.filter { $0.kind == .bookmark }.count == 2)
    #expect(items.first { $0.kind == .resume && $0.video.id == video.id }?.time == 30.5)
    #expect(items.first { $0.video.id == other.id }?.time == 9)
  }
  @Test func favoriteAndOccurrenceAreSavedAtomicallyAndRemovalKeepsOtherKinds() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var token = EijiroTests().token("copper")
    token.startTime = 42.125
    let favorite = FavoriteWord(token: token, entry: nil, video: video)
    try await store.saveFavorite(favorite)
    try await store.saveTimestamp(VideoTimestamp(video: video, time: 42.125))
    let items = try await store.timestamps()
    let occurrence = try #require(items.first { $0.kind == .favorite })
    #expect(occurrence.time == token.startTime && occurrence.videoURL == video.watchURL)
    #expect(occurrence.wordID == favorite.id)
    try await store.removeFavorite(favorite.id)
    #expect(try await store.timestamps().map(\.kind) == [.bookmark])
    let db = try SQLiteDatabase(url: root.appendingPathComponent("library.sqlite"))
    try db.execute("DROP TABLE video_timestamps")
    await #expect(throws: (any Error).self) { try await store.saveFavorite(favorite) }
    #expect(try await store.favorites().isEmpty)
  }
  @Test func oldFavoriteOccurrencesMigrateOnceWithoutResurrection() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try SQLiteDatabase(url: root.appendingPathComponent("library.sqlite"))
    try db.execute("CREATE TABLE favorite_words(word TEXT PRIMARY KEY,saved REAL NOT NULL,payload TEXT NOT NULL)")
    let word = FavoriteWord(token: EijiroTests().token("copper"), entry: nil, video: video)
    let encoded = String(decoding: try JSONEncoder().encode(word), as: UTF8.self)
    try db.execute("INSERT INTO favorite_words VALUES(?,?,?)", values: [word.id, "1", encoded])
    try db.execute("PRAGMA user_version=1")
    let store = try LibraryStore(directory: root)
    let timestamp = try #require(try await store.timestamps().first)
    #expect(timestamp.kind == .favorite && timestamp.video.id == video.id)
    #expect(try db.rows("PRAGMA user_version")[0][0] == "2")
    try await store.removeTimestamp(timestamp.id)
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.timestamps().isEmpty)
    #expect(try await reopened.favorites().count == 1)
  }
  @Test func invalidTimesRollbackAndValidTimesAreClamped() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    for time in [-1, Double.nan, Double.infinity] {
      await #expect(throws: (any Error).self) { try await store.saveTimestamp(VideoTimestamp(video: video, time: time)) }
    }
    #expect(try await store.timestamps().isEmpty)
    try await store.saveTimestamp(VideoTimestamp(video: video, time: 5000))
    #expect(try await store.timestamps().first?.time == video.duration)
    #expect(PlaybackTime.format(6814) == "1:53:34")
  }
}
