import Foundation
import StudyCore

@main struct Measure {
  static func main() async throws {
    guard CommandLine.arguments.count >= 2 else {
      throw NSError(
        domain: "benchmark", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Pass a local JSON3 file path"])
    }
    let caption = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let sentences = try CaptionPipeline().parse(caption, videoID: "benchmark")
    let initial = sentences.filter { $0.startTime < 300 }
    let batches = GrammarContract.batches(initial)
    var payloadBytes = 0
    var readingBytes = 0
    var legacyBytes = 0
    for batch in batches {
      let window = GrammarWindow(sentences: batch, context: sentences)
      payloadBytes += try window.payload().utf8.count
      legacyBytes += try window.payload(compact: false).utf8.count
      readingBytes += try window.readingPayload().utf8.count
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StudyStore(directory: root)
    let document = StudyDocument(
      video: try JSONDecoder().decode(
        Video.self, from: Data(#"{"id":"benchmark","title":"Benchmark","duration":900}"#.utf8)),
      rawCaption: caption, sentences: sentences)
    try await store.save(document, fingerprint: "benchmark", limit: 100_000_000)
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<3 { try await store.save(document, fingerprint: "benchmark", limit: 100_000_000) }
    let fullSaveMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 3
    let changed = Set(sentences.prefix(2).map(\.id))
    let progressStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 {
      try await store.saveProgress(
        document, changed: changed, fingerprint: "benchmark", limit: 100_000_000)
    }
    let progressSaveMilliseconds =
      (ProcessInfo.processInfo.systemUptime - progressStart) * 1000 / 30
    let stats: [String: Any] = [
      "sentences": sentences.count, "tokens": sentences.flatMap(\.tokens).count,
      "initialSentences": initial.count, "initialBatches": batches.count,
      "compilePayloadBytes": payloadBytes, "readingPayloadBytes": readingBytes,
      "legacySameWindowBytes": legacyBytes, "progressSaveMilliseconds": progressSaveMilliseconds,
      "fullSaveMilliseconds": fullSaveMilliseconds,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if CommandLine.arguments.count > 2 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
  }
}
