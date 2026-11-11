import Foundation
import QuartzCore
import Testing
import WebKit
@testable import StudyApp
@testable import StudyCore

@MainActor private final class RecordingNowPlayingOutput: NowPlayingOutput {
  var handler: (@MainActor (MediaPlaybackCommand) -> Bool)?
  var items: [NowPlayingItem] = []
  var activations = 0
  func activate(handler: @escaping @MainActor (MediaPlaybackCommand) -> Bool) {
    self.handler = handler; activations += 1
  }
  func publish(_ item: NowPlayingItem) { items.append(item) }
  func clear() { handler = nil }
}

@MainActor private final class RecordingMediaWebView: WKWebView {
  var scripts: [String] = []
  override func evaluateJavaScript(_ javaScriptString: String,
    completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
    scripts.append(javaScriptString)
    completionHandler?(nil, nil)
  }
}

@MainActor struct NowPlayingTests {
  let video = Video(id: "abcdefghijk", title: "A paper robot sings", duration: 120)

  @Test func commandsControlTheSameVideoAndFastTogglesDoNotDependOnIframeLatency() throws {
    let controller = NowPlayingController(output: nil)
    var commands: [MediaPlaybackCommand] = []
    controller.begin(video: video, position: 15) { commands.append($0) }
    #expect(controller.handle(.play, uptime: 10))
    // A stale paused sample arrives before YouTube has acknowledged play.
    controller.sample(time: 15, duration: 120, state: 2, rate: 1, uptime: 10.1)
    #expect(controller.handle(.toggle, uptime: 10.2))
    #expect(controller.handle(.toggle, uptime: 10.3))
    #expect(commands == [.play, .pause, .play])
    controller.sample(time: 16, duration: 120, state: 1, rate: 1, uptime: 10.4)
    controller.handle(.pause, uptime: 10.5)
    controller.handle(.play, uptime: 10.6)
    controller.handle(.seek(900))
    #expect(commands.suffix(3) == [.pause, .play, .seek(120)])
    #expect(!controller.handle(.seek(.nan)) && !controller.handle(.seek(-1)))
  }

  @Test func metadataTracksRealPositionStateRateBufferingAndSeeks() throws {
    let output = RecordingNowPlayingOutput()
    let active = NowPlayingController(output: output)
    active.begin(video: video, position: 30) { _ in }
    #expect(output.items.last?.title == video.title && output.items.last?.elapsed == 30)
    #expect(output.items.last?.state == .paused)
    active.sample(time: 30.1, duration: 121, state: 1, rate: 1.5, uptime: 100)
    #expect(output.items.last?.duration == 121 && output.items.last?.rate == 1.5)
    #expect(output.items.last?.state == .playing)
    active.sample(time: 31, duration: 121, state: 3, rate: 1.5, uptime: 100.6)
    #expect(output.items.last?.state == .buffering && output.items.last?.advancing == false)
    active.sample(time: 31, duration: 121, state: 2, rate: 1.5, uptime: 101)
    #expect(output.items.last?.state == .paused)
    active.sample(time: 80, duration: 121, state: 2, rate: 1.5, uptime: 102)
    #expect(output.items.last?.elapsed == 80)
    let before = output.items.count
    active.sample(time: .nan, duration: 121, state: 1, rate: 1, uptime: 103)
    active.sample(time: 80, duration: 121, state: 1, rate: 0, uptime: 103)
    #expect(output.items.count == before)
    active.sample(time: 121, duration: 121, state: 0, rate: 1, uptime: 104)
    #expect(output.items.last?.state == .stopped)
  }

  @Test func positionSamplesDoNotPublishEveryFrame() {
    let output = RecordingNowPlayingOutput()
    let active = NowPlayingController(output: output)
    active.begin(video: video, position: 0) { _ in }
    active.sample(time: 0, duration: 120, state: 1, rate: 2, uptime: 100)
    let initial = output.items.count
    for tick in 1..<100 {
      active.sample(time: Double(tick) / 10, duration: 120, state: 1, rate: 2,
        uptime: 100 + Double(tick) / 20)
    }
    #expect(output.items.count == initial)
    active.sample(time: 10, duration: 120, state: 1, rate: 2, uptime: 105)
    #expect(output.items.count == initial + 1)
  }

  @Test func closeReplacementAndOldHandlersCannotControlAnotherSession() throws {
    let output = RecordingNowPlayingOutput()
    let active = NowPlayingController(output: output)
    var commands: [MediaPlaybackCommand] = []
    active.begin(video: video, position: 20) { commands.append($0) }
    let old = try #require(output.handler)
    #expect(old(.play))
    active.begin(video: Video(id: "zyxwvutsrqp", title: "A blue lantern", duration: 50), position: 5) {
      commands.append($0)
    }
    #expect(!old(.pause))
    #expect(output.activations == 2 && output.items.last?.title == "A blue lantern")
    let current = try #require(output.handler)
    #expect(current(.seek(12)))
    active.end()
    #expect(output.handler == nil && active.item == nil)
    #expect(!current(.play) && !active.handle(.toggle))
    active.sample(time: 80, duration: 120, state: 1, rate: 1, uptime: 100)
    #expect(active.item == nil && commands == [.play, .seek(12)])
  }

  @Test func iframeSamplesDriveNowPlayingAndCloseClearsItButSpeechDoesNotRegister() throws {
    let (model, _) = try DictionaryPinTests().fixture(realtime: true)
    model.grammarEnabledForVideo = false
    model.beginNowPlaying(video: video, position: 0)
    let sid = model.bridge.playbackID
    let uptime = CACurrentMediaTime()
    model.bridge.receive(["session": sid, "time": 14.0, "duration": 120.0,
      "state": 1, "rate": 1.5], now: uptime)
    #expect(model.nowPlaying.item?.elapsed == 14 && model.nowPlaying.item?.rate == 1.5)
    model.bridge.receive(["session": "obsolete", "time": 40.0, "duration": 120.0,
      "state": 2], now: uptime + 1)
    #expect(model.nowPlaying.item?.elapsed == 14)
    model.closeVideo()
    #expect(model.nowPlaying.item == nil && !model.nowPlaying.handle(.play))
    model.liveSpeechSessionID = UUID()
    model.ready = true
    model.toggleVideoPlayback()
    #expect(model.nowPlaying.item == nil)
    model.closeVideo()
  }

  @Test func externalCommandsAndAppButtonUseTheYouTubeBridgeAndUnregisterOnClose() throws {
    let suite = "NowPlayingTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let output = RecordingNowPlayingOutput()
    let model = StudyModel(prepareStorage: false, defaults: defaults, nowPlayingOutput: output)
    model.document = StudyDocument(video: video, rawCaption: Data(), sentences: [])
    model.duration = video.duration
    model.grammarEnabledForVideo = false
    model.continuePlayback()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = RecordingMediaWebView(frame: .zero, configuration: configuration)
    model.bridge.webView = web
    model.bridge.receive(["session": model.bridge.playbackID, "ready": true])
    let handler = try #require(output.handler)
    #expect(handler(.play) && web.scripts.last == "player?.playVideo()")
    #expect(handler(.pause) && web.scripts.last == "player?.pauseVideo()")
    model.toggleVideoPlayback()
    #expect(web.scripts.last == "player?.playVideo()")
    #expect(handler(.seek(42)))
    #expect(model.bridge.pendingSeekTime == 42 && model.time == 42)
    #expect(web.scripts.last == "player?.seekTo(42.0,true)")
    model.closeVideo()
    #expect(output.handler == nil && !handler(.play))
    #expect(web.scripts.last == "player?.pauseVideo()")
  }
}
