import Foundation

public struct DictionaryExpression {
  public let id: UUID
  public let tokens: [Token]
  public init(_ tokens: [Token]) { id = UUID(); self.tokens = tokens }
  public var token: Token {
    var token = tokens[0]
    token.id = id
    token.surface = tokens.map(\.surface).joined(separator: " ")
    token.normalized = DictionaryText.normalize(token.surface)
    // A phrase's headword comes from a successful dictionary lookup. Joining
    // token lemmas can erase negation or possession and invent another phrase.
    token.lemma = nil
    token.partOfSpeech = "複数語表現"
    token.endTime = tokens.last!.endTime
    return token
  }
  public func contains(_ token: Token) -> Bool { tokens.contains { $0.id == token.id } }
}
public struct DictionaryExpressionMatch {
  public let expression: DictionaryExpression
  public let entry: DictionaryEntry
  public init(expression: DictionaryExpression, entry: DictionaryEntry) {
    self.expression = expression; self.entry = entry
  }
}
extension DictionaryProvider {
  public func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    var results: [DictionaryEntry?] = []
    for tokens in expressions {
      guard !Task.isCancelled else { return Array(repeating: nil, count: expressions.count) }
      var found: DictionaryEntry?
      guard let first = tokens.first, tokens.count > 1 else { results.append(nil); continue }
      for word in DictionaryExpressions.candidates(tokens) {
        guard !Task.isCancelled else { return Array(repeating: nil, count: expressions.count) }
        var query = first
        query.surface = word; query.normalized = DictionaryText.normalize(word)
        query.lemma = nil; query.partOfSpeech = nil
        if var entry = await lookup(query) {
          entry.headword = entry.headword ?? word
          entry.partOfSpeech = entry.partOfSpeech ?? "複数語表現"
          found = entry; break
        }
      }
      results.append(found)
    }
    return results
  }
}
public enum DictionaryExpressions {
  public static let maxAutomaticWords = 8
  public static func candidates(_ tokens: [Token]) -> [String] {
    guard tokens.count > 1, tokens.allSatisfy(\.lexical) else { return [] }
    var combinations = [tokens.map(\.surface).joined(separator: " ")]
    var variants = [[String]]()
    for (index, token) in tokens.enumerated() {
      var words = [DictionaryText.normalize(token.surface)]
      let canInflect = canInflect(token)
      if canInflect, let lemma = token.lemma {
        let normalized = DictionaryText.normalize(lemma)
        if isPlainWord(normalized) { words.append(normalized) }
      }
      if index == 0, canInflect {
        let word = words[0]
        if word.hasSuffix("ies"), word.count > 3 { words.append(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("s"), word.count > 3 { words.append(String(word.dropLast())) }
        if word.hasSuffix("es"), word.count > 4 { words.append(String(word.dropLast(2))) }
        for suffix in ["ing", "ed"] where word.hasSuffix(suffix) && word.count > suffix.count + 1 {
          let stem = String(word.dropLast(suffix.count))
          words += [stem, stem + "e"]
          if stem.count > 2, stem.last == stem.dropLast().last { words.append(String(stem.dropLast())) }
        }
      }
      var seen = Set<String>()
      variants.append(words.filter { !$0.isEmpty && seen.insert($0).inserted })
    }
    var partial = [""]
    for words in variants {
      partial = Array(partial.flatMap { prefix in words.map { prefix.isEmpty ? $0 : prefix + " " + $0 } }.prefix(64))
    }
    combinations += partial
    var seen = Set<String>()
    return combinations.filter { seen.insert(DictionaryText.normalize($0)).inserted }
  }
  private static func isPlainWord(_ word: String) -> Bool {
    !word.isEmpty && word.utf8.allSatisfy { (97...122).contains($0) }
  }
  private static func canInflect(_ token: Token) -> Bool {
    let word = DictionaryText.normalize(token.surface)
    // Contractions and possessives are whole units here: don't -> do and
    // robot's -> robot are not meaning-preserving phrase substitutions.
    // Single-word dictionary lookup can still resolve its own abbreviation
    // references. Do not use those references to invent compound headwords.
    guard isPlainWord(word) else { return false }
    if ["Pronoun", "Determiner", "Preposition", "Conjunction", "Particle"].contains(token.partOfSpeech ?? "") {
      return false
    }
    return !["no", "not", "never", "neither", "nor", "without"].contains(word)
  }
  public static func windows(containing anchor: Token, in tokens: [Token]) -> [[Token]] {
    guard let index = tokens.firstIndex(where: { $0.id == anchor.id }), anchor.lexical else { return [] }
    var windows: [[Token]] = []
    for start in max(0, index - maxAutomaticWords + 1)...index {
      let endLimit = min(tokens.count, start + maxAutomaticWords)
      guard endLimit > index else { continue }
      for end in (index + 1)...endLimit where end - start > 1 {
        let slice = Array(tokens[start..<end])
        guard slice.allSatisfy(\.lexical), zip(slice, slice.dropFirst()).allSatisfy({ $1.startTime - $0.endTime <= 1.2 })
        else { continue }
        windows.append(slice)
      }
    }
    return windows.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0].startTime < $1[0].startTime }
  }
  public static func matches(anchors: [Token], in tokens: [Token], provider: any DictionaryProvider) async -> [UUID: DictionaryExpressionMatch] {
    var candidates: [[Token]] = []
    var seen = Set<String>()
    var windows: [UUID: [[Token]]] = [:]
    func key(_ tokens: [Token]) -> String { tokens.map { $0.id.uuidString }.joined(separator: ":") }
    for anchor in anchors {
      let ranges = self.windows(containing: anchor, in: tokens)
      windows[anchor.id] = ranges
      for range in ranges where seen.insert(key(range)).inserted { candidates.append(range) }
    }
    let entries = await provider.lookupExpressions(candidates)
    var found: [String: DictionaryExpressionMatch] = [:]
    for (range, entry) in zip(candidates, entries) {
      if let entry { found[key(range)] = DictionaryExpressionMatch(expression: DictionaryExpression(range), entry: entry) }
    }
    var results: [UUID: DictionaryExpressionMatch] = [:]
    for anchor in anchors {
      for range in windows[anchor.id] ?? [] {
        if let match = found[key(range)] { results[anchor.id] = match; break }
      }
    }
    return results
  }
}
