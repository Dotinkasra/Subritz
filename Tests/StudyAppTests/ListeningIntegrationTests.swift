import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor private final class ListeningRecognizer: LiveSpeechRecognizing {
  var update: ((LiveSpeechUpdate) -> Void)?
  var final: LiveSpeechUpdate?
  func start(
    source: SpeechAudioSource, microphoneID: String,
    onUpdate: @escaping @MainActor (LiveSpeechUpdate) -> Void,
    onStatus: @escaping @MainActor (String) -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) async throws { update = onUpdate }
  func stop(finalize: Bool) async {
    if finalize, let final {
      update?(final)
      self.final = nil
    }
  }
}

@MainActor struct ListeningIntegrationTests {
  func fixture() throws -> (StudyModel, URL) {
    let (model, _, _) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    model.library = try LibraryStore(directory: root)
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":10000,"segs":[{"utf8":"A paper robot carries a blue lantern."}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "authored")
    model.document = StudyDocument(
      video: Video(id: "authored", title: "Authored fixture", duration: 10), rawCaption: raw,
      sentences: sentences)
    model.timeline = Timeline(sentences)
    model.ready = true
    model.grammarEnabledForVideo = false
    return (model, root)
  }
  @Test func displayUpdatesPinsAndSearchDoNotDriveOrDisableListeningAndCloseSavesIt() async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<30 { model.update(time: Double(i) / 30, duration: 10, state: 1) }
    #expect(!model.listeningBuffer.hasChanges)  // 30 Hz display clock is not evidence.
    let date = Date()
    func sample(_ t: Double) -> ListeningPlaybackSample {
      .init(
        mediaTime: t, uptime: t, date: date.addingTimeInterval(t), state: 1, rate: 1, audible: true)
    }
    model.recordListeningPlayback(sample(0))
    model.toggleSubtitleScrollPin()
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("robot")
    model.realtime = false
    var invalidations = 0
    let observation = model.objectWillChange.sink { invalidations += 1 }
    for tick in 1...20 { model.recordListeningPlayback(sample(Double(tick) / 20)) }
    #expect(invalidations == 0)  // Recording itself must not rebuild the UI.
    #expect(model.listeningBuffer.hasChanges && model.listeningSaveTask == nil)
    model.closeVideo()
    await model.listeningSaveTask?.value
    let bins = try await model.listeningTotals(in: .init(period: .day, anchor: date))
    #expect(abs(bins.reduce(0) { $0 + $1.total } - 1) < 0.00001)
    #expect(model.listeningSaveError == nil)
    withExtendedLifetime(observation) {}
  }
  @Test func bridgeReportsAudibilityFromAuthoritativeSamplesAndRejectsOldIframes() {
    let bridge = PlayerBridge()
    var received: [ListeningPlaybackSample] = []
    bridge.onListeningSample = { received.append($0) }
    func message(_ muted: Bool, volume: Double = 100, session: String? = nil) -> [String: Any] {
      [
        "session": session ?? bridge.playbackID, "time": 1.0, "duration": 10.0, "state": 1,
        "rate": 2.0,
        "muted": muted, "volume": volume,
      ]
    }
    bridge.receive(message(false))
    bridge.receive(message(true))
    bridge.receive(message(false, volume: 0))
    bridge.receive(message(false, session: "obsolete"))
    #expect(received.map(\.audible) == [true, false, false])
    #expect(received.first?.rate == 2)
  }
  @Test func livePartialsFinalizeOnPauseAndCachedHistoryDoesNotCountAgain() async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    model.closeVideo()
    await model.listeningSaveTask?.value
    let engine = ListeningRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech()
    await model.liveSpeechOperation?.value
    engine.update?(.init(text: "A paper robot.", start: 0, end: 2, isFinal: false))
    engine.update?(.init(text: "A blue robot.", start: 0, end: 2, isFinal: false))
    engine.final = .init(text: "A blue robot walks.", start: 0, end: 3, isFinal: true)
    let session = try #require(model.liveSpeechSessionID)
    model.configureLiveSpeech(listen: false)
    await model.liveSpeechOperation?.value
    await model.listeningSaveTask?.value
    let date = Date()
    let first = try await model.listeningTotals(in: .init(period: .day, anchor: date))
    #expect(first.reduce(0) { $0 + $1.speechSeconds } == 3)
    model.closeVideo()
    await model.liveSpeechShutdown?.value
    engine.update?(.init(text: "Obsolete input.", start: 3, end: 8, isFinal: true))
    model.restoreLiveSpeech(session)
    let restored = try await model.listeningTotals(in: .init(period: .day, anchor: date))
    #expect(restored.reduce(0) { $0 + $1.speechSeconds } == 3)
    model.closeVideo()
    await model.liveSpeechShutdown?.value
  }
  @Test func failedPersistenceRetainsPendingRecordsForRetry() async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try SQLiteDatabase(url: root.appendingPathComponent("library.sqlite"))
    try db.execute("DROP TABLE listening_spans")
    let date = Date()
    model.listeningBuffer.append(DateInterval(start: date, duration: 3), source: .video)
    model.flushListeningRecords()
    await model.listeningSaveTask?.value
    #expect(model.listeningSaveError != nil && model.listeningBuffer.hasChanges)
    _ = try LibraryStore(directory: root)  // Recreate the test-only missing table.
    model.flushListeningRecords()
    await model.listeningSaveTask?.value
    let bins = try await model.listeningTotals(in: .init(period: .day, anchor: date))
    #expect(bins.reduce(0) { $0 + $1.total } == 3 && model.listeningSaveError == nil)
    model.closeVideo()
    await model.listeningSaveTask?.value
  }
}
