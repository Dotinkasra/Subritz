import Foundation
import StudyCore

enum LiveSpeechState { case preparing, listening, paused, failed }
struct CachedSpeechSession: Identifiable {
  let id: UUID
  let date: Date
  let source: SpeechAudioSource
}

extension StudyModel {
  var isLiveSpeech: Bool { liveSpeechSessionID != nil }
  var liveSpeechSupported: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }
  func startLiveSpeech() {
    guard !isRestoringBackup, !hasOpenVideo, !isChangingCacheDirectory else { return }
    closeVideo()
    let id = liveTranscriptCache.begin(source: settings.speechAudioSource)
    openLiveSpeechSession(id)
    configureLiveSpeech(listen: true)
  }
  func restoreLiveSpeech(_ id: UUID) {
    guard !isRestoringBackup, !hasOpenVideo, liveTranscriptCache.session(id) != nil else { return }
    closeVideo()
    liveTranscriptCache.activate(id)
    openLiveSpeechSession(id)
    liveSpeechState = .paused
    liveSpeechStatus = "この起動中に認識した英文を表示しています"
  }
  private func openLiveSpeechSession(_ id: UUID) {
    liveSubtitleAutoFollow = true
    liveSpeechSessionID = id
    grammarEnabledForVideo = false
    ready = true
    liveSpeechState = .paused
    stage = "リアルタイム音声認識"
    renderLiveTranscript(id)
    refreshLiveSpeechCache()
  }
  func setSpeechAudioSource(_ source: SpeechAudioSource) {
    guard settings.speechAudioSource != source else { return }
    settings.speechAudioSource = source
    settings.save(defaults: defaults)
    markBackupChanged()
    if isLiveSpeech, liveSpeechState == .listening { configureLiveSpeech(listen: true) }
  }
  func setSpeechMicrophone(_ id: String) {
    guard settings.speechMicrophoneID != id else { return }
    settings.speechMicrophoneID = id
    settings.save(defaults: defaults)
    markBackupChanged()
    if isLiveSpeech, settings.speechAudioSource == .microphone, liveSpeechState == .listening {
      configureLiveSpeech(listen: true)
    }
  }
  func toggleLiveSpeech() { configureLiveSpeech(listen: liveSpeechState != .listening) }

  func configureLiveSpeech(listen: Bool) {
    guard let id = liveSpeechSessionID else { return }
    let sid = session
    let previous = liveSpeechOperation
    let shutdown = liveSpeechShutdown
    previous?.cancel()
    let previousRecognizer = liveSpeechRecognizer
    liveSpeechRecognizer = nil
    liveSpeechState = .preparing
    liveSpeechStatus = listen ? "音声認識を準備しています…" : "認識した英文を確定しています…"
    playing = false
    liveSpeechOperation = Task { [self] in
      await shutdown?.value
      await previous?.value
      await previousRecognizer?.stop(finalize: true)
      guard !Task.isCancelled, sid == session, liveSpeechSessionID == id else { return }
      finishListeningSpeechRun()
      if !listen {
        liveSpeechState = .paused
        liveSpeechStatus = "音声認識を一時停止しています"
        return
      }
      let run = UUID()
      liveSpeechRunID = run
      let offset = liveTranscriptCache.session(id)?.endTime ?? 0
      beginListeningSpeechRun()
      do {
        let recognizer: any LiveSpeechRecognizing
        if let liveSpeechRecognizerFactory { recognizer = try liveSpeechRecognizerFactory() }
        else if #available(macOS 26.0, *) { recognizer = AppleLiveSpeechRecognizer() }
        else { throw AppFailure("リアルタイム音声認識にはmacOS 26以降が必要です。") }
        liveSpeechRecognizer = recognizer
        error = nil; errorDetails = nil
        try await recognizer.start(source: settings.speechAudioSource, microphoneID: settings.speechMicrophoneID,
          onUpdate: { [weak self] update in
            guard let self, self.session == sid, self.liveSpeechRunID == run else { return }
            self.recordListeningSpeech(update)
            do {
              if try self.liveTranscriptCache.apply(update.offset(by: offset), to: id) {
                self.renderLiveTranscript(id)
                self.refreshLiveSpeechCache()
              }
            } catch { self.failLiveSpeech("認識結果を読み込めませんでした：" + error.localizedDescription) }
          }, onStatus: { [weak self] status in
            guard let self, self.session == sid, self.liveSpeechRunID == run else { return }
            self.liveSpeechStatus = status
          }, onFailure: { [weak self] message in
            guard let self, self.session == sid, self.liveSpeechRunID == run else { return }
            self.failLiveSpeech(message)
          })
        guard !Task.isCancelled, sid == session, liveSpeechRunID == run else {
          await recognizer.stop(finalize: false)
          return
        }
        liveSpeechState = .listening
        liveSpeechStatus = settings.speechAudioSource.title + "を認識しています"
        playing = true
      } catch is CancellationError {} catch {
        guard !Task.isCancelled, sid == session, liveSpeechRunID == run else { return }
        failLiveSpeech(error.localizedDescription)
      }
    }
  }
  private func failLiveSpeech(_ message: String) {
    finishListeningSpeechRun()
    liveSpeechRunID = UUID()
    liveSpeechOperation?.cancel()
    liveSpeechState = .failed
    liveSpeechStatus = "音声認識を停止しました"
    playing = false
    error = message
    let recognizer = liveSpeechRecognizer
    liveSpeechRecognizer = nil
    liveSpeechShutdown = Task { await recognizer?.stop(finalize: false) }
  }
  func endLiveSpeech() {
    finishListeningSpeechRun()
    liveSpeechRunID = UUID()
    let previous = liveSpeechOperation, recognizer = liveSpeechRecognizer, shutdown = liveSpeechShutdown
    previous?.cancel()
    liveSpeechRecognizer = nil
    liveSpeechOperation = nil
    liveSpeechShutdown = Task {
      await shutdown?.value
      await recognizer?.stop(finalize: false)
      await previous?.value
    }
    liveSpeechSessionID = nil
    liveSubtitleAutoFollow = true
    liveSpeechState = .paused
    liveSpeechStatus = ""
  }
  func refreshLiveSpeechCache() {
    liveSpeechCacheBytes = liveTranscriptCache.byteCount
    cachedSpeechSessions = liveTranscriptCache.sessions.filter { !$0.segments.isEmpty }.reversed().map {
      CachedSpeechSession(id: $0.id, date: $0.startedAt, source: $0.source)
    }
  }
  func clearLiveSpeechCacheOnExit() {
    liveTranscriptCache.removeAll()
    refreshLiveSpeechCache()
  }
  func renderLiveTranscript(_ id: UUID) {
    guard isLiveSpeech, let cached = liveTranscriptCache.session(id) else { return }
    document = cached.document
    timeline = Timeline(document!.sentences)
    let last = timeline?.tokens.last(where: \.lexical)
    let changed = currentToken?.id != last?.id
    currentToken = last
    currentLineIndex = max(0, (timeline?.lines.count ?? 0) - 1)
    subtitlePlaybackAnchorID = last?.id
    activeSentenceIndex = document?.sentences.last?.index
    currentSentence = document?.sentences.last
    time = cached.endTime
    duration = cached.endTime
    let retained = Set(timeline?.tokens.map(\.id) ?? [])
    if let pinnedToken, !retained.contains(pinnedToken.id) { releaseDictionaryPin() }
    if let hoverToken, !retained.contains(hoverToken.id) { self.hoverToken = nil }
    if let pinnedExpression, !pinnedExpression.tokens.allSatisfy({ retained.contains($0.id) }) { releaseDictionaryPin() }
    if let pinned = subtitlePinnedLineID, !subtitleLines.contains(where: { $0.id == pinned }) {
      subtitlePinnedLineID = subtitleLines.first?.id
    }
    if let anchor = subtitlePinnedTokenID, !retained.contains(anchor) { subtitlePinnedTokenID = subtitleLines.first?.tokens.first?.id }
    // Search offsets belong to the current snapshot, including volatile edits.
    refreshLiveSubtitleSearch()
    // A partial can grow without changing its row ID/index; cache eviction can
    // replace the last row while leaving its index unchanged too.
    liveSubtitleRevision &+= 1
    if changed, !dictionaryIsPinned, hoverToken == nil { lookup() }
    if last != nil { prefetchDictionary(nearLine: timeline?.lines.last?.id) }
  }
}
