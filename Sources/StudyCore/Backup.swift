import CryptoKit
import Foundation

public struct LibraryBackupData: Codable, Sendable {
  public var history: [VideoHistoryItem]
  public var favorites: [FavoriteWord]
  public var timestamps: [VideoTimestamp]
  public var listening: [ListeningSpan]
  public init(
    history: [VideoHistoryItem] = [], favorites: [FavoriteWord] = [],
    timestamps: [VideoTimestamp] = [], listening: [ListeningSpan] = []
  ) {
    self.history = history
    self.favorites = favorites
    self.timestamps = timestamps
    self.listening = listening
  }
  public func validate() throws {
    func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
    func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
    func validVideo(_ video: Video) -> Bool {
      !video.id.isEmpty && video.duration.isFinite && video.duration >= 0
    }
    guard history.count <= 100, timestamps.count <= 1000,
      unique(history.map(\.id)), unique(favorites.map(\.id)), unique(timestamps.map(\.id)),
      unique(listening.map(\.id)),
      history.allSatisfy({ validVideo($0.video) && validDate($0.lastOpened) }),
      favorites.allSatisfy({
        !$0.id.isEmpty && $0.id == DictionaryText.normalize($0.surface)
          && validDate($0.savedAt) && $0.sourceTime.isFinite && $0.sourceTime >= 0
          && ($0.sourceVideo.map(validVideo) ?? true)
      }),
      timestamps.allSatisfy({
        !$0.id.isEmpty && validVideo($0.video) && validDate($0.savedAt)
          && $0.time.isFinite && $0.time >= 0
      }),
      listening.allSatisfy({
        validDate($0.start) && validDate($0.end) && $0.seconds.isFinite && $0.seconds > 0
      })
    else { throw AppFailure("バックアップの学習データが正しくありません。現在のデータは変更していません。") }
  }
}

public struct BackupArchive: Codable, Sendable {
  public var createdAt: Date
  public var settings: AppSettings
  public var library: LibraryBackupData
  public init(settings: AppSettings, library: LibraryBackupData, createdAt: Date = Date()) {
    self.createdAt = createdAt
    self.settings = settings
    self.library = library
  }
  public func validate() throws {
    guard createdAt.timeIntervalSince1970.isFinite, settings.timeout.isFinite,
      (5...3600).contains(settings.timeout), (1...1_048_576).contains(settings.cacheMB),
      settings.subtitleRowSpacing.isFinite, settings.liveSubtitleRowSpacing.isFinite,
      settings.workspaceUpperFraction.isFinite, settings.workspaceLeadingFraction.isFinite,
      SubtitleAppearance.fontScaleRange.contains(settings.subtitleFontScale),
      SubtitleAppearance.fontScaleRange.contains(settings.liveSubtitleFontScale),
      SubtitleAppearance.characterRange.contains(settings.subtitleWrapCharacters),
      SubtitleAppearance.characterRange.contains(settings.liveSubtitleWrapCharacters)
    else {
      throw AppFailure("バックアップの設定が正しくありません。現在のデータは変更していません。")
    }
    try library.validate()
  }
  private struct Envelope: Codable {
    var format: String
    var version: Int
    var checksum: Data
    var payload: Data
  }
  public func encoded() throws -> Data {
    try validate()
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let payload = try encoder.encode(self)
    return try encoder.encode(
      Envelope(
        format: "SubritzBackup", version: 1,
        checksum: Data(SHA256.hash(data: payload)), payload: payload))
  }
  public static func decode(_ data: Data) throws -> Self {
    let decoder = PropertyListDecoder()
    let envelope: Envelope
    do { envelope = try decoder.decode(Envelope.self, from: data) } catch {
      throw AppFailure("Subritzのバックアップとして読み込めません。ファイルを確認してください。")
    }
    guard envelope.format == "SubritzBackup" else { throw AppFailure("Subritzのバックアップではありません。") }
    guard envelope.version == 1 else { throw AppFailure("このバックアップには新しいバージョンのSubritzが必要です。") }
    guard Data(SHA256.hash(data: envelope.payload)) == envelope.checksum else {
      throw AppFailure("バックアップが破損しているため復元できません。別の世代を選んでください。")
    }
    let archive = try decoder.decode(Self.self, from: envelope.payload)
    try archive.validate()
    return archive
  }
}

