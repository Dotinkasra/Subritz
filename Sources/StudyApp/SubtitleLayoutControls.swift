import StudyCore
import SwiftUI

struct SubtitleLayoutControls: View {
  @ObservedObject var model: StudyModel
  @State private var showingAdjustments = false
  @State private var confirmingReset = false
  var body: some View {
    HStack(spacing: 6) {
      Button("表示調整", systemImage: "slider.horizontal.3") { showingAdjustments.toggle() }
        .help("字幕の行間・1行の文字数・文字サイズを調整")
        .popover(isPresented: $showingAdjustments, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Text("字幕の表示調整").font(.headline)
              Spacer()
              Text(model.isLiveSpeech ? "音声認識" : "YouTube").font(.caption).foregroundStyle(
                .secondary)
            }
            parameter(
              "文字サイズ",
              value:
                "\(Int(SubtitleAppearance.fontSize(current: true, scale: model.subtitleFontScale).rounded())) pt"
            ) {
              Slider(
                value: Binding(
                  get: { model.subtitleFontScale }, set: { model.setSubtitleFontScale($0) }),
                in: SubtitleAppearance.fontScaleRange
              )
              .accessibilityLabel("字幕の文字サイズ")
            }
            parameter("1行の文字数", value: model.subtitleWrapCharacters == SubtitleAppearance.characterRange.upperBound ? "画面幅いっぱい" : "約\(model.subtitleWrapCharacters)文字") {
              Slider(
                value: Binding(
                  get: { Double(model.subtitleWrapCharacters) },
                  set: { model.setSubtitleWrapCharacters($0) }),
                in: Double(
                  SubtitleAppearance.characterRange.lowerBound)...Double(
                    SubtitleAppearance.characterRange.upperBound), step: 1
              )
              .accessibilityLabel("字幕1行の文字数")
            }
            parameter(
              "行間",
              value: model.subtitleRowSpacing == 1
                ? "標準（最大）" : "\(Int(model.subtitleRowSpacing * 100))%"
            ) {
              Slider(
                value: Binding(
                  get: { model.subtitleRowSpacing }, set: { model.setSubtitleRowSpacing($0) }),
                in: 0...1
              )
              .accessibilityLabel("字幕の行間")
            }
            HStack {
              Button("初期レイアウトに戻す", systemImage: "arrow.counterclockwise") {
                showingAdjustments = false
                confirmingReset = true
              }.help("カラム配置と字幕表示を初期レイアウトに戻す")
              Spacer()
              Button("完了") { showingAdjustments = false }.keyboardShortcut(.cancelAction)
            }
          }.padding(18).frame(width: 350)
        }
    }.controlSize(.small).fixedSize()
      .alert("レイアウトを初期状態に戻しますか？", isPresented: $confirmingReset) {
        Button("キャンセル", role: .cancel) {}
        Button("OK") { model.resetWorkspaceLayout() }.keyboardShortcut(.defaultAction)
      } message: {
        Text("カラムの幅・高さと、YouTube・音声認識の字幕の行間・1行の文字数・文字サイズを初期値に戻します。")
      }
  }
  private func parameter<Control: View>(
    _ title: String, value: String, @ViewBuilder control: () -> Control
  ) -> some View {
    VStack(spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text(value).monospacedDigit().foregroundStyle(.secondary)
      }
      .font(.callout)
      control().controlSize(.small)
    }
  }
}

struct SoftCloseButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.callout.weight(.medium))
      .padding(.horizontal, 10).padding(.vertical, 5)
      .foregroundStyle(
        !isEnabled ? Color.gray : colorScheme == .dark
          ? Color(red: 0.96, green: 0.70, blue: 0.71) : Color(red: 0.56, green: 0.22, blue: 0.24)
      )
      .background(
        isEnabled
          ? Color(red: 0.80, green: 0.40, blue: 0.43).opacity(configuration.isPressed ? 0.32 : 0.18)
          : Color.gray.opacity(0.10),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 5))
  }
}
