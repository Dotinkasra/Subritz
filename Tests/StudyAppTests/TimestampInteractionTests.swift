import Foundation
import Testing
import WebKit
@testable import StudyApp
@testable import StudyCore

private actor TimestampVideoProvider: YouTubeProvider {
  var requests: [String] = []
  func probe(id: String) async throws -> VideoProbe {
    requests.append(id)
    return VideoProbe(id: id, title: "Paper garden", duration: 120, language: "en", automatic_captions: nil)
  }
  func caption(_ probe: VideoProbe) async throws -> Data {
    Data(#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"A robot waits."}]},{"tStartMs":80000,"dDurationMs":5000,"segs":[{"utf8":"The copper tower glows."}]}]}"#.utf8)
  }
  func calls() -> [String] { requests }
}
@MainActor struct TimestampInteractionTests {
  func fixture() throws -> (StudyModel, URL) {
    let (model, root) = try LibraryInteractionTests().libraryModel()
    model.document?.video.id = "abcdefghijk"
    model.settings.aiGrammarEnabled = false
    model.grammarEnabledForVideo = false
    return (model, root)
  }
  func cleanup(_ model: StudyModel, _ root: URL) {
    model.ready = false  // Test teardown is not a user closing a video.
    model.closeVideo()
    try? FileManager.default.removeItem(at: root)
  }
  @Test func bookmarkSnapshotsClickTimeAndCloseRecordsLatestPositionOnce() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.saveBookmark()
    #expect(model.savingBookmark)
    model.saveBookmark() // duplicate event while the write is in flight
    model.seek(1.2)
    let document = try #require(model.document)
    model.closeVideo()
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(!model.savingBookmark && model.libraryError == nil)
    #expect(model.videoTimestamps.count == 2)
    #expect(model.videoTimestamps.first { $0.kind == .bookmark }?.time == 0.1)
    #expect(model.videoTimestamps.first { $0.kind == .resume }?.time == 1.2)
    model.document = document
    model.ready = true
    model.time = 1.8
    model.closeVideo()
    await model.libraryOperation?.value
    #expect(model.videoTimestamps.count == 2)
    #expect(model.videoTimestamps.first { $0.kind == .resume }?.time == 1.8)
    let reopened = try LibraryStore(directory: root)
    #expect(try await reopened.timestamps().count == 2)
  }
  @Test func favoriteSnapshotsSelectedWordTimeAndVideoInsteadOfCurrentPlayback() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let token = try #require(model.timeline?.tokens.first { $0.surface == "study" })
    model.pinDictionary(token)
    model.toggleDisplayedFavorite()
    model.document?.video.id = "lmnopqrstuv"
    model.update(time: 1.1, duration: 2, state: 1)
    await model.libraryOperation?.value
    let favorite = try #require(model.favoriteWords.first)
    let occurrence = try #require(model.videoTimestamps.first { $0.kind == .favorite })
    #expect(occurrence.video.id == "abcdefghijk" && occurrence.time == token.startTime)
    #expect(model.occurrence(of: favorite)?.videoURL == occurrence.videoURL)
    #expect(model.occurrence(of: favorite)?.time == occurrence.time)
  }
  @Test func sameVideoRequestConfirmsSeekWithoutReloadAndCancelLeavesPositionUntouched() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let provider = TimestampVideoProvider()
    model.youtubeProviderOverride = provider
    let video = try #require(model.document?.video)
    let timestamp = VideoTimestamp(video: video, time: 1.45)
    model.update(time: 0.1, duration: 2, state: 1)
    let session = model.session
    #expect(!model.selectTimestamp(timestamp))
    #expect(model.time == 0.1 && model.pendingLibraryPlayback?.time == 1.45)
    model.pendingLibraryPlayback = nil
    #expect(model.time == 0.1 && model.session == session)
    #expect(!model.selectTimestamp(timestamp))
    #expect(model.confirmLibraryPlayback())
    #expect(model.ready && model.playing && model.time == 1.45 && model.session == session)
    #expect(await provider.calls().isEmpty)
    #expect(model.videoTimestamps.isEmpty)
  }
  @Test func differentVideoRecordsExitAndStartsAtSavedTimeAfterConfirmation() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let provider = TimestampVideoProvider()
    model.youtubeProviderOverride = provider
    let timestamp = VideoTimestamp(video: Video(id: "lmnopqrstuv", title: "Paper garden", duration: 120), time: 80.125)
    #expect(!model.selectTimestamp(timestamp))
    #expect(await provider.calls().isEmpty)
    #expect(model.document?.video.id == "abcdefghijk")
    #expect(model.confirmLibraryPlayback())
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.ready && model.time == 80.125 && model.currentLineIndex == 1)
    #expect(model.currentToken?.surface == "The")
    #expect(model.document?.video.id == timestamp.video.id)
    #expect(model.bridge.initialTime == 80.125 && model.bridge.pendingSeekTime == 80.125)
    #expect(model.videoTimestamps.first { $0.kind == .resume }?.video.id == "abcdefghijk")
    #expect(model.videoTimestamps.first { $0.kind == .resume }?.time == 0.1)
  }
  @Test func unloadedVideoOpensDirectlyAndOutdatedDurationClampsToActualDuration() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    model.closeVideo()
    await model.libraryOperation?.value
    model.youtubeProviderOverride = TimestampVideoProvider()
    let timestamp = VideoTimestamp(video: Video(id: "lmnopqrstuv", title: "Paper garden", duration: 500), time: 300)
    #expect(model.selectTimestamp(timestamp) && model.pendingLibraryPlayback == nil)
    await model.loadTask?.value
    await model.libraryOperation?.value
    #expect(model.ready && model.time == 120 && model.bridge.initialTime == 120)
  }
  @Test func failedBookmarkWriteUnlocksButtonAndDoesNotReportSuccess() async throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    try await model.library?.db.execute("DROP TABLE video_timestamps")
    model.saveBookmark()
    await model.libraryOperation?.value
    #expect(!model.savingBookmark && model.libraryError != nil)
    #expect(model.timestampMessage.isEmpty && model.videoTimestamps.isEmpty)
  }
  @Test func blockedOrInvalidTimestampDoesNotCloseVideoOrQueueConfirmation() throws {
    let (model, root) = try fixture()
    defer { cleanup(model, root) }
    let video = try #require(model.document?.video)
    model.isChangingCacheDirectory = true
    #expect(!model.selectTimestamp(VideoTimestamp(video: video, time: 1)))
    model.isChangingCacheDirectory = false
    #expect(!model.selectTimestamp(VideoTimestamp(video: video, time: .nan)))
    #expect(model.pendingLibraryPlayback == nil && model.ready && model.time == 0.1)
  }
  @Test func playerWaitsForReadinessAndTargetSampleAndRejectsOldIframeCallbacks() throws {
    let bridge = PlayerBridge()
    var times: [Double] = []
    bridge.onTime = { t, _, _ in times.append(t) }
    let oldSession = bridge.playbackID
    bridge.prepareForVideo(at: 80.125)
    let session = bridge.playbackID
    bridge.receive(["session": oldSession, "time": 0.0, "duration": 120.0, "state": 2])
    #expect(times.isEmpty)
    bridge.receive(["session": session, "ready": true])
    bridge.receive(["session": session, "time": 0.0, "duration": 120.0, "state": 2])
    #expect(times.isEmpty && bridge.pendingSeekTime == 80.125)
    bridge.receive(["session": session, "time": 80.125, "duration": 120.0, "state": 2])
    #expect(times == [80.125] && bridge.pendingSeekTime == nil)
    bridge.seek(20)
    bridge.receive(["session": session, "time": 80.125, "duration": 120.0, "state": 2])
    #expect(times == [80.125])
    bridge.receive(["session": session, "time": 20.0, "duration": 120.0, "state": 2])
    #expect(times == [80.125, 20])
    bridge.invalidateVideo()
    bridge.receive(["session": session, "time": 0.0, "duration": 120.0, "state": 2])
    #expect(times == [80.125, 20])
  }
  @Test func oldPlayerTeardownDoesNotDetachReplacement() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let old = WKWebView(frame: .zero, configuration: configuration)
    let replacement = WKWebView(frame: .zero, configuration: configuration)
    let bridge = PlayerBridge()
    bridge.webView = replacement
    YouTubePlayer.dismantleNSView(old, coordinator: bridge)
    #expect(bridge.webView === replacement)
    YouTubePlayer.dismantleNSView(replacement, coordinator: bridge)
    #expect(bridge.webView == nil)
  }
}
