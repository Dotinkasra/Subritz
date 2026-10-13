import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct DictionaryBrowserTests {
  @Test func defaultPopupAndExplicitBrowserRoutingRemainSeparate() throws {
    let unreachable: (String) -> URL? = { _ in Issue.record("System/popup must not resolve an application"); return nil }
    #expect(try DictionaryBrowser.destination(for: "system", resolve: unreachable) == .system)
    #expect(try DictionaryBrowser.destination(for: "popup", resolve: unreachable) == .popup)
    let application = URL(fileURLWithPath: "/tmp/AuthoredBrowser.app")
    var resolvedID: String?
    let destination = try DictionaryBrowser.destination(for: "browser:fixture.browser", resolve: {
      resolvedID = $0; return application
    }, validate: { _ in true })
    #expect(destination == .application(application) && resolvedID == "fixture.browser")
    #expect(throws: AppFailure.self) {
      try DictionaryBrowser.destination(for: "browser:missing", resolve: { _ in nil })
    }
    #expect(throws: AppFailure.self) {
      try DictionaryBrowser.destination(for: "unexpected", resolve: { _ in application })
    }
  }
  private func browserInfo() -> [String: Any] {
    ["CFBundleIdentifier": "fixture.browser", "CFBundlePackageType": "APPL",
      "CFBundleURLTypes": [["CFBundleURLSchemes": ["http", "https"]]],
      "CFBundleDocumentTypes": [["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.html"]]]]
  }
  @Test func requiresWebPageViewingAsWellAsBothURLSchemes() {
    var info = browserInfo()
    #expect(DictionaryBrowser.supportsWebBrowsing(info))
    info["LSUIElement"] = true // Menu-bar browser routers are valid too.
    #expect(DictionaryBrowser.supportsWebBrowsing(info))
    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.data"]]]
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
    info = browserInfo()
    info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["http"]]]
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
    info = browserInfo()
    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.html"]]]
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
    info = browserInfo()
    info["CFBundleIdentifier"] = "io.nwjs.nwjs"
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
  }
  @Test func handlesLegacyHTMLDeclarationsAndRejectsInactiveRoles() {
    var info = browserInfo()
    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": "Viewer", "CFBundleTypeExtensions": ["htm"]]]
    #expect(DictionaryBrowser.supportsWebBrowsing(info))
    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": "Viewer", "CFBundleTypeMIMETypes": ["text/html"]]]
    #expect(DictionaryBrowser.supportsWebBrowsing(info))
    info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["http", "https"], "LSHandlerRank": "None"]]
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
    info = browserInfo()
    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.html"], "LSHandlerRank": "None"]]
    #expect(!DictionaryBrowser.supportsWebBrowsing(info))
  }
  @Test func exactInstalledCopyIsUsedAndOldNonBrowserPreferencesAreRejected() throws {
    let application = URL(fileURLWithPath: "/tmp/Authored Browser.app")
    #expect(try DictionaryBrowser.destination(for: "browser-app:" + application.absoluteString,
      resolve: { _ in Issue.record("Must use the selected copy"); return nil }, validate: { $0 == application })
      == .application(application))
    #expect(throws: AppFailure.self) {
      try DictionaryBrowser.destination(for: "browser:fixture.tool", resolve: { _ in application },
        validate: { _ in false })
    }
    #expect(throws: AppFailure.self) {
      try DictionaryBrowser.destination(for: "browser-app:https://example.invalid/", validate: { _ in true })
    }
  }
  @Test func dismissedPopupDetachesItsWebPageCallbacks() {
    let session = DictionaryWebSession(url: URL(string: "about:blank")!)
    #expect(session.webView.navigationDelegate === session)
    #expect(session.webView.uiDelegate === session)
    session.close()
    #expect(session.webView.navigationDelegate == nil && session.webView.uiDelegate == nil)
  }
}
