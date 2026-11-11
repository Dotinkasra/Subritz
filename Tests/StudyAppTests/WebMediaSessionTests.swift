import Foundation
import Testing
import WebKit
@testable import StudyApp
@testable import StudyCore

@MainActor private final class MediaPageLoad: NSObject, WKNavigationDelegate {
  var continuation: CheckedContinuation<Void, Error>?
  func load(_ web: WKWebView) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      web.navigationDelegate = self
      web.loadHTMLString("<html><body>Authored media fixture<iframe srcdoc='Authored child frame'></iframe></body></html>",
        baseURL: URL(string: "https://jp.local.youtubeenglishstudy"))
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume(); continuation = nil
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error); continuation = nil
  }
}

@MainActor struct WebMediaSessionTests {
  let item = NowPlayingItem(videoID: "authored", title: "検証用 'quoted' <title>", duration: 120,
    elapsed: 12, rate: 1.5, state: .playing, thumbnailURL: URL(string: "https://example.invalid/fixture.png"))

  @Test func metadataIsSafelyEncodedAndTheWebPageIsTheOnlyPublisher() throws {
    let data = Data(WebMediaSession.payload(item, session: "fixture-session").utf8)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let metadata = try #require(payload["item"] as? [String: Any])
    #expect(metadata["title"] as? String == item.title)
    #expect(metadata["position"] as? Double == 12 && metadata["rate"] as? Double == 1.5)
    #expect(payload["session"] as? String == "fixture-session")
    let bridge = PlayerBridge()
    let active = WebNowPlayingOutput(bridge: bridge)
    active.activate { _ in Issue.record("Web output must not register a second native command target"); return false }
    active.publish(item)
    #expect(bridge.mediaSessionItem == item)
    active.clear()
    #expect(bridge.mediaSessionItem == nil)
  }

  @Test func iframeCommandsRequireTheCurrentSessionAndValidSeekPosition() {
    let bridge = PlayerBridge()
    var commands: [MediaPlaybackCommand] = []
    bridge.onMediaCommand = { commands.append($0) }
    let id = bridge.playbackID
    bridge.receive(["session": id, "mediaCommand": "play"])
    bridge.receive(["session": id, "mediaCommand": "pause"])
    bridge.receive(["session": id, "mediaCommand": "seek", "position": 42.0])
    bridge.receive(["session": "obsolete", "mediaCommand": "play"])
    bridge.receive(["session": id, "mediaCommand": "seek", "position": Double.nan])
    bridge.receive(["session": id, "mediaCommand": "seek", "position": -3.0])
    #expect(commands == [.play, .pause, .seek(42)])
    bridge.invalidateVideo()
    bridge.receive(["session": id, "mediaCommand": "play"])
    #expect(commands.count == 3)
  }

  @Test func realWebKitInstallsMetadataHandlersAndClearsThemOnClose() async throws {
    let bridge = PlayerBridge()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(bridge, name: "player")
    // Keep the genuine WebKit API active while exposing its callbacks to this test.
    configuration.userContentController.addUserScript(WKUserScript(source: """
      window.fixtureActions = {};
      const originalSetActionHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
      navigator.mediaSession.setActionHandler = (action, handler) => {
        window.fixtureActions[action] = handler; originalSetActionHandler(action, handler);
      };
      """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    configuration.userContentController.addUserScript(WKUserScript(
      source: WebMediaSession.bootstrap(item: item, session: bridge.playbackID),
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let web = WKWebView(frame: .zero, configuration: configuration)
    defer { configuration.userContentController.removeScriptMessageHandler(forName: "player"); web.stopLoading() }
    let navigation = MediaPageLoad()
    try await navigation.load(web)
    let title = try await web.evaluateJavaScript("navigator.mediaSession.metadata.title") as? String
    #expect(title == item.title)
    #expect(try await web.evaluateJavaScript("frames[0].navigator.mediaSession.metadata.title") as? String == item.title)
    #expect(try await web.evaluateJavaScript("typeof window.fixtureActions.pause") as? String == "function")
    let received = await withCheckedContinuation { continuation in
      bridge.onMediaCommand = { command in continuation.resume(returning: command) }
      web.evaluateJavaScript("frames[0].fixtureActions.pause()")
    }
    #expect(received == .pause)
    try await web.evaluateJavaScript(WebMediaSession.updateScript(nil, session: bridge.playbackID))
    #expect(try await web.evaluateJavaScript("navigator.mediaSession.metadata === null && window.fixtureActions.pause === null") as? Bool == true)
  }

  @Test func isolatedPlayerStoreCanBeDeletedWithoutTouchingOtherProfiles() async throws {
    let id = UUID()
    var web: WKWebView? = {
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
      return WKWebView(frame: .zero, configuration: configuration)
    }()
    #expect(web?.configuration.websiteDataStore.isPersistent == true)
    #expect(web?.configuration.websiteDataStore.identifier == id)
    let navigation = MediaPageLoad()
    try await navigation.load(try #require(web))
    web?.stopLoading()
    web = nil
    try await MediaWebsiteDataStore.deleteReleasedStore(id)
  }
}
