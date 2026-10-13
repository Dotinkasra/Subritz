import AppKit
import StudyCore
import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum DictionaryBrowserDestination: Equatable {
  case system, popup, application(URL)
}

@MainActor enum DictionaryBrowser {
  struct Application: Identifiable {
    let url: URL
    let bundleID: String
    let name: String
    let version: String
    let icon: NSImage
    var id: String { "browser-app:" + url.absoluteString }
    var legacyID: String { "browser:" + bundleID }
  }

  // URL handlers include automation tools and deep-link apps. A browser must also
  // declare web-page viewing, rather than merely accepting an HTTP URL.
  nonisolated static func supportsWebBrowsing(_ info: [String: Any]) -> Bool {
    guard info["CFBundlePackageType"] as? String == "APPL",
      let identifier = info["CFBundleIdentifier"] as? String,
      !identifier.isEmpty else { return false }
    // An uncustomized NW.js runtime inherits Chromium's handlers even in games.
    // Its generic runtime identity does not identify an installed web browser.
    guard identifier != "io.nwjs.nwjs" else { return false }
    let urls = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
    let schemes = Set(urls.filter { item in
      (item["CFBundleTypeRole"] as? String ?? "Viewer") != "None"
        && (item["LSHandlerRank"] as? String ?? "Default") != "None"
    }.flatMap { ($0["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() } })
    guard schemes.isSuperset(of: ["http", "https"]) else { return false }
    let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    return documents.contains { item in
      guard item["CFBundleTypeRole"] as? String == "Viewer",
        (item["LSHandlerRank"] as? String ?? "Default") != "None" else { return false }
      let types = item["LSItemContentTypes"] as? [String] ?? []
      if !types.isEmpty { return types.contains("public.html") || types.contains("public.xhtml") }
      let extensions = item["CFBundleTypeExtensions"] as? [String] ?? []
      let mime = item["CFBundleTypeMIMETypes"] as? [String] ?? []
      return extensions.contains { ["html", "htm", "xhtml"].contains($0.lowercased()) }
        || mime.contains("text/html") || mime.contains("application/xhtml+xml")
    }
  }
  nonisolated static func isBrowser(at url: URL) -> Bool {
    guard let info = Bundle(url: url)?.infoDictionary else { return false }
    return supportsWebBrowsing(info)
  }
  static func installed() -> [Application] {
    let workspace = NSWorkspace.shared
    let http = Set(workspace.urlsForApplications(toOpen: URL(string: "http:")!)
      .map { $0.standardizedFileURL })
    let html = Set(workspace.urlsForApplications(toOpen: UTType.html)
      .map { $0.standardizedFileURL })
    var seen = Set<URL>()
    return workspace.urlsForApplications(toOpen: URL(string: "https:")!).compactMap { original in
      let url = original.standardizedFileURL
      guard http.contains(url), html.contains(url), seen.insert(url).inserted,
        let bundle = Bundle(url: url), let info = bundle.infoDictionary,
        supportsWebBrowsing(info), let id = bundle.bundleIdentifier else { return nil }
      let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? url.deletingPathExtension().lastPathComponent
      return Application(url: url, bundleID: id, name: name,
        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        icon: workspace.icon(forFile: url.path))
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      if order != .orderedSame { return order == .orderedAscending }
      let versions = $0.version.compare($1.version, options: .numeric)
      return versions == .orderedSame ? $0.url.path < $1.url.path : versions == .orderedDescending
    }
  }
  static func destination(for preference: String,
    resolve: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
    validate: (URL) -> Bool = { isBrowser(at: $0) }
  ) throws -> DictionaryBrowserDestination {
    switch preference {
    case "system": return .system
    case "popup": return .popup
    default:
      let application: URL?
      if preference.hasPrefix("browser-app:") {
        let url = URL(string: String(preference.dropFirst("browser-app:".count)))
        application = url?.isFileURL == true ? url : nil
      } else if preference.hasPrefix("browser:") {
        application = resolve(String(preference.dropFirst("browser:".count)))
      } else { application = nil }
      guard let application, validate(application) else {
        throw AppFailure("指定したブラウザを利用できません。設定の「辞書を開く際のブラウザ」を変更してください。")
      }
      return .application(application)
    }
  }
  static func open(_ url: URL, destination: DictionaryBrowserDestination) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
        if let error { continuation.resume(throwing: error) }
        else if app != nil { continuation.resume() }
        else { continuation.resume(throwing: AppFailure("ブラウザを開けませんでした。")) }
      }
      let configuration = NSWorkspace.OpenConfiguration()
      switch destination {
      case .system:
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion)
      case .application(let application):
        NSWorkspace.shared.open([url], withApplicationAt: application,
          configuration: configuration, completionHandler: completion)
      case .popup:
        continuation.resume(throwing: AppFailure("アプリ内の辞書表示を開けませんでした。"))
      }
    }
  }
}

