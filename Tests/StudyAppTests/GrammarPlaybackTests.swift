import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

private actor PlaybackGrammarProvider: GrammarProvider {
  nonisolated let identity = "offline-playback"
  nonisolated let concurrencyLimit: Int
  var blocked = true
  var failNext = false
  var history: [[UUID]] = []
  var active = 0
  var peak = 0
  init(limit: Int = 1, fail: Bool = false) {
    concurrencyLimit = limit
    failNext = fail
  }
  func release() { blocked = false }
  func snapshot() -> ([[UUID]], Int) { (history, peak) }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    try await analyze(
      sentences, context: [], repair: repair, validationFeedback: validationFeedback)
  }
  func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    if !repair { history.append(sentences.map(\.id)) }
    while blocked { try await Task.sleep(for: .milliseconds(2)) }
    if failNext {
      failNext = false
      throw AppFailure(.grammarProviderUnavailable, "Offline test failure")
    }
    if !repair { return Data(#"{"clauses":[],"notes":[]}"#.utf8) }
    let window = GrammarWindow(sentences: sentences, context: context)
    let clauses = sentences.map { sentence in
      let start = window.owners.firstIndex(of: sentence.id)!
      return GrammarClause(
        id: sentence.id.uuidString, parentID: nil, startAtom: start, endAtomExclusive: start + 3,
        kind: .FINITE, status: .COMPLETE, subjectOmitted: false, pattern: .SVO,
        constituents: [Role.SUBJECT, .VERB, .OBJECT].enumerated().map { i, role in
          GrammarConstituent(
            role: role, startAtom: start + i, endAtomExclusive: start + i + 1,
            text: window.atoms[start + i].text, childClauseID: nil)
        })
    }
    return try JSONEncoder().encode(
      ClauseResponse(schemaVersion: 2, clauses: clauses, unresolved: []))
  }
}

