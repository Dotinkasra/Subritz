import Foundation
import Testing

@testable import StudyCore

private actor PartialProvider: GrammarProvider {
  nonisolated let usesClauseStructure = false
  nonisolated let identity = "partial-test"
  let succeeds: Bool
  let malformedRepair: Bool
  var requests: [[UUID]] = []
  init(succeeds: Bool = false, malformedRepair: Bool = false) {
    self.succeeds = succeeds
    self.malformedRepair = malformedRepair
  }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    requests.append(sentences.map(\.id))
    if repair && malformedRepair { return Data("{}".utf8) }
    let analyses = sentences.map { sentence in
      Analysis(
        sentenceId: sentence.id, pattern: .SVO,
        spans: sentence.tokens.count > 7
          ? [
            Span(role: .VERB, startToken: 4, endTokenExclusive: repair && succeeds ? 5 : 6),
            Span(role: .OBJECT, startToken: 5, endTokenExclusive: repair && succeeds ? 6 : 7),
          ]
          : [
            Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1),
            Span(role: .VERB, startToken: 1, endTokenExclusive: 2),
          ])
    }
    return try JSONEncoder().encode(GrammarResponse(schemaVersion: 1, results: analyses))
  }
  func calls() -> [[UUID]] { requests }
}
struct GrammarPartialTests {
  func sentences() throws -> [Sentence] {
    try ["I study.", "We'll you're rather Uh draw this, she's quite sleepy tonight."].map { text in
      let data = try JSONSerialization.data(withJSONObject: [
        "events": [
          ["tStartMs": 0, "dDurationMs": 3000, "segs": [["utf8": text]]]
        ]
      ])
      return try CaptionPipeline().parse(data, videoID: "abcdefghijk")[0]
    }
  }
  @Test func crossingInOneSentenceDoesNotDiscardOtherResults() async throws {
    let batch = try sentences()
    let provider = PartialProvider()
    let scheduler = GrammarScheduler(provider: provider)
    let result = try await scheduler.analyze(batch)
    #expect(result.map(\.sentenceId) == [batch[0].id])
    #expect(await provider.calls() == [batch.map(\.id), [batch[1].id]])
    await scheduler.enqueue([batch[1]])
    #expect(await scheduler.next().isEmpty)
    await scheduler.enqueue([batch[1]], priority: true, retryFailed: true)
    #expect(await scheduler.next().map(\.id) == [batch[1].id])
  }
  @Test func targetedRepairRetainsFirstResult() async throws {
    let batch = try sentences()
    let provider = PartialProvider(succeeds: true)
    let scheduler = GrammarScheduler(provider: provider)
    let result = try await scheduler.analyze(batch)
    #expect(result.map(\.sentenceId) == batch.map(\.id))
    #expect(result[1].spans[0].endTokenExclusive == 5)
    #expect(await provider.calls() == [batch.map(\.id), [batch[1].id]])
  }
  @Test func unreadableRepairStillPreservesValidSentence() async throws {
    let batch = try sentences()
    let provider = PartialProvider(malformedRepair: true)
    let result = try await GrammarScheduler(provider: provider).analyze(batch)
    #expect(result.map(\.sentenceId) == [batch[0].id])
  }
  @Test func invalidRoleAndMissingSentenceAreIsolated() throws {
    let batch = try sentences()
    let data = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "results": [
        ["sentenceId": batch[0].id.uuidString, "pattern": "SV", "spans": []],
        [
          "sentenceId": batch[1].id.uuidString, "pattern": "SVO",
          "spans": [
            ["role": "NOT_A_ROLE", "startToken": 0, "endTokenExclusive": 1]
          ],
        ],
      ],
    ])
    let result = try GrammarContract.inspect(data, sentences: batch)
    #expect(result.valid.map(\.sentenceId) == [batch[0].id])
    #expect(result.invalid.map(\.id) == [batch[1].id])
    let missing = try JSONEncoder().encode(GrammarResponse(schemaVersion: 1, results: result.valid))
    #expect(
      try GrammarContract.inspect(missing, sentences: batch).invalid.map(\.id) == [batch[1].id])
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_FAILURE"] == "1"))
  func syntheticFragmentWithCodex() async throws {
    let batch = [try sentences()[1]]
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "gpt-6-luna"
    settings.timeout = 120
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX_PATH"] ?? ""
    let result = try await GrammarScheduler(provider: CodexGrammarProvider(settings: settings))
      .analyze(batch)
    #expect(result.count == 1)
    if let analysis = result.first {
      print(
        "Synthetic fragment: \(analysis.pattern.rawValue), \(analysis.spans.count) validated spans")
    }
  }
}