extension LibraryStore {
  /// Read through the storage actor in one transaction; never copy a live SQLite file.
  public func backupData() throws -> LibraryBackupData {
    try db.execute("BEGIN")
    do {
      let listening = try db.rows(
        "SELECT id,started,ended,source FROM listening_spans ORDER BY started,id"
      ).map { row -> ListeningSpan in
        guard let id = UUID(uuidString: row[0]), let start = Double(row[1]),
          let end = Double(row[2]),
          let source = ListeningSource(rawValue: row[3])
        else { throw AppFailure("視聴時間の記録を読み込めませんでした。") }
        return ListeningSpan(
          id: id, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
          source: source)
      }
      let data = LibraryBackupData(
        history: try history(), favorites: try favorites(), timestamps: try timestamps(),
        listening: listening)
      try data.validate()
      try db.execute("COMMIT")
      return data
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
  public func restoreBackupData(_ data: LibraryBackupData) throws {
    try data.validate()
    try db.execute("BEGIN IMMEDIATE")
    do {
      for table in ["video_history", "favorite_words", "video_timestamps", "listening_spans"] {
        try db.execute("DELETE FROM \(table)")
      }
      for item in data.history { try upsertHistory(item) }
      for item in data.favorites {
        try db.execute(
          "INSERT INTO favorite_words VALUES(?,?,?)",
          values: [item.id, String(item.savedAt.timeIntervalSince1970), try encode(item)])
      }
      // Restore the exact saved set, including intentionally deleted occurrences.
      for item in data.timestamps { try upsertTimestamp(item) }
      for span in data.listening {
        try db.execute(
          "INSERT INTO listening_spans VALUES(?,?,?,?)",
          values: [
            span.id.uuidString,
            String(span.start.timeIntervalSince1970), String(span.end.timeIntervalSince1970),
            span.source.rawValue,
          ])
      }
      for key in ["historySeeded", "timestampsSeeded"] {
        try db.execute("INSERT OR REPLACE INTO library_metadata VALUES(?, '1')", values: [key])
      }
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
  }
}

/// All coordination, serialization and pruning must be called off the main actor.
public enum BackupFiles {
  public static let fileExtension = "subritzbackup"
  public static let automaticLimit = 5
  public static func folder(in destination: URL) -> URL {
    destination.appendingPathComponent("Subritz Backups", isDirectory: true)
  }
  public static func write(_ archive: BackupArchive, to destination: URL, automatic: Bool) throws
    -> URL
  {
    let granted = destination.startAccessingSecurityScopedResource()
    defer { if granted { destination.stopAccessingSecurityScopedResource() } }
    let data = try archive.encoded()
    guard data.count <= 256 * 1024 * 1024 else { throw AppFailure("バックアップが256 MBを超えるため保存できません。") }
    let directory = folder(in: destination)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name =
      "Subritz-\(automatic ? "auto" : "manual")-\(Int(archive.createdAt.timeIntervalSince1970))-\(UUID().uuidString).\(fileExtension)"
    let target = directory.appendingPathComponent(name)
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(
      writingItemAt: directory, options: .forMerging, error: &coordinationError
    ) { directory in
      result = Result {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw AppFailure("バックアップの保存先にアクセスできませんでした。") }
    try result.get()
    // A successful new backup is already durable before deleting any old generation.
    if automatic { try? prune(directory, keeping: automaticLimit) }
    return target
  }
  public static func read(_ url: URL) throws -> BackupArchive {
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<BackupArchive, Error>?
    NSFileCoordinator().coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordinationError
    ) { coordinated in
      result = Result {
        let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw AppFailure("このバックアップは大きすぎて読み込めません。") }
        return try BackupArchive.decode(Data(contentsOf: coordinated, options: .mappedIfSafe))
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw AppFailure("バックアップを開けませんでした。") }
    return try result.get()
  }
  private static func prune(_ directory: URL, keeping limit: Int) throws {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
    )
    .filter { url in
      let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 3)
      return url.pathExtension == fileExtension && parts.count == 4 && parts[0] == "Subritz"
        && parts[1] == "auto" && Int(parts[2]) != nil && UUID(uuidString: String(parts[3])) != nil
    }.sorted {
      let a =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let b =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
    }
    for old in urls.dropFirst(limit) {
      var error: NSError?
      NSFileCoordinator().coordinate(writingItemAt: old, options: .forDeleting, error: &error) {
        url in
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}
