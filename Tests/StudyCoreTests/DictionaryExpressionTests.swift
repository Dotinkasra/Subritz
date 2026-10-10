import Foundation
import Testing
@testable import StudyCore

struct DictionaryExpressionTests {
  func words(_ text: String) throws -> [Token] {
    let raw = try JSONSerialization.data(withJSONObject: ["events": [[
      "tStartMs": 0, "dDurationMs": 5000, "segs": [["utf8": text]]]]])
    return try CaptionPipeline().parse(raw, videoID: "test").flatMap(\.tokens)
  }
  func dictionary(_ root: URL) async throws -> EijiroProvider {
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("phrases.txt")
    try """
    ■stack up  {句自動} : 自作句義A、自作句義B、自作句義C、自作句義D、自作句義E■・The copper robot stacks up seven tiles. 銅色のロボットが七枚のタイルを置く。
    ■stack up  {句他動-1} : 自作他動句義A、自作他動句義B
    ■stack up red cubes : 自作長句義
    ■look ahead to : 自作熟語義A
    ■at the edge of : 自作熟語義B
    ■signal box  {名} : 自作複合名義
    ■stack  {名} : 自作名義A、自作名義B
    """.write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    return provider
  }
  @Test func inflectedExpressionsResolveWithoutPartOfSpeechDependency() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    for surface in ["stacks up", "stacked up", "stacking up"] {
      var tokens = try words(surface)
      for i in tokens.indices { tokens[i].lemma = nil; tokens[i].partOfSpeech = "Noun" }
      let entry = await provider.lookupExpressions([tokens])[0]
      #expect(entry?.headword == "stack up" && entry?.partOfSpeech == "句動詞")
      #expect(entry?.shortGloss.hasPrefix("自作句義A") == true)
      #expect(entry?.definition.contains("The copper robot stacks up seven tiles") == true)
    }
    #expect(await provider.lookupExpressions([try words("up near")])[0] == nil)
    let noun = await provider.lookupExpressions([try words("signal box")])[0]
    #expect(noun?.partOfSpeech == "名詞" && noun?.shortGloss == "自作複合名義")
  }
  @Test func longestRegisteredExpressionIsSharedByItsWords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    let tokens = try words("robot stacks up red cubes near a bench.")
    let anchors = Array(tokens[1...4])
    let matches = await DictionaryExpressions.matches(anchors: anchors, in: tokens, provider: provider)
    for anchor in anchors {
      #expect(matches[anchor.id]?.expression.token.surface == "stacks up red cubes")
      #expect(matches[anchor.id]?.entry.headword == "stack up red cubes")
    }
    #expect(Set(matches.values.map { $0.expression.id }).count == 1)
    let idiom = try words("looking ahead to a copper tower.")
    let found = await DictionaryExpressions.matches(anchors: [idiom[1]], in: idiom, provider: provider)
    #expect(found[idiom[1].id]?.entry.headword == "look ahead to")
  }
  @Test func phraseLemmasCannotEraseNegationContractionsOrPossession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored.txt")
    try """
    ■I do : 自作肯定義A
    ■will go : 自作肯定義B
    ■he be : 自作肯定義C
    ■robot box : 自作複合義D
    ■I signal : 自作肯定義E
    ■there' : 自作別語義F
    ■there' up : 自作別句義G
    """.write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    for (surface, index, lemma, pos) in [
      ("I don't", 1, "do", "Verb"), ("I don’t", 1, "do", "Verb"),
      ("won't go", 0, "will", "Verb"), ("he's ready", 0, "he", "Pronoun"),
      ("robot's box", 0, "robot", "Noun"), ("my signal", 0, "I", "Determiner"),
      ("there's up", 0, "there", "Adverb"),
    ] {
      var tokens = try words(surface)
      tokens[index].lemma = lemma
      tokens[index].partOfSpeech = pos
      let candidates = DictionaryExpressions.candidates(tokens).map(DictionaryText.normalize)
      #expect(candidates == [DictionaryText.normalize(surface)])
      #expect(await provider.lookupExpressions([tokens])[0] == nil)
      #expect(DictionaryExpression(tokens).token.lemma == nil)
    }
    // Reject the affirmative compound in automatic lookup as well as explicit
    // selection; the ordinary dictionary word can then be displayed instead.
    var sentence = try words("I don't think the copper robot moves.")
    sentence[1].lemma = "do"
    let matches = await DictionaryExpressions.matches(anchors: Array(sentence.prefix(2)), in: sentence, provider: provider)
    #expect(matches.isEmpty)
  }
  @Test func exactContractedPhrasesStillResolveBeforeInflectedCandidates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let file = root.appendingPathComponent("authored.txt")
    try "■I don't : 自作否定義A\n■I do : 自作肯定義B\n■stacks up : 自作完全一致義C\n■stack up : 自作基本形義D".write(to: file, atomically: true, encoding: .utf8)
    _ = try await provider.importFile(file)
    var negative = try words("I don’t")
    negative[1].lemma = "do"
    let entry = await provider.lookupExpressions([negative])[0]
    #expect(entry.map { DictionaryText.normalize($0.headword ?? "") } == "i don't")
    #expect(entry?.shortGloss == "自作否定義A")
    #expect(await provider.lookupExpressions([try words("stacks up")])[0]?.shortGloss == "自作完全一致義C")
  }
  @Test func automaticExpressionsCrossCaptionLinesButNotPunctuationOrPauses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try await dictionary(root)
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":500,"segs":[{"utf8":"robot stacks"}]},{"tStartMs":500,"dDurationMs":1000,"segs":[{"utf8":"up near a lantern."}]}]}"#.utf8)
    let tokens = try CaptionPipeline().parse(raw, videoID: "test").flatMap(\.tokens)
    let matches = await DictionaryExpressions.matches(anchors: [tokens[1],tokens[2]], in: tokens, provider: provider)
    #expect(matches[tokens[1].id]?.expression.token.surface == "stacks up")
    #expect(matches[tokens[2].id]?.entry.headword == "stack up")
    let punctuated = try words("stacks, up")
    #expect(DictionaryExpressions.windows(containing: punctuated[0], in: punctuated).isEmpty)
    var paused = try words("stacks up")
    paused[1].startTime = paused[0].endTime + 2
    #expect(DictionaryExpressions.windows(containing: paused[0], in: paused).isEmpty)
  }
  @Test func legacyImportedTaggedHeadwordsAreFoundInBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try EijiroProvider(directory: root)
    let db = try SQLiteDatabase(url: root.appendingPathComponent("eijiro.sqlite"))
    for spaces in ["", " ", "  ", "　"] {
      let headword = "stack up" + spaces + "{句自動}"
      try db.execute("INSERT INTO entries VALUES(?,?,?)", values: [headword,DictionaryText.normalize(headword),"自作動詞義A"])
    }
    let entry = await provider.lookupExpressions([try words("stacks up")])[0]
    #expect(entry?.headword == "stack up" && entry?.shortGloss.contains("自作動詞義A") == true)
  }
  @Test func concurrentMacDictionaryCallsRejectPartialWordDefinitions() async throws {
    let provider = MacDictionaryProvider()
    let phrases = [try words("study zqxnotadictionaryword"), try words("stacks up")]
    await withTaskGroup(of: [DictionaryEntry?].self) { group in
      for _ in 0..<8 { group.addTask { await provider.lookupExpressions(phrases) } }
      for await entries in group {
        #expect(entries.count == 2)
        #expect(entries[0] == nil)  // The definition of study alone must not count as a phrase.
      }
    }
  }
}
