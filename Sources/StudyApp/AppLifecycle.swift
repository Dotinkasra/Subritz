import AppKit
import SwiftUI

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
  weak var model: StudyModel?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    guard !model.hasOpenVideo || confirmVideoExit(quitting: true) else { return .terminateCancel }
    model.flushAPIKey()
    model.closeVideo()
    return .terminateNow
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
    init(model: StudyModel) { self.model = model }
    func attach(_ window: NSWindow) {
      guard window.delegate !== self else { return }
      originalDelegate = window.delegate
      window.delegate = self
      window.title = "Subritz"
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
  var body: some Commands {
    CommandGroup(replacing: .sidebar) {}
    CommandGroup(replacing: .help) {}
    CommandGroup(replacing: .appInfo) {
      Button(String(localized: "About Subritz")) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Subritz"])
      }
    }
    CommandGroup(replacing: .newItem) {
      Button(String(localized: "Close Video")) { model.confirmCloseVideo = true }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(!model.hasOpenVideo)
    }
  }
}
