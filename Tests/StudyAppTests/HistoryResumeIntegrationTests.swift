import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

private struct ResumeVideoProvider: YouTubeProvider {
  func probe(id: String) async throws -> VideoProbe {
    VideoProbe(id: id, title: "Paper garden", duration: 120, language: "en", automatic_captions: nil)
  }
  func caption(_ probe: VideoProbe) async throws -> Data {
    Data(#"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"A paper robot waits."}]},{"tStartMs":60000,"dDurationMs":2000,"segs":[{"utf8":"A blue lantern glows."}]}]}"#.utf8)
  }
}
private struct ResumeTestDictionary: DictionaryProvider {
  func lookup(_ token: Token) async -> DictionaryEntry? { nil }
  func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    expressions.map { _ in nil }
  }
}
private extension LibraryStore {
  func executeResumeTestSQL(_ sql: String) throws { try db.execute(sql) }
}

@MainActor struct HistoryResumeIntegrationTests {
  let video = Video(id: "abcdefghijk", title: "Paper garden", duration: 120)
  func fixture() throws -> (StudyModel, URL, String) {
    let (model, _, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    model.library = try LibraryStore(directory: root)
    model.settings.aiGrammarEnabled = false
    model.youtubeProviderOverride = ResumeVideoProvider()
    model.dictionaryProviderOverride = ResumeTestDictionary()
    return (model, root, suite)
  }
  func cleanup(_ model: StudyModel, _ root: URL, _ suite: String) {
    model.ready = false
    model.closeVideo()
    model.defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  func seed(_ model: StudyModel, time: Double) async throws {
    let library = try #require(model.library)
    let date = Date().addingTimeInterval(-86400)
    try await library.record(video, at: date)
    try await library.saveHistoryPosition(videoID: video.id,
      position: .init(time: time, duration: 120, date: date))
    try await model.refreshLibrary()
  }
  func load(_ model: StudyModel, url: String? = nil) async throws {
    model.url = url ?? video.watchURL
    #expect(model.load())
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.ready && model.error == nil)
  }
  func sample(_ model: StudyModel, _ time: Double, _ uptime: Double, state: Int = 1) {
    model.bridge.receive(["session": model.bridge.playbackID, "time": time,
      "duration": 120.0, "state": state], now: uptime, date: Date())
  }

  @Test func urlAndHistoryBothResumeAndRevisitUpdatesTheViewingDay() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await seed(model, time: 60.125)
    let yesterday = try #require(model.videoHistory.first?.lastOpened)
    try await load(model, url: "https://youtu.be/abcdefghijk")
    #expect(model.time == 60.125 && model.bridge.initialTime == 60.125)
    #expect(model.videoHistory.first!.lastOpened > yesterday)
    #expect(model.videoHistory.first?.lastPosition == 60.125)
    model.closeVideo() // No iframe acknowledgement: do not replace with an invented position.
    await model.libraryOperation?.value
    let item = try #require(model.videoHistory.first)
    #expect(model.selectHistory(item))
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.time == 60.125 && model.bridge.pendingSeekTime == 60.125)
    model.closeVideo()
    await model.libraryOperation?.value
    try await load(model, url: video.watchURL + "&feature=shared")
    #expect(model.time == 60.125 && model.videoHistory.count == 1)
  }

  @Test func periodicCheckpointSurvivesRestartWithoutCloseAndCloseFlushesTheLatestSample() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await load(model)
    sample(model, 10, 0)
    await model.libraryOperation?.value
    sample(model, 14.5, 4.5)
    // Simulate abrupt termination: reopen the on-disk DB without running close.
    let crashRecovery = try LibraryStore(directory: root)
    #expect(try await crashRecovery.historyItem(for: video.id)?.lastPosition == 10)
    sample(model, 15, 5)
    await model.libraryOperation?.value
    #expect(try await crashRecovery.historyItem(for: video.id)?.lastPosition == 15)
    sample(model, 15.125, 5.125)
    model.update(time: 99, duration: 120, state: 1) // Interpolated/UI state is not authoritative.
    model.closeVideo()
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(!model.hasOpenVideo && model.pendingHistoryPositions.isEmpty)
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.history().count == 1)
    #expect(try await reopened.historyItem(for: video.id)?.lastPosition == 15.125)
    let timestamps = try await reopened.timestamps()
    #expect(timestamps.count == 1 && timestamps.first?.kind == .resume && timestamps.first?.time == 15.125)
  }

  @Test func osTerminationWaitsForQueuedWritesAndFlushesBeforeClearingTheVideo() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await load(model)
    sample(model, 21, 1)
    sample(model, 21.25, 1.25)
    // Exercise the same shutdown routine called by applicationShouldTerminate.
    await model.prepareForApplicationTermination()
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.historyItem(for: video.id)?.lastPosition == 21.25)
    #expect(try await reopened.timestamps().first?.time == 21.25)
    #expect(model.historyPositionSaveError == nil && model.libraryError == nil)
    #expect(!model.ready && model.document == nil && model.time == 0)
  }

  @Test func failedInitialSeekAndEarlyClosePreserveBothExistingResumeRecords() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await seed(model, time: 60)
    let library = try #require(model.library)
    let old = VideoTimestamp(video: video, time: 60, kind: .resume)
    try await library.saveTimestamp(old)
    try await load(model)
    let session = model.bridge.playbackID
    model.bridge.receive(["session": session, "ready": true], now: 0)
    sample(model, 0, 1, state: 5)
    sample(model, 0, 2, state: 2)
    sample(model, 0, 9) // Seek timeout: a fallback 0 must never become the saved location.
    #expect(model.error != nil && model.resumeTracker.latest == nil)
    await model.prepareForApplicationTermination()
    #expect(try await library.historyItem(for: video.id)?.lastPosition == 60)
    #expect(try await library.timestamps().first?.time == 60)
    #expect(try await library.timestamps().first?.savedAt == old.savedAt)
    // A late callback from the destroyed iframe cannot change either record.
    model.bridge.receive(["session": session, "time": 100.0, "duration": 120.0, "state": 1])
    #expect(model.resumeTracker.latest == nil)
  }

  @Test func unacknowledgedSeekSavesTheLastConfirmedPositionInsteadOfThePreviewTarget() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await load(model)
    sample(model, 25, 0)
    sample(model, 25.125, 0.125)
    model.seek(90)
    #expect(model.time == 90)
    sample(model, 25.125, 1)
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(try await model.library?.historyItem(for: video.id)?.lastPosition == 25.125)
    #expect(model.videoTimestamps.first?.time == 25.125)
  }

  @Test func explicitBookmarkAtZeroOverridesHistoryAndGenuineZeroCanBeSaved() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await seed(model, time: 80)
    let bookmark = VideoTimestamp(video: video, time: 0)
    #expect(model.selectTimestamp(bookmark))
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.time == 0 && model.videoHistory.first?.lastPosition == 80)
    sample(model, 0, 0, state: 2)
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(model.videoHistory.first?.lastPosition == 0)
  }

  @Test func writeFailureKeepsLastGoodDiskValueAndRetainsSnapshotForQuitRetry() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await seed(model, time: 60)
    try await load(model)
    let library = try #require(model.library)
    try await library.executeResumeTestSQL("CREATE TRIGGER fail_position BEFORE UPDATE ON video_history BEGIN SELECT RAISE(ABORT,'test'); END")
    sample(model, 60, 0)
    sample(model, 62.25, 2.25)
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(model.historyPositionSaveError != nil && !model.pendingHistoryPositions.isEmpty)
    #expect(try await library.historyItem(for: video.id)?.lastPosition == 60)
    try await library.executeResumeTestSQL("DROP TRIGGER fail_position")
    await model.prepareForApplicationTermination() // Already closed, but failed writes still retry.
    #expect(model.historyPositionSaveError == nil && model.pendingHistoryPositions.isEmpty)
    #expect(try await library.historyItem(for: video.id)?.lastPosition == 62.25)
  }

  @Test func datesGroupAtLocalMidnightAndRowsAreSortedByLatestView() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
    let older = VideoHistoryItem(video: video, lastOpened: midnight.addingTimeInterval(-1))
    let newer = VideoHistoryItem(video: Video(id: "lmnopqrstuv", title: "Lantern", duration: 90),
      lastOpened: midnight)
    let newest = VideoHistoryItem(video: Video(id: "zbcdefghijk", title: "Tower", duration: 90),
      lastOpened: midnight.addingTimeInterval(1))
    let groups = HistoryDayGroup.grouped([older, newer, newest], calendar: calendar)
    #expect(groups.count == 2 && groups.first?.day == midnight)
    #expect(groups.first?.videos.map(\.id) == [newest.id, newer.id])
    #expect(groups.last?.videos.map(\.id) == [older.id])
  }

  @Test func iframeMustConfirmEvenShortSeeksAndCanRecoverAfterATimeout() {
    let bridge = PlayerBridge()
    var confirmed: [Double] = []
    bridge.onResumePosition = { position, _, _ in confirmed.append(position.time) }
    bridge.prepareForVideo(at: 0.3)
    let session = bridge.playbackID
    bridge.receive(["session": session, "ready": true], now: 0)
    for state in [-1, 5, 2] {
      bridge.receive(["session": session, "time": 0.0, "duration": 120.0, "state": state], now: 1)
    }
    #expect(confirmed.isEmpty && bridge.pendingSeekTime == 0.3)
    bridge.receive(["session": session, "time": 0.3, "duration": 120.0, "state": 2], now: 2)
    #expect(confirmed == [0.3])
    bridge.seek(90)
    bridge.receive(["session": session, "ready": true], now: 10)
    bridge.receive(["session": session, "time": 0.0, "duration": 120.0, "state": 1], now: 19)
    #expect(bridge.pendingSeekTime == nil && confirmed == [0.3])
    bridge.receive(["session": session, "time": 90.0, "duration": 120.0, "state": 2], now: 20)
    #expect(confirmed == [0.3, 90])
    for (time, duration) in [(Double.nan, 120.0), (121.0, 120.0), (0.0, 0.0)] {
      bridge.receive(["session": session, "time": time, "duration": duration, "state": 2], now: 21)
    }
    bridge.invalidateVideo()
    bridge.receive(["session": session, "time": 100.0, "duration": 120.0, "state": 1], now: 22)
    #expect(confirmed == [0.3, 90])
  }

  @Test func outdatedPositionClampsOnlyAfterActualDurationIsKnown() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    let library = try #require(model.library)
    let oldVideo = Video(id: video.id, title: video.title, duration: 500)
    try await library.record(oldVideo)
    try await library.saveHistoryPosition(videoID: video.id,
      position: .init(time: 300, duration: 500, date: Date()))
    try await load(model)
    #expect(model.time == 120 && model.videoHistory.first?.lastPosition == 300)
    sample(model, 120, 0, state: 0)
    await model.libraryOperation?.value
    #expect(model.videoHistory.first?.lastPosition == 120)
    model.closeVideo()
    await model.libraryOperation?.value
  }

  @Test func deletingHistoryDuringPlaybackDoesNotResurrectItOrChangeBookmarksAndFavorites() async throws {
    let (model, root, suite) = try fixture()
    defer { cleanup(model, root, suite) }
    try await load(model)
    let token = try #require(model.timeline?.tokens.first { $0.lexical })
    let word = FavoriteWord(token: token, entry: nil, video: video)
    let bookmark = VideoTimestamp(video: video, time: 50)
    let library = try #require(model.library)
    try await library.saveFavorite(word)
    try await library.saveTimestamp(bookmark)
    sample(model, 20, 0)
    await model.libraryOperation?.value
    let item = try #require(model.videoHistory.first)
    model.removeHistory(item)
    await model.libraryOperation?.value
    sample(model, 25, 5)
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(try await library.history().isEmpty)
    let savedBookmark = try #require(try await library.timestamps().first { $0.id == bookmark.id })
    #expect(savedBookmark.time == 50 && savedBookmark.savedAt == bookmark.savedAt)
    let savedWord = try #require(try await library.favorites().first)
    #expect(savedWord.id == word.id && savedWord.savedAt == word.savedAt)
    #expect(savedWord.sourceTime == word.sourceTime)
    #expect(try await library.timestamps().first { $0.kind == .favorite }?.time == word.sourceTime)
  }
}
