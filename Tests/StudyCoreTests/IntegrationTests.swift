import Foundation
import Testing

@testable import StudyCore

final class MockCompletionProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "mock.local"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard request.url?.path == "/v1/chat/completions", request.httpMethod == "POST" else {
        throw AppFailure("Unexpected endpoint")
      }
      let stream = request.httpBodyStream
      stream?.open()
      defer { stream?.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      if let stream {
        while true {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n <= 0 { break }
          bytes.append(contentsOf: buffer.prefix(n))
        }
      } else {
        bytes = request.httpBody ?? Data()
      }
      let root = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      let messages = root["messages"] as! [[String: String]]
      let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8))
      let response: Data
      if let input = input as? [String: Any] {
        let transcript = input["transcript"] as! [[String: Any]]
        let atoms = transcript.flatMap { $0["atoms"] as! [[Any]] }
        response = try JSONSerialization.data(withJSONObject: [
          "schemaVersion": 2, "clauses": [],
          "unresolved": [
            ["startAtom": 0, "endAtomExclusive": atoms.count, "reason": "テスト用の未確定範囲"]
          ],
        ])
      } else {
        response = Data(#"{"clauses":[],"notes":"テスト用"}"#.utf8)
      }
      let data = try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": String(data: response, encoding: .utf8)!]]]
      ])
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
struct IntegrationTests {
  @Test func localCompletionRoundTrip() async throws {
    var config = AppSettings()
    config.baseURL = "http://mock.local/v1"
    config.model = "test-model"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockCompletionProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let sentences = try CaptionPipeline().parse(
      Data(
        #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"Hello world."}]}]}"#.utf8),
      videoID: "test")
    let scheduler = GrammarScheduler(
      provider: LocalGrammarProvider(settings: config, session: session))
    let results = try await scheduler.analyze(sentences)
    #expect(results.count == 1)
    #expect(results[0].sentenceId == sentences[0].id)
  }
  @Test func queueSeekPriorityAndDeduplication() async throws {
    let data = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello."}]},{"tStartMs":1000,"dDurationMs":1000,"segs":[{"utf8":"World."}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(data, videoID: "x")
    let scheduler = GrammarScheduler(provider: LocalGrammarProvider(settings: AppSettings()))
    await scheduler.enqueue(sentences)
    await scheduler.enqueue([sentences[1]], priority: true)
    let batch = await scheduler.next()
    #expect(batch.map(\.id) == [sentences[1].id, sentences[0].id])
    let empty = await scheduler.next()
    #expect(empty.isEmpty)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STUDY_LIVE_CAPTION"] != nil))
  func downloadedCaptionPipeline() async throws {
    let path = ProcessInfo.processInfo.environment["STUDY_LIVE_CAPTION"]!
    let sentences = try await CaptionService().parse(
      Data(contentsOf: URL(fileURLWithPath: path)), videoID: "abcdefghijk")
    let tokens = sentences.flatMap(\.tokens)
    #expect(sentences.count > 10)
    #expect(tokens.count > 100)
    #expect(tokens.allSatisfy { $0.startTime >= 0 && $0.endTime > $0.startTime })
    #expect(
      sentences.allSatisfy { sentence in
        sentence.tokens.allSatisfy { t in t.sentenceID == sentence.id }
      })
    let timeline = Timeline(sentences)
    for token in tokens where token.lexical {
      #expect(timeline.token(at: (token.startTime + token.endTime) / 2)?.id == token.id)
    }
    print("Live caption: \(sentences.count) sentences, \(tokens.count) tokens")
  }
}
