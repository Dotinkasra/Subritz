import AppKit
import Testing
import WebKit
@testable import StudyApp

@MainActor private final class ShapePageLoad: NSObject, WKNavigationDelegate {
  var continuation: CheckedContinuation<Void, Error>?
  func load(_ web: WKWebView) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      web.navigationDelegate = self
      web.loadHTMLString("""
        <html><body style="margin:0"><iframe style="border:0;width:100vw;height:100vh" srcdoc='
        <html><body style="margin:0"><div class="html5-video-player" style="width:100vw;height:100vh">
        <button class="ytp-chrome-bottom" style="position:absolute;left:10%;top:70%;width:80%;height:20%">Play / Seek / Settings</button>
        <div class="ytp-settings-menu" style="display:none;position:absolute;left:60%;top:30%;width:30%;height:40%">Settings menu</div>
        </div></body></html>'></iframe></body></html>
        """, baseURL: URL(string: "https://jp.local.youtubeenglishstudy"))
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume(); continuation = nil
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error); continuation = nil
  }
}

@MainActor struct VideoShapeWebTests {
  @Test func realWebKitReportsIframeControlsAndMenusOnlyWhileNeeded() async throws {
    _ = NSApplication.shared
    let bridge = PlayerBridge()
    var regions: [CGRect] = []
    bridge.onShapeControls = { regions = $0 }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(bridge, name: "player")
    config.userContentController.addUserScript(WKUserScript(
      source: VideoPlayerControlRegions.bootstrap(enabled: false, session: bridge.playbackID),
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 450), configuration: config)
    bridge.webView = web
    defer { config.userContentController.removeScriptMessageHandler(forName: "player"); web.stopLoading() }
    let navigation = ShapePageLoad()
    try await navigation.load(web)
    #expect(regions.isEmpty)
    bridge.setShapeControlsEnabled(true)
    try await Task.sleep(for: .milliseconds(180))
    #expect(regions.count == 1)
    let bottom = try #require(regions.first)
    #expect(abs(bottom.minY - 0.7) < 0.01 && abs(bottom.width - 0.8) < 0.01)
    try await web.evaluateJavaScript("""
      frames[0].document.querySelector('.ytp-settings-menu').style.display='block';
      frames[0].document.dispatchEvent(new Event('click'));
      """)
    try await Task.sleep(for: .milliseconds(180))
    #expect(regions.count == 2)
    bridge.setShapeControlsEnabled(false)
    try await web.evaluateJavaScript("frames[0].document.dispatchEvent(new Event('click'))")
    try await Task.sleep(for: .milliseconds(180))
    #expect(regions.isEmpty)
    // No timer scans run at playback frequency; only control changes and input
    // schedule a single snapshot, with identical snapshots deduplicated.
  }
}