struct CambridgeLookupRequest: Identifiable {
  let id = UUID()
  let word: String
  let url: URL
}

struct CambridgeLookupButton: View {
  let word: String
  let browser: String
  var label = "Cambridge"
  @State private var request: CambridgeLookupRequest?
  @State private var error: String?
  @State private var opening = false
  var body: some View {
    Button {
      // Keep the appearance stable through caption gaps and while opening a browser.
      guard !opening else { return }
      let url = CambridgeDictionary.destinationURL(for: word)
      do {
        let destination = try DictionaryBrowser.destination(for: browser)
        if destination == .popup {
          request = CambridgeLookupRequest(word: CambridgeDictionary.lookupURL(for: word) == nil
            ? "英英辞書を検索" : word, url: url)
        } else {
          opening = true
          Task { @MainActor in
            defer { opening = false }
            do { try await DictionaryBrowser.open(url, destination: destination) }
            catch { self.error = "辞書を開けませんでした：" + error.localizedDescription }
          }
        }
      } catch { self.error = error.localizedDescription }
    } label: {
      Label(label, systemImage: "arrow.up.right.square")
    }.buttonStyle(.bordered).controlSize(.regular)
      .help(CambridgeDictionary.lookupURL(for: word) == nil
        ? "Cambridge Dictionaryの英英辞書検索ページを開く"
        : "「\(word)」をCambridge Dictionaryの英英辞書で調べる")
      .accessibilityLabel(CambridgeDictionary.lookupURL(for: word) == nil
        ? "Cambridge Dictionaryを開く" : "Cambridge Dictionaryで「\(word)」を調べる")
      .popover(item: $request, arrowEdge: .bottom) { request in
        CambridgePopup(request: request).id(request.id)
      }
      .alert("辞書を開けませんでした", isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
  }
}

private struct CambridgePopup: View {
  let request: CambridgeLookupRequest
  @Environment(\.dismiss) private var dismiss
  @StateObject private var session: DictionaryWebSession
  @State private var browserError: String?
  init(request: CambridgeLookupRequest) {
    self.request = request
    _session = StateObject(wrappedValue: DictionaryWebSession(url: request.url))
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(request.word).font(.headline)
          Text("Cambridge Dictionary · 英英辞書").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
          .disabled(!session.canGoBack).help("前のページ")
        Button { session.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
          .help("再読み込み")
        Button("ブラウザで開く", systemImage: "safari") {
          let url = session.webView.url ?? request.url
          Task { @MainActor in
            do { try await DictionaryBrowser.open(url, destination: .system) }
            catch { browserError = error.localizedDescription }
          }
        }.help("システムのデフォルトブラウザでこのページを開く")
        Button { dismiss() } label: { Image(systemName: "xmark") }.help("辞書を閉じる")
          .keyboardShortcut(.cancelAction)
      }.padding(12)
      Divider()
      if session.loading { ProgressView().progressViewStyle(.linear) }
      DictionaryWebView(session: session)
        .overlay {
          if let error = session.error {
            ContentUnavailableView("辞書ページを読み込めませんでした", systemImage: "wifi.exclamationmark",
              description: Text(error))
              .background(Color(nsColor: .windowBackgroundColor))
          }
        }
    }.frame(width: 780, height: 640)
      .onDisappear { session.close() }
      .alert("ブラウザを開けませんでした", isPresented: Binding(
        get: { browserError != nil }, set: { if !$0 { browserError = nil } }
      )) { Button("OK") { browserError = nil } } message: { Text(browserError ?? "") }
  }
}

@MainActor final class DictionaryWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  let webView = WKWebView()
  @Published var loading = true
  @Published var error: String?
  @Published var canGoBack = false
  init(url: URL) {
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.load(URLRequest(url: url))
  }
  func close() {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    // A dismissed popover can be retained by SwiftUI. Tear down its page and audio anyway.
    webView.loadHTMLString("", baseURL: nil)
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    error = nil
    loading = true
    canGoBack = webView.canGoBack
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loading = false
    canGoBack = webView.canGoBack
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failed(error)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
  private func failed(_ error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    self.error = error.localizedDescription
    loading = false
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      webView.load(navigationAction.request)
    }
    return nil
  }
}

private struct DictionaryWebView: NSViewRepresentable {
  let session: DictionaryWebSession
  func makeNSView(context: Context) -> WKWebView { session.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}
