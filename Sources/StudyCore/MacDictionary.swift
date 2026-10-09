import CoreServices
import Darwin
import Foundation

// DictionaryServices' public API supplies plain text from the first active dictionary.
// Isolate optional, undocumented record access here; never alter the user's dictionary order.
final class MacDictionaryRuntime {
  typealias CopyAvailable = @convention(c) () -> Unmanaged<CFTypeRef>?
  typealias GetString = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
  typealias CopyRecords = @convention(c) (CFTypeRef, CFString, Int, Int) -> Unmanaged<CFTypeRef>?
  typealias CopyData = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
  let available: CopyAvailable
  let identifier: GetString
  let records: CopyRecords
  let data: CopyData
  let headword: GetString
  let anchor: GetString
  private var dictionary: CFTypeRef?
  private var cache: [String: [DictionaryEntry]] = [:]

  init?() {
    guard let handle = dlopen(
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices",
      RTLD_LAZY | RTLD_LOCAL) else { return nil }
    // CoreServices is already loaded; retaining the handle keeps function pointers valid.
    func symbol<T>(_ name: String, _: T.Type) -> T? {
      dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
    guard let available = symbol("DCSCopyAvailableDictionaries", CopyAvailable.self),
      let identifier = symbol("DCSDictionaryGetIdentifier", GetString.self),
      let records = symbol("DCSCopyRecordsForSearchString", CopyRecords.self),
      let data = symbol("DCSRecordCopyData", CopyData.self),
      let headword = symbol("DCSRecordGetHeadword", GetString.self),
      let anchor = symbol("DCSRecordGetAnchor", GetString.self)
    else { dlclose(handle); return nil }
    self.available = available; self.identifier = identifier; self.records = records
    self.data = data; self.headword = headword; self.anchor = anchor
  }
  func englishJapaneseDictionary() -> CFTypeRef? {
    if let dictionary { return dictionary }
    guard let value = available()?.takeRetainedValue() else { return nil }
    let dictionaries: [AnyObject]
    switch CFGetTypeID(value) {
    case CFSetGetTypeID(): dictionaries = (value as! NSSet).allObjects as [AnyObject]
    case CFArrayGetTypeID(): dictionaries = value as! [AnyObject]
    default: return nil
    }
    // This adapter implements the WISDOM markup schema, not arbitrary dictionary HTML.
    dictionary = dictionaries.first {
      identifier($0)?.takeUnretainedValue() as String? == "com.apple.dictionary.ja-en.WISDOM"
    }
    return dictionary
  }
  func lookup(_ word: String, pos: String?) -> DictionaryEntry? {
    if let cached = cache[word] { return MacDictionaryMarkup.combine(cached, pos: pos) }
    guard let dictionary = englishJapaneseDictionary(),
      let value = records(dictionary, word as CFString, 0, 32)?.takeRetainedValue(),
      CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
    var entries: [DictionaryEntry] = []
    for record in value as! [AnyObject] {
      guard let title = headword(record)?.takeUnretainedValue() as String?,
        let raw = data(record)?.takeRetainedValue(), CFGetTypeID(raw) == CFStringGetTypeID()
      else { continue }
      // A search can also return suffixes, spelling variants, or partial word matches.
      if word.contains(" ") && DictionaryText.normalize(title) != DictionaryText.normalize(word) {
        continue
      }
      if !word.contains(" ") && title.hasPrefix("-") && !word.hasPrefix("-") { continue }
      let pointer = anchor(record)?.takeUnretainedValue() as String?
      if let entry = MacDictionaryMarkup.parse(raw as! String, headword: title, anchor: pointer) {
        entries.append(entry)
      }
    }
    if cache.count >= 512 { cache.removeAll() }
    cache[word] = entries
    return MacDictionaryMarkup.combine(entries, pos: pos)
  }
}

enum MacDictionaryAccess {
  static let lock = NSLock()
  static let runtime = MacDictionaryRuntime()
  static func entry(for word: String, pos: String? = nil) -> DictionaryEntry? {
    lock.lock()
    defer { lock.unlock() }
    if let runtime, runtime.englishJapaneseDictionary() != nil {
      return runtime.lookup(word, pos: pos)
    }
    let range = CFRange(location: 0, length: (word as NSString).length)
    guard let value = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue()
    else { return nil }
    if word.contains(" ") {
      let detected = DCSGetTermRangeInString(nil, word as CFString, 0)
      guard detected.location == 0, detected.length == range.length else { return nil }
    }
    // Unknown schemas cannot safely yield a Japanese short gloss. Keep the full text
    // available in detail instead of showing a heading or pronunciation as a meaning.
    return DictionaryEntry(definition: value as String, shortGloss: "日本語の語義を抽出できません",
      headword: word)
  }
}

enum MacDictionaryMarkup {
  static let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
  static let excludedScopes: Set<String> = ["exg", "box", "np", "idmsec", "drvsec", "csec"]
  static let noteClasses: Set<String> = ["xrg", "grnote", "lbl", "con", "fld", "ph", "pr", "sn", "rf"]

