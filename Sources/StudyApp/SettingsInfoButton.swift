import SwiftUI

struct SettingsInfoButton: View {
  let title: String
  let message: String
  @State private var showingInfo = false
  var body: some View {
    Button { showingInfo.toggle() } label: {
      Image(systemName: "info.circle").font(.system(size: 13))
        .foregroundStyle(.secondary).padding(3).contentShape(Rectangle())
    }.buttonStyle(.plain).help(message).accessibilityLabel(title)
      .popover(isPresented: $showingInfo) {
        Text(message).font(.callout).textSelection(.enabled)
          .padding(16).frame(width: 340, alignment: .leading)
      }
  }
}
