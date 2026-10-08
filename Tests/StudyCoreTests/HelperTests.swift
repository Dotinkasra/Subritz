import Foundation
import Testing

@testable import StudyCore

struct HelperTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX"] != nil))
  func liveCodexGrammarRoundTrip() async throws {
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = "GPT-6-Luna"
    settings.codexPath = ProcessInfo.processInfo.environment["STUDY_LIVE_CODEX"]!
    settings.timeout = 60
    let sentences = try CaptionPipeline().parse(
      Data(
        #"{"events":[{"tStartMs":0,"dDurationMs":3000,"segs":[{"utf8":"I study English. She likes music."}]}]}"#
          .utf8), videoID: "test")
    let scheduler = GrammarScheduler(provider: CodexGrammarProvider(settings: settings))
    let results = try await scheduler.analyze(sentences)
    #expect(results.count == 2)
    #expect(Set(results.map(\.sentenceId)) == Set(sentences.map(\.id)))
  }
  @Test func modelCaseNormalization() throws {
    var settings = AppSettings()
    settings.provider = "codex"
    settings.model = " GPT-6-Luna "
    #expect(settings.grammarModel == "gpt-6-luna")
    settings.provider = "local"
    #expect(settings.grammarModel == "GPT-6-Luna")
    settings.provider = "codex"
    settings.model = ""
    #expect(settings.grammarModel.isEmpty)
  }
  @Test func modelFailureClassification() {
    let error = HelperFailure.make(
      name: "codex", status: 1,
      stderr:
        "ERROR: The 'GPT-6-Luna' model is not supported when using Codex with a ChatGPT account.")
    #expect(error.code == .grammarProviderUnavailable)
    #expect(error.message.contains("モデル"))
    #expect(!error.message.contains("動画"))
    #expect(error.details?.contains("GPT-6-Luna") == true)
  }
  @Test func diagnosticsRedactSecrets() {
    let error = HelperFailure.make(
      name: "codex", status: 1,
      stderr:
        "ERROR: Authorization Bearer private-secret\nERROR: api_key=private-key\nERROR: connection failed https://example.test/path?secret=abc"
    )
    #expect(error.details?.contains("private-secret") == false)
    #expect(error.details?.contains("private-key") == false)
    #expect(error.details?.contains("secret=abc") == false)
  }
  @Test func paragraphFormatting() {
    #expect(DictionaryText.paragraphs("意味1\n\n意味2") == ["意味1", "意味2"])
    #expect(DictionaryText.paragraphs("word 1. first 2. second").count == 3)
  }
  @Test func processPreservesFailureCause() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("codex")
    try "#!/bin/sh\nprintf '%s\\n' \"ERROR: model is not supported\" >&2\nexit 1\n".write(
      to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    do {
      _ = try await CommandRunner.run(helper, arguments: [])
      Issue.record("Expected failure")
    } catch let error as AppFailure {
      #expect(error.code == .grammarProviderUnavailable)
      #expect(error.details?.contains("model is not supported") == true)
    }
  }
}
