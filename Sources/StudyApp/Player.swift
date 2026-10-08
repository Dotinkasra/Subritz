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
  func startClock() {
    stopClock()
    clock = PlaybackClock()
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
    if let error = body["error"] as? Int {
      onError?("YouTube の埋め込み再生に失敗しました（\(error)）。動画の公開状態・埋め込み許可を確認してください")
      return
    }
    guard let time = body["time"] as? Double, let duration = body["duration"] as? Double,
      let state = body["state"] as? Int
    else { return }
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
    clock.seek(to: time, now: CACurrentMediaTime())
    webView?.evaluateJavaScript("player?.seekTo(\(max(0,time)),true)")
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
      let player; function sample(){post({time:player.getCurrentTime(),duration:player.getDuration(),state:player.getPlayerState(),rate:player.getPlaybackRate()})} function post(v){window.webkit.messageHandlers.player.postMessage(v)}
      function onYouTubeIframeAPIReady(){ player=new YT.Player('player',{videoId:'\(videoID)',playerVars:{playsinline:1,origin:'https://jp.local.youtubeenglishstudy',cc_load_policy:0},events:{onReady:()=>{sample();setInterval(sample,50)},onStateChange:sample,onPlaybackRateChange:sample,onError:e=>post({error:e.data})}}) }
      </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
      """, baseURL: URL(string: "https://jp.local.youtubeenglishstudy"))
    return web
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: PlayerBridge) {
    coordinator.stopClock()
    coordinator.webView = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "player")
    view.stopLoading()
  }
}