  static func parse(_ markup: String, headword: String, anchor: String? = nil) -> DictionaryEntry? {
    guard let doc = try? XMLDocument(xmlString: markup, options: [.nodeLoadExternalEntitiesNever]),
      let entry = doc.rootElement()?.allElements.first(where: { $0.localName == "entry" })
    else { return nil }
    let scope: XMLElement
    if let anchor, !anchor.isEmpty {
      // Match only the record's exact id. Do not evaluate arbitrary XPath from markup.
      guard let id = anchorID(anchor),
        let selected = entry.allElements.first(where: {
          $0.attribute(forName: "id")?.stringValue == id
        }) else { return nil }
      scope = selected
    } else { scope = entry }

    var sections: [DictionarySection] = []
    if scope !== entry {
      let pos = scope.ancestors.first(where: { $0.hasClass("gramb") })
        .flatMap { partOfSpeech($0) } ?? "複数語表現"
      let meanings = senses(in: scope, entry: entry)
      if !meanings.isEmpty {
        sections = [DictionarySection(partOfSpeech: pos == "動詞" ? "句動詞" : pos, senses: meanings)]
      }
    } else {
      for group in entry.allElements where group.hasClass("gramb") {
        guard !group.ancestors(until: entry).contains(where: { !$0.classes.isDisjoint(with: excludedScopes) }),
          let pos = partOfSpeech(group) else { continue }
        let meanings = senses(in: group, entry: entry)
        if !meanings.isEmpty { sections.append(DictionarySection(partOfSpeech: pos, senses: meanings)) }
      }
    }
    guard !sections.isEmpty else { return nil }
    let pronunciation = entry.allElements.first(where: { $0.semantic("prn") != nil })?.stringValue
    return makeEntry(headword: headword, pronunciation: pronunciation, sections: sections, pos: nil)
  }
  static func combine(_ entries: [DictionaryEntry], pos: String?) -> DictionaryEntry? {
    guard let first = entries.first else { return nil }
    let sections = entries.flatMap(\.sections)
    return makeEntry(headword: first.headword ?? "", pronunciation: first.pronunciation,
      sections: sections, pos: pos)
  }
  static func makeEntry(headword: String, pronunciation: String?, sections: [DictionarySection], pos: String?) -> DictionaryEntry {
    let wanted: Set<String>
    switch pos {
    case "Noun": wanted = ["名詞"]
    case "Verb": wanted = ["動詞", "句動詞", "助動詞"]
    case "Adjective": wanted = ["形容詞"]
    case "Adverb": wanted = ["副詞"]
    case "Pronoun": wanted = ["代名詞"]
    case "Preposition": wanted = ["前置詞"]
    case "Conjunction": wanted = ["接続詞"]
    case "Interjection": wanted = ["間投詞", "感動詞"]
    case "Determiner": wanted = ["限定詞", "冠詞", "形容詞"]
    case "Particle": wanted = ["副詞", "前置詞"]
    default: wanted = []
    }
    let matching = wanted.isEmpty ? sections : sections.filter { wanted.contains($0.partOfSpeech) }
    // Missing POS information may fall back to the first actual dictionary POS. A known
    // POS mismatch must not silently present another grammatical use as its meaning.
    let gloss = matching.flatMap(\.senses).prefix(3).map { $0.shortMeaning ?? $0.meaning }
      .joined(separator: "、")
    let definition = sections.map { section in
      section.partOfSpeech + "\n" + section.senses.enumerated().map { index, sense in
        "\(index + 1). " + sense.meaning + (sense.examples.isEmpty ? "" : "\n" + sense.examples.joined(separator: "\n"))
      }.joined(separator: "\n")
    }.joined(separator: "\n\n")
    return DictionaryEntry(definition: definition,
      shortGloss: gloss.isEmpty ? "この品詞の日本語語義はありません" : gloss,
      headword: headword, partOfSpeech: matching.first?.partOfSpeech ?? sections.first?.partOfSpeech,
      sections: sections, pronunciation: pronunciation)
  }
  static func partOfSpeech(_ group: XMLElement) -> String? {
    group.allElements.first {
      $0.semantic("pos") != nil
        && $0.ancestors.first(where: { $0.hasClass("gramb") }) === group
    }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func hasJapanese(_ text: String) -> Bool {
    text.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression) != nil
  }
  static func anchorID(_ pointer: String) -> String? {
    let regex = try! NSRegularExpression(pattern: #"@id\s*=\s*['\"]([^'\"]+)['\"]"#)
    let ns = pointer as NSString
    guard let match = regex.firstMatch(in: pointer, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: match.range(at: 1))
  }
  static func senses(in scope: XMLElement, entry: XMLElement, visited: Set<String> = []) -> [DictionarySense] {
    guard visited.count < 8 else { return [] }
    let phrase = scope.hasClass("idmsec") || scope.ancestors.contains(where: { $0.hasClass("idmsec") })
    let forbidden = phrase ? excludedScopes.subtracting(["idmsec"]) : excludedScopes
    let definitions = scope.allElements.filter {
      (phrase ? $0.hasClass("trg") : $0.semantic("def") != nil)
        && !$0.ancestors(until: scope).contains(where: { !$0.classes.isDisjoint(with: forbidden) })
        && !$0.ancestors(until: scope).contains(where: { $0.hasClass("trg") })
    }
    return definitions.flatMap { definition -> [DictionarySense] in
      let translations = definition.allElements.filter {
        $0.hasClass("trans") && !$0.hasClass("ty_用例訳")
          && !$0.ancestors(until: definition).contains(where: {
            $0.hasClass("trans") || !$0.classes.isDisjoint(with: noteClasses)
          })
      }
      // Multiple trans nodes may be the subject constraint and predicate of ONE
      // meaning. The definition/sense container, not each trans node, is the unit.
      let meaning = translations.map(meaningText).filter { !$0.isEmpty }.joined()
      if hasJapanese(meaning) {
        return [DictionarySense(meaning: meaning, examples: examples(near: definition, limit: scope),
          shortMeaning: shortMeaning(meaning))]
      }
      // Some phrase senses contain only an upward reference to a verb subsense.
      // Resolve local record references without opening URLs or crossing records.
      guard let entryID = entry.attribute(forName: "id")?.stringValue else { return [] }
      return definition.allElements.filter { $0.localName == "a" }.flatMap { link -> [DictionarySense] in
        guard let href = link.attribute(forName: "href")?.stringValue,
          href.hasPrefix("x-dictionary:r:" + entryID + ":"), let id = anchorID(href),
          !visited.contains(id), id != scope.attribute(forName: "id")?.stringValue,
          let target = entry.allElements.first(where: { $0.attribute(forName: "id")?.stringValue == id })
        else { return [] }
        return senses(in: target, entry: entry, visited: visited.union([id]))
      }
    }
  }
  static func meaningText(_ node: XMLElement) -> String {
    func render(_ node: XMLNode) -> String {
      if let element = node as? XMLElement {
        if !element.classes.isDisjoint(with: noteClasses) { return "" }
        return (element.children ?? []).map(render).joined()
      }
      return node.kind == .text ? node.stringValue ?? "" : ""
    }
    return render(node).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func shortMeaning(_ text: String) -> String {
    // WISDOM translations may contain untagged argument constraints and English
    // collocation notes. Remove these only from the speed-reading gloss. Full
    // meanings keep them, including parentheses that are part of a Japanese sense.
    let characters = Array(text)
    let pairs: [Character: Character] = ["(": ")", "（": "）", "〈": "〉", "〖": "〗", "｟": "｠", "«": "»"]
    var result = ""
    var i = 0
    while i < characters.count {
      let opening = characters[i]
      if let closing = pairs[opening] {
        var j = i + 1
        var depth = 1
        while j < characters.count {
          if characters[j] == opening { depth += 1 }
          if characters[j] == closing { depth -= 1 }
          if depth == 0 { break }
          j += 1
        }
        if j < characters.count {
          let inside = String(characters[(i + 1)..<j])
          let constraint = ["〈", "〖", "｟", "«"].contains(opening)
          let leading = result.trimmingCharacters(in: .whitespaces).isEmpty
          let englishNote = inside.range(of: "[A-Za-z]", options: .regularExpression) != nil
          if constraint || leading || englishNote { i = j + 1; continue }
        }
      }
      result.append(characters[i]); i += 1
    }
    let cleaned = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return hasJapanese(cleaned) ? cleaned : text
  }
  static func examples(near node: XMLElement, limit: XMLElement) -> [String] {
    // The smallest sense container owns these examples; do not take examples from
    // the next sense or a nested phrase.
    guard let sense = node.ancestors(until: limit).first(where: { $0.hasClass("semb") })
      ?? (limit.hasClass("semb") ? limit : nil) else { return [] }
    return sense.allElements.filter {
      $0.hasClass("exg") && $0.ancestors.first(where: { $0.hasClass("semb") }) === sense
    }.compactMap { example in
      let english = example.allElements.first(where: { $0.hasClass("ex") })?.stringValue ?? ""
      let japanese = example.allElements.first(where: { $0.hasClass("ty_用例訳") })?.stringValue ?? ""
      let lines = [english, japanese].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
  }
}

private extension XMLElement {
  var classes: Set<String> { Set((attribute(forName: "class")?.stringValue ?? "").split(whereSeparator: \.isWhitespace).map(String.init)) }
  func hasClass(_ name: String) -> Bool { classes.contains(name) }
  func semantic(_ name: String) -> String? {
    attributes?.first { $0.localName == name && $0.uri == MacDictionaryMarkup.namespace }?.stringValue
  }
  var allElements: [XMLElement] { [self] + (children ?? []).compactMap { $0 as? XMLElement }.flatMap(\.allElements) }
  var ancestors: [XMLElement] { ancestors(until: nil) }
  func ancestors(until limit: XMLElement?) -> [XMLElement] {
    if self === limit { return [] }
    var result: [XMLElement] = []
    var ancestor = parent as? XMLElement
    while let node = ancestor, node !== limit { result.append(node); ancestor = node.parent as? XMLElement }
    return result
  }
}
