import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

private struct OptOutVideoProvider: YouTubeProvider {
  static let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"I read books."}]}]}"#.utf8)
  func probe(id: String) async throws -> VideoProbe {
    VideoProbe(id: id, title: "Offline test", duration: 2, language: "en", automatic_captions: nil)
  }
  func caption(_ probe: VideoProbe) async throws -> Data { Self.raw }
}
private actor OptOutGrammarProvider: GrammarProvider {
  nonisolated let identity = "opt-out-test"
  var identityCalls = 0
  var analysisCalls = 0
  func cacheIdentity() async -> String {
    identityCalls += 1
    return identity
  }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws -> Data {
    analysisCalls += 1
    throw AppFailure("This test must not request grammar")
  }
  func calls() -> (Int, Int) { (identityCalls, analysisCalls) }
}

@MainActor struct GrammarOptOutTests {
  @Test func optOutSkipsProviderAndKeepsCaptionAndGrammarCachesSeparate() async throws {
    let (model, defaults, suite) = try SettingsLifecycleTests().isolatedModel()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      model.closeVideo()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let store = try StudyStore(directory: root)
    let provider = OptOutGrammarProvider()
    model.store = store
    model.youtubeProviderOverride = OptOutVideoProvider()
    model.grammarProviderOverride = provider
    model.settings.provider = "codex"
    model.settings.codexModel = "test"
    model.settings.codexPath = "/nonexistent-codex"
    model.url = "https://www.youtube.com/watch?v=abcdefghijk"
    var sentences = try CaptionPipeline().parse(OptOutVideoProvider.raw, videoID: "abcdefghijk")
    for i in sentences.indices {
      sentences[i].grammarAnalysis = Analysis(sentenceId: sentences[i].id, pattern: .SVO, spans: [])
      sentences[i].grammarStatus = .completed
    }
    let grammarKey = Fingerprint.make(
      videoID: "abcdefghijk", caption: OptOutVideoProvider.raw, provider: "opt-out-test", model: "test")
    try await store.save(StudyDocument(
      video: Video(id: "abcdefghijk", title: "Cached", duration: 2),
      rawCaption: OptOutVideoProvider.raw, sentences: sentences), fingerprint: grammarKey, limit: 1_000_000)
    model.setAIGrammarEnabled(false)
    model.load()
    await model.loadTask?.value
    #expect(model.ready && model.error == nil && !model.grammarEnabledForVideo)
    #expect(model.scheduler == nil && model.backgroundTask == nil)
    let offCalls = await provider.calls()
    #expect(offCalls.0 == 0 && offCalls.1 == 0)
    #expect(model.document?.sentences.allSatisfy { $0.grammarAnalysis == nil } == true)
    let captionKey = model.fingerprint
    let captionIDs = model.document!.sentences.map(\.id)
    #expect(captionKey != grammarKey)
    #expect(try await store.load(captionKey)?.sentences.map(\.id) == captionIDs)
    #expect(try await store.load(grammarKey)?.sentences[0].grammarAnalysis?.pattern == .SVO)
    // A change to the next-load preference must not start AI in the current video.
    model.setAIGrammarEnabled(true)
    model.retryGrammar()
    model.seek(1)
    #expect(!model.grammarEnabledForVideo && model.scheduler == nil)
    model.closeVideo()
    model.load()
    await model.loadTask?.value
    await model.backgroundTask?.value
    #expect(model.ready && model.grammarEnabledForVideo && model.scheduler != nil)
    #expect(model.fingerprint == grammarKey)
    #expect(model.document?.sentences[0].grammarAnalysis?.pattern == .SVO)
    let onCalls = await provider.calls()
    #expect(onCalls.0 == 1 && onCalls.1 == 0)
    model.closeVideo()
    model.settings.provider = "local"
    model.settings.localModel = "different-model"
    model.settings.baseURL = "invalid local URL"
    model.setAIGrammarEnabled(false)
    model.load()
    await model.loadTask?.value
    #expect(model.ready && model.error == nil && model.scheduler == nil)
    #expect(model.fingerprint == captionKey && model.document?.sentences.map(\.id) == captionIDs)
    let reusedCalls = await provider.calls()
    #expect(reusedCalls.0 == 1 && reusedCalls.1 == 0)
  }
}
