import Foundation
import Testing

@testable import StudyCore

private actor PerformanceProvider: GrammarProvider {
  nonisolated let identity = "offline-performance"
  nonisolated let concurrencyLimit: Int
  let delay: Duration
  var calls = 0
  var active = 0
  var peak = 0
  init(limit: Int = 1, delay: Duration = .milliseconds(20)) {
    concurrencyLimit = limit
    self.delay = delay
  }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    try await analyze(
      sentences, context: [], repair: repair, validationFeedback: validationFeedback)
  }
  func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    calls += 1
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    try await Task.sleep(for: delay)
    if !repair { return Data(#"{"clauses":[],"notes":[]}"#.utf8) }
    let window = GrammarWindow(sentences: sentences, context: context)
    let clauses = sentences.map { sentence in
      let start = window.owners.firstIndex(of: sentence.id)!
      let constituents = [Role.SUBJECT, .VERB, .OBJECT].enumerated().map { i, role in
        GrammarConstituent(
          role: role, startAtom: start + i, endAtomExclusive: start + i + 1,
          text: window.atoms[start + i].text, childClauseID: nil)
      }
      return GrammarClause(
        id: sentence.id.uuidString, parentID: nil, startAtom: start, endAtomExclusive: start + 3,
        kind: .FINITE, status: .COMPLETE, subjectOmitted: false, pattern: .SVO,
        constituents: constituents)
    }
    return try JSONEncoder().encode(
      ClauseResponse(schemaVersion: 2, clauses: clauses, unresolved: []))
  }
  func stats() -> (Int, Int) { (calls, peak) }
}

