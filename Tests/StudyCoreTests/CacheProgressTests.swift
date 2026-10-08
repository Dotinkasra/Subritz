import Foundation
import Testing

@testable import StudyCore

struct CacheProgressTests {
  func document() throws -> StudyDocument {
    let raw = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":900,"segs":[{"utf8":"I study music."}]},{"tStartMs":1000,"dDurationMs":900,"segs":[{"utf8":"You read books."}]}]}"#
        .utf8)
    return StudyDocument(
      video: Video(id: "test", title: "Test", duration: 2), rawCaption: raw,
      sentences: try CaptionPipeline().parse(raw, videoID: "test"))
  }
  func complete(_ doc: inout StudyDocument, _ index: Int) {
    doc.sentences[index].grammarStatus = .completed
    doc.sentences[index].grammarAnalysis = Analysis(
      sentenceId: doc.sentences[index].id, pattern: .SVO,
      spans: [Span(role: .SUBJECT, startToken: 0, endTokenExclusive: 1, confidence: .HIGH)])
    doc.sentences[index].tokens[0].grammarRole = .SUBJECT
  }
  @Test func incrementalResultsAndDeletionMatchFullSnapshotIncludingSize() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let incremental = try StudyStore(directory: root.appendingPathComponent("delta"))
    let full = try StudyStore(directory: root.appendingPathComponent("full"))
    var doc = try document()
    try await incremental.saveProgress(doc, changed: [], fingerprint: "key", limit: 1_000_000)
    complete(&doc, 0)
    try await incremental.saveProgress(
      doc, changed: [doc.sentences[0].id], fingerprint: "key", limit: 1_000_000)
    let first = try #require(await incremental.load("key"))
    #expect(first.sentences[0].grammarAnalysis?.pattern == .SVO)
    #expect(first.sentences[1].grammarAnalysis == nil)
    #expect(first.rawCaption == doc.rawCaption)
    #expect(
      first.sentences.flatMap(\.tokens).map(\.startTime)
        == doc.sentences.flatMap(\.tokens).map(\.startTime))
    complete(&doc, 1)
    doc.sentences[0].grammarAnalysis = nil
    doc.sentences[0].grammarStatus = .failed
    doc.sentences[0].tokens[0].grammarRole = nil
    try await incremental.saveProgress(
      doc, changed: Set(doc.sentences.map(\.id)), fingerprint: "key", limit: 1_000_000)
    try await full.save(doc, fingerprint: "key", limit: 1_000_000)
    let reloaded = try #require(await incremental.load("key"))
    #expect(
      reloaded.sentences[0].grammarAnalysis == nil
        && reloaded.sentences[0].grammarStatus == .notQueued
    )
    #expect(reloaded.sentences[1].tokens[0].grammarRole == .SUBJECT)
    #expect(try await incremental.usage() == full.usage())
    try await incremental.clear()
    try await incremental.saveProgress(
      doc, changed: [doc.sentences[1].id], fingerprint: "key", limit: 1_000_000)
    #expect(try await incremental.load("key")?.sentences.count == 2)
    #expect(try await incremental.usage() == full.usage())
  }
  @Test func canceledProgressWritePreservesPreviousSnapshot() async throws {
    let root = try CoreTests().temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StudyStore(directory: root)
    var doc = try document()
    try await store.save(doc, fingerprint: "key", limit: 1_000_000)
    let size = try await store.usage()
    complete(&doc, 0)
    let updated = doc
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.saveProgress(
        updated, changed: [updated.sentences[0].id], fingerprint: "key", limit: 1_000_000)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.load("key")?.sentences[0].grammarAnalysis == nil)
    #expect(try await store.usage() == size)
  }
}
