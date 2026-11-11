import CoreServices
import Darwin
import Foundation

// DictionaryServices' public API supplies plain text from the first active dictionary.
// Isolate optional, undocumented record access here; never alter the user's dictionary order.
// Positive definitions and phrase misses have independent bounded caches.
struct MacDictionaryRecordCache {
  private var words: [String: [DictionaryEntry]] = [:]
  private var wordOrder: [String] = []
  private var misses = Set<String>()
  private var missOrder: [String] = []
  func entries(for key: String) -> [DictionaryEntry]? {
    words[key] ?? (misses.contains(key) ? [] : nil)
  }
  mutating func store(_ entries: [DictionaryEntry], for key: String) {
    if entries.isEmpty {
      guard misses.insert(key).inserted else { return }
      if missOrder.count >= 8192 { misses.remove(missOrder.removeFirst()) }
      missOrder.append(key)
    } else {
      if words[key] == nil {
        if wordOrder.count >= 512 { words.removeValue(forKey: wordOrder.removeFirst()) }
        wordOrder.append(key)
      }
      words[key] = entries
    }
  }
}

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
  private var cache = MacDictionaryRecordCache()

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
    let key = DictionaryText.normalize(word)
    if let cached = cache.entries(for: key) { return MacDictionaryMarkup.combine(cached, pos: pos) }
    guard let dictionary = englishJapaneseDictionary(),
      let value = records(dictionary, word as CFString, 0, 32)?.takeRetainedValue(),
      CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
    var entries: [DictionaryEntry] = []
    for record in value as! [AnyObject] {
      guard !Task.isCancelled else { return nil }
      guard let title = headword(record)?.takeUnretainedValue() as String? else { continue }
      let pointer = anchor(record)?.takeUnretainedValue() as String?
      // A search can also return suffixes, spelling variants, or partial word matches.
      if word.contains(" ") && MacDictionaryMarkup.phraseHeadword(title, anchored: pointer?.isEmpty == false)
        .map(DictionaryText.normalize) != DictionaryText.normalize(word) {
        continue
      }
      if !word.contains(" ") && title.hasPrefix("-") && !word.hasPrefix("-") { continue }
      // Reject partial phrase hits before copying a potentially huge parent record.
      guard let raw = data(record)?.takeRetainedValue(), CFGetTypeID(raw) == CFStringGetTypeID()
      else { continue }
      if let entry = MacDictionaryMarkup.parse(raw as! String, headword: title, anchor: pointer) {
        entries.append(entry)
      }
    }
    // A completely parsed result remains useful if its hover was cancelled at
    // the last record. The caller still discards that obsolete UI update.
    cache.store(entries, for: key)
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

// Serialize DictionaryServices without blocking many cooperative-pool threads
// on NSLock. A cancelled hover/prefetch is discarded before its record is read.
private actor MacDictionaryWorker {
  static let shared = MacDictionaryWorker()
  func entry(for word: String, pos: String? = nil) -> DictionaryEntry? {
    guard !Task.isCancelled else { return nil }
    return MacDictionaryAccess.entry(for: word, pos: pos)
  }
}

extension MacDictionaryAccess {
  static func lookup(for word: String, pos: String? = nil) async -> DictionaryEntry? {
    await MacDictionaryWorker.shared.entry(for: word, pos: pos)
  }
}

