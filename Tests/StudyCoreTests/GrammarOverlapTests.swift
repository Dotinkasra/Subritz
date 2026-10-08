import Foundation
import Testing

@testable import StudyCore

struct GrammarOverlapTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_CAPTION"] != nil))
  func initialFiveMinutesWithCodex() async throws {
    let path = ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_CAPTION"]!
    let sentences = try await CaptionService().parse(
      Data(contentsOf: URL(fileURLWithPath: path)), videoID: "abcdefghijk"
    ).filter { $0.startTime < 300 }
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "gpt-6-luna"
    settings.timeout = 120
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX_PATH"] ?? ""
    let scheduler = GrammarScheduler(provider: CodexGrammarProvider(settings: settings))
    var completed = 0
    var nested = 0
    for batch in GrammarContract.batches(sentences) {
      let results = try await scheduler.analyze(batch)
      completed += results.count
      let roles: Set<Role> = [.SUBJECT, .VERB, .OBJECT, .OBJECT1, .OBJECT2, .COMPLEMENT]
      for result in results {
        let primary = result.spans.filter { roles.contains($0.role) }
        for i in primary.indices {
          for j in primary.indices where j > i {
            if primary[i].role != primary[j].role,
              max(primary[i].startToken, primary[j].startToken)
                < min(primary[i].endTokenExclusive, primary[j].endTokenExclusive)
            {
              nested += 1
            }
          }
        }
      }
    }
    #expect(!sentences.isEmpty)
    #expect(completed == sentences.count)
    print(
      "First 5 min grammar: \(completed) sentences; accepted nested primary-role pairs: \(nested)")
  }
  func sentence(_ text: String) throws -> [Sentence] {
    let raw = try JSONSerialization.data(withJSONObject: [
      "events": [["tStartMs": 0, "dDurationMs": 3000, "segs": [["utf8": text]]]]
    ])
    return try CaptionPipeline().parse(raw, videoID: "test")
  }
  func response(_ sentences: [Sentence], spans: [(Role, Int, Int)]) throws -> Data {
    let analysis = Analysis(
      sentenceId: sentences[0].id, pattern: .SVO,
      spans: spans.map { Span(role: $0.0, startToken: $0.1, endTokenExclusive: $0.2) })
    return try JSONEncoder().encode(GrammarResponse(schemaVersion: 1, results: [analysis]))
  }
  @Test func objectClauseRetainsItsSubjectAndVerb() throws {
    let sentences = try sentence("I know she likes music.")
    let data = try response(
      sentences,
      spans: [
        (.SUBJECT, 0, 1), (.VERB, 1, 2), (.OBJECT, 2, 5), (.SUBJECT, 2, 3), (.VERB, 3, 4),
        (.OBJECT, 4, 5), (.CLAUSE, 2, 5),
      ])
    let result = try GrammarContract.validate(data, sentences: sentences)
    #expect(result[0].spans.count == 7)
  }
  @Test func relativeClauseInsideSubjectIsValid() throws {
    let sentences = try sentence("The man who lives here likes music.")
    let data = try response(
      sentences,
      spans: [(.SUBJECT, 0, 5), (.SUBJECT, 2, 3), (.VERB, 3, 4), (.VERB, 5, 6), (.OBJECT, 6, 7)])
    #expect(try GrammarContract.validate(data, sentences: sentences)[0].spans.count == 5)
  }
  @Test func gerundCanBeSubjectAndInnerVerb() throws {
    let sentences = try sentence("Running helps.")
    let data = try response(sentences, spans: [(.SUBJECT, 0, 1), (.VERB, 0, 1), (.VERB, 1, 2)])
    #expect(try GrammarContract.validate(data, sentences: sentences)[0].spans.count == 3)
  }
  @Test func primaryRoleWithPrepositionalPhraseIsValid() throws {
    let sentences = try sentence("The man in the room sleeps.")
    let data = try response(
      sentences,
      spans: [(.SUBJECT, 0, 5), (.PREPOSITIONAL_PHRASE, 2, 5), (.PREPOSITION, 2, 3), (.VERB, 5, 6)])
    #expect(try GrammarContract.validate(data, sentences: sentences)[0].spans.count == 4)
  }
  @Test func overlappingSpansOfSameRoleAreNotContradictions() throws {
    let sentences = try sentence("I know she likes music.")
    let data = try response(sentences, spans: [(.VERB, 0, 3), (.VERB, 1, 4)])
    #expect(try GrammarContract.validate(data, sentences: sentences)[0].spans.count == 2)
  }
  @Test func crossingSpansHaveUnderstandableError() throws {
    let sentences = try sentence("I know she likes music.")
    let data = try response(sentences, spans: [(.SUBJECT, 0, 3), (.VERB, 2, 4)])
    do {
      _ = try GrammarContract.validate(data, sentences: sentences)
      Issue.record("Expected crossing span rejection")
    } catch let error as AppFailure {
      #expect(error.code == .grammarInvalidResponse)
      #expect(error.message.contains("範囲"))
      #expect(error.message.contains("再解析"))
      #expect(!error.message.contains("主要な役割"))
      #expect(error.details?.contains("SUBJECT") == true)
    }
  }
  @Test func outOfBoundsAndDuplicatesStillRejected() throws {
    let sentences = try sentence("I study.")
    for spans: [(Role, Int, Int)] in [[(.SUBJECT, 0, 99)], [(.SUBJECT, 0, 1), (.SUBJECT, 0, 1)]] {
      let data = try response(sentences, spans: spans)
      #expect(throws: AppFailure.self) { try GrammarContract.validate(data, sentences: sentences) }
    }
  }
}
