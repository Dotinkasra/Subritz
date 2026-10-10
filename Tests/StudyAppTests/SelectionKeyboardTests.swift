import AppKit
import Testing

@testable import StudyApp

@MainActor struct SelectionKeyboardTests {
  func key(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code))
  }
  @Test(arguments: [false, true]) func escapeClearsSelectionWithoutChangingPlayback(realtime: Bool) throws {
    _ = NSApplication.shared
    let (model, words) = try DictionaryPinTests().fixture(realtime: realtime)
    model.update(time: 0.1, duration: 2, state: 1)
    model.pinDictionaryRange(from: words[2].id, to: words[3].id)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let coordinator = MainWindowLifecycle.Coordinator(model: model)
    coordinator.attach(window)
    defer { coordinator.detach() }
    #expect(coordinator.handleKeyDown(try key(53, window: window)) == nil)
    #expect(!model.dictionaryIsPinned && model.hoverToken == nil)
    #expect(model.displayedToken?.id == (realtime ? words[0].id : nil))
    #expect(model.playing && model.time == 0.1 && model.ready)
    // Without a selection, Escape remains available to other controls.
    #expect(coordinator.handleKeyDown(try key(53, window: window)) != nil)
  }
  @Test func otherWindowsKeysAndModifiedEscapeKeepSelection() throws {
    _ = NSApplication.shared
    let (model, words) = try DictionaryPinTests().fixture(realtime: false)
    model.pinDictionary(words[1])
    let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let coordinator = MainWindowLifecycle.Coordinator(model: model)
    coordinator.attach(main)
    defer { coordinator.detach() }
    #expect(coordinator.handleKeyDown(try key(53, window: settings)) != nil)
    #expect(coordinator.handleKeyDown(try key(36, window: main)) != nil)
    #expect(coordinator.handleKeyDown(try key(53, window: main, modifiers: .command)) != nil)
    #expect(model.pinnedToken?.id == words[1].id)
    coordinator.detach()
    #expect(coordinator.handleKeyDown(try key(53, window: main)) != nil)
    #expect(model.pinnedToken?.id == words[1].id)
  }
  @Test func escapeClosesSearchBeforeUnpinningDictionaryAndKeepsQuery() throws {
    _ = NSApplication.shared
    let (model, words) = try DictionaryPinTests().fixture(realtime: false)
    defer { model.closeVideo() }
    model.pinDictionary(words[1])
    model.openSubtitleSearch()
    model.setSubtitleSearchQuery("study")
    let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let coordinator = MainWindowLifecycle.Coordinator(model: model)
    coordinator.attach(main)
    defer { coordinator.detach() }
    #expect(coordinator.handleKeyDown(try key(53, window: other)) != nil)
    #expect(coordinator.handleKeyDown(try key(53, window: main, modifiers: .command)) != nil)
    #expect(model.subtitleSearchVisible)
    #expect(coordinator.handleKeyDown(try key(53, window: main)) == nil)
    #expect(!model.subtitleSearchVisible && model.subtitleSearchQuery == "study")
    #expect(model.subtitleSearchResults.highlights.isEmpty && model.pinnedToken?.id == words[1].id)
    model.openSubtitleSearch()
    #expect(model.subtitleSearchQuery == "study" && model.subtitleSearchResults.matches.count == 1)
  }
}
