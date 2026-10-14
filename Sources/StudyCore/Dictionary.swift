import CoreServices
import Foundation
import Security

public struct DictionaryEntry: Sendable {
  public var definition: String
  public var shortGloss: String
  public var headword: String? = nil
  public var partOfSpeech: String? = nil
  public var sections: [DictionarySection] = []
  public var pronunciation: String? = nil
  public var expandedForms: [String] = []
  public var usedPartOfSpeechFallback = false
  public var blocks: [DictionaryBlock] = []
}
public struct DictionaryBlock: Codable, Sendable, Equatable {
  public enum Role: String, Codable, Sendable {
    case partOfSpeech, meaning, example, translation, note, phrase, metadata, body
  }
  public var text: String
  public var role: Role
  public init(_ text: String, role: Role) { self.text = text; self.role = role }
}
public struct DictionarySection: Sendable {
  public var partOfSpeech: String
  public var senses: [DictionarySense]
}
public struct DictionarySense: Sendable {
  public var meaning: String
  public var examples: [String]
  public var shortMeaning: String? = nil
}
public protocol DictionaryProvider: Sendable {
  func lookup(_ token: Token) async -> DictionaryEntry?
  func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?]
}
public enum DictionaryText {
  public static func candidates(_ token: Token) -> [String] {
    var seen = Set<String>()
    return [token.surface, token.normalized, normalize(token.surface), token.lemma, token.lemma?.lowercased()].compactMap {
      $0
    }.filter { seen.insert($0).inserted }
  }
  public static func normalize(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
      .lowercased()
  }
  public static func paragraphs(_ definition: String) -> [String] {
    definition.replacingOccurrences(
      of: "(?<=\\s)([1-9][0-9]?[.)])(?=\\s)", with: "\n$1", options: .regularExpression
    )
    .replacingOccurrences(of: "•", with: "\n• ")
    .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
  }
  public static func pronunciation(_ definition: String) -> String? {
    let pattern = #"【発音】\s*([^【\r\n■◆]+)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let text = definition as NSString
    guard let match = regex.firstMatch(in: definition, range: NSRange(location: 0, length: text.length))
    else { return nil }
    let value = text.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "、,，")))
    return value.isEmpty ? nil : value
  }
  public static func gloss(_ definition: String) -> String {
    let parts = definition.components(separatedBy: CharacterSet(charactersIn: "\n；;"))
    let japanese = parts.first { $0.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil }
    guard let japanese else { return "日本語の語義なし" }
    let cleaned = japanese.replacingOccurrences(
      of: "【[^】]*】|\\{[^}]*\\}", with: "", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(45)) + (cleaned.count > 45 ? "…" : "")
  }
}
// 品詞・同綴語番号・語義番号は見出し側に付く。原文は詳細用に保持する。
enum EijiroText {
  struct Sense {
    var headword: String
    var tag: String?
    var label: String?
    var group: Int
    var number: Int
    var definition: String
  }
  static let sensePattern = try! NSRegularExpression(pattern: #"^(.*?)\s*\{([^}]+)\}$"#)
  static func sense(_ headword: String, _ definition: String) -> Sense {
    let ns = headword as NSString
    guard
      let match = sensePattern.firstMatch(
        in: headword, range: NSRange(location: 0, length: ns.length))
    else {
      return Sense(
        headword: headword, tag: nil, label: nil, group: 0, number: 0, definition: definition)
    }
    let tag = ns.substring(with: match.range(at: 2))
    var parts = tag.components(separatedBy: "-")
    let group = parts.first.flatMap(Int.init) ?? 0
    if group > 0 { parts.removeFirst() }
    let number = parts.last.flatMap(Int.init) ?? 0
    if number > 0 { parts.removeLast() }
    let label = parts.joined(separator: "-")
    return Sense(
      headword: ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces),
      tag: tag, label: label.isEmpty ? nil : label, group: group, number: number,
      definition: definition)
  }
  static func labels(for pos: String?) -> Set<String> {
    switch pos {
    case "Noun": return ["名"]
    case "Verb": return ["動", "他動", "自動", "自他動", "助動", "句動", "句他動", "句自動", "他", "自"]
    case "Adjective": return ["形"]
    case "Adverb": return ["副"]
    case "Pronoun": return ["代", "代名"]
    case "Preposition": return ["前", "前置"]
    case "Conjunction": return ["接", "接続"]
    case "Interjection": return ["間", "間投"]
    // Possessives are often called determiners by the tokenizer and pronouns by
    // the dictionary. These labels describe the same lookup, not a missing use.
    case "Determiner": return ["定", "不", "冠", "形", "代", "代名"]
    case "Particle": return ["前", "副", "助"]
    default: return []
    }
  }
  static func matches(_ sense: Sense, pos: String?) -> Bool {
    let wanted = labels(for: pos)
    // A contraction represents more than one word, so the first token's POS
    // (often Pronoun) cannot be used to exclude its abbreviation record.
    return sense.label == "省略形" || wanted.isEmpty
      || sense.label.map {
        !wanted.isDisjoint(with: $0.components(separatedBy: "・"))
      } == true
  }
  static func meaning(_ raw: String) -> String {
    let value = raw.components(separatedBy: "■")[0].components(separatedBy: "◆")[0]
      .components(separatedBy: "【")[0]
    // 用法・分野は短義から除くが、意味の一部である丸括弧・角括弧は保持する。
    return value.replacingOccurrences(
      of: "〔[^〕]*〕|《[^》]*》|〈[^〉]*〉", with: "", options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func reference(_ value: String) -> String? {
    references(value).first
  }
  static func references(_ value: String) -> [String] {
    let text = meaning(value)
    if text.hasPrefix("＝<→") || text.hasPrefix("=<→") {
      let regex = try! NSRegularExpression(pattern: #"<→([^<>]+)>"#)
      let ns = text as NSString
      var seen = Set<String>()
      return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert(DictionaryText.normalize($0)).inserted }
    }
    // is / went など、辞書自身が説明している活用元。
    let regex = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z'-]*)の.*(?:形|分詞)$"#)
    let ns = text as NSString
    if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
      return [ns.substring(with: match.range(at: 1))]
    }
    return []
  }
  static func ordered(_ senses: [Sense]) -> [Sense] {
    // 品詞ごとのまとまりを保持し、10番を2番より先に表示しない。
    var order: [String: Int] = [:]
    for sense in senses {
      let key = "\(sense.group):\(sense.label ?? "")"
      if order[key] == nil { order[key] = order.count }
    }
    return senses.enumerated().sorted { a, b in
      if (a.element.label == nil) != (b.element.label == nil) { return a.element.label != nil }
      if a.element.group != b.element.group { return a.element.group < b.element.group }
      let ak = "\(a.element.group):\(a.element.label ?? "")"
      let bk = "\(b.element.group):\(b.element.label ?? "")"
      if ak != bk { return order[ak]! < order[bk]! }
      if a.element.number != b.element.number { return a.element.number < b.element.number }
      return a.offset < b.offset
    }.map(\.element)
  }
  static func meanings(_ senses: [Sense], pos: String?) -> [Sense] {
    selectedMeanings(senses, pos: pos).senses
  }
  static func selectedMeanings(_ senses: [Sense], pos: String?) -> (senses: [Sense], fallback: Bool) {
    let ordered = ordered(senses)
    let tagged = ordered.filter { $0.label != nil }
    let definitions = (tagged.isEmpty ? ordered : tagged).filter {
        meaning($0.definition).range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil
          || reference($0.definition) != nil
      }
    // Labels such as movie titles and country domains are separate entries, not
    // grammatical uses. Prefer lexical senses over those names when present.
    let lexical = definitions.filter {
      $0.label?.components(separatedBy: "・").contains { partOfSpeechNames[$0] != nil } == true
    }
    let available = lexical.isEmpty ? definitions : lexical
    let matching = available.filter { matches($0, pos: pos) }
    if !matching.isEmpty { return (matching, false) }
    guard let first = available.first else { return ([], false) }
    // The tokenizer's POS is only a hint. Use one actual dictionary group if it
    // disagrees, keeping the badge and short meanings from the same use.
    return (available.filter { $0.group == first.group && $0.label == first.label }, true)
  }
  static let partOfSpeechNames: [String: String] = [
    "名": "Noun", "動": "Verb", "他動": "Verb", "自動": "Verb", "自他動": "Verb", "他": "Verb", "自": "Verb",
    "助動": "助動詞", "句動": "句動詞", "句他動": "句動詞", "句自動": "句動詞",
    "形": "Adjective", "副": "Adverb", "代": "Pronoun", "代名": "Pronoun", "前": "Preposition", "前置": "Preposition",
    "接": "Conjunction", "接続": "Conjunction", "間": "間投詞", "間投": "間投詞",
    "定": "Determiner", "不": "Determiner", "冠": "Determiner", "省略形": "省略形",
  ]
  static func partOfSpeech(_ sense: Sense, preferred: String?) -> String? {
    guard let label = sense.label else { return nil }
    let components = label.components(separatedBy: "・")
    let wanted = labels(for: preferred)
    let selected = components.first { wanted.contains($0) } ?? components[0]
    return partOfSpeechNames[selected] ?? label
  }
  static func entry(_ senses: [Sense], pos: String?) -> DictionaryEntry {
    let selection = selectedMeanings(senses, pos: pos)
    let gloss = selection.senses.filter { reference($0.definition) == nil }
      .prefix(3).map { meaning($0.definition) }.joined(separator: "、")
    let detailed = ordered(senses).map { sense in
      let label = sense.tag.map { "{\($0)}: " } ?? ""
      return label
        + sense.definition.replacingOccurrences(of: "■", with: "\n■")
        .replacingOccurrences(of: "◆", with: "\n◆")
    }.joined(separator: "\n")
    let group = selection.senses.first?.group ?? 0
    let pronunciation = ordered(senses).filter { $0.group == group }
      .compactMap { DictionaryText.pronunciation($0.definition) }.first
      ?? DictionaryText.pronunciation(detailed)
    return DictionaryEntry(definition: detailed, shortGloss: gloss.isEmpty ? "日本語の語義なし" : gloss,
      partOfSpeech: selection.senses.first.flatMap { partOfSpeech($0, preferred: pos) },
      sections: sections(senses),
      pronunciation: pronunciation,
      usedPartOfSpeechFallback: selection.fallback, blocks: blocks(senses))
  }
  static func blocks(_ senses: [Sense]) -> [DictionaryBlock] {
    let labels = ["名": "名詞", "動": "動詞", "他動": "他動詞", "自動": "自動詞", "自他動": "自他動詞",
      "形": "形容詞", "副": "副詞", "代": "代名詞", "代名": "代名詞", "前": "前置詞", "前置": "前置詞",
      "接": "接続詞", "接続": "接続詞", "間": "間投詞", "間投": "間投詞", "句動": "句動詞",
      "句自動": "句動詞", "句他動": "句動詞", "定": "限定詞", "冠": "冠詞", "助動": "助動詞"]
    var result: [DictionaryBlock] = []
    var previousGroup: String?
    for sense in ordered(senses) {
      if let label = sense.label {
        let group = "\(sense.group):\(label)"
        if previousGroup != group {
          var heading = label.components(separatedBy: "・").map { labels[$0] ?? $0 }.joined(separator: " / ")
          if sense.group > 0 { heading += "（同綴語\(sense.group)）" }
          result.append(DictionaryBlock(heading, role: .partOfSpeech))
          previousGroup = group
        }
      }
      let lines = sense.definition.replacingOccurrences(of: "■", with: "\n■")
        .replacingOccurrences(of: "◆", with: "\n◆").components(separatedBy: .newlines)
      for (index, line) in lines.enumerated() {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let role: DictionaryBlock.Role = text.hasPrefix("■") ? .example
          : text.hasPrefix("◆") ? .note : text.hasPrefix("【") ? .metadata : .meaning
        if index == 0, sense.number > 0 { text = "\(sense.number). " + text }
        result.append(DictionaryBlock(text, role: role))
      }
    }
    return result
  }
  static func sections(_ senses: [Sense]) -> [DictionarySection] {
    var sections: [DictionarySection] = []
    var keys: [String] = []
    for sense in ordered(senses) {
      guard let pos = partOfSpeech(sense, preferred: nil), reference(sense.definition) == nil else { continue }
      let text = sense.definition.components(separatedBy: "■")[0].components(separatedBy: "◆")[0]
        .components(separatedBy: "【")[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let key = "\(sense.group):\(sense.label ?? "")"
      let examples = sense.definition.components(separatedBy: "■").dropFirst().map {
        $0.components(separatedBy: "◆")[0].trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      let item = DictionarySense(meaning: text, examples: examples, shortMeaning: meaning(sense.definition))
      if let index = keys.firstIndex(of: key) { sections[index].senses.append(item) }
      else { keys.append(key); sections.append(DictionarySection(partOfSpeech: pos, senses: [item])) }
    }
    return sections
  }
}
public struct MacDictionaryProvider: DictionaryProvider {
  public init() {}
  public func lookup(_ token: Token) async -> DictionaryEntry? {
    let task = Task.detached(priority: Task.currentPriority) {
      var fallback: DictionaryEntry?
      for word in DictionaryText.candidates(token) {
        guard !Task.isCancelled else { return nil as DictionaryEntry? }
        if let entry = await MacDictionaryAccess.lookup(for: word, pos: token.partOfSpeech) {
          if !entry.usedPartOfSpeechFallback { return entry }
          if fallback == nil { fallback = entry }
        }
      }
      return fallback
    }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  public func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    let task = Task.detached(priority: Task.currentPriority) { () -> [DictionaryEntry?] in
      var results: [DictionaryEntry?] = []
      for tokens in expressions {
        var found: DictionaryEntry?
        for word in DictionaryExpressions.candidates(tokens) {
          guard !Task.isCancelled else { return Array(repeating: nil, count: expressions.count) }
          if let entry = await MacDictionaryAccess.lookup(for: word) { found = entry; break }
        }
        results.append(found)
      }
      return results
    }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
}
public actor EijiroProvider: DictionaryProvider {
  let db: SQLiteDatabase
  public init(directory: URL? = nil) throws {
    let root =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("YouTubeEnglishStudy")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    db = try SQLiteDatabase(url: root.appendingPathComponent("eijiro.sqlite"))
    try db.execute(
      "CREATE TABLE IF NOT EXISTS entries(headword TEXT NOT NULL,normalized_headword TEXT NOT NULL,definition TEXT NOT NULL)"
    )
    try db.execute("CREATE INDEX IF NOT EXISTS dictionary_lookup ON entries(normalized_headword)")
  }
  public func count() throws -> Int {
    Int(try db.rows("SELECT COUNT(*) FROM entries").first?[0] ?? "0") ?? 0
  }
  public func remove() throws {
    try db.execute("DELETE FROM entries")
    try db.execute("VACUUM")
  }
  public static func parseLine(_ line: String) -> (String, String)? {
    let s = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
      in: CharacterSet(charactersIn: "■"))
    guard let r = s.range(of: " : ") ?? s.range(of: "\t") else { return nil }
    let word = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    let definition = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    guard !word.isEmpty, !definition.isEmpty else { return nil }
    return (word, definition)
  }
  public func importFile(_ url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    let encodings: [String.Encoding] = [
      .utf8,
      String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
          CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))), .shiftJIS, .japaneseEUC,
    ]
    var decoded: String?
    for encoding in encodings {
      if let value = String(data: data, encoding: encoding) {
        decoded = value
        break
      }
    }
    guard let text = decoded else {
      throw AppFailure("英辞郎データの文字コードを読み取れませんでした")
    }
    try db.execute("BEGIN IMMEDIATE")
    do {
      try db.execute("DELETE FROM entries")
      var count = 0
      for line in text.split(whereSeparator: \.isNewline) {
        try Task.checkCancellation()
        if let (word, definition) = Self.parseLine(String(line)) {
          try db.execute(
            "INSERT INTO entries VALUES(?,?,?)",
            values: [
              word, DictionaryText.normalize(EijiroText.sense(word, definition).headword),
              definition,
            ])
          count += 1
        }
      }
      guard count > 0 else { throw AppFailure("英辞郎形式の項目がありません。『■見出し : 定義』形式を確認してください") }
      try db.execute("COMMIT")
      return count
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
  func senses(for word: String) -> [EijiroText.Sense] {
    let normalized = DictionaryText.normalize(word)
    var rows =
      (try? db.rows(
        "SELECT headword,definition FROM entries WHERE normalized_headword=? ORDER BY rowid",
        values: [normalized])) ?? []
    // 旧インポートにも対応。句を総走査せず、品詞タグの索引範囲だけを取得する。
    for spaces in ["", " ", "  ", "　"] {
      let prefix = normalized + spaces
      rows +=
        (try? db.rows(
          "SELECT headword,definition FROM entries WHERE normalized_headword>=? AND normalized_headword<? ORDER BY rowid",
          values: [prefix + "{", prefix + "|"])) ?? []
    }
    return rows.map { EijiroText.sense($0[0], $0[1]) }
      .filter { DictionaryText.normalize($0.headword) == normalized }
  }
  func resolve(_ word: String, pos: String?, visited: Set<String>) -> DictionaryEntry? {
    let normalized = DictionaryText.normalize(word)
    guard visited.count < 5, !visited.contains(normalized) else { return nil }
    let senses = senses(for: word)
    guard !senses.isEmpty else { return nil }
    var direct = EijiroText.entry(senses, pos: pos)
    direct.headword = word
    let abbreviations = EijiroText.ordered(senses).filter { $0.label == "省略形" }
    if !abbreviations.isEmpty {
      direct.partOfSpeech = "省略形"
      var seen = Set<String>()
      let forms = abbreviations.flatMap { EijiroText.references($0.definition) }
        .filter { seen.insert(DictionaryText.normalize($0)).inserted }
      direct.expandedForms = forms
      if !forms.isEmpty {
        direct.definition = "省略前の形: " + forms.joined(separator: " / ") + "\n\n" + direct.definition
        direct.blocks.insert(DictionaryBlock("省略前の形: " + forms.joined(separator: " / "), role: .note), at: 0)
        var glosses: [String] = []
        for form in forms {
          // The expansion's POS may differ from the original contracted token.
          guard let resolved = resolve(form, pos: nil, visited: visited.union([normalized])),
            resolved.shortGloss != "日本語の語義なし" else { continue }
          direct.definition += "\n\n参照先: " + form + "\n" + resolved.definition
          direct.blocks += [DictionaryBlock("参照先: " + form, role: .phrase)] + resolved.blocks
          if !glosses.contains(resolved.shortGloss) { glosses.append(resolved.shortGloss) }
        }
        if direct.shortGloss != "日本語の語義なし" { glosses.insert(direct.shortGloss, at: 0) }
        direct.shortGloss = glosses.isEmpty
          ? forms.joined(separator: " / ") + " の省略形" : glosses.joined(separator: "、")
      }
      return direct
    }
    if word.contains(" ") {
      let labels = senses.compactMap(\.label)
      if labels.contains(where: { $0.contains("動") }) { direct.partOfSpeech = "句動詞" }
      else if labels.contains("名") { direct.partOfSpeech = "名詞" }
      else if labels.contains("形") { direct.partOfSpeech = "形容詞" }
      else if labels.contains("副") { direct.partOfSpeech = "副詞" }
      else if labels.contains("前") { direct.partOfSpeech = "前置詞句" }
      else { direct.partOfSpeech = "複数語表現" }
    }
    let meanings = EijiroText.meanings(senses, pos: pos)
    if let first = meanings.first, let reference = EijiroText.reference(first.definition),
      let resolved = resolve(reference, pos: pos, visited: visited.union([normalized])),
      resolved.shortGloss != "日本語の語義なし"
    {
      return DictionaryEntry(
        definition: direct.definition + "\n\n参照先: " + reference + "\n" + resolved.definition,
        shortGloss: resolved.shortGloss, headword: reference,
        partOfSpeech: direct.partOfSpeech ?? resolved.partOfSpeech,
        pronunciation: direct.pronunciation ?? resolved.pronunciation,
        usedPartOfSpeechFallback: direct.usedPartOfSpeechFallback || resolved.usedPartOfSpeechFallback,
        blocks: direct.blocks + [DictionaryBlock("参照先: " + reference, role: .phrase)] + resolved.blocks)
    }
    return direct
  }
  public func lookup(_ token: Token) async -> DictionaryEntry? {
    var fallback: DictionaryEntry?
    for word in DictionaryText.candidates(token) {
      guard !Task.isCancelled else { return nil }
      if let entry = resolve(word, pos: token.partOfSpeech, visited: []) {
        if entry.shortGloss != "日本語の語義なし", !entry.usedPartOfSpeechFallback { return entry }
        if fallback == nil || (fallback?.shortGloss == "日本語の語義なし" && entry.shortGloss != "日本語の語義なし") {
          fallback = entry
        }
      }
    }
    return fallback
  }
  public func lookupExpressions(_ expressions: [[Token]]) async -> [DictionaryEntry?] {
    let forms = expressions.map { DictionaryExpressions.candidates($0) }
    let words = Array(Set(forms.flatMap { $0 }.map(DictionaryText.normalize))).sorted()
    var present = Set<String>()
    // Batched indexed lookups also cover dictionaries imported before POS tags
    // were removed from normalized_headword. Never scan the whole dictionary.
    for start in stride(from: 0, to: words.count, by: 50) {
      guard !Task.isCancelled else { return Array(repeating: nil, count: expressions.count) }
      let chunk = words[start..<min(start + 50, words.count)]
      var predicates: [String] = []
      var values: [String] = []
      for word in chunk {
        predicates.append("normalized_headword=?")
        values.append(word)
        for spaces in ["", " ", "  ", "　"] {
          predicates.append("(normalized_headword>=? AND normalized_headword<?)")
          values += [word + spaces + "{", word + spaces + "|"]
        }
      }
      let rows = (try? db.rows(
        "SELECT headword,definition FROM entries WHERE " + predicates.joined(separator: " OR "),
        values: values)) ?? []
      for row in rows {
        present.insert(DictionaryText.normalize(EijiroText.sense(row[0], row[1]).headword))
      }
      await Task.yield()
    }
    return forms.map { candidates in
      for word in candidates where present.contains(DictionaryText.normalize(word)) {
        if let entry = resolve(word, pos: nil, visited: []), entry.shortGloss != "日本語の語義なし" {
          return entry
        }
      }
      return nil
    }
  }
}
public enum APISecret {
  static let service = "jp.local.YouTubeEnglishStudy.localLLM"
  public static func read() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "apiKey", kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
      let data = value as? Data
    else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
  public static func save(_ key: String) throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "apiKey",
    ]
    if key.isEmpty {
      let status = SecItemDelete(q as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw AppFailure("API キーを Keychain から削除できませんでした")
      }
      return
    }
    let data = Data(key.utf8)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw AppFailure("API キーを Keychain に保存できませんでした")
    }
    var item = q
    item[kSecValueData as String] = data
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw AppFailure("API キーを Keychain に保存できませんでした")
    }
  }
}