@MainActor struct GrammarPlaybackTests {
  private func fixture(_ provider: PlaybackGrammarProvider) throws -> (
    StudyModel, UserDefaults, String
  ) {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let events = [0, 1, 100, 250, 450, 600].enumerated().map { index, time in
      [
        "tStartMs": time * 1000, "dDurationMs": 900,
        "segs": [
          ["utf8": "I study \(["music", "books", "English", "art", "math", "history"][index])."]
        ],
      ]
        as [String: Any]
    }
    let raw = try JSONSerialization.data(withJSONObject: ["events": events])
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    model.document = StudyDocument(
      video: Video(id: "test", title: "Test", duration: 800), rawCaption: raw, sentences: sentences)
    model.timeline = Timeline(sentences)
    model.scheduler = GrammarScheduler(provider: provider, context: sentences)
    model.fingerprint = "test"
    model.loading = true
    for token in sentences.flatMap(\.tokens) {
      model.dictionaryCache[model.dictionaryKey(token)] = DictionaryEntry(
        definition: "test", shortGloss: "test")
    }
    return (model, defaults, suite)
  }
  func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<500 {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Offline grammar work did not reach the expected state")
  }
  @Test func playbackOpensBeforeGrammarAndFirstBatchIsSmallAndBounded() async throws {
    let provider = PlaybackGrammarProvider()
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.continuePlayback()
    #expect(model.ready && !model.loading)
    #expect(model.document?.sentences.allSatisfy { $0.grammarAnalysis == nil } == true)
    let firstToken = try #require(model.timeline?.tokens.first)
    model.update(time: (firstToken.startTime + firstToken.endTime) / 2, duration: 800, state: 1)
    #expect(model.currentToken?.surface == "I" && model.playing)
    try await eventually { await provider.snapshot().0.count == 1 }
    #expect(await provider.snapshot().0[0].count == 2)
    #expect(model.document?.sentences[4].grammarStatus == .notQueued)
    await provider.release()
    await model.backgroundTask?.value
    #expect(
      model.document?.sentences.prefix(4).allSatisfy { $0.grammarAnalysis?.pattern == .SVO } == true
    )
    #expect(model.document?.sentences.suffix(2).allSatisfy { $0.grammarAnalysis == nil } == true)
  }
  @Test func seekPrioritizesNewPositionAndDropsOldQueuedFuture() async throws {
    let provider = PlaybackGrammarProvider()
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.continuePlayback()
    try await eventually { await provider.snapshot().0.count == 1 }
    let last = try #require(model.document?.sentences.last)
    model.update(time: 600.1, duration: 800, state: 2)
    try await eventually {
      [GrammarStatus.queued, .analyzing].contains(model.document!.sentences.last!.grammarStatus)
    }
    #expect(model.document?.sentences[2].grammarStatus == .notQueued)
    // The old request must release its slot even while the mock remains blocked.
    try await eventually { await provider.snapshot().0.count == 2 }
    #expect(await provider.snapshot().0.last == [last.id])
    await provider.release()
    await model.backgroundTask?.value
    #expect(
      await provider.snapshot().0 == [
        Array(model.document!.sentences.prefix(2).map(\.id)), [last.id],
      ])
    #expect(model.currentSentence?.grammarAnalysis?.pattern == .SVO)
  }
  @Test func multipleWorkersReallyRunWhenCapacityAllows() async throws {
    let provider = PlaybackGrammarProvider(limit: 2)
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.continuePlayback()
    try await eventually { await provider.snapshot().0.count == 2 }
    #expect(await provider.snapshot().1 == 2)
    await provider.release()
    await model.backgroundTask?.value
    #expect(model.document?.sentences.prefix(4).allSatisfy { $0.grammarAnalysis != nil } == true)
  }
  @Test func providerFailureKeepsPlaybackUsableAndExplicitRetryRestarts() async throws {
    let provider = PlaybackGrammarProvider(fail: true)
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.continuePlayback()
    await provider.release()
    await model.backgroundTask?.value
    #expect(model.ready && model.grammarError != nil)
    model.update(time: 0.1, duration: 800, state: 1)
    #expect(model.playing && model.currentToken != nil)
    model.retryGrammar()
    try await eventually {
      model.grammarError == nil && model.document?.sentences[0].grammarAnalysis != nil
    }
    await model.backgroundTask?.value
    #expect(model.document?.sentences.prefix(4).allSatisfy { $0.grammarAnalysis != nil } == true)
  }
  @Test func closeDuringBlockedAnalysisRejectsLateResults() async throws {
    let provider = PlaybackGrammarProvider()
    let (model, defaults, suite) = try fixture(provider)
    defer { defaults.removePersistentDomain(forName: suite) }
    model.continuePlayback()
    try await eventually { await provider.snapshot().0.count == 1 }
    let task = model.backgroundTask
    model.closeVideo()
    await provider.release()
    await task?.value
    #expect(
      !model.ready && model.document == nil && model.grammarError == nil && !model.backgroundRunning
    )
  }
  @Test func completedCacheStartsWithoutProviderRequests() async throws {
    let provider = PlaybackGrammarProvider()
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.apply(
      model.document!.sentences.map { Analysis(sentenceId: $0.id, pattern: .UNKNOWN, spans: []) })
    model.continuePlayback()
    await model.backgroundTask?.value
    #expect(model.ready && !model.backgroundRunning)
    #expect(await provider.snapshot().0.isEmpty)
  }
  @Test func optedOutPlaybackSeekAndRetriesNeverQueueGrammar() async throws {
    let provider = PlaybackGrammarProvider()
    let (model, defaults, suite) = try fixture(provider)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
    }
    model.grammarEnabledForVideo = false
    model.continuePlayback()
    model.update(time: 0.1, duration: 800, state: 1)
    model.seek(600.1)
    model.retryCurrentGrammar()
    model.retryGrammar()
    model.enqueueGrammarRetry(model.document!.sentences)
    model.startBackground()
    await model.backgroundTask?.value
    #expect(model.ready && model.playing && model.currentToken != nil)
    #expect(model.grammarDemand(at: 600).isEmpty)
    #expect(model.backgroundTask == nil && !model.backgroundRunning)
    #expect(await provider.snapshot().0.isEmpty)
    #expect(model.document?.sentences.allSatisfy { $0.grammarStatus == .notQueued } == true)
    model.pinDictionary(model.currentToken!)
    #expect(model.dictionaryEntry != nil)
    let sentence = model.document!.sentences[0]
    model.apply([Analysis(sentenceId: sentence.id, pattern: .SVO, spans: [])])
    #expect(model.document?.sentences[0].grammarAnalysis == nil)
  }
}