struct GrammarPerformanceTests {
  func sentences(_ count: Int = 3) throws -> [Sentence] {
    let events = (0..<count).map { i in
      [
        "tStartMs": i * 1000, "dDurationMs": 900,
        "segs": [["utf8": "I study \(["music", "books", "English"][i % 3])."]],
      ]
        as [String: Any]
    }
    return try CaptionPipeline().parse(
      JSONSerialization.data(withJSONObject: ["events": events]), videoID: "performance")
  }
  @Test func compactRowsPreserveEveryAtomAndContextField() throws {
    var units = try sentences()
    units[1].tokens[0].surface = "I'm"
    let window = GrammarWindow(sentences: [units[1]], context: units)
    let compact = try #require(
      JSONSerialization.jsonObject(with: Data(window.payload().utf8)) as? [String: Any])
    let legacy = try #require(
      JSONSerialization.jsonObject(with: Data(window.payload(compact: false).utf8))
        as? [String: Any])
    #expect(compact["wireVersion"] as? Int == GrammarContract.wireVersion)
    #expect(compact["atomColumns"] as? [String] == ["index", "text", "sourceToken", "function?"])
    #expect(
      compact["requestedSentenceIds"] as? [String] == legacy["requestedSentenceIds"] as? [String])
    let rows = try #require(compact["transcript"] as? [[String: Any]])
    let old = try #require(legacy["transcript"] as? [[String: Any]])
    for (row, original) in zip(rows, old) {
      for field in ["sentenceId", "text", "target", "startTime", "endTime"] {
        #expect(String(describing: row[field]!) == String(describing: original[field]!))
      }
      let atoms = try #require(row["atoms"] as? [[Any]])
      let objects = try #require(original["atoms"] as? [[String: Any]])
      #expect(atoms.count == objects.count)
      for (atom, object) in zip(atoms, objects) {
        #expect(atom[0] as? Int == object["index"] as? Int)
        #expect(atom[1] as? String == object["text"] as? String)
        #expect(atom[2] as? Int == object["sourceToken"] as? Int)
        #expect((atom.count == 4 ? atom[3] as? String : nil) == object["function"] as? String)
      }
    }
    #expect(try window.payload().utf8.count < window.payload(compact: false).utf8.count)
    #expect(
      window.atoms.filter { window.owners[$0.index] == units[1].id }.prefix(2).map(\.text) == [
        "I", "am",
      ])
  }
  @Test func completedAndConcurrentDuplicateRequestsDoNotRepeatBothPasses() async throws {
    let units = try sentences(1)
    let provider = PerformanceProvider()
    let scheduler = GrammarScheduler(provider: provider, context: units)
    async let first = scheduler.analyze(units)
    async let second = scheduler.analyze(units)
    let results = try await [first, second]
    #expect(results.allSatisfy { $0.first?.pattern == .SVO })
    #expect(await provider.stats().0 == 2)
    await scheduler.enqueue(units)
    #expect(await scheduler.next().isEmpty)
    _ = try await scheduler.analyze(units)
    #expect(await provider.stats().0 == 2)
    await scheduler.enqueue(units, retryFailed: true)
    _ = try await scheduler.analyze(await scheduler.next())
    #expect(await provider.stats().0 == 4)
  }
  @Test func focusDropsDistantQueuedWorkButPreservesExplicitRetry() async throws {
    let units = try sentences()
    let scheduler = GrammarScheduler(provider: PerformanceProvider(), context: units)
    await scheduler.enqueue(units)
    #expect(await scheduler.focus(on: [units[1]]).map(\.id) == [units[0].id, units[2].id])
    #expect(await scheduler.next(maxSentences: 1).map(\.id) == [units[1].id])
    await scheduler.enqueue([units[0]], retryFailed: true)
    await scheduler.focus(on: [units[2]])
    #expect(await scheduler.next(maxSentences: 1).map(\.id) == [units[2].id])
    #expect(await scheduler.next(maxSentences: 1).map(\.id) == [units[0].id])
  }
  @Test func workersHonorProviderCapacity() async throws {
    let units = try sentences()
    for limit in [1, 2] {
      let provider = PerformanceProvider(limit: limit)
      let scheduler = GrammarScheduler(provider: provider, context: units)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for unit in units { group.addTask { _ = try await scheduler.analyze([unit]) } }
        try await group.waitForAll()
      }
      #expect(await provider.stats().0 == 6)
      #expect(await provider.stats().1 == limit)
    }
  }
  @Test func cancellationReleasesSlotAndPendingIDsWithoutMarkingFailure() async throws {
    let units = try sentences(1)
    let provider = PerformanceProvider(delay: .milliseconds(40))
    let scheduler = GrammarScheduler(provider: provider, context: units)
    await scheduler.enqueue(units)
    let batch = await scheduler.next()
    let task = Task { try await scheduler.analyze(batch) }
    for _ in 0..<100 {
      if await provider.stats().0 > 0 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await scheduler.enqueue(units)
    #expect(await scheduler.next().count == 1)
    #expect(try await scheduler.analyze(units).first?.pattern == .SVO)
  }
  @Test func ordinaryLookAheadKeepsRunningWorkAndSeekCanCancelIt() async throws {
    let units = try sentences()
    let provider = PerformanceProvider(delay: .milliseconds(30))
    let scheduler = GrammarScheduler(provider: provider, context: units)
    let first = Task { try await scheduler.analyze([units[0]]) }
    for _ in 0..<100 {
      if await provider.stats().0 > 0 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    await scheduler.focus(on: [units[2]])
    #expect(try await first.value.first?.pattern == .SVO)
    let next = Task { try await scheduler.analyze([units[1]]) }
    for _ in 0..<100 {
      if await provider.stats().0 > 2 { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    await scheduler.focus(on: [units[2]], cancelObsolete: true)
    await #expect(throws: CancellationError.self) { try await next.value }
    #expect(await scheduler.next().map(\.id) == [units[2].id])
  }
  @Test func providerCapacityMigratesSeparatelyAndIsBounded() throws {
    let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(old.localConcurrency == 1 && old.codexConcurrency == 1)
    var settings = old
    settings.localConcurrency = 1
    settings.codexConcurrency = 2
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.localConcurrency == 1 && decoded.codexConcurrency == 2)
    let invalid = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"localConcurrency":0,"codexConcurrency":99}"#.utf8))
    #expect(invalid.localConcurrency == 1 && invalid.codexConcurrency == 2)
    #expect(LocalGrammarProvider(settings: decoded).concurrencyLimit == 1)
    #expect(CodexGrammarProvider(settings: decoded).concurrencyLimit == 2)
  }
}
