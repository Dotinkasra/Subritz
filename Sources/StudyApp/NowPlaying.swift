import WebKit
import QuartzCore
import StudyCore

enum MediaPlaybackCommand: Equatable { case play, pause, toggle, seek(Double) }
struct NowPlayingItem: Equatable {
  enum State { case playing, buffering, paused, stopped }
  var videoID: String
  var title: String
  var duration: Double
  var elapsed: Double
  var rate: Double
  var state: State
  var thumbnailURL: URL?
  var advancing: Bool { state == .playing }
  var wantsPlayback: Bool { state == .playing || state == .buffering }
}

@MainActor protocol NowPlayingOutput: AnyObject {
  func activate(handler: @escaping @MainActor (MediaPlaybackCommand) -> Bool)
  func publish(_ item: NowPlayingItem)
  func clear()
}

/// Uses authoritative iframe samples, independent of SwiftUI's 30 Hz display clock.
@MainActor final class NowPlayingController {
  private let output: (any NowPlayingOutput)?
  private var onCommand: ((MediaPlaybackCommand) -> Void)?
  private var generation = UUID()
  private(set) var item: NowPlayingItem?
  private var published: NowPlayingItem?
  private var publishedAt: Double = 0
  private var requestedPlayback: (playing: Bool, uptime: Double)?

  init(output: (any NowPlayingOutput)?) { self.output = output }

  func begin(video: Video, position: Double, onCommand: @escaping (MediaPlaybackCommand) -> Void) {
    end()
    generation = UUID()
    let id = generation
    self.onCommand = onCommand
    item = NowPlayingItem(videoID: video.id, title: video.title, duration: max(0, video.duration),
      elapsed: max(0, position), rate: 1, state: .paused, thumbnailURL: video.thumbnailImageURL)
    output?.activate { [weak self] command in
      guard let self, self.generation == id else { return false }
      return self.handle(command)
    }
    publish(at: CACurrentMediaTime())
  }

  @discardableResult func handle(_ command: MediaPlaybackCommand,
    uptime: Double = CACurrentMediaTime()) -> Bool {
    guard let item, let onCommand else { return false }
    switch command {
    case .seek(let time):
      guard time.isFinite, time >= 0, item.duration > 0 else { return false }
      onCommand(.seek(min(time, item.duration)))
    case .play, .pause, .toggle:
      let pending = requestedPlayback.flatMap { uptime - $0.uptime < 2 ? $0.playing : nil }
      let play = command == .play || (command == .toggle && !(pending ?? item.wantsPlayback))
      requestedPlayback = (play, uptime)
      onCommand(play ? .play : .pause)
    }
    return true
  }

  func sample(time: Double, duration: Double, state: Int, rate: Double, uptime: Double) {
    guard var item, time.isFinite, duration.isFinite, rate.isFinite, uptime.isFinite,
      time >= 0, duration >= 0, rate > 0 else { return }
    item.elapsed = duration > 0 ? min(time, duration) : time
    if duration > 0 { item.duration = duration }
    item.rate = rate
    item.state = state == 1 ? .playing : state == 3 ? .buffering : state == 0 ? .stopped : .paused
    self.item = item
    if let request = requestedPlayback,
      request.playing == item.wantsPlayback || uptime - request.uptime >= 2 { requestedPlayback = nil }
    guard let published else { publish(at: uptime); return }
    let expected = published.elapsed + (published.advancing ? max(0, uptime - publishedAt) * published.rate : 0)
    if published.state != item.state || published.rate != item.rate || published.duration != item.duration
      || abs(item.elapsed - expected) > 0.75 || uptime - publishedAt >= 5 {
      publish(at: uptime)
    }
  }

  private func publish(at uptime: Double) {
    guard let item else { return }
    output?.publish(item)
    published = item
    publishedAt = uptime
  }
  func end() {
    generation = UUID()
    onCommand = nil
    requestedPlayback = nil
    item = nil
    published = nil
    output?.clear()
  }
}

/// WebKit owns the sole OS media session. Publishing a second native
/// MPNowPlayingInfoCenter session creates a separate control card for the same video.
@MainActor final class WebNowPlayingOutput: NowPlayingOutput {
  private weak var bridge: PlayerBridge?
  init(bridge: PlayerBridge) { self.bridge = bridge }
  func activate(handler: @escaping @MainActor (MediaPlaybackCommand) -> Bool) {}
  func publish(_ item: NowPlayingItem) { bridge?.publishMediaSession(item) }
  func clear() { bridge?.clearMediaSession() }
}

extension StudyModel {
  func beginNowPlaying(video: Video, position: Double) {
    nowPlaying.begin(video: video, position: position) { [weak self] command in
      guard let self, self.ready, !self.isLiveSpeech else { return }
      switch command {
      case .play: self.bridge.play()
      case .pause: self.bridge.pause()
      case .seek(let time): self.seek(time)
      case .toggle: break // Resolved to play/pause by the controller.
      }
    }
  }
  func toggleVideoPlayback() {
    guard ready, !isLiveSpeech else { return }
    if !nowPlaying.handle(.toggle) { playing ? bridge.pause() : bridge.play() }
  }
}
