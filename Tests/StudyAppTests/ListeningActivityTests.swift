import Foundation
import Testing
@testable import StudyApp
@testable import StudyCore

@MainActor struct ListeningActivityTests {
  @Test func playbackIndicatorFollowsCountedEnglishRatherThanPlayingOrDictionaryUpdates() async throws {
    let (model, root) = try ListeningIntegrationTests().fixture()
    defer {
      model.listeningActivity.stop()
      try? FileManager.default.removeItem(at: root)
    }
    model.listeningCoverage = EnglishListeningCoverage(ranges: [0..<1, 2..<3])
    model.listeningCoverageSession = model.session
    let date = Date()
    func sample(_ time: Double, uptime: Double? = nil, state: Int = 1, audible: Bool = true) {
      model.recordListeningPlayback(.init(mediaTime: time, uptime: uptime ?? time,
        date: date.addingTimeInterval(uptime ?? time), state: state, rate: 1, audible: audible))
    }
    model.update(time: 0, duration: 10, state: 1)
    #expect(!model.listeningActivity.isStudying)
    sample(0)
    #expect(!model.listeningActivity.isStudying)
    sample(0.5)
    #expect(model.listeningActivity.isStudying)
    sample(0.5, uptime: 0.55) // Coarse repeated iframe timestamps must not flicker.
    #expect(model.listeningActivity.isStudying)
    sample(0.5, uptime: 0.6, state: 3)
    #expect(!model.listeningActivity.isStudying)
    sample(0.6)
    sample(0.7)
    #expect(model.listeningActivity.isStudying)
    sample(0.8, audible: false)
    #expect(!model.listeningActivity.isStudying)
    sample(0.9)
    sample(1.0)
    sample(1.1) // Audible playback continues, but the English coverage ended.
    #expect(!model.listeningActivity.isStudying)
    sample(2.1)
    sample(2.2)
    #expect(model.listeningActivity.isStudying)
    sample(2.2, uptime: 2.3, state: 2)
    #expect(!model.listeningActivity.isStudying)
    model.closeVideo()
    await model.listeningSaveTask?.value
  }

  @Test func frequentSamplesOnlyInvalidateTheIndicatorOnStateChanges() async throws {
    let (model, root) = try ListeningIntegrationTests().fixture()
    defer {
      model.listeningActivity.stop()
      try? FileManager.default.removeItem(at: root)
    }
    var studyInvalidations = 0
    var footerInvalidations = 0
    let studyObservation = model.objectWillChange.sink { studyInvalidations += 1 }
    let footerObservation = model.listeningActivity.objectWillChange.sink { footerInvalidations += 1 }
    let date = Date()
    for i in 0...100 {
      let time = Double(i) / 20
      model.recordListeningPlayback(.init(mediaTime: time, uptime: time,
        date: date.addingTimeInterval(time), state: 1, rate: 1, audible: true))
    }
    #expect(studyInvalidations == 0 && footerInvalidations == 1)
    model.resetListeningPlayback()
    #expect(studyInvalidations == 0 && footerInvalidations == 2)
    #expect(!model.listeningActivity.isStudying)
    await model.listeningSaveTask?.value
    withExtendedLifetime((studyObservation, footerObservation)) {}
    model.closeVideo()
  }

  @Test func speechNeedsFreshEnglishAndPauseOrNonEnglishImmediatelyRestTheIndicator() async throws {
    let (model, root) = try ListeningIntegrationTests().fixture()
    defer {
      model.listeningActivity.stop()
      try? FileManager.default.removeItem(at: root)
    }
    model.beginListeningSpeechRun()
    model.liveSpeechState = .listening
    model.recordListeningSpeech(.init(text: "[Music]", start: 0, end: 1, isFinal: false))
    #expect(!model.listeningActivity.isStudying)
    model.recordListeningSpeech(.init(text: "A paper robot.", start: 1, end: 2, isFinal: false))
    #expect(model.listeningActivity.isStudying)
    model.recordListeningSpeech(.init(text: "A blue robot.", start: 1, end: 2, isFinal: true))
    #expect(model.listeningActivity.isStudying) // Same counted range: no flicker.
    model.recordListeningSpeech(.init(text: "日本語", start: 2, end: 3, isFinal: true))
    #expect(!model.listeningActivity.isStudying)
    model.recordListeningSpeech(.init(text: "Silver birds fly.", start: 3, end: 4, isFinal: true))
    #expect(model.listeningActivity.isStudying)
    model.finishListeningSpeechRun()
    #expect(!model.listeningActivity.isStudying)
    model.liveSpeechState = .preparing
    model.recordListeningSpeech(.init(text: "Final buffered words.", start: 0, end: 1, isFinal: true))
    #expect(!model.listeningActivity.isStudying)
    await model.listeningSaveTask?.value
    model.closeVideo()
  }

  @Test func missingCallbacksExpireAndAnOldDeadlineCannotCancelNewEvidence() {
    let activity = ListeningActivity()
    defer { activity.stop() }
    let start = ContinuousClock().now
    #expect(!activity.isStudying)
    activity.recordActivity(at: start)
    #expect(activity.isStudying)
    #expect(!activity.expireIfNeeded(at: start.advanced(by: .seconds(4))))
    activity.recordActivity(at: start.advanced(by: .seconds(4)))
    #expect(!activity.expireIfNeeded(at: start.advanced(by: .seconds(5))))
    #expect(activity.isStudying)
    #expect(activity.expireIfNeeded(at: start.advanced(by: .seconds(9))))
    #expect(!activity.isStudying)
    activity.recordActivity(at: start.advanced(by: .seconds(10)))
    activity.stop()
    #expect(!activity.isStudying)
    #expect(!activity.expireIfNeeded(at: start.advanced(by: .seconds(20))))
  }
}
