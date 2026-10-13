import AppKit
import SwiftUI

// NSMenuItem.image preserves native icon alignment in both the menu and button.
struct DictionaryBrowserPicker: NSViewRepresentable {
  @Binding var selection: String
  let applications: [DictionaryBrowser.Application]

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.setAccessibilityLabel("辞書を開く際のブラウザ")
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    let menu = NSMenu()
    func add(_ title: String, id: String, image: NSImage?) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.representedObject = id
      let icon = image?.copy() as? NSImage
      icon?.size = NSSize(width: 18, height: 18)
      item.image = icon
      menu.addItem(item)
    }
    add("システムのデフォルト", id: "system",
      image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil))
    add("アプリ内ポップアップ", id: "popup",
      image: NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil))
    menu.addItem(.separator())
    let nameCounts = Dictionary(grouping: applications, by: \.name).mapValues(\.count)
    for app in applications {
      let title = nameCounts[app.name, default: 0] > 1 && !app.version.isEmpty
        ? "\(app.name) (\(app.version))" : app.name
      add(title, id: app.id, image: app.icon)
      menu.items.last?.toolTip = app.url.path
    }
    // Old preferences were bundle IDs. Show their resolved installed copy without
    // silently changing the saved preference merely by opening Settings.
    var selected = menu.items.first { $0.representedObject as? String == selection }
    if selected == nil, selection.hasPrefix("browser:"),
      let resolved = try? DictionaryBrowser.destination(for: selection),
      case .application(let url) = resolved,
      let app = applications.first(where: { $0.url == url.standardizedFileURL }) {
      selected = menu.items.first { $0.representedObject as? String == app.id }
    }
    if selected == nil {
      add("利用できないブラウザ", id: selection,
        image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil))
      selected = menu.items.last
    }
    button.menu = menu
    button.select(selected)
  }
  final class Coordinator: NSObject {
    var selection: Binding<String>
    init(selection: Binding<String>) { self.selection = selection }
    @objc func choose(_ sender: NSPopUpButton) {
      guard let id = sender.selectedItem?.representedObject as? String else { return }
      selection.wrappedValue = id
    }
  }
}
