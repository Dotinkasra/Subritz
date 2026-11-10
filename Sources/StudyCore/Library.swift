import Foundation

public struct VideoHistoryItem: Codable, Sendable, Identifiable {
  public var video: Video
  public var lastOpened: Date
  public var lastPosition: Double?
  public var positionUpdatedAt: Date?
  public var id: String { video.id }
  public init(video: Video, lastOpened: Date = Date(), lastPosition: Double? = nil,
    positionUpdatedAt: Date? = nil) {
    self.video = video
    self.lastOpened = lastOpened
    self.lastPosition = lastPosition
    self.positionUpdatedAt = positionUpdatedAt
  }
}
public struct FavoriteWord: Codable, Sendable, Identifiable {
  public var id: String
  public var surface: String
  public var lemma: String?
  public var partOfSpeech: String?
  public var shortGloss: String
  public var definition: String
  public var pronunciation: String? = nil
  public var dictionaryBlocks: [DictionaryBlock]? = nil
  public var sourceVideo: Video?
  public var sourceTime: Double
  public var savedAt: Date
  public init(token: Token, entry: DictionaryEntry?, video: Video?, savedAt: Date = Date()) {
    id = DictionaryText.normalize(token.surface)
    surface = token.surface
    lemma = entry?.headword ?? token.lemma
    partOfSpeech = entry?.partOfSpeech ?? token.partOfSpeech
    shortGloss = entry?.shortGloss ?? ""
    definition = entry?.definition ?? ""
    pronunciation = entry?.pronunciation
    dictionaryBlocks = entry?.blocks
    sourceVideo = video
    sourceTime = token.startTime
    self.savedAt = savedAt
  }
}
// User-owned history and favorites outlive video-cache eviction and folder changes.
public actor LibraryStore {
  let db: SQLiteDatabase
  public init(directory: URL = AppSettings.defaultCacheURL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    db = try SQLiteDatabase(url: directory.appendingPathComponent("library.sqlite"))
    try db.execute(
      "CREATE TABLE IF NOT EXISTS video_history(video_id TEXT PRIMARY KEY,opened REAL NOT NULL,payload TEXT NOT NULL)"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS favorite_words(word TEXT PRIMARY KEY,saved REAL NOT NULL,payload TEXT NOT NULL)"
    )
    try db.execute(
      "CREATE TABLE IF NOT EXISTS library_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS video_timestamps(id TEXT PRIMARY KEY,video_id TEXT NOT NULL,time REAL NOT NULL,saved REAL NOT NULL,kind TEXT NOT NULL,word_id TEXT,payload TEXT NOT NULL)")
    try db.execute("CREATE INDEX IF NOT EXISTS timestamps_video ON video_timestamps(video_id)")
    try db.execute("CREATE INDEX IF NOT EXISTS timestamps_saved ON video_timestamps(saved DESC)")
    try db.execute("CREATE TABLE IF NOT EXISTS listening_spans(id TEXT PRIMARY KEY,started REAL NOT NULL,ended REAL NOT NULL,source TEXT NOT NULL,CHECK(ended > started))")
    try db.execute("CREATE INDEX IF NOT EXISTS listening_ended ON listening_spans(ended)")
    // Existing favorites already contain their video and occurrence time. Migrate once
    // so deleting a timestamp does not resurrect it on the next launch.
    if try db.rows("SELECT key FROM library_metadata WHERE key='timestampsSeeded'").isEmpty {
      try db.execute("BEGIN IMMEDIATE")
      do {
        let payloads = try db.rows("SELECT payload FROM favorite_words ORDER BY saved DESC,rowid DESC LIMIT 1000")
        for payload in payloads {
          let word = try JSONDecoder().decode(FavoriteWord.self, from: Data(payload[0].utf8))
          if let video = word.sourceVideo, word.sourceTime.isFinite, word.sourceTime >= 0 {
            try Self.upsertTimestamp(VideoTimestamp(video: video, time: word.sourceTime,
              kind: .favorite, wordID: word.id, savedAt: word.savedAt), in: db)
          }
        }
        try Self.trimTimestamps(in: db)
        try db.execute("INSERT INTO library_metadata VALUES('timestampsSeeded','1')")
        try db.execute("COMMIT")
      } catch { try? db.execute("ROLLBACK"); throw error }
    }
    // Copy old exit positions without removing or changing any saved timestamps.
    try db.execute("BEGIN IMMEDIATE")
    do {
      try Self.migrateHistoryPositions(in: db)
      try db.execute("COMMIT")
    } catch { try? db.execute("ROLLBACK"); throw error }
    try db.execute("PRAGMA user_version=3")
  }
  func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  public func history() throws -> [VideoHistoryItem] {
    try db.rows("SELECT payload FROM video_history ORDER BY opened DESC,rowid DESC LIMIT 100").map {
      try JSONDecoder().decode(VideoHistoryItem.self, from: Data($0[0].utf8))
    }
  }
  public func historyItem(for videoID: String) throws -> VideoHistoryItem? {
    guard let row = try db.rows("SELECT payload FROM video_history WHERE video_id=?",
      values: [videoID]).first else { return nil }
    return try JSONDecoder().decode(VideoHistoryItem.self, from: Data(row[0].utf8))
  }
  static func migrateHistoryPositions(in db: SQLiteDatabase) throws {
    let rows = try db.rows("""
      SELECT h.payload,t.payload FROM video_history h
      JOIN video_timestamps t ON t.id='resume:' || h.video_id
      """)
    for row in rows {
      var item = try JSONDecoder().decode(VideoHistoryItem.self, from: Data(row[0].utf8))
      guard item.lastPosition == nil else { continue }
      let timestamp = try JSONDecoder().decode(VideoTimestamp.self, from: Data(row[1].utf8))
      guard timestamp.kind == .resume, timestamp.video.id == item.id,
        timestamp.time.isFinite, timestamp.time >= 0 else { continue }
      item.lastPosition = item.video.duration > 0
        ? min(timestamp.time, item.video.duration) : timestamp.time
      item.positionUpdatedAt = timestamp.savedAt
      try db.execute("UPDATE video_history SET payload=? WHERE video_id=?",
        values: [String(decoding: try JSONEncoder().encode(item), as: UTF8.self), item.id])
    }
  }
  /// Only confirmed player positions may reach this method. Never recreate a
  /// history row removed by the user while its video is still playing.
  public func saveHistoryPosition(videoID: String, position: PlaybackResumePosition) throws {
    guard position.isValid else { throw AppFailure("再生位置が正しくありません") }
    guard var item = try historyItem(for: videoID) else { return }
    item.lastPosition = position.time
    item.positionUpdatedAt = position.date
    item.lastOpened = max(item.lastOpened, position.date)
    item.video.duration = position.duration
    try db.execute("UPDATE video_history SET opened=?,payload=? WHERE video_id=?",
      values: [String(item.lastOpened.timeIntervalSince1970), try encode(item), videoID])
  }
  func upsertHistory(_ item: VideoHistoryItem) throws {
    var item = item
    if item.video.thumbnailURL == nil,
      let prior = try db.rows(
        "SELECT payload FROM video_history WHERE video_id=?", values: [item.id]
      ).first,
      let saved = try? JSONDecoder().decode(VideoHistoryItem.self, from: Data(prior[0].utf8))
    {
      item.video.thumbnailURL = saved.video.thumbnailURL
    }
    try db.execute(
      "INSERT INTO video_history VALUES(?,?,?) ON CONFLICT(video_id) DO UPDATE SET opened=excluded.opened,payload=excluded.payload",
      values: [item.id, String(item.lastOpened.timeIntervalSince1970), try encode(item)])
  }
  func trimHistory() throws {
    try db.execute(
      "DELETE FROM video_history WHERE video_id IN (SELECT video_id FROM video_history ORDER BY opened DESC,rowid DESC LIMIT -1 OFFSET 100)"
    )
  }
  public func record(_ video: Video, at date: Date = Date()) throws {
    try db.execute("BEGIN IMMEDIATE")
    do {
      let prior = try historyItem(for: video.id)
      try upsertHistory(VideoHistoryItem(video: video, lastOpened: date,
        lastPosition: prior?.lastPosition, positionUpdatedAt: prior?.positionUpdatedAt))
      try Self.migrateHistoryPositions(in: db)
      try trimHistory()
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
  public func seedHistoryIfNeeded(_ items: [VideoHistoryItem]) throws {
    guard try db.rows("SELECT key FROM library_metadata WHERE key='historySeeded'").isEmpty else {
      return
    }
    try db.execute("BEGIN IMMEDIATE")
    do {
      var existing = Set(try history().map(\.id))
      for item in items.sorted(by: { $0.lastOpened > $1.lastOpened }).prefix(100)
      where existing.insert(item.id).inserted { try upsertHistory(item) }
      try Self.migrateHistoryPositions(in: db)
      try trimHistory()
      try db.execute("INSERT INTO library_metadata VALUES('historySeeded','1')")
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
  public func removeHistory(_ id: String) throws {
    try db.execute("DELETE FROM video_history WHERE video_id=?", values: [id])
  }
  public func favorites() throws -> [FavoriteWord] {
    try db.rows("SELECT payload FROM favorite_words ORDER BY saved DESC,rowid DESC").map {
      try JSONDecoder().decode(FavoriteWord.self, from: Data($0[0].utf8))
    }
  }
  public func saveFavorite(_ favorite: FavoriteWord) throws {
    var favorite = favorite
    favorite.id = DictionaryText.normalize(favorite.surface)
    guard !favorite.id.isEmpty else { throw AppFailure("登録する単語がありません") }
    try db.execute("BEGIN IMMEDIATE")
    do {
      try db.execute(
        "INSERT INTO favorite_words VALUES(?,?,?) ON CONFLICT(word) DO UPDATE SET saved=excluded.saved,payload=excluded.payload",
        values: [favorite.id, String(favorite.savedAt.timeIntervalSince1970), try encode(favorite)])
      if let video = favorite.sourceVideo {
        try upsertTimestamp(VideoTimestamp(video: video, time: favorite.sourceTime,
          kind: .favorite, wordID: favorite.id, savedAt: favorite.savedAt))
      } else {
        try db.execute("DELETE FROM video_timestamps WHERE id=?", values: ["favorite:" + favorite.id])
      }
      try trimTimestamps()
      try db.execute("COMMIT")
    } catch { try? db.execute("ROLLBACK"); throw error }
  }
  public func removeFavorite(_ id: String) throws {
    let word = DictionaryText.normalize(id)
    try db.execute("BEGIN IMMEDIATE")
    do {
      try db.execute("DELETE FROM favorite_words WHERE word=?", values: [word])
      try db.execute("DELETE FROM video_timestamps WHERE id=?", values: ["favorite:" + word])
      try db.execute("COMMIT")
    } catch { try? db.execute("ROLLBACK"); throw error }
  }
  public func timestamps() throws -> [VideoTimestamp] {
    try db.rows("SELECT payload FROM video_timestamps ORDER BY saved DESC,rowid DESC LIMIT 1000")
      .map { try JSONDecoder().decode(VideoTimestamp.self, from: Data($0[0].utf8)) }
  }
  func upsertTimestamp(_ timestamp: VideoTimestamp) throws {
    try Self.upsertTimestamp(timestamp, in: db)
  }
  private static func upsertTimestamp(_ timestamp: VideoTimestamp, in db: SQLiteDatabase) throws {
    guard !timestamp.video.id.isEmpty, timestamp.time.isFinite, timestamp.time >= 0 else {
      throw AppFailure("タイムスタンプの動画または時刻が正しくありません")
    }
    var timestamp = timestamp
    if timestamp.video.duration.isFinite, timestamp.video.duration > 0 {
      timestamp.time = min(timestamp.time, timestamp.video.duration)
    }
    try db.execute(
      "INSERT INTO video_timestamps VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET video_id=excluded.video_id,time=excluded.time,saved=excluded.saved,kind=excluded.kind,word_id=excluded.word_id,payload=excluded.payload",
      values: [timestamp.id, timestamp.video.id, String(timestamp.time), String(timestamp.savedAt.timeIntervalSince1970),
        timestamp.kind.rawValue, timestamp.wordID ?? "", String(decoding: try JSONEncoder().encode(timestamp), as: UTF8.self)])
  }
  func trimTimestamps() throws {
    try Self.trimTimestamps(in: db)
  }
  private static func trimTimestamps(in db: SQLiteDatabase) throws {
    try db.execute(
      "DELETE FROM video_timestamps WHERE id IN (SELECT id FROM video_timestamps ORDER BY saved DESC,rowid DESC LIMIT -1 OFFSET 1000)")
  }
  public func saveTimestamp(_ timestamp: VideoTimestamp) throws {
    try db.execute("BEGIN IMMEDIATE")
    do {
      try upsertTimestamp(timestamp)
      try trimTimestamps()
      try db.execute("COMMIT")
    } catch { try? db.execute("ROLLBACK"); throw error }
  }
  public func removeTimestamp(_ id: String) throws {
    try db.execute("DELETE FROM video_timestamps WHERE id=?", values: [id])
  }
}
