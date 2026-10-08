import Foundation
import Testing

@testable import StudyCore

// All definitions and examples below are independently authored test data.
struct EijiroTests {
  static let expected = "自作名義A、自作名義B、自作名義C、自作名義D、自作名義E（補足、注記）、自作名義F"
  let records = [
    ("sampleunit", "【レベル】9、【発音】sample-pronunciation、【＠】テスト音、【変化】《複》sampleunits"),
    ("sampleunit  {名-1}", "〔テスト補足A〕自作名義A、自作名義B"),
    ("sampleunit  {名-2}", "〔テスト補足B〕自作名義C、自作名義D"),
    ("sampleunit  {名-3}", "〔テスト補足C〕自作名義E（補足、注記）、自作名義F■・A silver robot sorts seven paper stars. 銀色のロボットが紙の星を七つ整理する。"),
    ("sampleunit  {名-4}", "〔テスト補足D〕自作名義G"),
    ("sampleunit  {名-5}", "自作名義H"),
    ("sampleunit  {名-6}", "自作名義I"),
    ("sampleunit  {他動-1}", "自作動義A"),
    ("sampleunit analysis", "自作別見出し義"),
  ]
  func token(_ word: String = "sampleunit", pos: String? = "Noun") -> Token {
    Token(
      index: 0, surface: word, normalized: word.lowercased(), lemma: nil,
      partOfSpeech: pos, startTime: 0, endTime: 1, timingQuality: .estimated, lexical: true)
  }
  @Test func previouslyImportedSenseHeadwords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let db = try SQLiteDatabase(url: root.appendingPathComponent("eijiro.sqlite"))
    for (headword, definition) in records.reversed() {
      try db.execute(
        "INSERT INTO entries VALUES(?,?,?)",
        values: [headword, DictionaryText.normalize(headword), definition])
    }
    let noun = await provider.lookup(token("Sampleunit"))
    #expect(noun?.shortGloss == Self.expected)
    #expect(noun?.definition.contains("{名-6}") == true)
    #expect(noun?.definition.contains("A silver robot sorts seven paper stars") == true)
    #expect(noun?.definition.contains("【発音】") == true)
    #expect(noun?.definition.contains("自作別見出し義") == false)
    let verb = await provider.lookup(token(pos: "Verb"))
    #expect(verb?.shortGloss == "自作動義A")
  }
  @Test func newImportUsesBaseHeadwordAndKeepsDetails() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("dictionary.txt")
    try records.map { "■\($0.0) : \($0.1)" }.joined(separator: "\n")
      .write(to: file, atomically: true, encoding: .utf8)
    let count = try await provider.importFile(file)
    #expect(count == records.count)
    let entry = await provider.lookup(token())
    #expect(entry?.shortGloss == Self.expected)
    let db = try SQLiteDatabase(url: root.appendingPathComponent("eijiro.sqlite"))
    #expect(
      try db.rows("SELECT COUNT(*) FROM entries WHERE normalized_headword=?", values: ["sampleunit"])[
        0][0] == "8")
  }
  @Test func metadataCannotBecomeAMeaning() {
    let entry = EijiroText.entry([EijiroText.sense("sampleunit", "【レベル】9、【発音】テスト音")], pos: "Noun")
    #expect(entry.shortGloss == "日本語の語義なし")
  }
  @Test func homographsCompositePartsOfSpeechAndArticles() {
    let senses = [
      EijiroText.sense("testword  {1-他動-10}", "自作動義J"),
      EijiroText.sense("testword  {1-他動-2}", "自作動義C◆自作補足■・A robot marks a blue tile. ロボットが青いタイルに印を付ける。"),
      EijiroText.sense("testword  {1-他動-1}", "自作動義B"),
      EijiroText.sense("testword  {1-他動-3}", "自作動義D"),
      EijiroText.sense("testword  {2-前-1}", "自作前置義"),
      EijiroText.sense("testword  {1}", "【レベル】9、【発音】テスト音"),
    ]
    #expect(EijiroText.entry(senses, pos: "Verb").shortGloss == "自作動義B、自作動義C、自作動義D")
    #expect(EijiroText.entry(senses, pos: "Preposition").shortGloss == "自作前置義")
    let compound = EijiroText.sense("mosaicword  {2-名・形}", "自作複合義")
    #expect(compound.headword == "mosaicword")
    #expect(compound.group == 2)
    #expect(EijiroText.matches(compound, pos: "Noun"))
    #expect(EijiroText.matches(compound, pos: "Adjective"))
    #expect(EijiroText.matches(EijiroText.sense("is  {自動・助動}", "自作助動義"), pos: "Verb"))
    #expect(EijiroText.matches(EijiroText.sense("the  {定-1}", "自作定冠詞義"), pos: "Determiner"))
    #expect(EijiroText.matches(EijiroText.sense("an  {1-不}", "自作不定冠詞義"), pos: "Determiner"))
  }
  @Test func lemmaFallbackReferencesAndCycles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("dictionary.txt")
    try """
    ■running : 【発音】テスト音
    ■running  {名} : 自作名義J
    ■run  {自動-1} : 〔自作補足〕自作走行義A、自作走行義B
    ■is  {自動・助動} : beの自作参照用の活用形
    ■be  {自動-1} : 自作存在義A、自作存在義B、自作存在義C
    ■colour  {名・動} : ＝<→color>
    ■color  {名-1} : 自作色義A、自作色義B
    ■loop  {名} : ＝<→cycle>
    ■cycle  {名} : ＝<→loop>
    """.write(to: file, atomically: true, encoding: .shiftJIS)
    _ = try await provider.importFile(file)
    var running = token("running", pos: "Verb")
    running.lemma = "run"
    #expect(await provider.lookup(running)?.shortGloss == "自作走行義A、自作走行義B")
    #expect(await provider.lookup(token("is", pos: "Verb"))?.shortGloss == "自作存在義A、自作存在義B、自作存在義C")
    let colour = await provider.lookup(token("colour"))
    #expect(colour?.shortGloss == "自作色義A、自作色義B")
    #expect(colour?.definition.contains("参照先: color") == true)
    #expect(await provider.lookup(token("loop"))?.shortGloss == "日本語の語義なし")
  }
  @Test func authoredFixtureSupportsUtf8AndShiftJIS() async throws {
    for encoding in [String.Encoding.utf8, .shiftJIS] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let provider = try EijiroProvider(directory: root)
      let file = root.appendingPathComponent("authored-fixture.txt")
      try records.map { "■\($0.0) : \($0.1)" }.joined(separator: "\n")
        .write(to: file, atomically: true, encoding: encoding)
      #expect(try await provider.importFile(file) == records.count)
      #expect(await provider.lookup(token())?.shortGloss == Self.expected)
    }
  }
  @Test func separateAuthoredDictionariesKeepTheirOwnMeanings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try EijiroProvider(directory: root.appendingPathComponent("first"))
    let second = try EijiroProvider(directory: root.appendingPathComponent("second"))
    let file = root.appendingPathComponent("authored-fixture.txt")
    try "■sampleunit {名} : 自作隔離義A".write(to: file, atomically: true, encoding: .utf8)
    _ = try await first.importFile(file)
    try "■sampleunit {名} : 自作隔離義B".write(to: file, atomically: true, encoding: .utf8)
    _ = try await second.importFile(file)
    #expect(await first.lookup(token())?.shortGloss == "自作隔離義A")
    #expect(await second.lookup(token())?.shortGloss == "自作隔離義B")
  }
}