enum MacDictionaryMarkup {
  static let namespace = "http://www.apple.com/DTDs/DictionaryService-1.0.rng"
  static let excludedScopes: Set<String> = ["exg", "box", "np", "idmsec", "drvsec", "csec"]
  static let noteClasses: Set<String> = ["xrg", "grnote", "lbl", "con", "fld", "ph", "pr", "sn", "rf", "ind", "exg", "ty_用例訳"]
  static func phraseHeadword(_ title: String, anchored: Bool) -> String? {
    guard anchored else { return title }
    // WISDOM's A/B/C slots are arguments, not literal articles in the subtitle.
    // "look at A" recognizes "look at", never the three-word "look at a".
    var words = title.split(separator: " ").map(String.init)
    let slots: Set<String> = ["A", "B", "C"]
    while let last = words.last, slots.contains(last) { words.removeLast() }
    guard words.count >= 2, !words.contains(where: { slots.contains($0) }) else { return nil }
    return words.joined(separator: " ")
  }

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
    let header = scope === entry ? entry.allElements.first(where: { $0.hasClass("hwg") }) : scope
    var seenPronunciations = Set<String>()
    let pronunciations = (header?.allElements ?? []).filter { $0.semantic("prn") != nil }
      .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seenPronunciations.insert($0).inserted }
    let blocks = structuredBlocks(scope)
    var parsed = makeEntry(headword: headword,
      pronunciation: pronunciations.isEmpty ? nil : pronunciations.joined(separator: " / "),
      sections: sections, pos: nil, definition: blocks.map(\.text).joined(separator: "\n"))
    parsed.blocks = blocks
    parsed.pronunciationCandidates = pronunciationCandidates(in: scope, headword: headword, sections: sections)
    return parsed
  }
  static func combine(_ entries: [DictionaryEntry], pos: String?) -> DictionaryEntry? {
    guard let first = entries.first else { return nil }
    let sections = entries.flatMap(\.sections)
    var combined = makeEntry(headword: first.headword ?? "", pronunciation: first.pronunciation,
      sections: sections, pos: pos,
      definition: entries.count == 1 ? first.definition : entries.map(\.definition).joined(separator: "\n\n"))
    combined.blocks = entries.flatMap(\.blocks)
    combined.pronunciationCandidates = entries.flatMap(\.pronunciationCandidates)
    return combined
  }
  static func pronunciationCandidates(in scope: XMLElement, headword: String,
    sections: [DictionarySection]) -> [PronunciationCandidate] {
    var result: [PronunciationCandidate] = []
    let firstPOS = sections.first?.partOfSpeech
    let referenceForms = sections.flatMap(\.senses).prefix(1).flatMap { sense -> [PronunciationInflection] in
      // A separate inflection record can have the same spelling (e.g. read).
      guard sense.meaning.range(of: #"^[A-Za-z0-9¹²]+の(?:過去|現在|原形)"#,
        options: .regularExpression) != nil else { return [] }
      return PronunciationText.inflectionsIn(sense.meaning)
    }
    for node in scope.allElements where node.semantic("prn") != nil || node.semantic("pr") != nil {
      guard let raw = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
      let ancestors = node.ancestors(until: scope)
      guard !ancestors.contains(where: { $0.hasClass("exg") || $0.hasClass("box")
        || $0.hasClass("etym") || $0.hasClass("u") || $0.hasClass("np") }) else { continue }
      // Anchored phrases own their pronunciation; never inherit the parent word's.
      if scope.localName == "entry", ancestors.contains(where: {
        $0.hasClass("idmsec") || $0.hasClass("drvsec") || $0.hasClass("csec")
      }) { continue }
      let group = ancestors.first(where: { $0.hasClass("gramb") })
      let pos = group.flatMap(partOfSpeech) ?? firstPOS
      let pronunciationGroup = ancestors.first(where: { $0.hasClass("pr") })
      let before = pronunciationGroup.map { textBefore(node, in: $0) } ?? ""
      var forms = referenceForms
      var owner = headword
      if let note = ancestors.first(where: { $0.hasClass("grnote") }) {
        // Only an explicit statement about this headword's inflection is usable.
        let prefix = textBefore(node, in: note).components(separatedBy: ";").last ?? ""
        guard prefix.range(of: #"(?:過去形|過去分詞).*発音(?:は|が)?\s*[|\s]*$"#,
          options: .regularExpression) != nil else { continue }
        forms = PronunciationText.inflectionsIn(prefix)
      } else if let formGroup = ancestors.first(where: { $0.hasClass("frmg") }) {
        let preceding = textBefore(pronunciationGroup ?? node, in: formGroup)
        let formNodes = formGroup.allElements.filter { $0.hasClass("frm") }
        let all = formGroup.allElements
        guard let index = all.firstIndex(where: { $0 === node }),
          let label = all[..<index].last(where: { $0.hasClass("frm") }),
          let written = label.stringValue else { continue }
        owner = written.replacingOccurrences(of: "～", with: headword)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = formNodes.last?.stringValue, last.hasSuffix("ing"), formNodes.count == 3,
          formNodes[1] === label {
          forms = [.past, .pastParticiple]
        } else if written.hasSuffix("ing") { forms = [.presentParticiple] }
        else if written.hasSuffix("s") { forms = [.thirdPerson] }
        else { forms = PronunciationText.inflectionsIn(preceding) }
      } else {
        // Accept main headings and POS headings, excluding pronunciation fragments in meanings.
        guard ancestors.contains(where: { $0.hasClass("hwg") || $0.hasClass("x_xdh") }) else { continue }
        if forms.isEmpty, PronunciationText.canonicalPOS(pos) == "Verb" { forms = [.base] }
      }
      let pr = node.semantic("pr") ?? ""
      let region: PronunciationRegion? = pr.contains("US") ? .us : pr.contains("UK") ? .uk : nil
      var strength: PronunciationCandidate.Strength? = nil
      let label = before.components(separatedBy: CharacterSet(charactersIn: ",;|")).last ?? ""
      if label.contains("強") { strength = .strong }
      else if label.contains("弱") { strength = .weak }
      // Some WISDOM headers mark only the strong form, with the weak forms preceding it.
      else if pronunciationGroup?.stringValue?.contains("｟強｠") == true { strength = .weak }
      result += PronunciationText.parse(raw, region: region, strength: strength,
        partOfSpeech: pos, inflections: forms, headword: owner)
    }
    return result
  }
  static func textBefore(_ target: XMLNode, in root: XMLNode) -> String {
    var text = ""
    func visit(_ node: XMLNode) -> Bool {
      if node === target { return false }
      if node.kind == .text { text += node.stringValue ?? "" }
      for child in node.children ?? [] { if !visit(child) { return false } }
      return true
    }
    _ = visit(root)
    return text
  }
  static func makeEntry(headword: String, pronunciation: String?, sections: [DictionarySection], pos: String?,
    definition fullDefinition: String? = nil) -> DictionaryEntry {
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
    case "Determiner": wanted = ["限定詞", "冠詞", "形容詞", "代名詞"]
    case "Particle": wanted = ["副詞", "前置詞"]
    default: wanted = []
    }
    let matching = wanted.isEmpty ? sections : sections.filter { wanted.contains($0.partOfSpeech) }
    let selected = matching.isEmpty ? Array(sections.prefix(1)) : matching
    // On a tokenizer mismatch, show an actual dictionary use with its own POS.
    // Keep that fallback separate so a matching lemma can still take priority.
    let gloss = selected.flatMap(\.senses).prefix(3).map { $0.shortMeaning ?? $0.meaning }
      .joined(separator: "、")
    let definition: String
    if let fullDefinition { definition = fullDefinition }
    else {
      definition = sections.map { section in
        let senses = section.senses.enumerated().map { index, sense -> String in
          let examples = sense.examples.isEmpty ? "" : "\n" + sense.examples.joined(separator: "\n")
          return "\(index + 1). " + sense.meaning + examples
        }.joined(separator: "\n")
        return section.partOfSpeech + "\n" + senses
      }.joined(separator: "\n\n")
    }
    return DictionaryEntry(definition: definition,
      shortGloss: gloss.isEmpty ? "この品詞の日本語語義はありません" : gloss,
      headword: headword, partOfSpeech: selected.first?.partOfSpeech,
      sections: sections, pronunciation: pronunciation, usedPartOfSpeechFallback: matching.isEmpty && !selected.isEmpty)
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
      // d:def marks priority/search summaries, not the complete set of senses.
      ($0.hasClass("trg") || ($0.semantic("def") != nil
        && !$0.allElements.dropFirst().contains(where: { $0.hasClass("trg") })))
        && !$0.ancestors(until: scope).contains(where: { !$0.classes.isDisjoint(with: forbidden) })
        && !$0.ancestors(until: scope).contains(where: { $0.hasClass("trg") })
    }
    return definitions.flatMap { definition -> [DictionarySense] in
      // Preserve inline punctuation between translations. Notes and examples are
      // omitted only here, when producing a compact gloss, never from full text.
      let meaning = meaningText(definition)
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
  static func fullText(_ scope: XMLElement) -> String {
    structuredBlocks(scope).map(\.text).joined(separator: "\n")
  }
  static func structuredBlocks(_ scope: XMLElement) -> [DictionaryBlock] {
    // Preserve every visible text node while retaining the dictionary's own
    // semantic hierarchy, including notes and idioms outside summary senses.
    let boundaries: Set<String> = ["hwg", "gramb", "semb", "box", "np", "idmsec", "drvsec",
      "csec", "cb", "title", "x_xdh", "etym", "exg", "ex", "ty_用例訳", "idm", "drv"]
    var blocks: [DictionaryBlock] = []
    var buffer = ""
    var kind: DictionaryBlock.Role = .body
    func flush() {
      let text = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { blocks.append(DictionaryBlock(text, role: kind)) }
      buffer = ""
    }
    func visit(_ node: XMLNode, role inherited: DictionaryBlock.Role) {
      guard let element = node as? XMLElement else {
        if node.kind == .text, let text = node.stringValue {
          if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { kind = inherited }
          buffer += text
        }
        return
      }
      if ["script", "style"].contains(element.localName ?? "") { return }
      if element.localName == "br" { flush(); return }
      let classes = element.classes
      let boundary = !classes.isDisjoint(with: boundaries)
      if boundary { flush() }
      let role: DictionaryBlock.Role
      if classes.contains("hwg") { role = .metadata }
      else if classes.contains("x_xdh") || element.semantic("pos") != nil { role = .partOfSpeech }
      else if classes.contains("idm") || classes.contains("drv") { role = .phrase }
      else if classes.contains("ty_用例訳") { role = .translation }
      else if classes.contains("exg") || classes.contains("ex") { role = .example }
      else if classes.contains("box") || classes.contains("np") || classes.contains("etym")
        || classes.contains("grnote") || classes.contains("title") { role = .note }
      else if classes.contains("trg") || element.semantic("def") != nil { role = .meaning }
      else { role = inherited }
      // Sense numbers precede their meaning in the same paragraph.
      if role == .meaning, kind == .body { kind = .meaning }
      for child in element.children ?? [] { visit(child, role: role) }
      if classes.contains("sn") { buffer += " " }
      if boundary { flush() }
    }
    visit(scope, role: .body)
    flush()
    return blocks
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
