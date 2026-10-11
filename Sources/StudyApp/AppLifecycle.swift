import AppKit
import SwiftUI

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
  weak var model: StudyModel?
  private var terminating = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let icon = AppArtwork.icon { NSApp.applicationIconImage = icon }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateLater }
    guard let model else { return .terminateNow }
    guard !model.hasOpenVideo || confirmVideoExit(quitting: true) else { return .terminateCancel }
    model.flushAPIKey()
    model.closeVideo()
    terminating = true
    Task {
      await model.libraryOperation?.value
      var shouldQuit = true
      if let error = model.libraryError {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "学習記録を保存できませんでした"
        alert.informativeText = error + "\n保存されていない記録がある可能性があります。終了しますか？"
        alert.addButton(withTitle: "終了しない")
        alert.addButton(withTitle: "終了")
        shouldQuit = alert.runModal() == .alertSecondButtonReturn
      }
      terminating = false
      sender.reply(toApplicationShouldTerminate: shouldQuit)
    }
    return .terminateLater
  }
}

@MainActor enum AppArtwork {
  // Read the bundled artwork directly. NSApplicationIcon may still contain the
  // generic icon cached when this development bundle was first registered.
  static let icon: NSImage? = {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
    return NSImage(contentsOf: url)
  }()
  static var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "Subritz"]
    if let icon { options[.applicationIcon] = icon }
    return options
  }
}

@MainActor func confirmVideoExit(quitting: Bool) -> Bool {
  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = quitting ? "動画を閉じてSubritzを終了しますか？" : "本当に動画を閉じますか？"
  alert.informativeText = "動画が読み込まれています。字幕の解析と再生を終了します。保存済みのキャッシュは残ります。"
  alert.addButton(withTitle: "キャンセル")
  alert.addButton(withTitle: quitting ? "終了" : "動画を閉じる")
  return alert.runModal() == .alertSecondButtonReturn
}

struct MainWindowLifecycle: NSViewRepresentable {
  let model: StudyModel
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> WindowProbe {
    let probe = WindowProbe()
    probe.onWindow = { [weak coordinator = context.coordinator] window in
      coordinator?.attach(window)
    }
    return probe
  }
  func updateNSView(_ view: WindowProbe, context: Context) {}
  static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) {
    view.onWindow = nil
    coordinator.detach()
  }
  final class WindowProbe: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { onWindow?(window) }
    }
  }
  @MainActor final class Coordinator: NSObject, NSWindowDelegate {
    weak var model: StudyModel?
    weak var originalDelegate: NSWindowDelegate?
    weak var window: NSWindow?
    private var keyMonitor: Any?
    init(model: StudyModel) { self.model = model }
    func attach(_ window: NSWindow) {
      guard self.window !== window else { return }
      detach()
      self.window = window
      originalDelegate = window.delegate
      window.delegate = self
      window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Subritz"
      // Native subtitle buttons and the embedded player may hold keyboard focus.
      // Close Find before clearing a dictionary selection. Sheets and other
      // windows retain their own Escape handling.
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handleKeyDown(event)
      }
    }
    func detach() {
      if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
      keyMonitor = nil
      if window?.delegate === self { window?.delegate = originalDelegate }
      window = nil
      originalDelegate = nil
    }
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
      guard event.keyCode == 53,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        let window, event.window === window, window.attachedSheet == nil,
        let model else { return event }
      if model.subtitleSearchVisible {
        model.closeSubtitleSearch()
        return nil
      }
      guard model.dictionaryIsPinned else { return event }
      model.releaseDictionaryPin()
      return nil
    }
    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
      originalDelegate?.responds(to: selector) == true
        ? originalDelegate : super.forwardingTarget(for: selector)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if let model, model.hasOpenVideo {
        guard confirmVideoExit(quitting: false) else { return false }
        model.closeVideo()
      }
      return originalDelegate?.windowShouldClose?(sender) ?? true
    }
  }
}

@MainActor final class WindowReference {
  weak var value: NSWindow?
}

struct SettingsWindowTitle: NSViewRepresentable {
  let window: WindowReference
  func makeNSView(context: Context) -> MainWindowLifecycle.WindowProbe {
    let view = MainWindowLifecycle.WindowProbe()
    view.onWindow = {
      $0.title = "Subritz — 設定"
      window.value = $0
    }
    return view
  }
  func updateNSView(_ view: MainWindowLifecycle.WindowProbe, context: Context) {}
}

struct SubritzCommands: Commands {
  @ObservedObject var model: StudyModel
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(replacing: .sidebar) {}
    CommandGroup(replacing: .help) {}
    CommandGroup(replacing: .appInfo) {
      Button(String(localized: "About Subritz")) {
        NSApp.orderFrontStandardAboutPanel(options: AppArtwork.aboutOptions)
      }
    }
    CommandGroup(after: .textEditing) {
      Button(String(localized: "Find in Subtitles")) {
        openWindow(id: "main")
        model.openSubtitleSearch()
      }.keyboardShortcut("f", modifiers: .command).disabled(!model.ready)
    }
    CommandMenu(String(localized: "Library")) {
      Button(String(localized: "Video History")) {
        model.librarySection = .history
        openWindow(id: "library")
      }.keyboardShortcut("h", modifiers: [.command, .shift])
      Button(String(localized: "Timestamps")) {
        model.librarySection = .timestamps
        openWindow(id: "library")
      }
      Button(String(localized: "Favorite Words")) {
        model.librarySection = .favorites
        openWindow(id: "library")
      }.keyboardShortcut("b", modifiers: [.command, .shift])
      Divider()
      Button(String(localized: "Toggle Favorite Word")) { model.toggleDisplayedFavorite() }
        .keyboardShortcut("d", modifiers: .command).disabled(!model.canToggleDisplayedFavorite)
    }
    CommandGroup(replacing: .newItem) {
      Button(String(localized: "Close Video")) { model.confirmCloseVideo = true }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(!model.hasOpenVideo)
    }
  }
}
