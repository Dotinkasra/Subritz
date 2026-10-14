import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

private actor HeldExpressionProvider: DictionaryProvider {
  var requests = 0
  var pending: [Int: (Int, CheckedContinuation<[DictionaryEntry?], Never>)] = [:]
  var observers: [(Int, CheckedContinuation<Void, Never>)] = []
  func lookup(_ token: Token) async -> DictionaryEntry? {
    DictionaryEntry(definition: "自作本文 " + token.surface, shortGloss: token.surface)
  }
  func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    requests += 1
    let number = requests
    return await withCheckedContinuation { continuation in
      pending[number] = (expressions.count, continuation)
      let ready = observers.filter { $0.0 <= requests }
      observers.removeAll { $0.0 <= requests }
      for observer in ready { observer.1.resume() }
    }
  }
  func wait(for count: Int) async {
    if requests >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }
  func release(_ request: Int, entry: DictionaryEntry? = nil) {
    if let (count, continuation) = pending.removeValue(forKey: request) {
      continuation.resume(returning: Array(repeating: entry, count: count))
    }
  }
}
private actor RecordingDictionaryProvider: DictionaryProvider {
  var calls: [String] = []
  func lookup(_ token: Token) async -> DictionaryEntry? {
    calls.append(token.surface)
    return DictionaryEntry(definition: "自作本文", shortGloss: token.surface)
  }
  func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    calls.append("expression")
    return Array(repeating: nil, count: expressions.count)
  }
}

@MainActor struct DictionaryLatencyTests {
  @Test func adjacentHoverEventsDoNotClearTheNewWordAndLeavingStillClearsIt() async throws {
    let (model, words) = try DictionaryPinTests().fixture(realtime: false)
    model.expressionMisses.formUnion(words.map(\.id))
    model.hover(words[0])
    model.hover(nil, exiting: words[0].id)
    let obsoleteExit = model.hoverExitTask
    model.hover(words[1])
    await obsoleteExit?.value
    #expect(model.hoverToken?.id == words[1].id && model.dictionaryEntry?.shortGloss == words[1].surface)
    model.hover(nil, exiting: words[1].id)
    await model.hoverExitTask?.value
    #expect(model.hoverToken == nil && model.dictionaryEntry == nil)
    model.closeVideo()
  }
  @Test func wordPublishesBeforeSlowExpressionsAndObsoleteHoverCannotReplaceIt() async throws {
    let (model, tokens, root, defaults, suite) = try await DictionaryExpressionInteractionTests().fixture()
    defer {
      model.closeVideo(); defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let provider = HeldExpressionProvider()
    model.dictionaryProviderOverride = provider
    model.realtime = false
    model.hover(tokens[1])
    let old = model.dictionaryTask
    await provider.wait(for: 1)
    #expect(model.dictionaryEntry?.shortGloss == tokens[1].surface && !model.dictionaryLoading)
    model.hover(tokens[3])
    let latest = model.dictionaryTask
    await provider.wait(for: 2)
    #expect(old?.isCancelled == true)
    #expect(model.dictionaryEntry?.shortGloss == tokens[3].surface && !model.dictionaryLoading)
    await provider.release(1, entry: DictionaryEntry(definition: "古い語句", shortGloss: "古い語句"))
    await old?.value
    #expect(model.dictionaryEntry?.shortGloss == tokens[3].surface && model.resolvedExpression == nil)
    await provider.release(2)
    await latest?.value
    #expect(model.dictionaryEntry?.shortGloss == tokens[3].surface)
    // Revisiting the warmed word publishes synchronously, without a new await.
    model.expressionMisses.insert(tokens[1].id)
    model.hover(tokens[1])
    #expect(model.dictionaryEntry?.shortGloss == tokens[1].surface && !model.dictionaryLoading)
  }

  @Test func visibleWordsAreWarmedBeforeExpressionsAndSameLineDoesNotRestartPrefetch() async throws {
    let (model, tokens, root, defaults, suite) = try await DictionaryExpressionInteractionTests().fixture()
    defer {
      model.closeVideo(); defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let provider = RecordingDictionaryProvider()
    model.dictionaryProviderOverride = provider
    model.prefetchDictionary(at: 0)
    await model.dictionaryPrefetchTask?.value
    let calls = await provider.calls
    let lexical = tokens.filter(\.lexical)
    #expect(Array(calls.prefix(lexical.count)) == lexical.map(\.surface))
    #expect(calls.dropFirst(lexical.count).allSatisfy { $0 == "expression" })
    model.prefetchDictionary(at: 0.1)
    await model.dictionaryPrefetchTask?.value
    #expect(await provider.calls == calls)
    for token in lexical {
      model.hover(token)
      #expect(model.dictionaryEntry?.shortGloss == token.surface && !model.dictionaryLoading)
    }
  }
}
