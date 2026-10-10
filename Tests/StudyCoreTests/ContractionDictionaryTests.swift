import Foundation
import Testing

@testable import StudyCore

// Linguistic expansions and independently authored meanings; no dictionary excerpts.
struct ContractionDictionaryTests {
  func token(_ surface: String, pos: String? = "Pronoun") -> Token {
    EijiroTests().token(surface, pos: pos)
  }
  func abbreviation(_ word: String, forms: [String]) -> String {
    "■\(word) {省略形-1} : ＝" + forms.map { "<→\($0)>" }.joined(separator: "、")
  }
  func dictionary(_ root: URL) async throws -> EijiroProvider {
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored-contractions.txt")
    let records = [
      abbreviation("there's", forms: ["there is", "there has"]),
      "■there's : 【発音】テスト音",
      "■there is {動} : 自作存在義A",
      "■there has {助動} : 自作完了義B",
      abbreviation("I'm", forms: ["I am"]),
      abbreviation("it's", forms: ["it is", "it has"]),
      abbreviation("I'd", forms: ["I had", "I would"]),
      abbreviation("won't", forms: ["will not"]),
      "■will not {助動} : 自作否定義C",
      "■can't {助動} : 自作否定義D",
      "■robot {名} : 自作名詞義E",
      "■mosaicabbr {省略形} : ＝<→missingform>、<→definedform>、<→definedform>",
      "■definedform {動} : 自作参照義F",
      abbreviation("cycleabbrA", forms: ["cycleabbrB"]),
      abbreviation("cycleabbrB", forms: ["cycleabbrA"]),
    ]
    try records.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    return provider
  }
  @Test(arguments: ["There's", "there’s", "THERE'S"])
  func abbreviationKeepsEveryExpansionDespiteOriginalPartOfSpeech(surface: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    for pos in ["Pronoun", "Verb", "Adverb", nil] {
      let entry = try #require(await provider.lookup(token(surface, pos: pos)))
      #expect(entry.expandedForms == ["there is", "there has"])
      #expect(entry.partOfSpeech == "省略形")
      #expect(entry.shortGloss == "自作存在義A、自作完了義B")
      #expect(entry.definition.contains("参照先: there is") && entry.definition.contains("参照先: there has"))
      #expect(!entry.shortGloss.contains("テスト音"))
    }
  }
  @Test func missingExpansionRecordsStillExplainTheContraction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    for (surface, forms) in [("I’m", ["I am"]), ("it's", ["it is", "it has"]), ("I'd", ["I had", "I would"])] {
      let entry = try #require(await provider.lookup(token(surface)))
      #expect(entry.expandedForms == forms && entry.partOfSpeech == "省略形")
      #expect(entry.shortGloss == forms.joined(separator: " / ") + " の省略形")
    }
    let negative = try #require(await provider.lookup(token("won't", pos: "Verb")))
    #expect(negative.shortGloss == "自作否定義C" && negative.expandedForms == ["will not"])
  }
  @Test func missingFirstReferenceDoesNotHideLaterMeaningsAndCyclesAreBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    let entry = try #require(await provider.lookup(token("mosaicabbr")))
    #expect(entry.shortGloss == "自作参照義F")
    #expect(entry.expandedForms == ["missingform", "definedform"])
    let cycle = try #require(await provider.lookup(token("cycleabbrA")))
    #expect(cycle.expandedForms == ["cycleabbrB"])
    #expect(cycle.definition.count < 1000)
  }
  @Test func lexicalNegativesAndPossessivesRetainTheirOwnLookupBehavior() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    let negative = try #require(await provider.lookup(token("can't", pos: "Verb")))
    #expect(negative.shortGloss == "自作否定義D" && negative.expandedForms.isEmpty)
    var possessive = token("robot's", pos: "Noun")
    possessive.lemma = "robot"
    let noun = try #require(await provider.lookup(possessive))
    #expect(noun.shortGloss == "自作名詞義E" && noun.expandedForms.isEmpty)
    #expect(DictionaryText.candidates(token("There’s")).contains("there's"))
  }
  @Test func legacyImportNeedsNoReimportForAbbreviations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let db = try SQLiteDatabase(url: root.appendingPathComponent("eijiro.sqlite"))
    for spaces in ["", " ", "  ", "　"] {
      let headword = "there's" + spaces + "{省略形}"
      try db.execute("INSERT INTO entries VALUES(?,?,?)", values: [headword, DictionaryText.normalize(headword), "＝<→authored expansion>"])
    }
    try db.execute("INSERT INTO entries VALUES(?,?,?)", values: ["authored expansion {動}", "authored expansion {動}", "自作互換義G"])
    let entry = try #require(await provider.lookup(token("There's")))
    #expect(entry.shortGloss == "自作互換義G" && entry.expandedForms == ["authored expansion"])
  }
}
