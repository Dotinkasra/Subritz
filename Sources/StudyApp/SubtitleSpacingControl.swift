import SwiftUI

struct SubtitleSpacingControl: View {
  @ObservedObject var model: StudyModel
  var body: some View {
    HStack(spacing: 8) {
      Text("字幕の行間")
      Image(systemName: "minus").foregroundStyle(.secondary).accessibilityHidden(true)
      Slider(value: Binding(get: { model.subtitleRowSpacing },
        set: { model.setSubtitleRowSpacing($0) }), in: 0...1)
        .controlSize(.small).frame(width: 150)
        .accessibilityLabel("字幕の行間")
        .accessibilityValue(model.subtitleRowSpacing == 1 ? "標準（最大）"
          : model.subtitleRowSpacing == 0 ? "狭い（最小）" : "\(Int(model.subtitleRowSpacing * 100))%")
      Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
    }.font(.caption).fixedSize()
      .help("左へ動かすと行間が狭くなります。右端が標準の行間です。")
  }
}
