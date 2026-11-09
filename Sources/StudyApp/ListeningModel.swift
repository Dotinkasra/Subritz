import Foundation
import StudyCore

extension StudyModel {
  func recordListeningPlayback(_ sample: ListeningPlaybackSample) {
    guard ready, !isLiveSpeech, let timeline else {
      playbackListening.reset()
      return
    }
    if listeningCoverageSession != session {
      listeningCoverage = EnglishListeningCoverage(lines: timeline.lines)
      listeningCoverageSession = session
      playbackListening.reset()
    }
    guard let coverage = listeningCoverage else { return }
    for interval in playbackListening.consume(sample, coverage: coverage) {
      listeningBuffer.append(interval, source: .video)
    }
    checkpointListening(uptime: sample.uptime)
    if sample.state != 1 || !sample.audible { flushListeningRecords() }
  }
  func resetListeningPlayback(clearCoverage: Bool = false) {
    playbackListening.reset()
    if clearCoverage {
      listeningCoverageSession = nil
      listeningCoverage = nil
    }
    flushListeningRecords()
  }
  func beginListeningSpeechRun() { speechListening.reset() }
  func finishListeningSpeechRun() {
    speechListening.reset()
    flushListeningRecords()
  }
  func recordListeningSpeech(
    _ update: LiveSpeechUpdate, receivedAt date: Date = Date(),
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) {
    for interval in speechListening.consume(update, receivedAt: date) {
      listeningBuffer.append(interval, source: .speech)
    }
    checkpointListening(uptime: uptime)
  }
  private func checkpointListening(uptime: Double) {
    if let last = listeningCheckpointUptime {
      if uptime - last >= 30 {
        listeningCheckpointUptime = uptime
        flushListeningRecords()
      }
    } else {
      listeningCheckpointUptime = uptime
    }
  }
  func flushListeningRecords() {
    guard listeningBuffer.hasChanges, library != nil || libraryStartup != nil else { return }
    let spans = listeningBuffer.drain()
    let previous = listeningSaveTask
    listeningSaveTask = Task { [self] in
      await previous?.value
      // An earlier in-flight checkpoint may have failed after this snapshot was
      // drained. Include its restored records before marking the next save OK.
      var batch = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
      for pending in listeningBuffer.drain() {
        if batch[pending.id].map({ $0.end < pending.end }) ?? true { batch[pending.id] = pending }
      }
      do {
        let storage: LibraryStore
        if let library {
          storage = library
        } else if let libraryStartup {
          storage = try await libraryStartup.value
        } else {
          throw AppFailure("視聴時間の保存先を開けませんでした")
        }
        try await storage.saveListeningSpans(Array(batch.values))
        listeningSaveError = nil
      } catch {
        listeningBuffer.restore(Array(batch.values))
        listeningSaveError = "視聴時間を保存できませんでした：" + error.localizedDescription
      }
    }
  }
  func listeningTotals(in range: ListeningCalendarRange) async throws -> [ListeningTimeBin] {
    flushListeningRecords()
    await listeningSaveTask?.value
    if let listeningSaveError { throw AppFailure(listeningSaveError) }
    if let library { return try await library.listeningTotals(in: range) }
    if let libraryStartup { return try await libraryStartup.value.listeningTotals(in: range) }
    throw AppFailure("視聴時間の保存先を準備しています。少し待って再試行してください。")
  }
}
