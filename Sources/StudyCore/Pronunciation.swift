import Foundation

public enum PronunciationRegion: String, Codable, CaseIterable, Sendable {
  case us = "US", uk = "UK"
}
public enum PronunciationInflection: String, Codable, Sendable {
  case base, past, pastParticiple, presentParticiple, thirdPerson
}
public struct PronunciationCandidate: Sendable, Equatable {
  public enum Strength: Sendable, Equatable { case weak, strong }
  public var text: String
  public var region: PronunciationRegion?
  public var strength: Strength?
  public var partOfSpeech: String?
  public var inflections: [PronunciationInflection]
  public var headword: String?
  public init(_ text: String, region: PronunciationRegion? = nil, strength: Strength? = nil,
    partOfSpeech: String? = nil, inflections: [PronunciationInflection] = [], headword: String? = nil) {
    self.text = text; self.region = region; self.strength = strength
    self.partOfSpeech = partOfSpeech; self.inflections = inflections; self.headword = headword
  }
}

/// Parse once with the dictionary record, never by searching the dictionary during rendering.
public enum PronunciationText {
  private static let labels = try! NSRegularExpression(
    pattern: #"\[[^\]]+\]|《[^》]+》|｟[^｠]+｠|〖[^〗]+〗|〈[^〉]+〉|（[^）]+）|\([^()]+\)"#)
  private static let separators = try! NSRegularExpression(pattern: #"[|/、,，;；\n]+"#)
  public static func parse(_ raw: String, region: PronunciationRegion? = nil,
    strength: PronunciationCandidate.Strength? = nil, partOfSpeech: String? = nil,
    inflections: [PronunciationInflection] = [], headword: String? = nil) -> [PronunciationCandidate] {
    // Labels apply to the following sound(s), including comma-separated variants.
    let ns = raw as NSString
    let ranges = labels.matches(in: raw, range: NSRange(location: 0, length: ns.length))
    var result: [PronunciationCandidate] = []
    var currentRegion = region, currentStrength = strength, currentPOS = partOfSpeech
    var currentInflections = inflections
    func append(_ text: String) {
      let source = text as NSString
      var start = 0
      let cuts = separators.matches(in: text, range: NSRange(location: 0, length: source.length))
      for end in cuts.map(\.range) + [NSRange(location: source.length, length: 0)] {
        let sound = source.substring(with: NSRange(location: start, length: end.location - start))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        // A hyphenated suffix is a shorthand, not a complete pronunciation.
        if !sound.isEmpty, !sound.hasPrefix("-"), !sound.hasSuffix("-"),
          sound.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) == nil {
          result.append(PronunciationCandidate(sound, region: currentRegion, strength: currentStrength,
            partOfSpeech: currentPOS, inflections: currentInflections, headword: headword))
        }
        start = NSMaxRange(end)
      }
    }
    var start = 0
    for match in ranges {
      let label = ns.substring(with: match.range)
      let upper = label.uppercased()
      let bare = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]《》｟｠〖〗〈〉（）() "))
      let newRegion: PronunciationRegion? = ["US", "USA", "米", "米音", "米国", "アメリカ英語"].contains(bare.uppercased()) ? .us
        : ["UK", "英", "英音", "英国", "イギリス英語"].contains(bare.uppercased()) ? .uk : nil
      let newStrength: PronunciationCandidate.Strength? = label.contains("弱") || upper.contains("WEAK") ? .weak
        : label.contains("強") || upper.contains("STRONG") ? .strong : nil
      let newInflections = inflectionsIn(label)
      let newPOS = posIn(label)
      let annotation = newRegion != nil || newStrength != nil || !newInflections.isEmpty || newPOS != nil
        || label.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil
      guard annotation else { continue } // Preserve optional IPA segments such as (ə) and (r).
      append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
      if let newRegion { currentRegion = newRegion; currentStrength = strength }
      if let newStrength { currentStrength = newStrength }
      if let newPOS {
        if currentPOS != newPOS { currentInflections = inflections }
        currentPOS = newPOS
      }
      if !newInflections.isEmpty { currentInflections = newInflections }
      start = NSMaxRange(match.range)
    }
    append(ns.substring(from: start))
    return result
  }
  static func inflectionsIn(_ label: String) -> [PronunciationInflection] {
    var result: [PronunciationInflection] = []
    let bare = label.trimmingCharacters(in: CharacterSet(charactersIn: "《》｟｠〖〗〈〉[]（）() "))
    if label.contains("過去形") || label.contains("過去・") || label.contains("過去･") || bare == "過去" { result.append(.past) }
    if label.contains("過去分詞") { result.append(.pastParticiple) }
    if label.contains("現在分詞") { result.append(.presentParticiple) }
    if label.contains("原形") || label.contains("現在形") || bare == "現在" { result.append(.base) }
    return result
  }
  static func posIn(_ label: String) -> String? {
    if label.contains("副詞") || label == "《副》" { return "Adverb" }
    if label.contains("形容詞") || label == "《形》" { return "Adjective" }
    if label.contains("代名詞") { return "Pronoun" }
    if label.contains("動詞") || label == "《動》" { return "Verb" }
    if label.contains("名詞") || label == "《名》" { return "Noun" }
    return nil
  }
  static func canonicalPOS(_ value: String?) -> String? {
    value.flatMap { posIn($0) ?? $0 }
  }
}

