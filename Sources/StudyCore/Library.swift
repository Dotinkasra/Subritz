import Foundation

public struct VideoHistoryItem: Codable, Identifiable {
  public var video: Video
  public var lastOpened: Date
  public var id: String { video.id }
  public init(video: Video, lastOpened: Date = Date()) {
    self.video = video
    self.lastOpened = lastOpened
  }
}
public struct FavoriteWord: Codable, Identifiable {
  public var id: String
  public var surface: String
  public var lemma: String?
  public var partOfSpeech: String?
  public var shortGloss: String
  public var definition: String
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
    try db.execute("PRAGMA user_version=1")
  }
  func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  public func history() throws -> [VideoHistoryItem] {
    try db.rows("SELECT payload FROM video_history ORDER BY opened DESC,rowid DESC LIMIT 100").map {
      try JSONDecoder().decode(VideoHistoryItem.self, from: Data($0[0].utf8))
    }
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
      try upsertHistory(VideoHistoryItem(video: video, lastOpened: date))
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
    try db.execute(
      "INSERT INTO favorite_words VALUES(?,?,?) ON CONFLICT(word) DO UPDATE SET saved=excluded.saved,payload=excluded.payload",
      values: [favorite.id, String(favorite.savedAt.timeIntervalSince1970), try encode(favorite)])
  }
  public func removeFavorite(_ id: String) throws {
    try db.execute(
      "DELETE FROM favorite_words WHERE word=?", values: [DictionaryText.normalize(id)])
  }
}
