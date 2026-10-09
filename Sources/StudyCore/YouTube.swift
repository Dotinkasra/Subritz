import Foundation
import OSLog

public enum StudyLog {
  public static let youtube = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "youtube")
  public static let caption = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "caption")
  public static let timing = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "timing")
  public static let dictionary = Logger(
    subsystem: "jp.local.YouTubeEnglishStudy", category: "dictionary")
  public static let grammar = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "grammar")
  public static let cache = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "cache")
  public static let player = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "player")
  public static let ui = Logger(subsystem: "jp.local.YouTubeEnglishStudy", category: "ui")
}
public enum Executable {
  public static func find(_ name: String, explicit: String) throws -> URL {
    let paths =
      explicit.isEmpty
      ? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
        String($0) + "/" + name
      } + [
        "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
        FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/" + name,
      ] : [explicit]
    guard let p = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw AppFailure(
        name == "yt-dlp" ? .ytDlpNotFound : .grammarProviderUnavailable,
        "\(name) が見つかりません。設定で実行ファイルのパスを指定してください")
    }
    return URL(fileURLWithPath: p)
  }
}
// File-backed output avoids pipe buffer deadlocks on large metadata responses.
public enum CommandRunner {
  public static func run(
    _ executable: URL, arguments: [String], input: Data? = nil, timeout: Double = 120,
    directory: URL? = nil
  ) async throws -> Data {
    let task = Task.detached { () throws -> Data in
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let output = root.appendingPathComponent("stdout")
      let error = root.appendingPathComponent("stderr")
      let stdin = root.appendingPathComponent("stdin")
      FileManager.default.createFile(atPath: output.path, contents: nil)
      FileManager.default.createFile(atPath: error.path, contents: nil)
      try (input ?? Data()).write(to: stdin)
      let out = try FileHandle(forWritingTo: output)
      let err = try FileHandle(forWritingTo: error)
      let inp = try FileHandle(forReadingFrom: stdin)
      defer {
        try? out.close()
        try? err.close()
        try? inp.close()
      }
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.currentDirectoryURL = directory
      process.standardOutput = out
      process.standardError = err
      process.standardInput = inp
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] =
        executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
        + ":/opt/homebrew/bin:/usr/local/bin"
      process.environment = environment
      do { try process.run() } catch {
        throw AppFailure(
          .grammarProviderUnavailable, "\(executable.lastPathComponent) を起動できません。設定の実行ファイルを確認してください"
        )
      }
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning {
        if Task.isCancelled || Date() > deadline {
          process.terminate()
          throw Task.isCancelled
            ? CancellationError() : AppFailure("処理がタイムアウトしました。設定を確認して再試行してください")
        }
        do { try await Task.sleep(nanoseconds: 25_000_000) } catch {
          process.terminate()
          throw error
        }
      }
      guard process.terminationStatus == 0 else {
        let stderr = (try? String(contentsOf: error, encoding: .utf8)) ?? ""
        throw HelperFailure.make(
          name: executable.lastPathComponent, status: process.terminationStatus, stderr: stderr)
      }
      return try Data(contentsOf: output)
    }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
}
public struct CaptionTrack: Decodable {
  public var ext: String
  public var url: String
  public var name: String?
}
public struct VideoProbe: Decodable {
  public var id: String
  public var title: String
  public var duration: Double?
  public var language: String?
  public var automatic_captions: [String: [CaptionTrack]]?
  public var thumbnail: String? = nil
  public var video: Video {
    Video(id: id, title: title, duration: duration ?? 0, thumbnailURL: thumbnail)
  }
}
public protocol YouTubeProvider {
  func probe(id: String) async throws -> VideoProbe
  func caption(_ probe: VideoProbe) async throws -> Data
}
public struct YtDlpProvider: YouTubeProvider {
  public let path: String
  public init(path: String) { self.path = path }
  public func probe(id: String) async throws -> VideoProbe {
    let exe = try Executable.find("yt-dlp", explicit: path)
    let data = try await CommandRunner.run(
      exe,
      arguments: [
        "--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings",
        "https://www.youtube.com/watch?v=" + id,
      ])
    guard let result = try? JSONDecoder().decode(VideoProbe.self, from: data), result.id == id
    else { throw AppFailure(.videoUnavailable, "動画情報を取得できませんでした") }
    return result
  }
  public static func select(_ probe: VideoProbe) throws -> [CaptionTrack] {
    let tracks = probe.automatic_captions ?? [:]
    // An orig track is positive evidence; en alone requires original audio metadata.
    let originalEnglish = probe.language == "en" || (probe.language?.hasPrefix("en-") ?? false)
    for key in ["en-orig", "en"] {
      guard key == "en-orig" || originalEnglish else { continue }
      let candidates = (tracks[key] ?? []).filter { track in
        guard let c = URLComponents(string: track.url) else { return false }
        return !(c.queryItems ?? []).contains { $0.name == "tlang" }
      }
      if !candidates.isEmpty {
        return candidates.sorted { ($0.ext == "json3" ? 0 : 1) < ($1.ext == "json3" ? 0 : 1) }
      }
    }
    throw AppFailure(.automaticEnglishCaptionNotFound, "自動生成英語字幕を取得できませんでした。原音声が英語と確認できる自動字幕が必要です")
  }
  public func caption(_ probe: VideoProbe) async throws -> Data {
    for track in try Self.select(probe) where track.ext == "json3" {
      guard let url = URL(string: track.url) else { continue }
      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty { return data }
      } catch is CancellationError { throw CancellationError() } catch let e as URLError
        where e.code == .cancelled
      { throw CancellationError() } catch { continue }
    }
    throw AppFailure(.captionDownloadFailed, "JSON3 自動字幕を取得できませんでした。yt-dlp の更新後に再試行してください")
  }
}

