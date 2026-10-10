import Combine
import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

@MainActor struct PlaybackInvalidationTests {
  private func fixture() throws -> StudyModel {
    let (model, _) = try DictionaryPinTests().fixture(realtime: true)
    model.grammarEnabledForVideo = false
    for token in model.timeline!.tokens { model.expressionMisses.insert(token.id) }
    model.update(time: 0.1, duration: 2, state: 1)
    return model
  }

  @Test func clockTicksOnlyInvalidatePositionUntilWordActuallyChanges() throws {
    let model = try fixture()
    defer { model.closeVideo() }
    var studyChanges = 0
    var positionChanges = 0
    let studySubscription = model.objectWillChange.sink { studyChanges += 1 }
    let positionSubscription = model.playbackPosition.objectWillChange.sink { positionChanges += 1 }
    let first = model.currentToken?.id
    // The synchronization loop retains its 30 Hz frequency. Only the seek bar
    // needs notifications while the sentence, word, and playback state stay fixed.
    for tick in 1...10 {
      model.update(time: 0.1 + Double(tick) / 30, duration: 2, state: 1)
    }
    #expect(studyChanges == 0)
    #expect(positionChanges >= 2)
    #expect(model.time > 0.3 && model.currentToken?.id == first)
    model.update(time: 0.46, duration: 2, state: 1)
    #expect(studyChanges > 0 && model.currentToken?.id != first)
    #expect(model.dictionaryEntry?.shortGloss == "study")
    withExtendedLifetime((studySubscription, positionSubscription)) {}
  }

  @Test func pauseDurationAndSeekStillPublishToTheirConsumers() throws {
    let model = try fixture()
    defer { model.closeVideo() }
    var studyChanges = 0
    var positionChanges = 0
    let studySubscription = model.objectWillChange.sink { studyChanges += 1 }
    let positionSubscription = model.playbackPosition.objectWillChange.sink { positionChanges += 1 }
    model.update(time: 0.1, duration: 3, state: 1)
    #expect(studyChanges == 0 && positionChanges == 1 && model.duration == 3)
    model.update(time: 0.1, duration: 3, state: 2)
    #expect(studyChanges == 1 && !model.playing)
    let before = studyChanges
    for _ in 0..<60 { model.update(time: 0.1, duration: 3, state: 2) }
    #expect(studyChanges == before)
    model.seek(1.1)
    #expect(model.time == 1.1 && model.playbackPosition.time == 1.1)
    #expect(model.currentLineIndex == 1 && model.currentToken?.surface == "You")
    #expect(model.bridge.pendingSeekTime == 1.1)
    #expect(model.dictionaryEntry?.shortGloss == "You")
    withExtendedLifetime((studySubscription, positionSubscription)) {}
  }
}
