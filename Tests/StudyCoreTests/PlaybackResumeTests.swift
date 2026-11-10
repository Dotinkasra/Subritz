import Foundation
import Testing
@testable import StudyCore

struct PlaybackResumeTests {
  let date = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func checkpointsUseConfirmedSamplesAndThrottleWithoutLosingTheFinalPosition() {
    var tracker = PlaybackResumeTracker()
    func sample(_ time: Double, _ uptime: Double, _ state: Int = 1) -> PlaybackResumePosition? {
      tracker.receive(time: time, duration: 120, state: state, uptime: uptime,
        date: date.addingTimeInterval(uptime))
    }
    #expect(sample(10, 0)?.time == 10)
    for i in 1..<100 { #expect(sample(10 + Double(i) / 20, Double(i) / 20) == nil) }
    #expect(sample(15, 5)?.time == 15)
    #expect(sample(15.1, 5.1, 2)?.time == 15.1) // Pause flushes immediately.
    #expect(sample(15.1, 50, 2) == nil) // A paused player does not repeatedly write.
    #expect(sample(15.2, 50.1)?.time == 15.2)
    #expect(sample(15.25, 50.15) == nil)
    #expect(tracker.latest?.time == 15.25) // Closing must flush this, not 15.2.
    #expect(sample(120, 51, 0)?.time == 120)
    #expect(sample(0, 52, 1) == nil)
    #expect(tracker.latest?.time == 0) // A genuine replay from 0 is valid.
  }
  @Test func invalidUnstartedCuedAndBufferingSamplesCannotOverwriteAGoodPosition() {
    var tracker = PlaybackResumeTracker()
    let good = tracker.receive(time: 50, duration: 120, state: 1, uptime: 0, date: date)
    for (time, duration, state, uptime) in [
      (Double.nan, 120.0, 1, 6.0), (Double.infinity, 120, 1, 6),
      (-1, 120, 1, 6), (121, 120, 1, 6), (0, 0, 2, 6),
      (0, Double.infinity, 2, 6), (0, 120, -1, 6), (0, 120, 5, 6),
      (0, 120, 3, 6), (60, 120, 1, Double.nan),
    ] {
      #expect(tracker.receive(time: time, duration: duration, state: state,
        uptime: uptime, date: date) == nil)
      #expect(tracker.latest == good)
    }
  }

  @Test func reopeningPreservesPositionAndEachVideoHasExactlyOneReplaceablePosition() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    let other = Video(id: "lmnopqrstuv", title: "Copper tower", duration: 60)
    try await store.record(video, at: date)
    try await store.record(other, at: date)
    try await store.saveHistoryPosition(videoID: video.id,
      position: .init(time: 85.25, duration: 120, date: date.addingTimeInterval(1)))
    try await store.record(video, at: date.addingTimeInterval(2))
    #expect(try await store.historyItem(for: video.id)?.lastPosition == 85.25)
    // Rewind is an update, not another row, and must not be treated as stale.
    try await store.saveHistoryPosition(videoID: video.id,
      position: .init(time: 20, duration: 120, date: date.addingTimeInterval(3)))
    let reopened = try LibraryStore(directory: root)
    let history = try await reopened.history()
    #expect(history.count == 2 && history.first?.id == video.id)
    #expect(history.first?.lastPosition == 20)
    #expect(history.first?.positionUpdatedAt == date.addingTimeInterval(3))
    #expect(history.last?.lastPosition == nil)
    for time in [-1.0, .nan, .infinity, 121] {
      await #expect(throws: (any Error).self) {
        try await store.saveHistoryPosition(videoID: video.id,
          position: .init(time: time, duration: 120, date: date.addingTimeInterval(4)))
      }
    }
    #expect(try await store.historyItem(for: video.id)?.lastPosition == 20)
    try await store.removeHistory(video.id)
    try await store.saveHistoryPosition(videoID: video.id,
      position: .init(time: 21, duration: 120, date: date.addingTimeInterval(5)))
    #expect(try await store.historyItem(for: video.id) == nil)
  }

  @Test func oldHistoryMigratesExitPositionWithoutChangingTimestampsOrFavorites() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    let legacy = try JSONDecoder().decode(VideoHistoryItem.self,
      from: Data(#"{"video":{"id":"abcdefghijk","title":"Paper garden","duration":120},"lastOpened":0}"#.utf8))
    #expect(legacy.lastPosition == nil && legacy.positionUpdatedAt == nil)
    try await store.record(video, at: date)
    let resume = VideoTimestamp(video: video, time: 48.125, kind: .resume, savedAt: date)
    let bookmark = VideoTimestamp(video: video, time: 80, savedAt: date)
    try await store.saveTimestamp(resume)
    try await store.saveTimestamp(bookmark)
    let before = try await store.backupData()
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.historyItem(for: video.id)?.lastPosition == 48.125)
    #expect(try await reopened.historyItem(for: video.id)?.lastOpened == date)
    #expect(try await reopened.timestamps().map(\.id) == before.timestamps.map(\.id))
    try await reopened.removeTimestamp(resume.id)
    #expect(try await reopened.historyItem(for: video.id)?.lastPosition == 48.125)
    try await reopened.saveHistoryPosition(videoID: video.id,
      position: .init(time: 60, duration: 120, date: date.addingTimeInterval(5)))
    #expect(try await reopened.timestamps().map(\.id) == [bookmark.id])
    #expect(try await reopened.favorites().isEmpty)
  }

  @Test func backupsKeepIndependentHistoryPositionsAndOldBackupResumePositions() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
    let legacy = LibraryBackupData(history: [.init(video: video, lastOpened: date)],
      timestamps: [.init(video: video, time: 45, kind: .resume, savedAt: date)])
    try await store.restoreBackupData(legacy)
    #expect(try await store.historyItem(for: video.id)?.lastPosition == 45)
    try await store.saveHistoryPosition(videoID: video.id,
      position: .init(time: 70, duration: 120, date: date.addingTimeInterval(5)))
    let archive = try await BackupArchive(settings: AppSettings(), library: store.backupData())
    let decoded = try BackupArchive.decode(archive.encoded())
    try await store.restoreBackupData(.init())
    try await store.restoreBackupData(decoded.library)
    let restored = try LibraryStore(directory: root)
    #expect(try await restored.historyItem(for: video.id)?.lastPosition == 70)
    #expect(try await restored.timestamps().first?.time == 45)
    var bad = decoded.library
    bad.history[0].lastPosition = -.infinity
    await #expect(throws: (any Error).self) { try await restored.restoreBackupData(bad) }
    #expect(try await restored.historyItem(for: video.id)?.lastPosition == 70)
  }
}
