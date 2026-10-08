import Foundation
import Testing

@testable import StudyCore

private actor RepairProvider: GrammarProvider {
  nonisolated let usesClauseStructure = false
  nonisolated let identity = "repair-test"
  let valid: Data
  let succeeds: Bool
  var requests: [(Bool, String?)] = []
  init(valid: Data, succeeds: Bool) {
    self.valid = valid
    self.succeeds = succeeds
  }
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  {
    requests.append((repair, validationFeedback))
    return repair && succeeds ? valid : Data("{}".utf8)
  }
  func calls() -> [(Bool, String?)] { requests }
}
struct GrammarRepairTests {
  func fixture() throws -> ([Sentence], Data) {
    let sentences = try CaptionPipeline().parse(
      Data(#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello."}]}]}"#.utf8),
      videoID: "test")
    let result = GrammarResponse(
      schemaVersion: 1,
      results: [Analysis(sentenceId: sentences[0].id, pattern: .UNKNOWN, spans: [])])
    return (sentences, try JSONEncoder().encode(result))
  }
  @Test func repairReceivesValidationFeedback() async throws {
    let (sentences, data) = try fixture()
    let provider = RepairProvider(valid: data, succeeds: true)
    let scheduler = GrammarScheduler(provider: provider)
    let result = try await scheduler.analyze(sentences)
    #expect(result.count == 1)
    let calls = await provider.calls()
    #expect(calls.count == 2)
    #expect(!calls[0].0)
    #expect(calls[1].0)
    #expect(calls[1].1?.contains("JSON decoding") == true)
  }
  @Test func invalidRepairStopsAfterOneRetry() async throws {
    let (sentences, data) = try fixture()
    let provider = RepairProvider(valid: data, succeeds: false)
    let scheduler = GrammarScheduler(provider: provider)
    do {
      _ = try await scheduler.analyze(sentences)
      Issue.record("Invalid result accepted")
    } catch let error as AppFailure { #expect(error.code == .grammarInvalidResponse) }
    let calls = await provider.calls()
    #expect(calls.count == 2)
  }
}
