import Foundation
import Testing
@testable import StudyCore

// Independently authored definitions and examples; no system dictionary text is copied.
struct MacDictionaryTests {
  @Test func argumentSlotsInAnchoredIdiomsCannotConsumeLiteralSubtitleArticles() {
    #expect(MacDictionaryMarkup.phraseHeadword("sampleunit at A", anchored: true) == "sampleunit at")
    #expect(MacDictionaryMarkup.phraseHeadword("sampleunit A for B", anchored: true) == nil)
    #expect(MacDictionaryMarkup.phraseHeadword("sampleunit a tower", anchored: true) == "sampleunit a tower")
    #expect(MacDictionaryMarkup.phraseHeadword("authored vitamin B", anchored: false) == "authored vitamin B")
  }
  @Test func phraseMissesNeverEvictPositiveRecordsAndPositiveEvictionIsIncremental() {
    var cache = MacDictionaryRecordCache()
    let entry = DictionaryEntry(definition: "自作本文", shortGloss: "自作義")
    cache.store([entry], for: "authoredunit")
    for index in 0..<9000 { cache.store([], for: "absent phrase \(index)") }
    #expect(cache.entries(for: "authoredunit")?.first?.definition == "自作本文")
    #expect(cache.entries(for: "absent phrase 8999")?.isEmpty == true)
    #expect(cache.entries(for: "absent phrase 0") == nil)
    for index in 0..<512 { cache.store([entry], for: "word\(index)") }
    #expect(cache.entries(for: "authoredunit") == nil)
    #expect(cache.entries(for: "word0")?.count == 1 && cache.entries(for: "word511")?.count == 1)
  }

