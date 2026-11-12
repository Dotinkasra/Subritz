import AppKit
import StudyCore
import SwiftUI

struct VideoShapeControls: View {
  @ObservedObject var model: VideoShapeModel
  @State private var showing = false
  var body: some View {
    Button("字幕マスク", systemImage: "square.on.circle.fill") { showing.toggle() }
      .labelStyle(.iconOnly).help("動画に重ねる字幕マスクのシェイプを操作")
      .accessibilityLabel("字幕マスクのシェイプ")
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 16) {
          Text("字幕マスク").font(.headline)
          HStack {
            Button("追加", systemImage: "plus.rectangle") { model.add(); showing = false }
              .disabled(model.shape != nil)
            Button {
              model.setVisible(!model.visible)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: model.visible ? "eye.slash" : "eye")
                  .frame(width: 16, height: 16).accessibilityHidden(true)
                // Reserve the longer label's width in both states.
                Text("非表示").hidden()
                  .overlay { Text(model.visible ? "非表示" : "表示") }
              }.fixedSize()
            }.accessibilityLabel(model.visible ? "非表示" : "表示")
              .disabled(model.shape == nil)
            Button("削除", systemImage: "trash", role: .destructive) { model.delete() }
              .disabled(model.shape == nil)
          }
          HStack {
            Text("カラー")
            Spacer()
            VideoShapeColorWell(model: model).frame(width: 52, height: 26)
              .disabled(model.shape == nil)
          }
          VStack(spacing: 6) {
            HStack { Text("不透明度"); Spacer(); Text("\(Int((model.shape?.opacity ?? model.state.template.opacity) * 100))%").monospacedDigit() }
            Slider(value: Binding(get: { model.shape?.opacity ?? model.state.template.opacity }, set: { model.setOpacity($0) }),
              in: 0...1, onEditingChanged: { editing in
                if editing { model.beginEditing("シェイプの透明度を変更") } else { model.finishEditing() }
              }).disabled(model.shape == nil).accessibilityLabel("シェイプの不透明度")
          }
          HStack {
            Button("取り消す", systemImage: "arrow.uturn.backward") { model.undo() }
              .disabled(!model.undoManager.canUndo)
            Button("やり直す", systemImage: "arrow.uturn.forward") { model.redo() }
              .disabled(!model.undoManager.canRedo)
            Spacer()
            Button("完了") { showing = false }.keyboardShortcut(.cancelAction)
          }
        }.padding(18).frame(width: 320)
          .background(ShapeControlsWindow(model: model))
          .onDisappear { model.finishEditing(); model.controlsWindow = nil }
      }
  }
}

private struct ShapeControlsWindow: NSViewRepresentable {
  let model: VideoShapeModel
  func makeNSView(context: Context) -> MainWindowLifecycle.WindowProbe {
    let probe = MainWindowLifecycle.WindowProbe()
    probe.onWindow = { [weak model] window in model?.controlsWindow = window }
    return probe
  }
  func updateNSView(_ view: MainWindowLifecycle.WindowProbe, context: Context) {}
}

private struct VideoShapeColorWell: NSViewRepresentable {
  let model: VideoShapeModel
  func makeNSView(context: Context) -> ShapeColorWell {
    let well = ShapeColorWell()
    well.model = model
    well.target = well; well.action = #selector(ShapeColorWell.colorChanged)
    well.isContinuous = true
    well.setAccessibilityLabel("シェイプのカラー")
    return well
  }
  func updateNSView(_ view: ShapeColorWell, context: Context) {
    let color = model.shape ?? model.state.template
    view.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    view.isEnabled = model.shape != nil
  }
  static func dismantleNSView(_ view: ShapeColorWell, coordinator: ()) { view.deactivate() }

  final class ShapeColorWell: NSColorWell {
    weak var model: VideoShapeModel?
    override func activate(_ exclusive: Bool) {
      model?.beginEditing("シェイプの色を変更")
      model?.colorPanelActive = true
      NSColorPanel.shared.showsAlpha = false
      super.activate(exclusive)
    }
    override func deactivate() {
      model?.finishEditing(); model?.colorPanelActive = false
      super.deactivate()
    }
    @objc func colorChanged() { model?.setColor(color) }
  }
}
