import Foundation
import Testing

@testable import StudyCore

struct CoreTests {
  func fixture(_ name: String) throws -> Data {
    try Data(
      contentsOf: Bundle.module.url(
        forResource: "fixture_" + name, withExtension: "json3", subdirectory: "Fixtures")!)
  }
  func parse(_ name: String) throws -> [Sentence] {
    try CaptionPipeline().parse(fixture(name), videoID: "abcdefghijk")
  }
  @Test func testURLValidation() throws {
    XCTAssertEqual(try YouTubeURL.id("https://youtu.be/abcdefghijk?t=2"), "abcdefghijk")
    XCTAssertEqual(try YouTubeURL.id("https://www.youtube.com/watch?v=abcdefghijk"), "abcdefghijk")
    XCTAssertThrowsError(try YouTubeURL.id("https://youtube.com.evil/watch?v=abcdefghijk"))
    XCTAssertThrowsError(try YouTubeURL.id("https://youtu.be/no"))
  }
  @Test func testJSON3AndOffsets() throws {
    let s = try parse("word_level")
    XCTAssertEqual(s.count, 1)
    XCTAssertEqual(s[0].text, "Hello world.")
    XCTAssertEqual(s[0].tokens[1].startTime, 1, accuracy: 0.001)
    XCTAssertEqual(s[0].tokens[0].timingQuality, .exact)
  }
  @Test func testMultiwordInterpolation() throws {
    let ts = try parse("multiword_segments")[0].tokens
    XCTAssertEqual(ts.first!.startTime, 1)
    XCTAssertEqual(ts.last!.endTime, 4, accuracy: 0.001)
    XCTAssertTrue(ts.allSatisfy { $0.endTime > $0.startTime })
    XCTAssertEqual(ts[0].timingQuality, .anchored)
    XCTAssertGreaterThan(ts[2].endTime - ts[2].startTime, ts[0].endTime - ts[0].startTime)
  }
  @Test func testNoOffsets() throws {
    let ts = try parse("no_offsets")[0].tokens
    XCTAssertTrue(ts.allSatisfy { $0.timingQuality == .interpolated })
    XCTAssertEqual(ts.last!.endTime, 4, accuracy: 0.001)
  }
  @Test func testRollingDeduplication() throws {
    let tokens = try parse("rolling_duplicates").flatMap(\.tokens)
    XCTAssertEqual(tokens.map(\.surface), ["hello", "world", "again", "."])
  }
  @Test func testMissingDuration() throws {
    let ts = try parse("missing_duration").flatMap(\.tokens)
    XCTAssertTrue(
      ts.allSatisfy {
        $0.startTime >= 0 && $0.endTime > $0.startTime && $0.timingQuality == .estimated
      })
  }
  @Test func testSentenceReconstructionAcrossEvents() throws {
    let data = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"I like "}]},{"tStartMs":1000,"dDurationMs":2000,"segs":[{"utf8":"apples. You too?"}]}]}"#
        .utf8)
    let sentences = try CaptionPipeline().parse(data, videoID: "x")
    XCTAssertEqual(sentences.map(\.text), ["I like apples.", "You too?"])
    XCTAssertTrue(sentences.allSatisfy { s in s.tokens.allSatisfy { $0.sentenceID == s.id } })
  }
  @Test func testSafetyBoundary() throws {
    let text = Array(repeating: "word", count: 90).joined(separator: " ")
    let data = try JSONSerialization.data(withJSONObject: [
      "events": [["tStartMs": 0, "dDurationMs": 90000, "segs": [["utf8": text]]]]
    ])
    let s = try CaptionPipeline().parse(data, videoID: "x")
    XCTAssertGreaterThan(s.count, 2)
    XCTAssertTrue(s.allSatisfy { $0.tokens.count <= 40 })
  }
  @Test func testTokenEndsAndBinarySearch() throws {
    let s = try parse("word_level")
    let timeline = Timeline(s)
    XCTAssertEqual(timeline.token(at: 0.1)?.surface, "Hello")
    XCTAssertEqual(timeline.token(at: 1.1)?.surface, "world")
    XCTAssertNil(timeline.token(at: 1.95))
    XCTAssertNil(timeline.token(at: 4))
    XCTAssertNil(timeline.token(at: -1))
    XCTAssertEqual(timeline.sentence(at: 1)?.id, s[0].id)
    XCTAssertNil(timeline.sentence(at: 2))
    for t in timeline.tokens { XCTAssertGreaterThan(t.endTime, t.startTime) }
  }
  @Test func testGrammarValidation() throws {
    let sentences = try parse("word_level")
    let id = sentences[0].id.uuidString
    let valid = Data(
      "{\"schemaVersion\":1,\"results\":[{\"sentenceId\":\"\(id)\",\"pattern\":\"UNKNOWN\",\"spans\":[{\"role\":\"SUBJECT\",\"startToken\":0,\"endTokenExclusive\":1}]}]}"
        .utf8)
    XCTAssertEqual(try GrammarContract.validate(valid, sentences: sentences).count, 1)
    for bad in [
      String(data: valid, encoding: .utf8)!.replacingOccurrences(
        of: "Exclusive\":1", with: "Exclusive\":99"),
      String(data: valid, encoding: .utf8)!.replacingOccurrences(of: id, with: UUID().uuidString),
      "{}", String(data: valid, encoding: .utf8)!.replacingOccurrences(of: "UNKNOWN", with: "FAKE"),
    ] { XCTAssertThrowsError(try GrammarContract.validate(Data(bad.utf8), sentences: sentences)) }
  }
  @Test func testBatches() throws {
    let s = try parse("word_level")[0]
    XCTAssertEqual(
      GrammarContract.batches(Array(repeating: s, count: 65)).map(\.count),
      [8, 8, 8, 8, 8, 8, 8, 8, 1])
  }
  @Test func testFingerprint() {
    let a = Fingerprint.make(videoID: "x", caption: Data("a".utf8), provider: "local", model: "m")
    XCTAssertEqual(
      a, Fingerprint.make(videoID: "x", caption: Data("a".utf8), provider: "local", model: "m"))
    XCTAssertNotEqual(
      a, Fingerprint.make(videoID: "x", caption: Data("b".utf8), provider: "local", model: "m"))
    XCTAssertNotEqual(
      a, Fingerprint.make(videoID: "x", caption: Data("a".utf8), provider: "local", model: "n"))
  }
  func temporary() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
  @Test func testCacheRoundTripAndLRU() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StudyStore(directory: root)
    let s = try parse("word_level")
    let a = StudyDocument(
      video: Video(id: "a", title: "A", duration: 2), rawCaption: try fixture("word_level"),
      sentences: s)
    var b = a
    b.video.id = "b"
    try await store.save(a, fingerprint: "a", limit: 1_000_000)
    try await store.save(b, fingerprint: "b", limit: 1_000_000)
    let read = try await store.load("a")
    XCTAssertEqual(read?.sentences[0].tokens[0].id, s[0].tokens[0].id)
    try await store.evict(limit: 1, protecting: "a")
    let removed = try await store.load("b")
    XCTAssertNil(removed)
    let protected = try await store.load("a")
    XCTAssertNotNil(protected)
    try await store.clear()
    let usage = try await store.usage()
    XCTAssertEqual(usage, 0)
  }
  @Test func testEijiroNormalizationAndImport() async throws {
    XCTAssertEqual(DictionaryText.normalize(" RUN "), "run")
    XCTAssertEqual(EijiroProvider.parseLine("■run : 【動】自作基本義A")?.0, "run")
    XCTAssertEqual(DictionaryText.gloss("【動】自作基本義A；自作基本義B"), "自作基本義A")
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("import.txt")
    try "■hello : 自作あいさつ義\n■world : 自作対象義".write(to: file, atomically: true, encoding: .shiftJIS)
    let count = try await provider.importFile(file)
    XCTAssertEqual(count, 2)
    let token = try parse("word_level")[0].tokens[0]
    let result = await provider.lookup(token)
    XCTAssertEqual(result?.shortGloss, "自作あいさつ義")
    let bad = root.appendingPathComponent("bad.txt")
    try "invalid".write(to: bad, atomically: true, encoding: .utf8)
    do {
      _ = try await provider.importFile(bad)
      XCTFail()
    } catch {}
    let remaining = try await provider.count()
    XCTAssertEqual(remaining, 2)
  }
  @Test func testAutomaticTrackRejectsTranslationAndManual() throws {
    let p = VideoProbe(
      id: "x", title: "x", duration: 2, language: nil,
      automatic_captions: ["en": [CaptionTrack(ext: "json3", url: "https://x.test?tlang=en")]])
    XCTAssertThrowsError(try YtDlpProvider.select(p))
    var q = p
    q.automatic_captions = ["en-orig": [CaptionTrack(ext: "json3", url: "https://x.test?lang=en")]]
    XCTAssertEqual(try YtDlpProvider.select(q).count, 1)
  }
  @Test func testCoincidentAnchorsRemainSearchable() throws {
    let data = Data(
      #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"hello ","tOffsetMs":0},{"utf8":"world","tOffsetMs":0}]}]}"#
        .utf8)
    let timeline = Timeline(try CaptionPipeline().parse(data, videoID: "x"))
    for token in timeline.tokens where token.lexical {
      XCTAssertEqual(timeline.token(at: (token.startTime + token.endTime) / 2)?.id, token.id)
    }
  }
  @Test func testCancellationOfProcess() async throws {
    let task = Task {
      try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancel ignored")
    } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
  }
}

private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
private func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) {
  #expect(abs(a - b) <= accuracy)
}
private func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a != b) }
private func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T) { #expect(a > b) }
private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
private func XCTAssertNotNil<T>(_ value: T?) { #expect(value != nil) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
  do {
    _ = try expression()
    Issue.record("Expected error")
  } catch {}
}
private func XCTFail(_ message: String = "Failed") { Issue.record(Comment(rawValue: message)) }
