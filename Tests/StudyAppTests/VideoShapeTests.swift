import AppKit
import Combine
import SwiftUI
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct VideoShapeTests {
  @Test func oneShapeRemembersItsLastAppearanceAndSupportsUndoRedo() throws {
    let model = VideoShapeModel(template: .initial)
    model.add()
    let original = try #require(model.shape)
    model.add()
    #expect(model.shape == original)
    model.beginEditing("移動")
    model.preview(original.moved(by: CGSize(width: 15, height: -40), in: CGSize(width: 1000, height: 600)))
    model.finishEditing()
    model.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    model.finishEditing()
    model.setOpacity(0.7); model.finishEditing()
    let edited = try #require(model.shape)
    model.undo(); #expect(model.shape?.opacity == 1)
    model.redo(); #expect(model.shape == edited)
    model.setVisible(false); #expect(!model.visible && !model.selected)
    model.undo(); #expect(model.visible && model.shape == edited)
    model.delete(); #expect(model.shape == nil)
    model.undo(); #expect(model.shape == edited && model.selected)
    model.redo(); #expect(model.shape == nil)
    model.add(); #expect(model.shape == edited)
    #expect(!model.undoManager.canRedo)
    model.undo(); model.undo()
    #expect(model.shape == edited)
  }
  @Test func dragIsOneUndoAndDoesNotInvalidateThePlaybackModelOrWriteEachFrame() throws {
    let domain = "VideoShapeTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let study = StudyModel(prepareStorage: false, defaults: defaults)
    study.videoShape.add()
    let original = try #require(study.videoShape.shape)
    var studyChanges = 0, writes = 0
    let subscription = study.objectWillChange.sink { studyChanges += 1 }
    let persist = study.videoShape.onTemplateChange
    study.videoShape.onTemplateChange = { writes += 1; persist?($0) }
    study.videoShape.beginEditing("シェイプのサイズを変更")
    for pixel in 1...100 {
      study.videoShape.preview(original.resized(at: .topLeft,
        by: CGSize(width: pixel, height: -pixel), in: CGSize(width: 1000, height: 600)))
    }
    #expect(studyChanges == 0 && writes == 0)
    study.videoShape.finishEditing()
    #expect(writes == 1)
    let final = try #require(study.videoShape.shape)
    #expect(AppSettings.load(defaults: defaults).videoMaskTemplate == final)
    study.videoShape.undo(); #expect(study.videoShape.shape == original)
    study.videoShape.redo(); #expect(study.videoShape.shape == final)
    study.closeVideo()
    #expect(!study.bridge.shapeControlsEnabled && study.videoShape.shape == nil)
    #expect(!study.videoShape.undoManager.canUndo)
    let reopened = StudyModel(prepareStorage: false, defaults: defaults)
    reopened.videoShape.add(); #expect(reopened.videoShape.shape == final)
    withExtendedLifetime(subscription) {}
  }
  @Test func playerControlsWinEvenUnderTheShapeAndUncoveredVideoReceivesClicks() {
    let model = VideoShapeModel(template: VideoMaskShape(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
    model.add()
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
    let player = NSView(frame: parent.bounds)
    parent.addSubview(player)
    let canvas = VideoShapeCanvas(model: model)
    canvas.frame = CGRect(x: 30, y: 20, width: 1000, height: 600)
    parent.addSubview(canvas)
    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
      let point = parent.convert(CGPoint(x: x, y: y), from: canvas)
      return parent.hitTest(point)
    }
    #expect(hit(150, 200) === canvas)
    #expect(hit(20, 200) === player)
    #expect(hit(100, 120) === canvas) // corner handle
    #expect(hit(500, 580) === player) // control activation strip
    model.setProtectedControls([CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.2),
      CGRect(x: 0.6, y: 0.3, width: 0.3, height: 0.2)])
    #expect(model.protectedControls.count == 1)
    #expect(hit(250, 220) === player && hit(700, 220) === player)
    canvas.enabled = false; #expect(hit(150, 200) === player)
    canvas.enabled = true; model.setVisible(false); #expect(hit(150, 200) === player)
  }
  @Test func swiftUISurfaceRoutesClicksToTheShapeOrUnderlyingPlayer() throws {
    _ = NSApplication.shared
    let model = VideoShapeModel(template: VideoMaskShape(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
    model.add()
    let player = ShapeHitTarget(frame: .zero)
    let host = NSHostingView(rootView: ShapeHitFixture(player: player, model: model))
    host.frame = CGRect(x: 0, y: 0, width: 800, height: 450)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func findCanvas(_ view: NSView) -> VideoShapeCanvas? {
      if let canvas = view as? VideoShapeCanvas { return canvas }
      return view.subviews.lazy.compactMap { findCanvas($0) }.first
    }
    let canvas = try #require(findCanvas(host))
    let shapeHit = host.hitTest(host.convert(CGPoint(x: 120, y: 180), from: canvas)) === canvas
    let outsideHit = host.hitTest(host.convert(CGPoint(x: 20, y: 180), from: canvas)) === player
    #expect(shapeHit)
    #expect(outsideHit)
    model.setProtectedControls([CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)])
    let controlHit = host.hitTest(host.convert(CGPoint(x: 300, y: 200), from: canvas)) === player
    #expect(controlHit)
  }
  @Test func nativeDragAndCornerResizeAreIndividuallyUndoable() throws {
    _ = NSApplication.shared
    let model = VideoShapeModel(template: VideoMaskShape(x: 0.2, y: 0.3, width: 0.5, height: 0.3))
    model.add()
    let original = try #require(model.shape)
    let surface = VideoPlayerSurface(player: NSView(), model: model)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = surface; surface.layoutSubtreeIfNeeded()
    let canvas = surface.canvas
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
        modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    }
    canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 400, y: 240)))
    canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 500, y: 180)))
    canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 500, y: 180)))
    let moved = try #require(model.shape)
    #expect(abs(moved.x - 0.3) < 0.000001 && abs(moved.y - 0.2) < 0.000001)
    #expect(moved.width == original.width && moved.height == original.height)
    let corner = moved.rect(in: canvas.bounds.size).origin
    canvas.mouseDown(with: try event(.leftMouseDown, corner))
    canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: corner.x - 50, y: corner.y - 30)))
    canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: corner.x - 50, y: corner.y - 30)))
    #expect(model.shape?.width != moved.width && model.shape?.height != moved.height)
    model.undo(); #expect(model.shape == moved)
    model.undo(); #expect(model.shape == original)
    model.redo(); #expect(model.shape == moved)
  }
  @Test func shortcutsDoNotDeleteTextOrAffectOtherWindows() throws {
    _ = NSApplication.shared
    let model = StudyModel(prepareStorage: false)
    model.videoShape.add()
    let main = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let coordinator = MainWindowLifecycle.Coordinator(model: model)
    coordinator.attach(main)
    defer { coordinator.detach(); model.closeVideo() }
    let keys = SelectionKeyboardTests()
    #expect(coordinator.handleKeyDown(try keys.key(51, window: other)) != nil)
    #expect(coordinator.handleKeyDown(try keys.key(51, window: main, modifiers: .command)) != nil)
    let editor = NSTextView(frame: main.contentView!.bounds)
    main.contentView?.addSubview(editor); main.makeFirstResponder(editor)
    #expect(coordinator.handleKeyDown(try keys.key(51, window: main)) != nil)
    #expect(coordinator.handleKeyDown(try keys.key(6, window: main, modifiers: .command)) != nil)
    #expect(model.videoShape.shape != nil)
    main.makeFirstResponder(nil)
    #expect(coordinator.handleKeyDown(try keys.key(117, window: main)) == nil)
    #expect(model.videoShape.shape == nil)
    model.videoShape.controlsWindow = other
    #expect(coordinator.handleKeyDown(try keys.key(6, window: other, modifiers: .command)) == nil)
    #expect(model.videoShape.shape != nil)
    #expect(coordinator.handleKeyDown(try keys.key(6, window: other, modifiers: [.command, .shift])) == nil)
    #expect(model.videoShape.shape == nil)
    model.videoShape.controlsWindow = nil
    #expect(coordinator.handleKeyDown(try keys.key(6, window: main, modifiers: .command)) == nil)
    #expect(model.videoShape.shape != nil)
    #expect(coordinator.handleKeyDown(try keys.key(6, window: main, modifiers: [.command, .shift])) == nil)
    #expect(model.videoShape.shape == nil)
  }
  @Test func playerRegionsRequireTheCurrentSessionAndValidGeometry() {
    let bridge = PlayerBridge()
    var received: [CGRect] = []
    bridge.onShapeControls = { received = $0 }
    let values: [[String: Double]] = [["x": 0.9,"y": 0.8,"width": 0.3,"height": 0.5],
      ["x": 0,"y": 0,"width": .nan,"height": 0.5]]
    bridge.receive(["session": bridge.playbackID,"shapeControls": values])
    #expect(received.isEmpty)
    bridge.setShapeControlsEnabled(true)
    bridge.receive(["session": "old","shapeControls": values]); #expect(received.isEmpty)
    bridge.receive(["session": bridge.playbackID,"shapeControls": values])
    #expect(received.count == 1 && received[0].maxX == 1 && received[0].maxY == 1)
    bridge.setShapeControlsEnabled(false); #expect(received.isEmpty)
  }
}

@MainActor private final class ShapeHitTarget: NSView {}
private struct ShapeHitFixture: NSViewRepresentable {
  let player: ShapeHitTarget
  @ObservedObject var model: VideoShapeModel
  func makeNSView(context: Context) -> VideoPlayerSurface { VideoPlayerSurface(player: player, model: model) }
  func updateNSView(_ view: VideoPlayerSurface, context: Context) { view.canvas.refresh(enabled: true) }
}