extension DictionaryEntry {
  public func realtimePronunciation(for token: Token, region: PronunciationRegion) -> String? {
    let candidates = pronunciationCandidates.isEmpty
      ? pronunciation.map { PronunciationText.parse($0, headword: headword) } ?? [] : pronunciationCandidates
    let pos = PronunciationText.canonicalPOS(usedPartOfSpeechFallback ? partOfSpeech : token.partOfSpeech)
    let surface = DictionaryText.normalize(token.surface)
    func rank(_ candidate: PronunciationCandidate) -> [Int] {
      let cp = PronunciationText.canonicalPOS(candidate.partOfSpeech)
      let posRank = pos == nil || cp == pos ? 0 : cp == nil ? 1 : 2
      let formRank: Int
      if let form = token.pronunciationInflection {
        formRank = candidate.inflections.contains(form) ? 0 : candidate.inflections.isEmpty ? 1 : 2
      } else { formRank = 0 }
      let wordRank = candidate.headword.map { DictionaryText.normalize($0) == surface ? 0 : 1 } ?? 1
      let regionRank = candidate.region == region ? 0 : candidate.region == nil ? 1 : 2
      let strengthRank = candidate.strength == .weak ? 0 : candidate.strength == nil ? 1 : 2
      return [posRank, wordRank, formRank, regionRank, strengthRank]
    }
    // Strict comparison preserves dictionary order for equal-ranked candidates.
    let eligible = candidates.filter { candidate in
      guard let headword = candidate.headword else { return true }
      // A lemma's citation form is not the surface word's inflected pronunciation.
      return surface.contains(" ") || DictionaryText.normalize(headword) == surface
        || token.pronunciationInflection.map { candidate.inflections.contains($0) } == true
    }
    return eligible.enumerated().min {
      let a = rank($0.element), b = rank($1.element)
      return a == b ? $0.offset < $1.offset : a.lexicographicallyPrecedes(b)
    }?.element.text
  }
}

/// Only use local grammatical evidence. Bare "I read" remains ambiguous.
public enum PronunciationContext {
  public static func annotate(_ tokens: [Token]) -> [Token] {
    var result = tokens
    for i in result.indices where result[i].lexical && result[i].partOfSpeech == "Verb" {
      let surface = DictionaryText.normalize(result[i].surface)
      let lemma = result[i].lemma.map(DictionaryText.normalize)
      var j = i - 1
      // Adverbs/negation can intervene, but never cross a clause, subject or punctuation.
      while j >= 0, result[j].lexical,
        result[j].partOfSpeech == "Adverb" || result[j].normalized == "not" { j -= 1 }
      let previous = j >= 0 && result[j].lexical ? DictionaryText.normalize(result[j].surface) : ""
      if ["have", "has", "had", "'ve"].contains(previous) || previous.hasSuffix("'ve") {
        result[i].pronunciationInflection = .pastParticiple
      } else if ["can", "could", "will", "would", "shall", "should", "may", "might", "must", "do", "does", "did", "to", "'ll"].contains(previous) || previous.hasSuffix("'ll") {
        result[i].pronunciationInflection = .base
      } else if ["be", "am", "is", "are", "was", "were", "been", "being"].contains(previous) {
        result[i].pronunciationInflection = surface.hasSuffix("ing") ? .presentParticiple : .pastParticiple
      } else if let lemma, lemma != surface {
        if surface == lemma + "ing" || (lemma.hasSuffix("e") && surface == lemma.dropLast() + "ing") {
          result[i].pronunciationInflection = .presentParticiple
        } else if surface == lemma + "s" || surface == lemma + "es" {
          result[i].pronunciationInflection = .thirdPerson
        }
      }
    }
    return result
  }
}
