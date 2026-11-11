import Foundation
import Testing
@testable import StudyCore

// Authored phonetic fixtures; no dictionary records are redistributed.
struct PronunciationTests {
  func token(_ word: String = "sampleunit", pos: String = "Verb",
    form: PronunciationInflection? = nil) -> Token {
    var token = Token(index: 0, surface: word, normalized: word.lowercased(), lemma: word.lowercased(),
      partOfSpeech: pos, startTime: 0, endTime: 1, timingQuality: .estimated, lexical: true)
    token.pronunciationInflection = form
    return token
  }
  func entry(_ candidates: [PronunciationCandidate]) -> DictionaryEntry {
    DictionaryEntry(definition: "自作の本文", shortGloss: "自作義", pronunciationCandidates: candidates)
  }
  @Test func regionalPreferenceThenWeakFormThenSourceOrder() {
    let value = entry([
      .init("us-strong", region: .us, strength: .strong),
      .init("uk-weak", region: .uk, strength: .weak),
      .init("us-weak-first", region: .us, strength: .weak),
      .init("us-weak-second", region: .us, strength: .weak),
    ])
    #expect(value.realtimePronunciation(for: token(), region: .us) == "us-weak-first")
    #expect(value.realtimePronunciation(for: token(), region: .uk) == "uk-weak")
    #expect(entry([.init("first"), .init("second")]).realtimePronunciation(for: token(), region: .uk) == "first")
  }
  @Test func grammaticalUseOutranksRegionAndStrength() {
    let value = entry([
      .init("noun", region: .us, strength: .weak, partOfSpeech: "名詞"),
      .init("present", region: .us, partOfSpeech: "動詞", inflections: [.base]),
      .init("past", region: .uk, strength: .strong, partOfSpeech: "Verb", inflections: [.past, .pastParticiple]),
    ])
    #expect(value.realtimePronunciation(for: token(form: .pastParticiple), region: .us) == "past")
    #expect(value.realtimePronunciation(for: token(form: .base), region: .us) == "present")
    #expect(value.realtimePronunciation(for: token(pos: "Noun"), region: .uk) == "noun")
  }
  @Test func ambiguousGrammarPreservesSourceOrderAndDictionaryPOSFallback() {
    var value = entry([
      .init("past-first", partOfSpeech: "Verb", inflections: [.past]),
      .init("base-second", partOfSpeech: "Verb", inflections: [.base]),
      .init("noun", partOfSpeech: "Noun"),
    ])
    #expect(value.realtimePronunciation(for: token(), region: .us) == "past-first")
    value.usedPartOfSpeechFallback = true
    value.partOfSpeech = "Noun"
    #expect(value.realtimePronunciation(for: token(pos: "Adjective"), region: .us) == "noun")
  }
  @Test func commonPronunciationPrecedesOtherRegionAndNoLabelsAreDisplayed() {
    let raw = "[US]《強》strɔŋ | [UK]《弱》wiːk | [UK]《弱》wiːkə"
    let parsed = PronunciationText.parse(raw)
    #expect(parsed.count == 3)
    #expect(entry(parsed).realtimePronunciation(for: token(), region: .uk) == "wiːk")
    #expect(entry([.init("uk", region: .uk), .init("common")])
      .realtimePronunciation(for: token(), region: .us) == "common")
    #expect(entry([.init("uk", region: .uk)]).realtimePronunciation(for: token(), region: .us) == "uk")
  }
  @Test func explicitLabelsOptionalSegmentsAndUnlabelledVariants() {
    let raw = "《米》《動》《現在形》sæm(p)l | 《過去形・過去分詞》sɛmpl | 《英》《名》sɑːmpl"
    let values = PronunciationText.parse(raw)
    #expect(values.map(\.text) == ["sæm(p)l", "sɛmpl", "sɑːmpl"])
    #expect(values[0].region == .us && values[0].partOfSpeech == "Verb")
    #expect(values[1].inflections == [.past, .pastParticiple])
    #expect(values[2].region == .uk && values[2].partOfSpeech == "Noun")
    #expect(PronunciationText.parse("(子音の前で) sə, (母音の前で) sɪ / sɑː").map(\.text) == ["sə", "sɪ", "sɑː"])
    #expect(PronunciationText.parse("sæm(ə)l|-mɔːl").map(\.text) == ["sæm(ə)l"])
  }
  @Test func missingPhrasePronunciationIsNotSynthesizedAndFullDetailRemainsIntact() {
    let missing = DictionaryEntry(definition: "自作句の本文", shortGloss: "自作句義")
    #expect(missing.realtimePronunciation(for: token("sample phrase"), region: .us) == nil)
    let raw = "[US]《弱》səm | 《強》sæm | [UK]sɑːm"
    let value = DictionaryEntry(definition: "全候補 " + raw, shortGloss: "自作義", pronunciation: raw)
    #expect(value.realtimePronunciation(for: token(), region: .us) == "səm")
    #expect(value.pronunciation == raw && value.definition.contains(raw))
  }
  @Test func explicitSurfaceFormsDoNotBorrowLemmaPronunciation() {
    let value = entry([.init("base", headword: "sample"),
      .init("inflected", inflections: [.past], headword: "sampled")])
    #expect(value.realtimePronunciation(for: token("sampled"), region: .us) == "inflected")
    #expect(entry([.init("base", headword: "sample")])
      .realtimePronunciation(for: token("sampled"), region: .us) == nil)
  }
  @Test func contextUsesAuxiliariesButDoesNotGuessAmbiguousTense() {
    func form(_ words: [(String, String)]) -> PronunciationInflection? {
      PronunciationContext.annotate(words.map { token($0.0, pos: $0.1) }).last?.pronunciationInflection
    }
    #expect(form([("have", "Verb"), ("already", "Adverb"), ("read", "Verb")]) == .pastParticiple)
    #expect(form([("will", "Verb"), ("not", "Adverb"), ("read", "Verb")]) == .base)
    #expect(form([("did", "Verb"), ("read", "Verb")]) == .base)
    #expect(form([("is", "Verb"), ("read", "Verb")]) == .pastParticiple)
    #expect(form([("I've", "Pronoun"), ("read", "Verb")]) == .pastParticiple)
    #expect(form([("I'd", "Pronoun"), ("read", "Verb")]) == nil)
    #expect(form([("I", "Pronoun"), ("read", "Verb")]) == nil)
    #expect(form([("have", "Verb"), ("friends", "Noun"), ("read", "Verb")]) == nil)
    #expect(form([("have", "Verb"), (".", "Punctuation"), ("read", "Verb")]) == nil)
  }
  @Test func preferenceDefaultsPersistenceAndBackup() throws {
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).pronunciationRegion == .us)
    #expect(try JSONDecoder().decode(AppSettings.self,
      from: Data(#"{"pronunciationRegion":"invalid"}"#.utf8)).pronunciationRegion == .us)
    var settings = AppSettings(); settings.pronunciationRegion = .uk
    let decoded = try BackupArchive.decode(BackupArchive(settings: settings, library: .init()).encoded())
    #expect(decoded.settings.pronunciationRegion == .uk)
    let data = try JSONEncoder().encode(token())
    #expect(try JSONDecoder().decode(Token.self, from: data).pronunciationInflection == nil)
  }
  @Test func captionContextAndOldTimelineBothDistinguishConfirmedInflections() throws {
    let raw = Data(#"{"events":[{"tStartMs":0,"dDurationMs":3000,"segs":[{"utf8":"I have read the paper robot manual."}]}]}"#.utf8)
    let sentences = try CaptionPipeline().parse(raw, videoID: "authored")
    let read = try #require(sentences.flatMap(\.tokens).first { $0.normalized == "read" })
    #expect(read.pronunciationInflection == .pastParticiple)
    var older = sentences
    for i in older.indices {
      for j in older[i].tokens.indices { older[i].tokens[j].pronunciationInflection = nil }
    }
    #expect(Timeline(older).tokens.first { $0.id == read.id }?.pronunciationInflection == .pastParticiple)
    let phrase = DictionaryExpression(Timeline(older).tokens.filter(\.lexical))
    #expect(phrase.token.pronunciationInflection == nil)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBRITZ_TEST_SYSTEM_DICTIONARY"] == "1"))
  func installedDictionarySelectsPOSAndConfirmedReadInflectionWithoutHoverWork() async throws {
    let provider = MacDictionaryProvider()
    let start = ContinuousClock.now
    let word = token("record", pos: "Noun")
    let record = try #require(await provider.lookup(word))
    let noun = try #require(record.realtimePronunciation(for: word, region: .us))
    let verb = try #require(record.realtimePronunciation(for: token("record"), region: .us))
    #expect(noun != verb)
    let read = try #require(await provider.lookup(token("read")))
    let base = try #require(read.realtimePronunciation(for: token("read", form: .base), region: .us))
    let past = try #require(read.realtimePronunciation(for: token("read", form: .pastParticiple), region: .us))
    #expect(base != past)
    for word in ["have", "to", "possible"] {
      let query = token(word)
      let entry = try #require(await provider.lookup(query))
      let pronunciation = try #require(entry.realtimePronunciation(for: query, region: .us))
      #expect(!pronunciation.contains("|") && !pronunciation.contains(",") && !pronunciation.contains("強"))
    }
    print("Pronunciation cold dictionary checks:", start.duration(to: .now))
    let warm = ContinuousClock.now
    for _ in 0..<10_000 {
      #expect(read.realtimePronunciation(for: token("read", form: .pastParticiple), region: .uk) == past)
    }
    print("Pronunciation cached selection × 10000:", warm.duration(to: .now))
  }
}
