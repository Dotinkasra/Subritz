import CSQLite
import CryptoKit
import Foundation

public enum Fingerprint {
  public static func make(videoID: String, caption: Data, provider: String, model: String) -> String
  {
    let hash = SHA256.hash(data: caption).map { String(format: "%02x", $0) }.joined()
    let components = [
      videoID, hash, String(CaptionPipeline.parserVersion),
      String(CaptionPipeline.reconstructionVersion), String(GrammarContract.promptVersion),
      String(GrammarContract.schemaVersion), provider, model,
    ]
    return SHA256.hash(data: try! JSONEncoder().encode(components)).map {
      String(format: "%02x", $0)
    }.joined()
  }
}
final class SQLiteDatabase {
  var handle: OpaquePointer?
  init(url: URL) throws {
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw AppFailure("データベースを開けませんでした") }
    sqlite3_busy_timeout(handle, 5000)
  }
  deinit { sqlite3_close(handle) }
  func execute(_ sql: String, values: [String] = []) throws {
    let statement = try prepare(sql, values: values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw AppFailure("データの保存に失敗しました") }
  }
  func prepare(_ sql: String, values: [String]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw AppFailure("データベースの読み書きに失敗しました")
    }
    for (i, v) in values.enumerated() {
      sqlite3_bind_text(
        statement, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    return statement
  }
  func rows(_ sql: String, values: [String] = []) throws -> [[String]] {
    let s = try prepare(sql, values: values)
    defer { sqlite3_finalize(s) }
    var result: [[String]] = []
    while true {
      let status = sqlite3_step(s)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw AppFailure("データの読み取りに失敗しました") }
      result.append(
        (0..<sqlite3_column_count(s)).map { c in
          sqlite3_column_text(s, c).map { String(cString: $0) } ?? ""
        })
    }
    return result
  }
}
private struct StoredSentence: Codable {
  let id: UUID
  let videoID: String
  let index: Int
  let text: String
  let startTime: Double
  let endTime: Double
  let grammarStatus: GrammarStatus
  init(_ sentence: Sentence) {
    id = sentence.id
    videoID = sentence.videoID
    index = sentence.index
    text = sentence.text
    startTime = sentence.startTime
    endTime = sentence.endTime
    grammarStatus = sentence.grammarStatus
  }
  func sentence(tokens: [Token], analysis: Analysis?) -> Sentence {
    Sentence(
      id: id, videoID: videoID, index: index, text: text, startTime: startTime, endTime: endTime,
      tokens: tokens, grammarStatus: analysis == nil ? .notQueued : .completed,
      grammarAnalysis: analysis)
  }
}
public actor StudyStore {
  let db: SQLiteDatabase
  public init(directory: URL? = nil) throws {
    let root =
      directory
      ?? AppSettings.defaultCacheURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    db = try SQLiteDatabase(url: root.appendingPathComponent("video-cache.sqlite"))
    try db.execute("PRAGMA foreign_keys=ON")
    let version = Int(try db.rows("PRAGMA user_version").first?[0] ?? "0") ?? 0
    if version < 2 { try db.execute("DROP TABLE IF EXISTS cache_entries") }
    try db.execute(
      "CREATE TABLE IF NOT EXISTS cache_entries (fingerprint TEXT PRIMARY KEY,video_id TEXT NOT NULL,size INTEGER NOT NULL,accessed REAL NOT NULL,schema_version INTEGER NOT NULL)"
    )
    try db.execute("CREATE INDEX IF NOT EXISTS cache_lru ON cache_entries(accessed)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS videos(fingerprint TEXT PRIMARY KEY REFERENCES cache_entries(fingerprint) ON DELETE CASCADE,metadata TEXT NOT NULL)"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS caption_assets(fingerprint TEXT PRIMARY KEY REFERENCES cache_entries(fingerprint) ON DELETE CASCADE,raw_data TEXT NOT NULL,parser_version INTEGER NOT NULL,reconstruction_version INTEGER NOT NULL)"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS sentences(fingerprint TEXT NOT NULL REFERENCES cache_entries(fingerprint) ON DELETE CASCADE,id TEXT NOT NULL,sentence_index INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(fingerprint,id))"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS tokens(fingerprint TEXT NOT NULL REFERENCES cache_entries(fingerprint) ON DELETE CASCADE,id TEXT NOT NULL,sentence_id TEXT NOT NULL,token_index INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(fingerprint,id))"
    )
    try db.execute(
      "CREATE INDEX IF NOT EXISTS token_sentence ON tokens(fingerprint,sentence_id,token_index)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS grammar_analyses(fingerprint TEXT NOT NULL REFERENCES cache_entries(fingerprint) ON DELETE CASCADE,sentence_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(fingerprint,sentence_id))"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS settings_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    try db.execute("INSERT OR REPLACE INTO settings_metadata VALUES('schemaVersion','2')")
    try db.execute("PRAGMA user_version=2")
  }
  func encode<T: Encodable>(_ value: T) throws -> String {
    String(data: try JSONEncoder().encode(value), encoding: .utf8)!
  }
  func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.utf8))
  }
  public func load(_ fingerprint: String) throws -> StudyDocument? {
    guard
      !(try db.rows(
        "SELECT fingerprint FROM cache_entries WHERE fingerprint=? AND schema_version=2",
        values: [fingerprint])).isEmpty
    else { return nil }
    guard
      let video = try db.rows(
        "SELECT metadata FROM videos WHERE fingerprint=?", values: [fingerprint]
      ).first,
      let asset = try db.rows(
        "SELECT raw_data FROM caption_assets WHERE fingerprint=? AND parser_version=? AND reconstruction_version=?",
        values: [
          fingerprint, String(CaptionPipeline.parserVersion),
          String(CaptionPipeline.reconstructionVersion),
        ]
      ).first,
      let raw = Data(base64Encoded: asset[0])
    else { throw AppFailure(.cacheReadFailed, "キャッシュを読み取れませんでした") }
    var tokenGroups: [UUID: [Token]] = [:]
    for row in try db.rows(
      "SELECT payload FROM tokens WHERE fingerprint=? ORDER BY token_index", values: [fingerprint])
    {
      let token = try decode(Token.self, row[0])
      tokenGroups[token.sentenceID, default: []].append(token)
    }
    var analyses: [UUID: Analysis] = [:]
    for row in try db.rows(
      "SELECT payload FROM grammar_analyses WHERE fingerprint=?", values: [fingerprint])
    {
      let analysis = try decode(Analysis.self, row[0])
      analyses[analysis.sentenceId] = analysis
    }
    let sentences = try db.rows(
      "SELECT payload FROM sentences WHERE fingerprint=? ORDER BY sentence_index",
      values: [fingerprint]
    ).map { row in
      let record = try decode(StoredSentence.self, row[0])
      return record.sentence(tokens: tokenGroups[record.id] ?? [], analysis: analyses[record.id])
    }
    try db.execute(
      "UPDATE cache_entries SET accessed=? WHERE fingerprint=?",
      values: [String(Date().timeIntervalSince1970), fingerprint])
    StudyLog.cache.debug("Reused video cache")
    return StudyDocument(
      video: try decode(Video.self, video[0]), rawCaption: raw, sentences: sentences)
  }
  public func save(_ document: StudyDocument, fingerprint: String, limit: Int) throws {
    try db.execute("BEGIN IMMEDIATE")
    do {
      try db.execute("DELETE FROM cache_entries WHERE fingerprint=?", values: [fingerprint])
      try db.execute(
        "INSERT INTO cache_entries VALUES(?,?,?,?,2)",
        values: [fingerprint, document.video.id, "0", String(Date().timeIntervalSince1970)])
      let metadata = try encode(document.video)
      let raw = document.rawCaption.base64EncodedString()
      var size = metadata.utf8.count + raw.utf8.count
      try db.execute("INSERT INTO videos VALUES(?,?)", values: [fingerprint, metadata])
      try db.execute(
        "INSERT INTO caption_assets VALUES(?,?,?,?)",
        values: [
          fingerprint, raw, String(CaptionPipeline.parserVersion),
          String(CaptionPipeline.reconstructionVersion),
        ])
      for sentence in document.sentences {
        try Task.checkCancellation()
        let payload = try encode(StoredSentence(sentence))
        size += payload.utf8.count
        try db.execute(
          "INSERT INTO sentences VALUES(?,?,?,?)",
          values: [fingerprint, sentence.id.uuidString, String(sentence.index), payload])
        for token in sentence.tokens {
          let payload = try encode(token)
          size += payload.utf8.count
          try db.execute(
            "INSERT INTO tokens VALUES(?,?,?,?,?)",
            values: [
              fingerprint, token.id.uuidString, token.sentenceID.uuidString, String(token.index),
              payload,
            ])
        }
        if let analysis = sentence.grammarAnalysis {
          let payload = try encode(analysis)
          size += payload.utf8.count
          try db.execute(
            "INSERT INTO grammar_analyses VALUES(?,?,?)",
            values: [fingerprint, sentence.id.uuidString, payload])
        }
      }
      try db.execute(
        "UPDATE cache_entries SET size=? WHERE fingerprint=?", values: [String(size), fingerprint])
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
    try evict(limit: limit, protecting: document.video.id)
  }
  // Captions and timings are immutable while grammar progresses. Update only
  // the changed sentences; the first write (or a cleared cache) creates a snapshot.
  public func saveProgress(
    _ document: StudyDocument, changed: Set<UUID>, fingerprint: String, limit: Int
  ) throws {
    let exists =
      !(try db.rows(
        "SELECT fingerprint FROM cache_entries WHERE fingerprint=?", values: [fingerprint])).isEmpty
    let sentences = document.sentences.filter { changed.contains($0.id) }
    var matching = exists
    for sentence in sentences where matching {
      matching =
        !(try db.rows(
          "SELECT id FROM sentences WHERE fingerprint=? AND id=?",
          values: [fingerprint, sentence.id.uuidString])).isEmpty
    }
    guard matching else {
      try save(document, fingerprint: fingerprint, limit: limit)
      return
    }
    guard !sentences.isEmpty else { return }
    try db.execute("BEGIN IMMEDIATE")
    do {
      var delta = 0
      for sentence in sentences {
        try Task.checkCancellation()
        let id = sentence.id.uuidString
        let oldSentence =
          try db.rows(
            "SELECT length(CAST(payload AS BLOB)) FROM sentences WHERE fingerprint=? AND id=?",
            values: [fingerprint, id]
          ).first?[0] ?? "0"
        let oldTokens =
          try db.rows(
            "SELECT COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM tokens WHERE fingerprint=? AND sentence_id=?",
            values: [fingerprint, id]
          ).first?[0] ?? "0"
        let oldAnalysis =
          try db.rows(
            "SELECT length(CAST(payload AS BLOB)) FROM grammar_analyses WHERE fingerprint=? AND sentence_id=?",
            values: [fingerprint, id]
          ).first?[0] ?? "0"
        delta -= (Int(oldSentence) ?? 0) + (Int(oldTokens) ?? 0) + (Int(oldAnalysis) ?? 0)
        let record = try encode(StoredSentence(sentence))
        delta += record.utf8.count
        try db.execute(
          "UPDATE sentences SET payload=? WHERE fingerprint=? AND id=?",
          values: [record, fingerprint, id])
        for token in sentence.tokens {
          let payload = try encode(token)
          delta += payload.utf8.count
          try db.execute(
            "UPDATE tokens SET payload=? WHERE fingerprint=? AND id=?",
            values: [payload, fingerprint, token.id.uuidString])
        }
        if let analysis = sentence.grammarAnalysis {
          let payload = try encode(analysis)
          delta += payload.utf8.count
          try db.execute(
            "INSERT OR REPLACE INTO grammar_analyses VALUES(?,?,?)",
            values: [fingerprint, id, payload])
        } else {
          try db.execute(
            "DELETE FROM grammar_analyses WHERE fingerprint=? AND sentence_id=?",
            values: [fingerprint, id])
        }
      }
      try db.execute(
        "UPDATE cache_entries SET size=size+?,accessed=? WHERE fingerprint=?",
        values: [String(delta), String(Date().timeIntervalSince1970), fingerprint])
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
    try evict(limit: limit, protecting: document.video.id)
  }
  public func usage() throws -> Int {
    Int(try db.rows("SELECT COALESCE(SUM(size),0) FROM cache_entries").first?[0] ?? "0") ?? 0
  }
  public func clear() throws {
    try db.execute("DELETE FROM cache_entries")
    try db.execute("VACUUM")
  }
  public func evict(limit: Int, protecting: String?) throws {
    var deleted = false
    for row in try db.rows(
      "SELECT video_id FROM cache_entries GROUP BY video_id ORDER BY MAX(accessed) ASC")
    {
      guard try usage() > limit else { break }
      if row[0] == protecting { continue }
      try db.execute("DELETE FROM cache_entries WHERE video_id=?", values: [row[0]])
      deleted = true
    }
    if deleted {
      try db.execute("VACUUM")
      StudyLog.cache.info("Evicted least recently used video cache")
    }
  }
}
