import Foundation
import Testing

@testable import StudyCore

private actor ClauseAuditProvider: GrammarProvider {
  nonisolated let identity = "clause-audit-test"
  let malformedDraft: Bool
  let malformedAudit: Bool
  var calls: [(Bool, String?, [UUID])] = []
  init(malformedDraft: Bool = false, malformedAudit: Bool = false) {
    self.malformedDraft = malformedDraft
    self.malformedAudit = malformedAudit
  }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    try await analyze(
      sentences, context: [], repair: repair, validationFeedback: validationFeedback)
  }
  func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool,
    validationFeedback: String?
  ) async throws -> Data {
    calls.append((repair, validationFeedback, context.map(\.id)))
    if (!repair && malformedDraft) || (repair && malformedAudit) { return Data("{}".utf8) }
    let window = GrammarWindow(sentences: sentences, context: context)
    let start = window.owners.firstIndex(of: sentences[0].id)!
    let roles: [Role] = [.SUBJECT, .VERB, .OBJECT]
    let constituents = roles.enumerated().map { i, role in
      GrammarConstituent(
        role: role, startAtom: start + i, endAtomExclusive: start + i + 1,
        text: window.atoms[start + i].text, childClauseID: nil)
    }
    return try JSONEncoder().encode(
      ClauseResponse(
        schemaVersion: 2,
        clauses: [
          GrammarClause(
            id: "root", parentID: nil, startAtom: start, endAtomExclusive: start + 3,
            kind: .FINITE, status: .COMPLETE, subjectOmitted: false, pattern: .SVO,
            constituents: constituents)
        ], unresolved: []))
  }
  func history() -> [(Bool, String?, [UUID])] { calls }
}
struct GrammarAuditTests {
  func sentence(_ text: String) throws -> Sentence {
    let raw = try JSONSerialization.data(withJSONObject: [
      "events": [
        [
          "tStartMs": 0,
          "dDurationMs": 1000, "segs": [["utf8": text]],
        ]
      ]
    ])
    return try CaptionPipeline().parse(raw, videoID: "test")[0]
  }
  @Test func semanticReadingIsCompiledWithSameContext() async throws {
    let context = try ["Earlier words", "I study music.", "Later words"].map(sentence)
    let provider = ClauseAuditProvider()
    let result = try await GrammarScheduler(provider: provider, context: context).analyze([
      context[1]
    ])
    #expect(result[0].displaySpans(at: 1).map(\.role) == [.VERB])
    let history = await provider.history()
    #expect(history.count == 2)
    #expect(history[0].0 == false && history[1].0 == true)
    #expect(history[1].1?.contains("Independently audit") == true)
    #expect(history[0].2 == context.map(\.id) && history[1].2 == context.map(\.id))
  }
  @Test func unusableSemanticReadingIsReportedToCompiler() async throws {
    let target = try sentence("I study music.")
    let provider = ClauseAuditProvider(malformedDraft: true)
    let result = try await GrammarScheduler(provider: provider).analyze([target])
    #expect(result[0].pattern == .SVO)
    let history = await provider.history()
    #expect(history.count == 2)
    #expect(history[1].1?.contains("JSON decoding") == true)
  }
  @Test func malformedAuditIsNotReplacedByUncheckedDraftOrRetriedForever() async throws {
    let provider = ClauseAuditProvider(malformedAudit: true)
    let target = try sentence("I study music.")
    let scheduler = GrammarScheduler(provider: provider)
    await #expect(throws: AppFailure.self) { try await scheduler.analyze([target]) }
    #expect(await provider.history().count == 3)
    await scheduler.enqueue([target])
    #expect(await scheduler.next().isEmpty)
    await scheduler.enqueue([target], retryFailed: true)
    #expect(await scheduler.next().count == 1)
  }
}
