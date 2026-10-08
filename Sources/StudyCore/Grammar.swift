import Foundation

public struct GrammarResponse: Codable {
  public var schemaVersion: Int
  public var results: [Analysis]
}
public protocol GrammarProvider: Sendable {
  var identity: String { get }
  var concurrencyLimit: Int { get }
  var usesClauseStructure: Bool { get }
  func cacheIdentity() async -> String
  func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String?) async throws
    -> Data
  func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data
}
extension GrammarProvider {
  public func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    try await analyze(sentences, repair: repair, validationFeedback: validationFeedback)
  }
  public var usesClauseStructure: Bool { true }
  public var concurrencyLimit: Int { 1 }
  public func cacheIdentity() async -> String { identity }
  public func analyze(_ sentences: [Sentence], repair: Bool) async throws -> Data {
    try await analyze(sentences, repair: repair, validationFeedback: nil)
  }
}
public enum GrammarContract {
  public static let promptVersion = 7, schemaVersion = 2, wireVersion = 2, maxSentences = 8,
    maxInputTokens = 6000
  public static let prompt = StructuredGrammar.prompt
  public static func payload(_ sentences: [Sentence], context: [Sentence] = []) throws -> String {
    try GrammarWindow(sentences: sentences, context: context).payload()
  }
  public static func validate(_ data: Data, sentences: [Sentence]) throws -> [Analysis] {
    if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["schemaVersion"] as? Int == 2
    {
      return try StructuredGrammar.validate(data, window: GrammarWindow(sentences: sentences))
    }
    // Schema 1 compatibility for existing integrations; built-in providers and
    // the scheduler's default path exclusively use the clause contract.

    let response: GrammarResponse
    do { response = try JSONDecoder().decode(GrammarResponse.self, from: data) } catch {
      let path: String
      switch error {
      case DecodingError.keyNotFound(let key, let context):
        path =
          context.codingPath.map(\.stringValue).joined(separator: ".") + " / missing: "
          + key.stringValue
      case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
        DecodingError.dataCorrupted(let context):
        path = context.codingPath.map(\.stringValue).joined(separator: ".")
      default: path = "unknown"
      }
      throw AppFailure(
        .grammarInvalidResponse, "文法解析サービスから、読み取れない形式の結果が返されました。再試行するか、文法表示なしで続行してください。",
        details: "JSON decoding: \(path) / bytes: \(data.count)")
    }
    guard response.schemaVersion == 1 else {
      throw AppFailure(
        .grammarInvalidResponse, "文法解析サービスから、このアプリが対応していない形式の結果が返されました。",
        details: "schemaVersion: \(response.schemaVersion) / expected: \(schemaVersion)")
    }
    guard response.results.count == sentences.count else {
      throw AppFailure(
        .grammarInvalidResponse, "一部の字幕の文法解析結果が不足しているか、余分な結果が含まれています。再試行するか、文法表示なしで続行してください。",
        details: "Expected \(sentences.count) sentence results; received \(response.results.count)")
    }
    let counts = Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, $0.tokens.count) })
    var seen = Set<UUID>()
    for result in response.results {
      guard let count = counts[result.sentenceId], seen.insert(result.sentenceId).inserted else {
        throw AppFailure(.grammarInvalidResponse, "文法解析サービスから、対象の字幕と一致しない結果が返されました。再試行してください。")
      }
      var spans = Set<String>()
      for span in result.spans {
        guard span.startToken >= 0, span.endTokenExclusive > span.startToken,
          span.endTokenExclusive <= count
        else {
          throw AppFailure(
            .grammarInvalidResponse, "文法解析結果で、字幕に存在しない単語の位置が指定されています。再試行してください。",
            details:
              "sentenceId: \(result.sentenceId) / \(span.role.rawValue) [\(span.startToken), \(span.endTokenExclusive)) / 単語数: \(count)"
          )
        }
        guard
          spans.insert("\(span.role.rawValue):\(span.startToken):\(span.endTokenExclusive)")
            .inserted
        else {
          throw AppFailure(.grammarInvalidResponse, "文法解析サービスから、同じ注釈が重複して返されました。再試行してください。")
        }
      }
      // The contract has no clause ID. Overlap alone cannot establish a conflict:
      // an outer subject/object can contain the subject and verb of an inner clause.
      // Only partially crossing constituents across different primary roles
      // violate a nested structure; same-role annotations may overlap.
      // Equal or contained ranges remain valid, including a one-word gerund.
      let primary: Set<Role> = [.SUBJECT, .VERB, .OBJECT, .OBJECT1, .OBJECT2, .COMPLEMENT]
      let main = result.spans.filter {
        primary.contains($0.role)
          && ($0.confidence == .HIGH || ($0.confidence == nil && result.pattern != .UNKNOWN))
      }
      for i in main.indices {
        for j in main.indices where j > i {
          let a = main[i]
          let b = main[j]
          let intersects =
            max(a.startToken, b.startToken) < min(a.endTokenExclusive, b.endTokenExclusive)
          let aContainsB =
            a.startToken <= b.startToken && a.endTokenExclusive >= b.endTokenExclusive
          let bContainsA =
            b.startToken <= a.startToken && b.endTokenExclusive >= a.endTokenExclusive
          if a.role != b.role && intersects && !aContainsB && !bContainsA {
            throw AppFailure(
              .grammarInvalidResponse,
              "この文の解析結果で、動詞・目的語などの単語の範囲が部分的に重なっています。文法表示を作れないため、この文を再解析してください。",
              details:
                "sentenceId: \(result.sentenceId) / \(a.role.rawValue) [\(a.startToken), \(a.endTokenExclusive)) / \(b.role.rawValue) [\(b.startToken), \(b.endTokenExclusive))"
                + "\n字幕: " + (sentences.first { $0.id == result.sentenceId }?.text ?? "")
            )
          }
        }
      }
    }
    return response.results.map { result in
      var safe = result
      safe.spans = safe.spans.filter {
        $0.confidence == .HIGH || ($0.confidence == nil && safe.pattern != .UNKNOWN)
      }
      let original = safe.spans
      let tokens = sentences.first { $0.id == result.sentenceId }?.tokens ?? []
      safe.spans = original.filter { span in
        if span.role == .VERB, span.endTokenExclusive == span.startToken + 1,
          tokens.indices.contains(span.startToken),
          ["to", "very", "so", "really"].contains(tokens[span.startToken].normalized)
        {
          return false
        }
        if [.OBJECT, .OBJECT1, .OBJECT2].contains(span.role) {
          let insidePP = original.contains {
            $0.role == .PREPOSITIONAL_PHRASE && $0.startToken <= span.startToken
              && $0.endTokenExclusive >= span.endTokenExclusive
          }
          // A noun governed by a preposition is not a verb object. Preserve objects
          // within explicitly identified subordinate clauses inside a PP.
          let insideClause = original.contains { clause in
            clause.role == .CLAUSE && clause.startToken <= span.startToken
              && clause.endTokenExclusive >= span.endTokenExclusive
              && original.contains { pp in
                pp.role == .PREPOSITIONAL_PHRASE && pp.startToken <= clause.startToken
                  && pp.endTokenExclusive >= clause.endTokenExclusive
              }
          }
          if insidePP && !insideClause { return false }
        }
        return true
      }
      return safe
    }
  }
  struct Inspection {
    var valid: [Analysis]
    var invalid: [Sentence]
    var feedback: String
  }
  // 個々の結果を検証する。1文の失敗で正常な文まで破棄しない。
  static func inspect(_ data: Data, sentences: [Sentence]) throws -> Inspection {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = root["schemaVersion"] as? Int, version == 1,
      let rawResults = root["results"] as? [Any]
    else {
      // 既存の検証を通して、読み取れない形式の具体的な理由を得る。
      _ = try validate(data, sentences: sentences)
      throw AppFailure(.grammarInvalidResponse, "文法解析結果を読み取れませんでした。")
    }
    var results: [UUID: [Any]] = [:]
    for raw in rawResults {
      if let object = raw as? [String: Any], let text = object["sentenceId"] as? String,
        let id = UUID(uuidString: text)
      {
        results[id, default: []].append(raw)
      }
    }
    var valid: [Analysis] = []
    var invalid: [Sentence] = []
    var feedback: [String] = []
    for sentence in sentences {
      do {
        guard let candidates = results[sentence.id], candidates.count == 1 else {
          throw AppFailure(
            .grammarInvalidResponse, "対象の文の結果が不足または重複しています。", details: "sentenceId: \(sentence.id)")
        }
        let single = try JSONSerialization.data(withJSONObject: [
          "schemaVersion": 1, "results": candidates,
        ])
        valid += try validate(single, sentences: [sentence])
      } catch {
        invalid.append(sentence)
        let failure = error as? AppFailure
        feedback.append(
          (failure?.message ?? "Invalid sentence result") + "\n" + (failure?.details ?? ""))
      }
    }
    return Inspection(valid: valid, invalid: invalid, feedback: feedback.joined(separator: "\n"))
  }
  public static func batches(_ sentences: [Sentence], maxSentences: Int = Self.maxSentences)
    -> [[Sentence]]
  {
    var result: [[Sentence]] = []
    var batch: [Sentence] = []
    var size = 0
    for sentence in sentences {
      let n = GrammarWindow.estimatedCost(sentence)
      if !batch.isEmpty,
        batch.count >= max(1, maxSentences)
          || size + n > maxInputTokens - GrammarWindow.contextBudget
      {
        result.append(batch)
        batch = []
        size = 0
      }
      batch.append(sentence)
      size += n
    }
    if !batch.isEmpty { result.append(batch) }
    return result
  }
}
public struct LocalGrammarProvider: GrammarProvider {
  public let settings: AppSettings
  public let session: URLSession
  public var usesClauseStructure: Bool { true }
  public var identity: String { "local:" + settings.baseURL }
  public var concurrencyLimit: Int { max(1, min(2, settings.localConcurrency)) }
  public init(settings: AppSettings, session: URLSession = .shared) {
    self.settings = settings
    self.session = session
  }
  public func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String? = nil)
    async throws -> Data
  {
    try await analyze(
      sentences, context: [], repair: repair, validationFeedback: validationFeedback)
  }
  public func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    guard !settings.grammarModel.isEmpty, let base = URL(string: settings.baseURL),
      ["http", "https"].contains(base.scheme ?? ""), base.host != nil
    else { throw AppFailure(.grammarProviderUnavailable, "ローカル LLM の URL とモデル名を設定してください") }
    let url = base.appendingPathComponent("chat/completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = max(5, settings.timeout)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let key = APISecret.read()
    if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": settings.grammarModel,
      "messages": [
        [
          "role": "system",
          "content": (repair ? GrammarContract.prompt : StructuredGrammar.readingPrompt)
            + (repair
              ? " Audit or repair the previous clause tree. "
                + (validationFeedback ?? "") : "")
            ,
        ],
        [
          "role": "user",
          "content": try
            (repair
            ? GrammarContract.payload(sentences, context: context)
            : GrammarWindow(sentences: sentences, context: context).readingPayload()),
        ],
      ], "temperature": 0, "response_format": ["type": "json_object"],
    ])
    do {
      let (data, response) = try await session.data(for: request)
      guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = root["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let content = message["content"] as? String
      else {
        throw AppFailure(
          .grammarProviderUnavailable, "ローカル LLM に接続できませんでした。設定と structured output 対応を確認してください")
      }
      return Data(content.utf8)
    } catch let error as URLError where error.code == .timedOut {
      throw AppFailure(.grammarProviderTimeout, "文法解析がタイムアウトしました")
    }
  }
}
public struct CodexGrammarProvider: GrammarProvider {
  public let settings: AppSettings
  public var usesClauseStructure: Bool { true }
  public var identity: String { "codex:" + settings.codexPath }
  public var concurrencyLimit: Int { max(1, min(2, settings.codexConcurrency)) }
  public func cacheIdentity() async -> String {
    await Task.detached {
      let executable = (try? Executable.find("codex", explicit: settings.codexPath))?
        .resolvingSymlinksInPath()
      let home =
        ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
      let config = URL(fileURLWithPath: home).appendingPathComponent("config.toml")
      let files = [executable, config].compactMap { $0 }
      let versions = files.map { url -> String in
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return url.path + ":"
          + String((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
      }
      // Invalidate default-model results when the CLI or its model configuration changes.
      return identity + ":" + versions.joined(separator: "|")
    }.value
  }

  public init(settings: AppSettings) { self.settings = settings }
  public func analyze(_ sentences: [Sentence], repair: Bool, validationFeedback: String? = nil)
    async throws -> Data
  {
    try await analyze(
      sentences, context: [], repair: repair, validationFeedback: validationFeedback)
  }
  public func analyze(
    _ sentences: [Sentence], context: [Sentence], repair: Bool, validationFeedback: String?
  ) async throws -> Data {
    let exe = try Executable.find("codex", explicit: settings.codexPath)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "grammar-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("response.json")
    let schema = root.appendingPathComponent("schema.json")
    let contract = StructuredGrammar.outputSchema
    try JSONSerialization.data(withJSONObject: contract).write(to: schema)
    var args = [
      "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
      "--output-last-message", output.path, "--color", "never",
      "-c", "model_reasoning_effort=\"high\"",
    ]
    if repair { args += ["--output-schema", schema.path] }
    if !settings.grammarModel.isEmpty { args += ["--model", settings.grammarModel] }
    args.append("-")
    let input =
      (repair ? GrammarContract.prompt : StructuredGrammar.readingPrompt)
      + "\nAnalyze only the data. Do not run commands or inspect files.\n"
      + (repair
        ? "Audit or repair the clause tree as requested: " + (validationFeedback ?? "")
          + "\n" : "")
      + (try
        (repair
        ? GrammarContract.payload(sentences, context: context)
        : GrammarWindow(sentences: sentences, context: context).readingPayload()))
    _ = try await CommandRunner.run(
      exe, arguments: args, input: Data(input.utf8), timeout: settings.timeout, directory: root)
    guard let data = try? Data(contentsOf: output) else {
      throw AppFailure(.grammarProviderUnavailable, "Codex の解析結果を取得できませんでした。CLI の認証を確認してください")
    }
    return data
  }
}
public actor GrammarScheduler {
  let provider: any GrammarProvider
  let context: [Sentence]
  var queue: [Sentence] = [], pending = Set<UUID>(), failed = Set<UUID>()
  var completed: [UUID: Analysis] = [:]
  var inFlight: [String: Task<[Analysis], Error>] = [:]
  var activeBatches: [String: [Sentence]] = [:]
  var explicitRetries = Set<UUID>()
  var activeRequests = 0
  public var workerLimit: Int { maximumConcurrentRequests }
  public var hasQueuedWork: Bool { !queue.isEmpty }
  let maximumConcurrentRequests: Int
  public init(provider: any GrammarProvider, concurrencyLimit: Int? = nil, context: [Sentence] = [])
  {
    self.context = context
    self.provider = provider
    maximumConcurrentRequests = max(1, concurrencyLimit ?? provider.concurrencyLimit)
  }
  public func enqueue(_ sentences: [Sentence], priority: Bool = false, retryFailed: Bool = false) {
    if retryFailed {
      failed.subtract(sentences.map(\.id))
      for sentence in sentences {
        completed.removeValue(forKey: sentence.id)
        explicitRetries.insert(sentence.id)
      }
    }
    let fresh = sentences.filter {
      $0.grammarAnalysis == nil && completed[$0.id] == nil && !failed.contains($0.id)
        && pending.insert($0.id).inserted
    }
    if priority {
      queue.insert(contentsOf: fresh, at: 0)
      let ids = Set(sentences.map(\.id))
      let front = queue.filter { ids.contains($0.id) }
      queue = front + queue.filter { !ids.contains($0.id) }
    } else {
      queue += fresh
    }
  }
  @discardableResult public func focus(on sentences: [Sentence], cancelObsolete: Bool = false)
    -> [Sentence]
  {
    let desired = Set(sentences.map(\.id)).union(explicitRetries)
    if cancelObsolete {
      for (key, batch) in activeBatches where batch.allSatisfy({ !desired.contains($0.id) }) {
        inFlight[key]?.cancel()
      }
    }
    let removed = queue.filter { !desired.contains($0.id) }
    queue.removeAll { !desired.contains($0.id) }
    pending.subtract(removed.map(\.id))
    enqueue(sentences, priority: true)
    return removed
  }
  public func next(maxSentences: Int = GrammarContract.maxSentences) -> [Sentence] {
    guard let batch = GrammarContract.batches(queue, maxSentences: maxSentences).first else {
      return []
    }
    queue.removeFirst(batch.count)
    return batch
  }
  public func analyze(_ batch: [Sentence]) async throws -> [Analysis] {
    if batch.allSatisfy({ completed[$0.id] != nil }) {
      return batch.compactMap { completed[$0.id] }
    }
    let key = batch.map { $0.id.uuidString }.joined(separator: ":")
    if let existing = inFlight[key] {
      return try await withTaskCancellationHandler(
        operation: { try await existing.value }, onCancel: { existing.cancel() })
    }
    let task = Task { try await self.performAnalysis(batch) }
    inFlight[key] = task
    activeBatches[key] = batch
    defer {
      inFlight.removeValue(forKey: key)
      activeBatches.removeValue(forKey: key)
    }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
  func performAnalysis(_ batch: [Sentence]) async throws -> [Analysis] {
    defer { finish(batch) }
    while activeRequests >= maximumConcurrentRequests {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try Task.checkCancellation()
    activeRequests += 1
    defer { activeRequests -= 1 }
    if provider.usesClauseStructure {
      do {
        let window = GrammarWindow(sentences: batch, context: context)
        let readingStart = ProcessInfo.processInfo.systemUptime
        let draft = try await provider.analyze(
          batch, context: context, repair: false, validationFeedback: nil)
        try Task.checkCancellation()
        let readingSeconds = ProcessInfo.processInfo.systemUptime - readingStart
        StudyLog.grammar.info("Semantic reading: \(batch.count) units, \(readingSeconds) seconds")
        let feedback: String
        if let reading = try? JSONSerialization.jsonObject(with: draft) as? [String: Any],
          reading["clauses"] as? [Any] != nil
        {
          feedback =
            "Independently audit this semantic reading against the supplied transcript, then compile it into the schema 2 clause tree using exact global atom ranges. Preserve clause ownership, contractions and restarts. Correct any mistake in the reading. Semantic reading:\n"
            + String(decoding: draft, as: UTF8.self)
        } else {
          feedback =
            "JSON decoding: the semantic reading is missing its clauses array. Interpret the transcript and compile a complete schema 2 tree. Unusable reading:\n"
            + String(decoding: draft, as: UTF8.self)
        }
        let compileStart = ProcessInfo.processInfo.systemUptime
        let audited = try await provider.analyze(
          batch, context: context, repair: true, validationFeedback: feedback)
        try Task.checkCancellation()
        let compileSeconds = ProcessInfo.processInfo.systemUptime - compileStart
        let inputBytes = try window.payload().utf8.count
        StudyLog.grammar.info(
          "Clause audit: \(batch.count) units, \(inputBytes) input bytes, \(compileSeconds) seconds"
        )
        let result: [Analysis]
        do { result = try StructuredGrammar.validate(audited, window: window) } catch {
          let failure = error as? AppFailure
          let repairStart = ProcessInfo.processInfo.systemUptime
          let repaired = try await provider.analyze(
            batch, context: context, repair: true,
            validationFeedback:
              "The semantic audit has a structural defect. Preserve correct clauses and repair only the stated defect. "
              + (failure?.details ?? error.localizedDescription) + "\nAudited tree:\n"
              + String(decoding: audited, as: UTF8.self))
          try Task.checkCancellation()
          let repairSeconds = ProcessInfo.processInfo.systemUptime - repairStart
          StudyLog.grammar.info("Structural repair: \(batch.count) units, \(repairSeconds) seconds")
          do { result = try StructuredGrammar.validate(repaired, window: window) } catch {
            let partial =
              (try? StructuredGrammar.recoverValidatedClauses(repaired, window: window)) ?? []
            guard !partial.isEmpty else { throw error }
            failed.formUnion(
              batch.filter { sentence in !partial.contains { $0.sentenceId == sentence.id } }.map(
                \.id))
            result = partial
          }
        }
        for analysis in result { completed[analysis.sentenceId] = analysis }
        return result
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        failed.formUnion(batch.map(\.id))
        throw error
      }
    }
    do {
      let data = try await provider.analyze(
        batch, context: context, repair: false, validationFeedback: nil)
      try Task.checkCancellation()
      let first: GrammarContract.Inspection
      do { first = try GrammarContract.inspect(data, sentences: batch) } catch {
        let failure = error as? AppFailure
        first = GrammarContract.Inspection(
          valid: [], invalid: batch,
          feedback: (failure?.message ?? "Invalid response") + "\n" + (failure?.details ?? ""))
      }
      if first.invalid.isEmpty {
        for analysis in first.valid { completed[analysis.sentenceId] = analysis }
        return first.valid
      }
      do {
        let repaired = try await provider.analyze(
          first.invalid, context: context, repair: true, validationFeedback: first.feedback)
        try Task.checkCancellation()
        let second = try GrammarContract.inspect(repaired, sentences: first.invalid)
        failed.formUnion(second.invalid.map(\.id))
        let results = first.valid + second.valid
        for analysis in results { completed[analysis.sentenceId] = analysis }
        return batch.compactMap { sentence in results.first { $0.sentenceId == sentence.id } }
      } catch is CancellationError { throw CancellationError() } catch {
        failed.formUnion(first.invalid.map(\.id))
        if !first.valid.isEmpty {
          for analysis in first.valid { completed[analysis.sentenceId] = analysis }
          return first.valid
        }
        throw error
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      failed.formUnion(batch.map(\.id))
      throw error
    }
  }
  func finish(_ batch: [Sentence]) {
    pending.subtract(batch.map(\.id))
    explicitRetries.subtract(batch.map(\.id))
  }
}
