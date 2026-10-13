import Foundation

public enum TimingQuality: String, Codable { case exact, anchored, interpolated, estimated }
public enum GrammarStatus: String, Codable { case notQueued, queued, analyzing, completed, failed }
public enum Pattern: String, Codable { case SV, SVC, SVO, SVOO, SVOC, OTHER, UNKNOWN }
public enum Role: String, Codable, CaseIterable {
  case SUBJECT, VERB, OBJECT, OBJECT1, OBJECT2, COMPLEMENT, PREPOSITION, PREPOSITIONAL_PHRASE,
    MODIFIER, CONJUNCTION, CLAUSE
}
public enum RoleConfidence: String, Codable { case HIGH, MEDIUM, LOW }
public struct Span: Codable, Equatable {
  public var role: Role
  public var startToken: Int
  public var endTokenExclusive: Int
  public var confidence: RoleConfidence? = nil
  public var clauseID: String? = nil
  public var depth: Int? = nil
  public var evidence: String? = nil
}
public struct Analysis: Codable, Equatable {
  public var sentenceId: UUID
  public var pattern: Pattern
  public var spans: [Span]
  public var clauses: [GrammarClause]? = nil
  public var unresolvedReasons: [String]? = nil
}
public struct Token: Codable, Identifiable, Equatable {
  public var id = UUID()
  public var sentenceID = UUID()
  public var index: Int
  public var surface: String
  public var normalized: String
  public var lemma: String?
  public var partOfSpeech: String?
  public var startTime: Double
  public var endTime: Double
  public var timingQuality: TimingQuality
  public var lexical: Bool
  public var captionLineIndex: Int? = nil
  public var grammarRole: Role? = nil
}
public struct Sentence: Codable, Identifiable, Equatable {
  public var id: UUID
  public var videoID: String
  public var index: Int
  public var text: String
  public var startTime: Double
  public var endTime: Double
  public var tokens: [Token]
  public var grammarStatus: GrammarStatus = .notQueued
  public var grammarAnalysis: Analysis?
}
public struct Video: Codable, Sendable {
  public var id: String
  public var title: String
  public var duration: Double
  public var thumbnailURL: String? = nil
  public var watchURL: String { "https://www.youtube.com/watch?v=" + id }
  public var thumbnailImageURL: URL? {
    if let thumbnailURL, let url = URL(string: thumbnailURL), url.scheme == "https", url.host != nil
    {
      return url
    }
    guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
      return nil
    }
    return URL(string: "https://i.ytimg.com/vi/" + id + "/mqdefault.jpg")
  }
}
public struct StudyDocument: Codable {
  public var video: Video
  public var rawCaption: Data
  public var sentences: [Sentence]
  public init(video: Video, rawCaption: Data, sentences: [Sentence]) {
    self.video = video
    self.rawCaption = rawCaption
    self.sentences = sentences
  }
}
public enum AppErrorCode: String, Codable {
  case invalidYouTubeURL, ytDlpNotFound, ytDlpExecutionFailed, videoUnavailable,
    embeddingUnavailable
  case automaticEnglishCaptionNotFound, captionDownloadFailed, captionParseFailed,
    unsupportedCaptionStructure
  case dictionaryUnavailable, eijiroImportFailed, grammarProviderUnavailable,
    grammarProviderTimeout, grammarInvalidResponse
  case cacheReadFailed, cacheWriteFailed, unknown
}
public struct AppFailure: LocalizedError {
  public let code: AppErrorCode
  public let message: String
  public let details: String?
  public var errorDescription: String? { message }
  public init(_ message: String, details: String? = nil) {
    self.details = details
    self.code = .unknown
    self.message = message
  }
  public init(_ code: AppErrorCode, _ message: String, details: String? = nil) {
    self.details = details
    self.code = code
    self.message = message
  }
}
public enum YouTubeURL {
  public static func id(_ text: String) throws -> String {
    guard let u = URLComponents(string: text), u.scheme == "https" || u.scheme == "http",
      let host = u.host?.lowercased()
    else { throw AppFailure(.invalidYouTubeURL, "有効な YouTube URL を入力してください") }
    let candidate: String?
    if host == "youtu.be" {
      candidate = u.path.split(separator: "/").first.map(String.init)
    } else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host), u.path == "/watch"
    {
      candidate = u.queryItems?.first(where: { $0.name == "v" })?.value
    } else {
      candidate = nil
    }
    guard let value = candidate,
      value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    else { throw AppFailure(.invalidYouTubeURL, "有効な YouTube 動画 URL を入力してください") }
    return value
  }
}
public struct AppSettings: Codable, Sendable, Equatable {
  public var ytDlpPath = ""
  public var codexPath = ""
  public var dictionary = "macOS"
  public var dictionaryBrowser = "system"
  public var provider = "local"
  public var baseURL = "http://localhost:1234/v1"
  public var localModel = ""
  public var codexModel = ""
  public var aiGrammarEnabled = true
  public var advancedMode = false
  public var cacheDirectory = ""
  // Compatibility for callers using the active provider's model.
  public var model: String {
    get { provider == "codex" ? codexModel : localModel }
    set { if provider == "codex" { codexModel = newValue } else { localModel = newValue } }
  }
  public var grammarModel: String {
    let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return provider == "codex" && name.lowercased().hasPrefix("gpt-") ? name.lowercased() : name
  }
  public var cacheURL: URL {
    cacheDirectory.isEmpty
      ? Self.defaultCacheURL : URL(fileURLWithPath: cacheDirectory, isDirectory: true)
  }
  public static var defaultCacheURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("YouTubeEnglishStudy", isDirectory: true)
  }
  public var localConcurrency = 1
  public var codexConcurrency = 1
  public var timeout: Double = 120
  public var cacheMB = 1024
  public init() {}
  enum CodingKeys: String, CodingKey {
    case ytDlpPath, codexPath, dictionary, provider, baseURL, localModel, codexModel,
      cacheDirectory, timeout, cacheMB, localConcurrency, codexConcurrency, aiGrammarEnabled,
      advancedMode, dictionaryBrowser
  }
  enum LegacyKeys: String, CodingKey { case model }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ytDlpPath = try c.decodeIfPresent(String.self, forKey: .ytDlpPath) ?? ytDlpPath
    codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? codexPath
    dictionary = try c.decodeIfPresent(String.self, forKey: .dictionary) ?? dictionary
    dictionaryBrowser = try c.decodeIfPresent(String.self, forKey: .dictionaryBrowser) ?? dictionaryBrowser
    provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
    baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
    localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? localModel
    codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? codexModel
    aiGrammarEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiGrammarEnabled) ?? aiGrammarEnabled
    advancedMode = try c.decodeIfPresent(Bool.self, forKey: .advancedMode) ?? advancedMode
    cacheDirectory = try c.decodeIfPresent(String.self, forKey: .cacheDirectory) ?? cacheDirectory
    localConcurrency = max(
      1, min(2, try c.decodeIfPresent(Int.self, forKey: .localConcurrency) ?? 1))
    codexConcurrency = max(
      1, min(2, try c.decodeIfPresent(Int.self, forKey: .codexConcurrency) ?? 1))
    timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? timeout
    cacheMB = try c.decodeIfPresent(Int.self, forKey: .cacheMB) ?? cacheMB
    let old = try decoder.container(keyedBy: LegacyKeys.self)
    if let legacy = try old.decodeIfPresent(String.self, forKey: .model) {
      if provider == "codex", !c.contains(.codexModel) { codexModel = legacy }
      if provider != "codex", !c.contains(.localModel) { localModel = legacy }
    }
  }
  public static func load(defaults: UserDefaults = .standard) -> Self {
    (defaults.data(forKey: "settings").flatMap {
      try? JSONDecoder().decode(Self.self, from: $0)
    }) ?? Self()
  }
  public func save(defaults: UserDefaults = .standard) {
    defaults.set(try? JSONEncoder().encode(self), forKey: "settings")
  }
}

public enum VideoLoadPhase {
  case idle, validatingURL, probingVideo, fetchingCaptions, parsingCaptions, buildingTimeline
  case ready, playing, backgroundAnalysis
  case failed(AppFailure)
}
