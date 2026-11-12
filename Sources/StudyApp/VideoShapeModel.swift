import AppKit
import StudyCore

@MainActor final class VideoShapeModel: ObservableObject {
  struct State: Equatable {
    var shape: VideoMaskShape?
    var template: VideoMaskShape
    var visible = true
  }
  @Published private(set) var state: State
  @Published var selected = false
  @Published private(set) var focusRequest = 0
  @Published private(set) var protectedControls: [CGRect] = []
  @Published private(set) var historyRevision = 0
  let undoManager = UndoManager()
  var colorPanelActive = false
  weak var controlsWindow: NSWindow?
  var onTemplateChange: ((VideoMaskShape) -> Void)?
  var onVisibilityChange: ((Bool) -> Void)?
  private var editing: (before: State, name: String)?
  var shape: VideoMaskShape? { state.shape }
  var visible: Bool { state.visible && shape != nil }

  init(template: VideoMaskShape) {
    state = State(template: template.normalized)
    undoManager.groupsByEvent = false
    undoManager.levelsOfUndo = 100
  }
  private func set(_ next: State) {
    let wasVisible = visible
    state = next
    if visible != wasVisible { onVisibilityChange?(visible) }
  }
  private func persist() { onTemplateChange?(state.template) }
  private func register(_ before: State, name: String) {
    let grouping = !undoManager.isUndoing && !undoManager.isRedoing
    if grouping { undoManager.beginUndoGrouping() }
    undoManager.registerUndo(withTarget: self) { target in target.restore(before, name: name) }
    undoManager.setActionName(name)
    if grouping { undoManager.endUndoGrouping() }
    historyRevision += 1
  }
  private func restore(_ snapshot: State, name: String) {
    let previous = state
    set(snapshot)
    selected = visible
    register(previous, name: name)
    persist()
    focusRequest += 1
  }
  private func change(_ next: State, name: String) {
    finishEditing()
    guard next != state else { return }
    let before = state
    set(next)
    register(before, name: name)
    persist()
  }
  func add() {
    guard shape == nil else { selected = visible; focusRequest += 1; return }
    change(State(shape: state.template, template: state.template), name: "シェイプを追加")
    selected = true
    focusRequest += 1
  }
  func delete() {
    finishEditing()
    guard let shape else { return }
    change(State(template: shape), name: "シェイプを削除")
    selected = false
  }
  func setVisible(_ visible: Bool) {
    guard shape != nil else { return }
    var next = state; next.visible = visible
    change(next, name: visible ? "シェイプを表示" : "シェイプを非表示")
    if !visible { selected = false }
  }
  func beginEditing(_ name: String) {
    if editing?.name != name { finishEditing(); editing = (state, name) }
  }
  func preview(_ shape: VideoMaskShape) {
    guard state.shape != nil else { return }
    var next = state; next.shape = shape.normalized; next.template = shape.normalized
    set(next)
  }
  func finishEditing() {
    guard let editing else { return }
    self.editing = nil
    guard state != editing.before else { return }
    register(editing.before, name: editing.name)
    persist()
  }
  func setOpacity(_ opacity: Double) {
    guard var shape else { return }
    beginEditing("シェイプの透明度を変更")
    shape.opacity = opacity
    preview(shape)
  }
  func setColor(_ color: NSColor) {
    guard var shape, let rgb = color.usingColorSpace(.sRGB) else { return }
    beginEditing("シェイプの色を変更")
    shape.red = rgb.redComponent; shape.green = rgb.greenComponent; shape.blue = rgb.blueComponent
    preview(shape)
  }
  func undo() { finishEditing(); if undoManager.canUndo { undoManager.undo(); historyRevision += 1 } }
  func redo() { finishEditing(); if undoManager.canRedo { undoManager.redo(); historyRevision += 1 } }
  func reset(template: VideoMaskShape? = nil) {
    finishEditing()
    set(State(template: template?.normalized ?? state.template))
    selected = false
    protectedControls = []
    undoManager.removeAllActions()
    historyRevision += 1
  }
  func setProtectedControls(_ rects: [CGRect]) {
    // Non-overlapping holes keep clipping and hit testing in agreement.
    var merged: [CGRect] = []
    for rect in rects {
      var next = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !next.isNull, !next.isEmpty else { continue }
      var index = 0
      while index < merged.count {
        if next.intersects(merged[index]) {
          next = next.union(merged.remove(at: index))
          index = 0
        } else { index += 1 }
      }
      merged.append(next)
    }
    if protectedControls != merged { protectedControls = merged }
  }
  func handleKey(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let flags = modifiers.intersection([.command, .shift, .option, .control])
    if code == 6, flags == .command || flags == [.command, .shift] {
      finishEditing()
      if flags.contains(.shift), undoManager.canRedo { redo(); return true }
      if !flags.contains(.shift), undoManager.canUndo { undo(); return true }
    }
    if [51, 117].contains(code), flags.isEmpty, selected, visible { delete(); return true }
    return false
  }
}
