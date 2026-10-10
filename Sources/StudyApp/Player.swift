import QuartzCore
import StudyCore
import SwiftUI
import WebKit

@MainActor final class PlayerBridge: NSObject, ObservableObject, WKScriptMessageHandler {
  weak var webView: WKWebView?
  var onTime: ((Double, Double, Int) -> Void)?
  var onError: ((String) -> Void)?
  private var clock = PlaybackClock()
  private var timer: Timer?
  private var duration: Double = 0
  private var state = -1
  private(set) var playbackID = UUID().uuidString
  private(set) var initialTime: Double = 0
  private(set) var pendingSeekTime: Double?
  private var playerReady = false
  private var seekIssuedAt: Double?
  func prepareForVideo(at time: Double) {
    stopClock()
    playbackID = UUID().uuidString
    initialTime = max(0, time)
    pendingSeekTime = initialTime > 0 ? initialTime : nil
    playerReady = false
    seekIssuedAt = nil
    duration = 0
    state = -1
    clock = PlaybackClock()
    clock.seek(to: initialTime, now: CACurrentMediaTime())
  }
  func invalidateVideo() {
    playbackID = UUID().uuidString
    playerReady = false
    pendingSeekTime = nil
    webView = nil
  }
  func startClock() {
    stopClock()
    clock = PlaybackClock()
    clock.seek(to: initialTime, now: CACurrentMediaTime())
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.onTime?(self.clock.position(now: CACurrentMediaTime()), self.duration, self.state)
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func stopClock() {
    timer?.invalidate()
    timer = nil
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else { return }
    receive(body)
  }
  func receive(_ body: [String: Any]) {
    // Ignore callbacks from the previous iframe while a replacement video loads.
    guard body["session"] as? String == playbackID else { return }
    if let error = body["error"] as? Int {
      onError?("YouTube の埋め込み再生に失敗しました（\(error)）。動画の公開状態・埋め込み許可を確認してください")
      return
    }
    if body["ready"] as? Bool == true {
      playerReady = true
      issuePendingSeek()
      return
    }
    guard let time = body["time"] as? Double, let duration = body["duration"] as? Double,
      let state = body["state"] as? Int
    else { return }
    guard time.isFinite, duration.isFinite, time >= 0, duration >= 0 else { return }
    if let pending = pendingSeekTime {
      let target = duration > 0 ? min(pending, duration) : pending
      if target != pending {
        pendingSeekTime = target
        issuePendingSeek()
      }
      if abs(time - target) <= 0.75 {
        pendingSeekTime = nil
        seekIssuedAt = nil
      } else if let issued = seekIssuedAt, CACurrentMediaTime() - issued > 8 {
        pendingSeekTime = nil
        seekIssuedAt = nil
        onError?("保存した再生位置へ移動できませんでした。シークバーで移動してください")
      } else {
        return
      }
    }
    self.duration = duration
    self.state = state
    clock.sample(
      time: time, now: CACurrentMediaTime(), state: state, rate: body["rate"] as? Double ?? 1)
    onTime?(clock.position(now: CACurrentMediaTime()), duration, state)
  }
  func play() { webView?.evaluateJavaScript("player?.playVideo()") }
  func pause() { webView?.evaluateJavaScript("player?.pauseVideo()") }
  func seek(_ time: Double) {
    guard time.isFinite else { return }
    pendingSeekTime = max(0, time)
    clock.seek(to: max(0, time), now: CACurrentMediaTime())
    issuePendingSeek()
  }
  private func issuePendingSeek() {
    guard playerReady, let time = pendingSeekTime else { return }
    seekIssuedAt = CACurrentMediaTime()
    webView?.evaluateJavaScript("player?.seekTo(\(time),true)")
  }
}
struct YouTubePlayer: NSViewRepresentable {
  let videoID: String
  let bridge: PlayerBridge
  func makeCoordinator() -> PlayerBridge { bridge }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.userContentController.add(bridge, name: "player")
    let web = WKWebView(frame: .zero, configuration: configuration)
    bridge.webView = web
    bridge.startClock()
    // HTTPS base URL supplies Referer identity required by embedded YouTube clients.
    web.loadHTMLString(
      """
      <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#player{margin:0;width:100%;height:100%;background:#111;overflow:hidden}</style></head><body><div id="player"></div><script>
      let player; function sample(){post({time:player.getCurrentTime(),duration:player.getDuration(),state:player.getPlayerState(),rate:player.getPlaybackRate()})} function post(v){v.session='\(bridge.playbackID)';window.webkit.messageHandlers.player.postMessage(v)}
      function onYouTubeIframeAPIReady(){ player=new YT.Player('player',{videoId:'\(videoID)',playerVars:{playsinline:1,origin:'https://jp.local.youtubeenglishstudy',cc_load_policy:0},events:{onReady:()=>{post({ready:true});sample();setInterval(sample,50)},onStateChange:sample,onPlaybackRateChange:sample,onError:e=>post({error:e.data})}}) }
      </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
      """, baseURL: URL(string: "https://jp.local.youtubeenglishstudy"))
    return web
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: PlayerBridge) {
    // SwiftUI can create the replacement iframe before dismantling the old one.
    if coordinator.webView === view {
      coordinator.stopClock()
      coordinator.webView = nil
    }
    view.configuration.userContentController.removeScriptMessageHandler(forName: "player")
    view.stopLoading()
  }
}
