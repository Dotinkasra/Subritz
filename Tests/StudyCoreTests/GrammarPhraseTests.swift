import Foundation
import Testing

@testable import StudyCore

struct GrammarPhraseTests {
  func sentence(_ text: String) throws -> Sentence {
    let raw = try JSONSerialization.data(withJSONObject: [
      "events": [
        ["tStartMs": 0, "dDurationMs": 3000, "segs": [["utf8": text]]]
      ]
    ])
    return try CaptionPipeline().parse(raw, videoID: "test")[0]
  }
  func validate(_ sentence: Sentence, _ spans: [Span]) throws -> Analysis {
    try GrammarContract.validate(
      JSONEncoder().encode(
        GrammarResponse(
          schemaVersion: 1,
          results: [
            Analysis(sentenceId: sentence.id, pattern: .UNKNOWN, spans: spans)
          ])), sentences: [sentence])[0]
  }
  @Test func prepositionObjectIsNotDisplayedAsVerbObject() throws {
    let target = try sentence("We walk along the stone bridge.")
    let result = try validate(
      target,
      [
        Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1, confidence: .HIGH),
        Span(role: .VERB, startToken: 1, endTokenExclusive: 2, confidence: .HIGH),
        Span(role: .PREPOSITIONAL_PHRASE, startToken: 2, endTokenExclusive: 6, confidence: .HIGH),
        Span(role: .OBJECT, startToken: 5, endTokenExclusive: 6, confidence: .HIGH),
      ])
    #expect(!result.spans.contains { $0.role == .OBJECT })
    #expect(result.spans.contains { $0.role == .PREPOSITIONAL_PHRASE })
  }
  @Test func subordinateVerbObjectInsidePPIsPreserved() throws {
    let target = try sentence("He spoke about what she bought.")
    let result = try validate(
      target,
      [
        Span(role: .PREPOSITIONAL_PHRASE, startToken: 2, endTokenExclusive: 6, confidence: .HIGH),
        Span(role: .CLAUSE, startToken: 3, endTokenExclusive: 6, confidence: .HIGH),
        Span(role: .OBJECT, startToken: 3, endTokenExclusive: 4, confidence: .HIGH),
      ])
    #expect(result.spans.contains { $0.role == .OBJECT })
  }
  @Test func functionWordsCannotBeStandaloneVerbs() throws {
    let target = try sentence("to very so really")
    let spans = (0..<4).map {
      Span(role: .VERB, startToken: $0, endTokenExclusive: $0 + 1, confidence: .HIGH)
    }
    #expect(try validate(target, spans).spans.isEmpty)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_PHRASE"] == "1"))
  func syntheticDisfluencyWithCodex() async throws {
    let target = try sentence(
      "Well we don't plan to draw we don't plan to walk along the stone bridge and we think they painted this."
    )
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "gpt-6-luna"
    settings.timeout = 120
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX_PATH"] ?? ""
    let result = try #require(
      try await GrammarScheduler(
        provider: CodexGrammarProvider(settings: settings), context: [target]
      ).analyze([target]).first)
    #expect(
      result.spans.contains {
        $0.role == .PREPOSITIONAL_PHRASE && $0.startToken == 11 && $0.endTokenExclusive == 15
      })
    #expect(!result.spans.contains { $0.role == .OBJECT && $0.startToken == 14 })
    #expect(
      result.spans.contains {
        $0.role == .OBJECT && $0.startToken == 18 && $0.endTokenExclusive == 21
      })
    print("Synthetic PP/object clause: \(result.pattern.rawValue), \(result.spans.count) spans")
  }
}
