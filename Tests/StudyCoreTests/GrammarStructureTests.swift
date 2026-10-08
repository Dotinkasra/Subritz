import Foundation
import Testing

@testable import StudyCore

private actor RecordingClauseProvider: GrammarProvider {
  nonisolated let identity = "recording-clause-test"
  let provider: CodexGrammarProvider
  var counter = 0
  init(settings: AppSettings) { provider = CodexGrammarProvider(settings: settings) }
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
    counter += 1
    let number = counter
    let data = try await provider.analyze(
      sentences, context: context, repair: repair, validationFeedback: validationFeedback)
    try data.write(
      to: URL(fileURLWithPath: "/private/tmp/yt-grammar-structure-response-\(number).json"))
    try Data(
      (repair
        ? GrammarContract.payload(sentences, context: context)
        : GrammarWindow(sentences: sentences, context: context).readingPayload()).utf8
    ).write(
      to:
        URL(fileURLWithPath: "/private/tmp/yt-grammar-structure-input-\(number).json"))
    if let feedback = validationFeedback {
      try Data(feedback.utf8).write(
        to:
          URL(fileURLWithPath: "/private/tmp/yt-grammar-structure-feedback-\(number).txt"))
    }
    return data
  }
}

struct GrammarStructureTests {
  func sentence(_ text: String) throws -> Sentence {
    let data = try JSONSerialization.data(withJSONObject: [
      "events": [
        [
          "tStartMs": 0,
          "dDurationMs": 1000, "segs": [["utf8": text]],
        ]
      ]
    ])
    return try CaptionPipeline().parse(data, videoID: "test")[0]
  }
  func constituent(
    _ window: GrammarWindow, _ role: Role, _ start: Int, _ end: Int,
    child: String? = nil
  ) -> GrammarConstituent {
    GrammarConstituent(
      role: role, startAtom: start, endAtomExclusive: end,
      text: window.atoms[start..<end].map(\.text).joined(separator: " "), childClauseID: child,
      headAtom: role == .PREPOSITIONAL_PHRASE ? start : nil)
  }
  func clause(
    _ id: String, _ start: Int, _ end: Int, _ pattern: Pattern,
    _ constituents: [GrammarConstituent], parent: String? = nil,
    status: ClauseStatus = .COMPLETE, kind: ClauseKind = .FINITE,
    omitted: Bool = false
  ) -> GrammarClause {
    GrammarClause(
      id: id, parentID: parent, startAtom: start, endAtomExclusive: end,
      kind: kind, status: status, subjectOmitted: omitted, pattern: pattern,
      constituents: constituents)
  }
  func validate(_ window: GrammarWindow, _ clauses: [GrammarClause]) throws -> [Analysis] {
    try StructuredGrammar.validate(
      JSONEncoder().encode(
        ClauseResponse(
          schemaVersion: 2,
          clauses: clauses, unresolved: [])), window: window)
  }
  @Test func contractionsPreserveOriginalTimedTokensAndBothRoles() throws {
    let target = try sentence("We're ready.")
    let window = GrammarWindow(sentences: [target])
    #expect(window.atoms.map(\.text) == ["We", "are", "ready", "."])
    let result = try validate(
      window,
      [
        clause(
          "a", 0, 3, .SVC,
          [
            constituent(window, .SUBJECT, 0, 1), constituent(window, .VERB, 1, 2),
            constituent(window, .COMPLEMENT, 2, 3),
          ])
      ])[0]
    #expect(result.displaySpans(at: 0).map(\.role) == [.SUBJECT, .VERB])
    #expect(result.displaySpans(at: 1).map(\.role) == [.COMPLEMENT])
    #expect(target.tokens[0].surface == "We're")
    #expect(GrammarWindow.components("I'll") == ["I", "will"])
    #expect(GrammarWindow.components("don't") == ["do", "not"])
    #expect(GrammarWindow.components("won't") == ["will", "not"])
    #expect(GrammarWindow.components("it's") == ["it", "'s"])
    #expect(GrammarWindow.components("John's") == ["John's"])
  }
  @Test func sameClauseOverlapIsRejectedEvenIfContained() throws {
    let window = GrammarWindow(sentences: [try sentence("Help her.")])
    let bad = clause(
      "a", 0, 2, .SVO,
      [
        constituent(window, .VERB, 0, 2),
        constituent(window, .OBJECT, 1, 2),
      ], kind: .ELLIPTIC, omitted: true)
    #expect(throws: AppFailure.self) { try validate(window, [bad]) }
    let good = clause(
      "a", 0, 2, .SVO,
      [
        constituent(window, .VERB, 0, 1),
        constituent(window, .OBJECT, 1, 2),
      ], kind: .ELLIPTIC, omitted: true)
    #expect(try validate(window, [good])[0].displaySpans(at: 1).map(\.role) == [.OBJECT])
  }
  @Test func nestedObjectClauseHasOwnershipAndNoStackedObjectLabel() throws {
    let window = GrammarWindow(sentences: [try sentence("We think they painted this.")])
    let root = clause(
      "root", 0, 5, .SVO,
      [
        constituent(window, .SUBJECT, 0, 1),
        constituent(window, .VERB, 1, 2), constituent(window, .OBJECT, 2, 5, child: "child"),
      ])
    let child = clause(
      "child", 2, 5, .SVO,
      [
        constituent(window, .SUBJECT, 2, 3),
        constituent(window, .VERB, 3, 4), constituent(window, .OBJECT, 4, 5),
      ], parent: "root")
    let result = try validate(window, [root, child])[0]
    #expect(result.clauses?.count == 2)
    #expect(result.displaySpans(at: 2).map(\.role) == [.SUBJECT])
    #expect(result.displaySpans(at: 3).map(\.role) == [.VERB])
    #expect(result.displaySpans(at: 4).map(\.role) == [.OBJECT])
    var orphan = child
    orphan.parentID = nil
    #expect(throws: AppFailure.self) { try validate(window, [root, orphan]) }
    var detached = root
    detached.constituents[2].childClauseID = nil
    #expect(throws: AppFailure.self) { try validate(window, [detached, child]) }
  }
  @Test func phraseCrossesTargetBoundaryUsingGlobalCoordinates() throws {
    let before = try sentence("checking on our")
    let target = try sentence("garden gate")
    let window = GrammarWindow(sentences: [target], context: [before, target])
    #expect(window.atoms.map(\.text) == ["checking", "on", "our", "garden", "gate"])
    let fragment = clause(
      "a", 0, 5, .OTHER,
      [
        constituent(window, .VERB, 0, 1),
        constituent(window, .PREPOSITIONAL_PHRASE, 1, 5),
      ], status: .FRAGMENT, kind: .NONFINITE, omitted: true)
    let result = try validate(window, [fragment])[0]
    #expect(result.sentenceId == target.id)
    #expect(result.spans[0].role == .PREPOSITIONAL_PHRASE)
    #expect(result.spans[0].startToken == 0 && result.spans[0].endTokenExclusive == 2)
    #expect(result.spans[0].evidence == "on our garden gate")
  }
  @Test func evidencePatternCoverageAndCyclesAreValidated() throws {
    let window = GrammarWindow(sentences: [try sentence("I study music.")])
    let good = clause(
      "a", 0, 3, .SVO,
      [
        constituent(window, .SUBJECT, 0, 1),
        constituent(window, .VERB, 1, 2), constituent(window, .OBJECT, 2, 3),
      ])
    var mismatched = good
    mismatched.constituents[1].text = "you"
    #expect(throws: AppFailure.self) { try validate(window, [mismatched]) }
    var uncovered = good
    uncovered.constituents.removeLast()
    uncovered.pattern = .SV
    #expect(throws: AppFailure.self) { try validate(window, [uncovered]) }
    var pattern = good
    pattern.pattern = .SVOC
    #expect(throws: AppFailure.self) { try validate(window, [pattern]) }
    var cycle = good
    cycle.parentID = "a"
    #expect(throws: AppFailure.self) { try validate(window, [cycle]) }
    #expect(throws: AppFailure.self) { try validate(window, [good, good]) }
  }
  @Test func payloadProvidesContinuousAtomsInsteadOfIndependentTargetStrings() throws {
    let units = try ["checking on our", "garden gate", "We paint it green"].map(sentence)
    let input = try #require(
      JSONSerialization.jsonObject(
        with:
          Data(GrammarWindow(sentences: [units[1]], context: units).payload().utf8))
        as? [String: Any])
    let transcript = try #require(input["transcript"] as? [[String: Any]])
    #expect(transcript.count == 3)
    #expect(transcript.map { $0["target"] as? Bool } == [false, true, false])
    let indices = transcript.flatMap {
      ($0["atoms"] as! [[String: Any]]).map { $0["index"] as! Int }
    }
    #expect(indices == Array(indices.indices))
  }

  @Test func prepositionalPhraseMustIncludeItsHeadAndRecoveryPreservesIndependentClauses() throws {
    let first = try sentence("I study music.")
    let second = try sentence("Help her.")
    let window = GrammarWindow(sentences: [first, second])
    let good = clause(
      "good", 0, 3, .SVO,
      [
        constituent(window, .SUBJECT, 0, 1),
        constituent(window, .VERB, 1, 2), constituent(window, .OBJECT, 2, 3),
      ])
    let bad = clause(
      "bad", 4, 6, .SVO,
      [
        constituent(window, .VERB, 4, 6),
        constituent(window, .OBJECT, 5, 6),
      ], kind: .ELLIPTIC, omitted: true)
    let response = try JSONEncoder().encode(
      ClauseResponse(schemaVersion: 2, clauses: [good, bad], unresolved: []))
    #expect(throws: AppFailure.self) { try StructuredGrammar.validate(response, window: window) }
    let recovered = try StructuredGrammar.recoverValidatedClauses(response, window: window)
    #expect(recovered.map(\.sentenceId) == [first.id])
    #expect(recovered[0].spans.count == 3)
    let ppWindow = GrammarWindow(sentences: [try sentence("checking on our gate")])
    var pp = constituent(ppWindow, .PREPOSITIONAL_PHRASE, 1, 4)
    pp.headAtom = 2
    let fragment = clause(
      "pp", 0, 4, .OTHER, [constituent(ppWindow, .VERB, 0, 1), pp],
      status: .FRAGMENT, kind: .NONFINITE, omitted: true)
    #expect(throws: AppFailure.self) { try validate(ppWindow, [fragment]) }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_GRAMMAR_STRUCTURE"] == "1"))
  func syntheticRegressionWithActualProvider() async throws {
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "gpt-6-luna"
    settings.timeout = 180
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX_PATH"] ?? ""
    // Self-authored restarts and a coordinated prepositional phrase.
    let units = try [
      "We're ready.", "We'll be calm.", "We'll start we're ready.",
      "Help her with the garden and with uh watering the plants.", "She she often repairs it.",
    ].map(sentence)
    let provider = RecordingClauseProvider(settings: settings)
    let scheduler = GrammarScheduler(provider: provider, context: units)
    let results = try await scheduler.analyze(Array(units[2...4]))
    try JSONEncoder().encode(results).write(
      to: URL(fileURLWithPath: "/private/tmp/yt-grammar-structure-synthetic-results.json"))
    #expect(results.count == 3)
    let restart = try #require(results.first { $0.sentenceId == units[2].id })
    #expect(restart.displaySpans(at: 0).map(\.role).contains(.SUBJECT))
    #expect(restart.displaySpans(at: 0).map(\.role).contains(.VERB))
    #expect(restart.displaySpans(at: 2).map(\.role).contains(.SUBJECT))
    #expect(restart.displaySpans(at: 2).map(\.role).contains(.VERB))
    #expect(restart.displaySpans(at: 3).map(\.role) == [.COMPLEMENT])
    let thanks = try #require(results.first { $0.sentenceId == units[3].id })
    #expect(thanks.displaySpans(at: 0).map(\.role) == [.VERB])
    #expect(thanks.displaySpans(at: 1).map(\.role) == [.OBJECT])
    #expect(thanks.displaySpans(at: 5).map(\.role) == [.CONJUNCTION])
    #expect(
      thanks.spans.contains {
        $0.role == .PREPOSITIONAL_PHRASE && $0.startToken == 6 && $0.endTokenExclusive == 11
      })
    let appreciate = try #require(results.first { $0.sentenceId == units[4].id })
    #expect(appreciate.displaySpans(at: 1).filter { $0.role == .SUBJECT }.count == 1)
    #expect(appreciate.displaySpans(at: 3).map(\.role).contains(.VERB))
    #expect(appreciate.displaySpans(at: 4).map(\.role).contains(.OBJECT))
    for result in results {
      print("CLAUSE_RESULT " + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
    let second = try [
      "We're uh Who named her Nora Quartz?",
      "We think they painted this.", "We don't plan to walk along those narrow paths.",
      "She gave him a book.", "The man who lives here likes music.", "Running helps.",
    ].map(sentence)
    let other = try await GrammarScheduler(provider: provider, context: second).analyze(second)
    try JSONEncoder().encode(other).write(
      to: URL(fileURLWithPath: "/private/tmp/yt-grammar-structure-other-results.json"))
    #expect(other.count == second.count)
    let who = try #require(other.first { $0.sentenceId == second[0].id })
    #expect(!who.displaySpans(at: 1).contains { $0.role == .COMPLEMENT || $0.role == .VERB })
    #expect(who.displaySpans(at: 2).map(\.role) == [.SUBJECT])
    #expect(who.displaySpans(at: 3).map(\.role) == [.VERB])
    #expect(who.displaySpans(at: 4).map(\.role) == [.OBJECT])
    #expect(who.displaySpans(at: 5).map(\.role) == [.COMPLEMENT])
    let hope = try #require(other.first { $0.sentenceId == second[1].id })
    #expect(hope.displaySpans(at: 2).map(\.role) == [.SUBJECT])
    #expect(hope.displaySpans(at: 3).map(\.role) == [.VERB])
    #expect(hope.displaySpans(at: 4).map(\.role) == [.OBJECT])
    let detail = try #require(other.first { $0.sentenceId == second[2].id })
    #expect(!detail.displaySpans(at: 8).map(\.role).contains(.OBJECT))
    let gave = try #require(other.first { $0.sentenceId == second[3].id })
    #expect(gave.displaySpans(at: 2).map(\.role) == [.OBJECT1])
    #expect(gave.displaySpans(at: 4).map(\.role) == [.OBJECT2])
    let relative = try #require(other.first { $0.sentenceId == second[4].id })
    #expect(relative.displaySpans(at: 2).map(\.role) == [.SUBJECT])
    #expect(relative.displaySpans(at: 3).map(\.role) == [.VERB])
    #expect(relative.displaySpans(at: 5).map(\.role) == [.VERB])
    #expect(relative.displaySpans(at: 6).map(\.role) == [.OBJECT])
    let gerund = try #require(other.first { $0.sentenceId == second[5].id })
    #expect(gerund.spans.contains { $0.role == .SUBJECT && $0.startToken == 0 })
    #expect(gerund.displaySpans(at: 1).map(\.role) == [.VERB])
    for result in other {
      print("CLAUSE_RESULT " + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
  }
}
