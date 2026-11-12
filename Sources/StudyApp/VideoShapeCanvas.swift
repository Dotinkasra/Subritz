import AppKit
import StudyCore

/// One native surface makes click-through independent of SwiftUI overlay routing.
@MainActor final class VideoPlayerSurface: NSView {
  let player: NSView
  let canvas: VideoShapeCanvas
  init(player: NSView, model: VideoShapeModel) {
    self.player = player
    canvas = VideoShapeCanvas(model: model)
    super.init(frame: .zero)
    player.autoresizingMask = [.width, .height]
    canvas.autoresizingMask = [.width, .height]
    addSubview(player)
    addSubview(canvas)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    player.frame = bounds
    canvas.frame = bounds
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    return canvas.hitTest(local) ?? player.hitTest(local)
  }
}

/// A passive overlay outside the shape. No mouse-move polling, layout of
/// subtitles, or redraw tied to playback is needed.
@MainActor final class VideoShapeCanvas: NSView {
  let model: VideoShapeModel
  var enabled = true
  var focusRequest = 0
  private var clickMonitor: Any?
  private var startPoint: CGPoint?
  private var startShape: VideoMaskShape?
  private var corner: VideoMaskShape.Corner?
  private struct Appearance: Equatable {
    var shape: VideoMaskShape?
    var selected: Bool
    var visible: Bool
    var controls: [CGRect]
  }
  private var drawnAppearance: Appearance?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var undoManager: UndoManager? { model.undoManager }
  init(model: VideoShapeModel) {
    self.model = model
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("字幕マスクのシェイプ")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func refresh(enabled: Bool) {
    self.enabled = enabled
    let next = Appearance(shape: model.shape, selected: model.selected,
      visible: enabled && model.visible, controls: model.protectedControls)
    if drawnAppearance != next {
      drawnAppearance = next
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
    }
    if focusRequest != model.focusRequest {
      focusRequest = model.focusRequest
      if enabled, model.selected { window?.makeFirstResponder(self) }
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private var shapeRect: CGRect? {
    enabled && model.visible ? model.shape?.rect(in: bounds.size) : nil
  }
  private func handles(_ rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
  }
  private func handle(at point: CGPoint, rect: CGRect) -> VideoMaskShape.Corner? {
    guard model.selected else { return nil }
    return VideoMaskShape.Corner.allCases.first {
      let center = handles(rect)[$0.rawValue]
      return hypot(point.x - center.x, point.y - center.y) <= 10
    }
  }
  func playerControl(at point: CGPoint) -> Bool {
    // Keep activation strips available even before YouTube fades its controls in.
    if point.y < min(40, bounds.height * 0.12) || point.y > bounds.height - min(48, bounds.height * 0.18) { return true }
    return model.protectedControls.contains {
      CGRect(x: $0.minX * bounds.width, y: $0.minY * bounds.height,
        width: $0.width * bounds.width, height: $0.height * bounds.height).contains(point)
    }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    intercepts(convert(point, from: superview)) ? self : nil
  }
  func intercepts(_ point: NSPoint) -> Bool {
    guard let rect = shapeRect, bounds.contains(point), !playerControl(at: point) else { return false }
    return rect.contains(point) || handle(at: point, rect: rect) != nil
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    guard window != nil else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, event.window === self.window, self.model.selected else { return event }
      let point = self.convert(event.locationInWindow, from: nil)
      if self.bounds.contains(point), !self.intercepts(point) { self.model.selected = false }
      return event
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill(using: .copy)
    guard let rect = shapeRect, let shape = model.shape else { return }
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(rect: bounds)
    clip.windingRule = .evenOdd
    for normalized in model.protectedControls {
      clip.appendRect(CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height,
        width: normalized.width * bounds.width, height: normalized.height * bounds.height))
    }
    clip.addClip()
    NSColor(srgbRed: shape.red, green: shape.green, blue: shape.blue, alpha: shape.opacity).setFill()
    rect.fill()
    if model.selected {
      NSColor.controlAccentColor.setStroke()
      let outline = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75)); outline.lineWidth = 1.5; outline.stroke()
      for point in handles(rect) {
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        NSColor.white.setFill(); circle.fill(); circle.lineWidth = 1.5; circle.stroke()
      }
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  override func resetCursorRects() {
    guard let rect = shapeRect else { return }
    if model.selected {
      for point in handles(rect) where !playerControl(at: point) {
        addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16), cursor: .crosshair)
      }
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard let rect = shapeRect else { return }
    let point = convert(event.locationInWindow, from: nil)
    model.selected = true
    window?.makeFirstResponder(self)
    startPoint = point
    startShape = model.shape
    corner = handle(at: point, rect: rect)
    model.beginEditing(corner == nil ? "シェイプを移動" : "シェイプのサイズを変更")
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let startPoint, let shape = startShape else { return }
    let point = convert(event.locationInWindow, from: nil)
    let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
    model.preview(corner.map { shape.resized(at: $0, by: delta, in: bounds.size) }
      ?? shape.moved(by: delta, in: bounds.size))
  }
  override func mouseUp(with event: NSEvent) {
    model.finishEditing()
    startShape = nil; startPoint = nil; corner = nil
  }
  @objc func undo(_ sender: Any?) { model.undo() }
  @objc func redo(_ sender: Any?) { model.redo() }
  deinit { if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }
}
