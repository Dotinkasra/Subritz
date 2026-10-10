import Foundation

public enum TimestampKind: String, Codable, Sendable {
  case bookmark, resume, favorite
}
public struct VideoTimestamp: Codable, Identifiable, Sendable {
  public var id: String
  public var video: Video
  public var time: Double
  public var kind: TimestampKind
  public var wordID: String?
  public var savedAt: Date
  public var videoURL: String { video.watchURL }
  public init(video: Video, time: Double, kind: TimestampKind = .bookmark,
    wordID: String? = nil, savedAt: Date = Date()) {
    self.video = video
    self.time = time
    self.kind = kind
    self.wordID = wordID
    self.savedAt = savedAt
    switch kind {
    case .bookmark: id = UUID().uuidString
    case .resume: id = "resume:" + video.id
    case .favorite: id = "favorite:" + (wordID ?? UUID().uuidString)
    }
  }
}
public enum PlaybackTime {
  public static func format(_ time: Double) -> String {
    guard time.isFinite, time < Double(Int.max) else { return "0:00" }
    let n = Int(max(0, time))
    if n >= 3600 { return String(format: "%d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60) }
    return String(format: "%d:%02d", n / 60, n % 60)
  }
}