  @Test func structuredBodyPreservesSemanticRolesAndAllVisibleContent() throws {
    let xml = document("""
    <span class='gramb'><span d:pos='1'>動詞</span><span class='semb'>
    <span class='sn'>1</span><span class='trg'><span class='trans'>自作義A</span></span>
    <span class='exg'><span class='ex'>A paper robot turns.</span><span class='ty_用例訳'>紙のロボットが回る。</span></span>
    </span><span class='box'><span class='title'>自作用法</span><span class='np'>自作用法の本文</span></span>
    <span class='idmsec'><span class='idm'>sampleunit around</span><span class='trg'>自作句義</span></span>
    </span>
    """)
    let entry = try #require(MacDictionaryMarkup.parse(xml, headword: "sampleunit"))
    #expect(entry.blocks.contains { $0.role == .partOfSpeech && $0.text == "動詞" })
    #expect(entry.blocks.contains { $0.role == .meaning && $0.text == "1 自作義A" })
    #expect(entry.blocks.contains { $0.role == .example && $0.text == "A paper robot turns." })
    #expect(entry.blocks.contains { $0.role == .translation && $0.text == "紙のロボットが回る。" })
    #expect(entry.blocks.contains { $0.role == .note && $0.text == "自作用法の本文" })
    #expect(entry.blocks.contains { $0.role == .phrase && $0.text == "sampleunit around" })
    #expect(entry.blocks.map(\.text).joined(separator: "\n") == entry.definition)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBRITZ_TEST_SYSTEM_DICTIONARY"] == "1"),
    arguments: [("like", "Verb", "動詞"), ("like", "Preposition", "前置詞"),
      ("like", "Conjunction", "接続詞"), ("run", "Verb", "動詞"), ("run", "Noun", "名詞"),
      ("example", "Noun", "名詞"), ("beautiful", "Adjective", "形容詞"),
      ("quickly", "Adverb", "副詞"), ("piles", "Verb", "動詞"), ("pile up", "", "句動詞")])
  func installedEnglishJapaneseDictionary(word: String, pos: String, label: String) async throws {
    let token = Token(index: 0, surface: word, normalized: word, lemma: nil,
      partOfSpeech: pos.isEmpty ? nil : pos, startTime: 0, endTime: 1,
      timingQuality: .estimated, lexical: true)
    let entry = try #require(await MacDictionaryProvider().lookup(token))
    #expect(entry.partOfSpeech == label)
    #expect(!entry.sections.isEmpty && MacDictionaryMarkup.hasJapanese(entry.shortGloss))
    #expect(!entry.shortGloss.contains("語義を抽出できません") && !entry.shortGloss.contains("語義はありません"))
  }
  func document(_ body: String, prefix: String = "d") -> String {
    """
    <html xmlns:\(prefix)="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><body>
    <\(prefix):entry \(prefix):title="sampleunit">
    <span class="hwg"><span \(prefix):dhw="1">sam･ple･unit</span><span class="hm">9</span>
    <span \(prefix):prn="1">fictional-sound</span><span class="etym">自作語源</span></span>
    \(body)
    </\(prefix):entry></body></html>
    """
  }
  func group(_ pos: String, _ meanings: [String], prefix: String = "d") -> String {
    """
    <span class="gramb x_xd0"><span class="x_xdh"><span \(prefix):pos="1">\(pos)<\(prefix):pos/></span></span>
    \(meanings.enumerated().map { index, meaning in
      "<span class='semb'><span class='sn'>\(index+1)</span><span \(prefix):def='1'><span class='trans'>\(meaning)</span><\(prefix):def/></span></span>"
    }.joined())
    </span>
    """
  }
  @Test func definitionsExcludeHeadingsNumbersPronunciationAndExampleTranslations() throws {
    let body = """
    <span class="gramb"><span d:pos="1">名詞</span><span class="semb">
    <span class="sn">1</span><span d:def="1"><span class="trans">自作名義A<span class="gp">, </span><span class="bold">自作名義B</span>
    <span class="xrg">→ 別項目</span><span class="grnote">自作注記</span></span><d:def/></span>
    <span class="exg"><span class="ex">A paper robot sorts blue tiles.</span><span class="trans ty_用例訳">紙のロボットが青いタイルを整理する。</span></span>
    </span><span class="box"><span d:def="1"><span class="trans">除外する囲み記事</span></span></span></span>
    """
    let entry = try #require(MacDictionaryMarkup.parse(document(body), headword: "sampleunit"))
    #expect(entry.shortGloss == "自作名義A, 自作名義B")
    #expect(entry.pronunciation == "fictional-sound")
    #expect(entry.sections[0].senses.count == 1)
    #expect(entry.sections[0].senses[0].examples == ["A paper robot sorts blue tiles.\n紙のロボットが青いタイルを整理する。"])
    #expect(entry.definition.contains("自作語源") && !entry.shortGloss.contains("紙のロボット"))
    #expect(entry.definition.contains("自作注記") && entry.definition.contains("除外する囲み記事"))
  }
  @Test func unmarkedSubsensesNotesAndIdiomsRemainInTheCompleteRecord() throws {
    let senses = (1...12).map { index in
      "<span class='semb'><span class='sn'>\(index)</span><span class='trg' \(index == 1 ? "d:def='1'" : "")><span class='trans'>自作未省略義\(index)</span></span><span class='exg'><span class='ex'>Robot example \(index).</span><span class='trans ty_用例訳'>自作例文訳\(index)</span></span></span>"
    }.joined()
    let body = """
    <span class='gramb'><span d:pos='1'>動詞</span>
    <span class='semb'><span class='x_xdh'>他動詞</span>\(senses)</span>
    <span class='box'><span class='title'>自作用法見出し</span><span class='np'>自作用法本文</span></span>
    <span class='idmsec' id='authored-idiom'><span class='idm'>sampleunit around</span>
    <span class='semb'><span class='trg'><span class='trans'>自作熟語義</span></span></span></span>
    </span>
    """
    let entry = try #require(MacDictionaryMarkup.parse(document(body), headword: "sampleunit"))
    #expect(entry.sections[0].senses.count == 12)
    for index in 1...12 {
      #expect(entry.definition.contains("自作未省略義\(index)"))
      #expect(entry.definition.contains("自作例文訳\(index)"))
    }
    #expect(entry.definition.contains("他動詞") && entry.definition.contains("自作用法本文"))
    #expect(entry.definition.contains("sampleunit around") && entry.definition.contains("自作熟語義"))
    #expect(!entry.shortGloss.contains("自作用法本文") && !entry.shortGloss.contains("自作熟語義"))
  }
  @Test func punctuationBetweenSplitTranslationsAndAllPronunciationVariantsArePreserved() throws {
    let body = """
    <span class='gramb'><span d:pos='1'>動詞</span><span class='semb'>
    <span class='trg'><span class='trans'>自作義A</span><span class='gp'>; </span><span class='trans'>自作義B</span></span>
    </span></span>
    """
    let xml = document(body).replacingOccurrences(of: "<span class=\"etym\">",
      with: "<span d:prn='2'>alternate-sound</span><span class=\"etym\">")
    let entry = try #require(MacDictionaryMarkup.parse(xml, headword: "sampleunit"))
    #expect(entry.sections[0].senses[0].meaning == "自作義A; 自作義B")
    #expect(entry.pronunciation == "fictional-sound / alternate-sound")
  }
  @Test func partOfSpeechSelectsAcrossHomographsWithoutMixingTheirMeanings() throws {
    let a = try #require(MacDictionaryMarkup.parse(document(group("動詞", ["自作動義A"])), headword: "sampleunit"))
    let b = try #require(MacDictionaryMarkup.parse(document(group("前置詞", ["自作前置義A", "自作前置義B"])), headword: "sampleunit"))
    let entry = try #require(MacDictionaryMarkup.combine([a,b], pos: "Preposition"))
    #expect(entry.shortGloss == "自作前置義A、自作前置義B")
    #expect(entry.partOfSpeech == "前置詞" && entry.sections.count == 2)
    #expect(entry.definition.contains("自作動義A"))
    let fallback = try #require(MacDictionaryMarkup.combine([a,b], pos: "Noun"))
    #expect(fallback.shortGloss == "自作動義A" && fallback.partOfSpeech == "動詞")
    #expect(fallback.usedPartOfSpeechFallback && !entry.usedPartOfSpeechFallback)
  }
  @Test func nestedDefinitionsAndLongMeaningsArePreserved() throws {
    let long = String(repeating: "自作長義", count: 16)
    let body = """
    <span class="gramb"><span d:pos="1">動詞</span><span class="semb"><span class="gr">他動詞</span>
    <span class="semb"><span d:def="1"><span class="trans">\(long)</span></span></span></span></span>
    """
    #expect(MacDictionaryMarkup.parse(document(body), headword: "sampleunit")?.shortGloss == long)
  }
  @Test func possessiveDeterminerChoosesPronounAndMismatchStaysInOneDictionarySection() throws {
    let xml = document(group("間投詞", ["自作間投義A"]) + group("代名詞", ["自作所有義B", "自作所有義C"]))
    let parsed = try #require(MacDictionaryMarkup.parse(xml, headword: "sampleunit"))
    let possessive = try #require(MacDictionaryMarkup.combine([parsed], pos: "Determiner"))
    #expect(possessive.partOfSpeech == "代名詞" && possessive.shortGloss == "自作所有義B、自作所有義C")
    #expect(!possessive.usedPartOfSpeechFallback)
    let mismatch = try #require(MacDictionaryMarkup.combine([parsed], pos: "Adjective"))
    #expect(mismatch.partOfSpeech == "間投詞" && mismatch.shortGloss == "自作間投義A")
    #expect(mismatch.usedPartOfSpeechFallback && mismatch.definition.contains("自作所有義B"))
  }
  @Test func phrasesUseExactRecordAnchorInsteadOfParentWordMeanings() throws {
    let body = group("名詞", ["自作親名義"]) + """
    <span class="gramb"><span d:pos="2">動詞</span>
    <span class="idmsec" id="own-phrase"><span class="idm">sámpleunit ùp</span><span class="semb">
    <span class="trg"><span class="trans">自作句動義A</span></span><span class="exg"><span class="ex">We sampleunit up near a paper tower.</span><span class="trans ty_用例訳">自作句用例訳</span></span></span>
    <span class="semb"><span class="trg"><span class="trans">自作句動義B</span></span></span></span>
    <span class="idmsec" id="other-phrase"><span class="trg"><span class="trans">自作別句義</span></span></span></span>
    """
    let xml = document(body)
    let phrase = try #require(MacDictionaryMarkup.parse(xml, headword: "sampleunit up", anchor: "xpointer(//*[@id='own-phrase'])"))
    #expect(phrase.shortGloss == "自作句動義A、自作句動義B")
    #expect(phrase.partOfSpeech == "句動詞" && phrase.headword == "sampleunit up")
    #expect(!phrase.definition.contains("自作親名義") && !phrase.definition.contains("自作別句義"))
    #expect(phrase.sections[0].senses[0].examples.count == 1)
    #expect(MacDictionaryMarkup.parse(xml, headword: "sampleunit up", anchor: "xpointer(//*[@id='missing'])") == nil)
    #expect(MacDictionaryMarkup.parse(xml, headword: "sampleunit")?.shortGloss == "自作親名義")
  }
  @Test func namespacePrefixesAndEntitiesAreParsedStructurally() throws {
    let xml = document(group("形容詞", ["自作形義A &amp; 自作形義B"], prefix: "dict"), prefix: "dict")
    #expect(MacDictionaryMarkup.parse(xml, headword: "sampleunit")?.shortGloss == "自作形義A & 自作形義B")
  }
  @Test func unknownOrNonJapaneseSchemasDoNotTurnHeadingsIntoGlosses() {
    #expect(MacDictionaryMarkup.parse("<html><body>見出し 発音 自作説明</body></html>", headword: "sampleunit") == nil)
    #expect(MacDictionaryMarkup.parse(document(group("名詞", ["An invented definition only."])), headword: "sampleunit") == nil)
    #expect(MacDictionaryMarkup.parse("<html>", headword: "sampleunit") == nil)
  }
  @Test func examplesStayWithTheirOwnSense() throws {
    let body = """
    <span class="gramb"><span d:pos="1">名詞</span>
    <span class="semb"><span d:def="1"><span class="trans">自作名義A</span></span><span class="exg"><span class="ex">A robot sorts tiles.</span></span></span>
    <span class="semb"><span d:def="1"><span class="trans">自作名義B</span></span><span class="exg"><span class="ex">A robot paints stars.</span></span></span>
    </span>
    """
    let entry = try #require(MacDictionaryMarkup.parse(document(body), headword: "sampleunit"))
    #expect(entry.sections[0].senses[0].examples == ["A robot sorts tiles."])
    #expect(entry.sections[0].senses[1].examples == ["A robot paints stars."])
  }
  @Test func speedReadingGlossOmitsConstraintsButPreservesFullDefinitions() throws {
    let meaning = "(自作条件)〈自作対象〉自作義A、自作義B（的な補足） (robot(1)red, (2)blue)"
    let entry = try #require(MacDictionaryMarkup.parse(document(group("名詞", [meaning])), headword: "sampleunit"))
    #expect(entry.shortGloss == "自作義A、自作義B（的な補足）")
    #expect(entry.sections[0].senses[0].meaning == meaning)
    #expect(MacDictionaryMarkup.shortMeaning("自作義A（閉じ忘れ") == "自作義A（閉じ忘れ")
  }
  @Test func localPhraseReferencesAndSplitTranslationsResolveAsWholeSenses() throws {
    let xml = document("""
    <span class="gramb"><span d:pos="1">動詞</span>
    <span class="semb" id="own-base"><span d:def="1"><span class="trans">自作参照動義</span></span>
    <span class="exg"><span class="ex">A robot draws paper stars.</span></span></span>
    <span class="idmsec" id="own-phrase"><span class="idm">sampleunit up</span>
    <span class="semb"><span class="trg"><span class="xrg"><a href="x-dictionary:r:own-entry:test#xpointer(//*[@id='own-base'])">上向き参照</a></span></span></span>
    <span class="semb"><span class="trg"><span class="trans">〈自作対象〉 </span><span class="ind">【補足】</span><span class="trans">自作句義</span></span></span>
    </span></span>
    """).replacingOccurrences(of: "<d:entry ", with: "<d:entry id=\"own-entry\" ")
    let entry = try #require(MacDictionaryMarkup.parse(xml, headword: "sampleunit up", anchor: "xpointer(//*[@id='own-phrase'])"))
    #expect(entry.shortGloss == "自作参照動義、自作句義")
    #expect(entry.sections[0].senses.count == 2)
    #expect(entry.sections[0].senses[0].examples == ["A robot draws paper stars."])
    #expect(entry.sections[0].senses[1].meaning == "〈自作対象〉 自作句義")
    let cycle = xml.replacingOccurrences(of: "@id='own-base'", with: "@id='own-phrase'")
    #expect(MacDictionaryMarkup.parse(cycle, headword: "sampleunit up", anchor: "xpointer(//*[@id='own-phrase'])")?.shortGloss == "自作句義")
  }
}