public enum HelperFailure {
  public static func make(name: String, status: Int32, stderr: String) -> AppFailure {
    let text = stderr.lowercased()
    let isCodex = name.lowercased().contains("codex")
    let message: String
    if isCodex, text.contains("model"),
      text.contains("not supported") || text.contains("model not found")
        || text.contains("does not exist")
    {
      message = "Codex が指定モデルを利用できません。モデル名を確認するか、空欄にして CLI の設定を使用してください。"
    } else if isCodex,
      text.contains("login") || text.contains("unauthorized") || text.contains("401")
    {
      message = "Codex の認証が必要です。ターミナルで codex login を実行してください。"
    } else if text.contains("node"), text.contains("no such file") || text.contains("not found") {
      message = "Codex の起動に必要な Node.js が見つかりません。Node.js と同じフォルダの codex 実行ファイルを指定してください。"
    } else if isCodex {
      message = "Codex の文法解析に失敗しました。詳細を確認し、Provider 設定から再試行してください。"
    } else {
      message = "\(name) の処理に失敗しました。詳細を確認し、公開状態やヘルパー設定を確認してください。"
    }
    let lines = stderr.split(whereSeparator: \.isNewline).filter { line in
      let s = line.lowercased()
      return ["error", "failed", "not found", "warning", "unsupported"].contains { s.contains($0) }
    }.prefix(10).map { line -> String in
      let s = String(line)
      if s.range(
        of: "authorization|api[-_ ]?key|cookie|access[-_ ]?token|refresh[-_ ]?token|bearer|sk-",
        options: .regularExpression.union(.caseInsensitive)) != nil
      {
        return "[認証情報を含む行を省略]"
      }
      return String(
        s.replacingOccurrences(
          of: #"https?://[^\s"<>]+"#, with: "[URL]", options: .regularExpression
        ).prefix(600))
    }.joined(separator: "\n")
    return AppFailure(
      isCodex ? .grammarProviderUnavailable : .ytDlpExecutionFailed, message,
      details: "\(name) / 終了コード \(status)\n" + lines)
  }
}
