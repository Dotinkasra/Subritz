import Foundation
import Testing

@testable import StudyCore

private actor ContextProvider: GrammarProvider {
  nonisolated let usesClauseStructure = false
  nonisolated let identity = "context-test"
  var contexts: [[UUID]] = []
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    Issue.record("Context overload was not called")
    return Data("{}".utf8)
  }
  func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    contexts.append(context.map(\.id))
    if !repair { return Data("{}".utf8) }
    return try JSONEncoder().encode(
      GrammarResponse(
        schemaVersion: 1,
        results: sentences.map {
          Analysis(
            sentenceId: $0.id, pattern: .UNKNOWN,
            spans: [
              Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1, confidence: .HIGH)
            ])
        }))
  }
  func received() -> [[UUID]] { contexts }
}
struct GrammarContextTests {
  func sentence(_ text: String) throws -> Sentence {
    let raw = try JSONSerialization.data(withJSONObject: [
      "events": [
        ["tStartMs": 0, "dDurationMs": 1000, "segs": [["utf8": text]]]
      ]
    ])
    return try CaptionPipeline().parse(raw, videoID: "test")[0]
  }
  @Test func contextCrossesDisplayAndTargetBoundariesWithoutChangingIndices() throws {
    let units = try [
      "we are checking on our", "garden gate after the rain", "We paint it green",
    ].map(sentence)
    let data = Data(try GrammarContract.payload([units[1]], context: units).utf8)
    let input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let transcript = try #require(input["transcript"] as? [[String: Any]])
    #expect(transcript.map { $0["text"] as? String } == units.map(\.text))
    #expect(transcript.map { $0["target"] as? Bool } == [false, true, false])
    let targetAtoms = try #require(transcript[1]["atoms"] as? [[String: Any]])
    #expect(targetAtoms.map { $0["text"] as? String } == units[1].tokens.map(\.surface))
    #expect((targetAtoms[0]["index"] as? Int ?? 0) > 0)

  }
  @Test func twoDisplayLinesAreOneGrammarUnit() throws {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"we are checking on our"}]},{"tStartMs":1500,"dDurationMs":2000,"segs":[{"utf8":"garden gate after the rai"}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    #expect(sentences.count == 1)
    #expect(sentences[0].text == "we are checking on our garden gate after the rai")
    #expect(Timeline(sentences).lines.count == 2)
  }
  @Test func unknownKeepsOnlyConfidentLocalRoles() throws {
    let target = try sentence("I perhaps study something")
    let input = GrammarResponse(
      schemaVersion: 1,
      results: [
        Analysis(
          sentenceId: target.id, pattern: .UNKNOWN,
          spans: [
            Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1, confidence: .HIGH),
            Span(role: .MODIFIER, startToken: 1, endTokenExclusive: 2, confidence: .LOW),
            Span(role: .VERB, startToken: 2, endTokenExclusive: 3, confidence: .HIGH),
            Span(role: .OBJECT, startToken: 3, endTokenExclusive: 4, confidence: .MEDIUM),
          ])
      ])
    let result = try GrammarContract.validate(JSONEncoder().encode(input), sentences: [target])
    #expect(result[0].pattern == .UNKNOWN)
    #expect(result[0].spans.map(\.role) == [.SUBJECT, .VERB])
  }
  @Test func schedulerIncludesContextOnInitialAndRepairCalls() async throws {
    let units = try ["Before this", "I study", "After that"].map(sentence)
    let provider = ContextProvider()
    let scheduler = GrammarScheduler(provider: provider, context: units)
    let result = try await scheduler.analyze([units[1]])
    #expect(result[0].spans[0].role == .SUBJECT)
    #expect(await provider.received() == [units.map(\.id), units.map(\.id)])
  }
  @Test func safetyBoundaryKeepsPossessiveWithFollowingNounPhrase() throws {
    let text = Array(repeating: "word", count: 39).joined(separator: " ") + " our garden gate."
    let raw = try JSONSerialization.data(withJSONObject: [
      "events": [
        ["tStartMs": 0, "dDurationMs": 1000, "segs": [["utf8": text]]]
      ]
    ])
    let sentences = try CaptionPipeline().parse(raw, videoID: "test")
    #expect(sentences.count == 2)
    #expect(sentences[0].tokens.last?.surface == "word")
    #expect(sentences[1].text == "our garden gate.")
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_CONTEXT"] == "1"))
  func syntheticContextRetainsClearClauseInsideFragment() async throws {
    let before = try sentence("Yay.")
    let target = try sentence("We're uh Who named her Nora Quartz?")
    let after = try sentence("Does she often look like Nora Quartz?")
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "gpt-6-luna"
    settings.timeout = 120
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX_PATH"] ?? ""
    let results = try await GrammarScheduler(
      provider: CodexGrammarProvider(settings: settings), context: [before, target, after]
    ).analyze([target])
    let result = try #require(results.first)
    #expect(
      result.spans.contains {
        $0.role == .SUBJECT && $0.startToken == 2 && $0.endTokenExclusive == 3
      })
    #expect(
      result.spans.contains { $0.role == .VERB && $0.startToken == 3 && $0.endTokenExclusive == 4 })
    #expect(
      result.spans.contains {
        $0.role == .OBJECT && $0.startToken == 4 && $0.endTokenExclusive == 5
      })
    #expect(
      result.spans.contains {
        $0.role == .COMPLEMENT && $0.startToken == 5 && $0.endTokenExclusive == 7
      })
    #expect(!result.spans.contains { $0.role == .VERB && $0.startToken == 1 })
    print("Context grammar: \(result.pattern.rawValue), \(result.spans.count) confident roles")
  }
}
