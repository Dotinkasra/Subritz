import CoreServices
import Foundation
import Security

public struct DictionaryEntry: Sendable {
  public var definition: String
  public var shortGloss: String
}
public protocol DictionaryProvider: Sendable {
  func lookup(_ token: Token) async -> DictionaryEntry?
}
public enum DictionaryText {
  public static func candidates(_ token: Token) -> [String] {
    var seen = Set<String>()
    return [token.surface, token.normalized, token.lemma, token.lemma?.lowercased()].compactMap {
      $0
    }.filter { seen.insert($0).inserted }
  }
  public static func normalize(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case "Determiner": return ["定", "不", "冠", "形"]
    case "Particle": return ["前", "副", "助"]
    default: return []
    }
  }
  static func matches(_ sense: Sense, pos: String?) -> Bool {
    let wanted = labels(for: pos)
    return wanted.isEmpty
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
    let text = meaning(value)
    if text.hasPrefix("＝<→"), let end = text.firstIndex(of: ">") {
      return String(text[text.index(text.startIndex, offsetBy: 3)..<end])
    }
    // is / went など、辞書自身が説明している活用元。
    let regex = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z'-]*)の.*(?:形|分詞)$"#)
    let ns = text as NSString
    if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
      return ns.substring(with: match.range(at: 1))
    }
    return nil
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
    let ordered = ordered(senses)
    let tagged = ordered.filter { $0.label != nil }
    return (tagged.isEmpty ? ordered : tagged.filter { matches($0, pos: pos) })
      .filter {
        meaning($0.definition).range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil
          || reference($0.definition) != nil
      }
  }
  static func entry(_ senses: [Sense], pos: String?) -> DictionaryEntry {
    let gloss = meanings(senses, pos: pos).filter { reference($0.definition) == nil }
      .prefix(3).map { meaning($0.definition) }.joined(separator: "、")
    let detailed = ordered(senses).map { sense in
      let label = sense.tag.map { "{\($0)}: " } ?? ""
      return label
        + sense.definition.replacingOccurrences(of: "■", with: "\n■")
        .replacingOccurrences(of: "◆", with: "\n◆")
    }.joined(separator: "\n")
    return DictionaryEntry(definition: detailed, shortGloss: gloss.isEmpty ? "日本語の語義なし" : gloss)
  }
}
public struct MacDictionaryProvider: DictionaryProvider {
  public init() {}
  public func lookup(_ token: Token) async -> DictionaryEntry? {
    await Task.detached {
      for word in DictionaryText.candidates(token) {
        if let value = DCSCopyTextDefinition(
          nil, word as CFString, CFRange(location: 0, length: (word as NSString).length))?
          .takeRetainedValue()
        {
          let text = value as String
          return DictionaryEntry(definition: text, shortGloss: DictionaryText.gloss(text))
        }
      }
      return nil
    }.value
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
    let direct = EijiroText.entry(senses, pos: pos)
    let meanings = EijiroText.meanings(senses, pos: pos)
    if let first = meanings.first, let reference = EijiroText.reference(first.definition),
      let resolved = resolve(reference, pos: pos, visited: visited.union([normalized])),
      resolved.shortGloss != "日本語の語義なし"
    {
      return DictionaryEntry(
        definition: direct.definition + "\n\n参照先: " + reference + "\n" + resolved.definition,
        shortGloss: resolved.shortGloss)
    }
    return direct
  }
  public func lookup(_ token: Token) async -> DictionaryEntry? {
    var fallback: DictionaryEntry?
    for word in DictionaryText.candidates(token) {
      if let entry = resolve(word, pos: token.partOfSpeech, visited: []) {
        if entry.shortGloss != "日本語の語義なし" { return entry }
        if fallback == nil { fallback = entry }
      }
    }
    return fallback
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
    SecItemDelete(q as CFDictionary)
    if key.isEmpty { return }
    var item = q
    item[kSecValueData as String] = Data(key.utf8)
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw AppFailure("API キーを Keychain に保存できませんでした")
    }
  }
}
