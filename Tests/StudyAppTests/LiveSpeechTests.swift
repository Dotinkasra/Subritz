import Foundation
import AVFoundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor private final class TestSpeechRecognizer: LiveSpeechRecognizing {
  var updates: ((LiveSpeechUpdate) -> Void)?
  var failure: ((String) -> Void)?
  var starts: [(SpeechAudioSource, String)] = []
  var stops: [Bool] = []
  var finalOnStop: LiveSpeechUpdate?
  func start(source: SpeechAudioSource, microphoneID: String,
    onUpdate: @escaping @MainActor (LiveSpeechUpdate) -> Void,
    onStatus: @escaping @MainActor (String) -> Void,
    onFailure: @escaping @MainActor (String) -> Void) async throws {
    updates = onUpdate; failure = onFailure; starts.append((source, microphoneID))
    onStatus("Authored recognition ready")
  }
  func stop(finalize: Bool) async {
    stops.append(finalize)
    if finalize, let finalOnStop { updates?(finalOnStop); self.finalOnStop = nil }
  }
}

@MainActor struct LiveSpeechTests {
  func model() -> StudyModel {
    let defaults = UserDefaults(suiteName: "Subritz.LiveSpeechTests." + UUID().uuidString)!
    return StudyModel(prepareStorage: false, defaults: defaults)
  }
  @Test func streamingUsesSubtitlesAndDictionaryAndCacheSurvivesClosingUntilExit() async throws {
    let model = model(), recognizer = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { recognizer }
    model.startLiveSpeech()
    await model.liveSpeechOperation?.value
    #expect(model.isLiveSpeech && model.ready && model.playing && !model.grammarEnabledForVideo)
    #expect(!model.canSaveBookmark && model.scheduler == nil)
    recognizer.updates?(.init(text: "A blue robot.", start: 0, end: 2, isFinal: false))
    let id = try #require(model.liveSpeechSessionID)
    #expect(model.subtitleLines.count == 1 && model.currentToken?.normalized == "robot")
    model.openSubtitleSearch(); model.setSubtitleSearchQuery("blue")
    #expect(model.subtitleSearchResults.matches.count == 1)
    recognizer.updates?(.init(text: "A violet robot.", start: 0, end: 3, isFinal: true))
    #expect(model.subtitleSearchResults.matches.isEmpty && model.liveSpeechCacheBytes > 0)
    model.closeVideo()
    await model.liveSpeechShutdown?.value
    #expect(!model.ready && !model.isLiveSpeech && model.liveSpeechCacheBytes > 0)
    #expect(recognizer.stops.last == false)
    recognizer.updates?(.init(text: "Late stale words.", start: 3, end: 4, isFinal: true))
    #expect(model.document == nil)
    model.restoreLiveSpeech(id)
    #expect(model.isLiveSpeech && model.ready && !model.playing && model.subtitleLines.count == 1)
    model.closeVideo()
    await model.liveSpeechShutdown?.value
    model.clearLiveSpeechCacheOnExit()
    #expect(model.cachedSpeechSessions.isEmpty && model.liveSpeechCacheBytes == 0)
  }
  @Test func sourceAndMicrophoneSwitchesFinalizeOldInputBeforeResuming() async throws {
    let model = model()
    var engines: [TestSpeechRecognizer] = []
    model.liveSpeechRecognizerFactory = { let engine = TestSpeechRecognizer(); engines.append(engine); return engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engines[0].updates?(.init(text: "A paper robot.", start: 0, end: 2, isFinal: false))
    engines[0].finalOnStop = .init(text: "A paper robot walks.", start: 0, end: 3, isFinal: true)
    model.setSpeechAudioSource(.microphone)
    await model.liveSpeechOperation?.value
    #expect(engines.count == 2 && engines[0].stops == [true])
    #expect(engines[1].starts.first?.0 == .microphone)
    engines[1].updates?(.init(text: "It reads.", start: 0, end: 1, isFinal: true))
    #expect(model.document?.sentences.last?.startTime == 3)
    model.setSpeechMicrophone("authored-mic")
    await model.liveSpeechOperation?.value
    #expect(engines[2].starts.first?.1 == "authored-mic")
    engines[0].updates?(.init(text: "Stale input.", start: 5, end: 6, isFinal: true))
    #expect(model.document?.sentences.last?.text == "It reads.")
    model.toggleLiveSpeech(); await model.liveSpeechOperation?.value
    #expect(model.liveSpeechState == .paused && !model.playing)
    model.closeVideo(); await model.liveSpeechShutdown?.value
  }
  @Test func failureRetainsTranscriptAndLateCallbacksCannotReviveClosedSession() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engine.updates?(.init(text: "A copper clock.", start: 0, end: 2, isFinal: true))
    engine.failure?("Authored capture error")
    await model.liveSpeechShutdown?.value
    #expect(model.liveSpeechState == .failed && !model.playing && model.error == "Authored capture error")
    #expect(model.subtitleLines.count == 1 && engine.stops == [false])
    model.closeVideo(); await model.liveSpeechShutdown?.value
    engine.failure?("A late error")
    #expect(model.error == nil && !model.hasOpenVideo)
  }
  @Test func audioConversionResamplesStereoAndOwnsBuffersWithContinuousTime() throws {
    guard #available(macOS 26.0, *) else { return }
    let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
    let source = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4800))
    source.frameLength = 4800
    for channel in 0..<2 {
      for index in 0..<4800 { source.floatChannelData![channel][index] = Float(sin(Double(index) / 20)) }
    }
    let converter = SpeechPCMConverter(format: target)
    let first = try #require(try converter.convert(source))
    let savedSample = first.buffer.floatChannelData![0][100]
    #expect(first.buffer.format == target && first.buffer.frameLength > 1400 && first.buffer.frameLength <= 1600)
    for channel in 0..<2 { source.floatChannelData![channel].initialize(repeating: 0, count: 4800) }
    let second = try #require(try converter.convert(source))
    #expect(first.buffer.floatChannelData![0][100] == savedSample)
    #expect(first.bufferStartTime?.seconds == 0)
    #expect(second.bufferStartTime?.seconds == Double(first.buffer.frameLength) / 16000)
  }

  @Test func liveRecognitionNeverCreatesYouTubeHistoryOrResumeTimestamps() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    model.library = try LibraryStore(directory: root)
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engine.updates?(.init(text: "A blue lantern.", start: 0, end: 1, isFinal: true))
    model.recordCurrentVideo(); model.saveBookmark()
    model.closeVideo(); await model.liveSpeechShutdown?.value
    await model.libraryOperation?.value
    #expect(try await model.library?.history().isEmpty == true)
    #expect(try await model.library?.timestamps().isEmpty == true)
  }

  @Test func growingPartialRequestsFollowingEvenWhenRowIDAndIndexStayTheSame() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engine.updates?(.init(text: "A blue robot", start: 0, end: 1, isFinal: false))
    let row = try #require(model.subtitleLines.last?.id)
    var revision = try #require(model.liveSubtitleFollowRevision)
    for count in 1...20 {
      let text = "A blue robot " + String(repeating: "carries a paper lantern ", count: count)
      engine.updates?(.init(text: text, start: 0, end: Double(count + 1), isFinal: false))
      #expect(model.currentLineIndex == 0 && model.subtitleLines.last?.id == row)
      #expect(model.liveSubtitleFollowRevision != revision && model.subtitleFollowLineID() == row)
      revision = try #require(model.liveSubtitleFollowRevision)
    }
    model.toggleSubtitleScrollPin(at: row)
    engine.updates?(.init(text: "A blue robot reads another page.", start: 0, end: 22, isFinal: true))
    #expect(!model.followsLiveSubtitles && model.liveSubtitleFollowRevision == nil)
    model.toggleSubtitleScrollPin()
    #expect(model.followsLiveSubtitles && model.liveSubtitleFollowRevision != revision)
    model.openSubtitleSearch(); model.setSubtitleSearchQuery("robot")
    #expect(!model.followsLiveSubtitles)
    model.closeSubtitleSearch()
    #expect(model.followsLiveSubtitles)
    model.draggingDictionarySelection = true
    #expect(!model.followsLiveSubtitles)
    model.draggingDictionarySelection = false
    #expect(model.followsLiveSubtitles)
    model.closeVideo(); await model.liveSpeechShutdown?.value
  }

  @Test func boundedCacheStillRequestsFollowingWhenNewestRowReplacesAnOldOne() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    model.liveTranscriptCache.setLimit(100)
    var previousIndex: Int?
    var previousRow: UUID?
    var previousRevision: Int?
    for index in 0..<60 {
      engine.updates?(.init(text: String(format: "A blue robot carries item %03d.", index),
        start: Double(index * 2), end: Double(index * 2 + 1), isFinal: true))
      if index >= 5 {
        #expect(model.currentLineIndex == previousIndex)
        #expect(model.subtitleLines.last?.id != previousRow)
        #expect(model.liveSubtitleFollowRevision != previousRevision)
        #expect(model.subtitleFollowLineID() == model.subtitleLines.last?.id)
      }
      previousIndex = model.currentLineIndex
      previousRow = model.subtitleLines.last?.id
      previousRevision = model.liveSubtitleFollowRevision
    }
    #expect(model.liveSpeechCacheBytes <= 100 && model.subtitleLines.count == 3)
    model.closeVideo(); await model.liveSpeechShutdown?.value
  }

  @Test func manualScrollingReleasesFollowingUntilTheUserReturnsToTheBottom() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engine.updates?(.init(text: "A paper robot reads.", start: 0, end: 1, isFinal: true))
    // New content changing the bottom distance is not a manual scroll.
    model.updateLiveSubtitleScroll(previousOffset: 500, offset: 500, bottomDistance: 120, userInitiated: false)
    #expect(model.followsLiveSubtitles)
    model.updateLiveSubtitleScroll(previousOffset: 500, offset: 480, bottomDistance: 20, userInitiated: true)
    #expect(!model.liveSubtitleAutoFollow && !model.followsLiveSubtitles)
    engine.updates?(.init(text: "A blue lantern glows.", start: 1, end: 2, isFinal: true))
    #expect(model.liveSubtitleFollowRevision == nil && model.subtitleFollowLineID() == nil)
    // Resizing, a search jump, or automatic layout corrections must not resume following.
    model.updateLiveSubtitleScroll(previousOffset: 480, offset: 600, bottomDistance: 0, userInitiated: false)
    #expect(!model.liveSubtitleAutoFollow)
    model.updateLiveSubtitleScroll(previousOffset: 480, offset: 490, bottomDistance: 110, userInitiated: true)
    #expect(!model.liveSubtitleAutoFollow)
    model.openSubtitleSearch(); model.setSubtitleSearchQuery("robot"); model.closeSubtitleSearch()
    #expect(!model.liveSubtitleAutoFollow)
    model.updateLiveSubtitleScroll(previousOffset: 490, offset: 600, bottomDistance: 1, userInitiated: true)
    #expect(model.followsLiveSubtitles && model.subtitleFollowLineID() == model.subtitleLines.last?.id)
    let revision = model.liveSubtitleFollowRevision
    engine.updates?(.init(text: "The copper clock chimes.", start: 2, end: 3, isFinal: true))
    #expect(model.liveSubtitleFollowRevision != revision)
    model.updateLiveSubtitleScroll(previousOffset: 600, offset: 400, bottomDistance: 200, userInitiated: true)
    let sessionID = try #require(model.liveSpeechSessionID)
    model.closeVideo(); await model.liveSpeechShutdown?.value
    model.restoreLiveSpeech(sessionID)
    #expect(model.liveSubtitleAutoFollow && model.followsLiveSubtitles)
    model.closeVideo(); await model.liveSpeechShutdown?.value
  }

  @Test func returningToTheBottomDoesNotOverrideExplicitPinOrSearch() async throws {
    let model = model(), engine = TestSpeechRecognizer()
    model.liveSpeechRecognizerFactory = { engine }
    model.startLiveSpeech(); await model.liveSpeechOperation?.value
    engine.updates?(.init(text: "A violet robot walks.", start: 0, end: 1, isFinal: true))
    model.updateLiveSubtitleScroll(previousOffset: 100, offset: 80, bottomDistance: 20, userInitiated: true)
    model.toggleSubtitleScrollPin()
    model.updateLiveSubtitleScroll(previousOffset: 80, offset: 100, bottomDistance: 0, userInitiated: true)
    #expect(model.subtitleScrollPinned && !model.liveSubtitleAutoFollow && !model.followsLiveSubtitles)
    model.toggleSubtitleScrollPin()
    #expect(model.liveSubtitleAutoFollow && model.followsLiveSubtitles)
    model.openSubtitleSearch(); model.setSubtitleSearchQuery("robot")
    model.updateLiveSubtitleScroll(previousOffset: 100, offset: 80, bottomDistance: 20, userInitiated: true)
    #expect(model.liveSubtitleAutoFollow && !model.followsLiveSubtitles)
    model.closeVideo(); await model.liveSpeechShutdown?.value
  }
}
