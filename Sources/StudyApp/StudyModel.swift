import StudyCore
import SwiftUI

@MainActor final class StudyModel: ObservableObject {
  @Published var url = ""
  @Published var settings = AppSettings()
  @Published var phase: VideoLoadPhase = .idle
  @Published var stage = "YouTube の英語動画 URL を入力してください"
  @Published var error: String?
  @Published var grammarError: String?
  @Published var errorDetails: String?
  @Published var grammarErrorDetails: String?
  @Published var dictionaryLoading = false
  @Published var ready = false
  @Published var loading = false
  @Published var showSettings = false
  @Published var document: StudyDocument?
  @Published var currentSentence: Sentence?
  @Published var currentLineIndex = 0
  @Published var currentToken: Token?
  @Published var pinnedToken: Token?
  @Published var hoverToken: Token?
  @Published var dictionaryEntry: DictionaryEntry?
  @Published var realtime = true
  @Published var time: Double = 0
  @Published var duration: Double = 0
  @Published var playing = false
  @Published var cacheUsage = 0
  @Published var eijiroCount = 0
  @Published var settingsMessage = ""
  @Published var isImportingDictionary = false
  @Published var isRemovingDictionary = false
  @Published var dictionaryMessage = ""
  @Published var isChangingCacheDirectory = false
  @Published var cacheMessage = ""
  @Published var confirmCloseVideo = false
  let defaults: UserDefaults
  var apiKeyTask: Task<Void, Never>?
  var pendingAPIKey: String?
  var dictionaryOperation: Task<Void, Never>?
  var cacheOperation: Task<Void, Never>?
  var dictionaryBusy: Bool { isImportingDictionary || isRemovingDictionary }
  var hasOpenVideo: Bool { loading || ready || document != nil }
  let bridge = PlayerBridge()
  var storageTask: Task<(StudyStore, EijiroProvider), Error>?
  var store: StudyStore?
  var eijiro: EijiroProvider?
  var timeline: Timeline?
  var session = UUID()
  var fingerprint = ""
  var scheduler: GrammarScheduler?
  var loadTask: Task<Void, Never>?
  var backgroundTask: Task<Void, Never>?
  var backgroundRunning = false
  var dictionaryTask: Task<Void, Never>?
  var dictionaryPrefetchTask: Task<Void, Never>?
  var dictionaryMisses = Set<String>()
  var dictionaryCache: [String: DictionaryEntry] = [:]
  var selectedDictionaryID: UUID?
  var lastPriorityTime: Double = -300
  var activeSentenceIndex: Int?
  init(prepareStorage: Bool = true, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    settings = AppSettings.load(defaults: defaults)
    bridge.onTime = { [weak self] t, d, s in self?.update(time: t, duration: d, state: s) }
    bridge.onError = { [weak self] message in self?.error = message }
    guard prepareStorage else { return }
    let directory = settings.cacheURL
    storageTask = Task.detached { (try StudyStore(directory: directory), try EijiroProvider()) }
    Task {
      do {
        let stores = try await storageTask!.value
        store = stores.0
        eijiro = stores.1
        await refreshStorage()
      } catch { self.error = "永続データを開けませんでした：" + error.localizedDescription }
    }
  }
  func load() {
    guard !isChangingCacheDirectory else { return }
    phase = .validatingURL
    let id: String
    do { id = try YouTubeURL.id(url) } catch {
      self.error = error.localizedDescription
      return
    }
    loadTask?.cancel()
    backgroundTask?.cancel()
    backgroundRunning = false
    dictionaryTask?.cancel()
    dictionaryPrefetchTask?.cancel()
    bridge.pause()
    session = UUID()
    let sid = session
    ready = false
    loading = true
    error = nil
    errorDetails = nil
    grammarError = nil
    grammarErrorDetails = nil
    document = nil
    timeline = nil
    currentSentence = nil
    currentToken = nil
    currentLineIndex = 0
    hoverToken = nil
    pinnedToken = nil
    dictionaryEntry = nil
    selectedDictionaryID = nil
    activeSentenceIndex = nil
    lastPriorityTime = -300
    time = 0
    let config = settings
    loadTask = Task {
      do {
        if store == nil, let storageTask {
          let stores = try await storageTask.value
          store = stores.0
          eijiro = stores.1
        }
        phase = .probingVideo
        StudyLog.youtube.info("Probing video metadata")
        stage = "動画情報を取得しています…"
        let yt = YtDlpProvider(path: config.ytDlpPath)
        let probe = try await yt.probe(id: id)
        guard sid == session else { return }
        phase = .fetchingCaptions
        stage = "自動生成英語字幕を取得しています…"
        let raw = try await yt.caption(probe)
        guard sid == session else { return }
        phase = .parsingCaptions
        stage = "字幕を解析し、単語タイムラインを構築しています…"
        let provider: any GrammarProvider =
          config.provider == "codex"
          ? CodexGrammarProvider(settings: config) : LocalGrammarProvider(settings: config)
        let key = Fingerprint.make(
          videoID: id, caption: raw, provider: await provider.cacheIdentity(),
          model: config.grammarModel)
        let cached = try await store?.load(key)
        let sentences: [Sentence]
        if let cached {
          sentences = cached.sentences
        } else {
          sentences = try await CaptionService().parse(raw, videoID: id)
        }
        guard sid == session, !Task.isCancelled else { return }
        phase = .buildingTimeline
        StudyLog.timing.info("Built caption timeline")
        document = StudyDocument(video: probe.video, rawCaption: raw, sentences: sentences)
        timeline = Timeline(sentences)
        duration = probe.video.duration
        fingerprint = key
        scheduler = GrammarScheduler(provider: provider, context: sentences)
        continuePlayback()
      } catch is CancellationError {} catch {
        guard sid == session else { return }
        loading = false
        phase = .failed((error as? AppFailure) ?? AppFailure(error.localizedDescription))
        self.error = error.localizedDescription
        errorDetails = (error as? AppFailure)?.details
        stage = "読み込みに失敗しました"
      }
    }
  }
  func retryCurrentGrammar() {
    guard var sentence = currentSentence else { return }
    sentence.grammarAnalysis = nil
    enqueueGrammarRetry([sentence])
  }
  func retryGrammar() {
    guard ready, let document else {
      load()
      return
    }
    enqueueGrammarRetry(
      document.sentences.filter {
        $0.grammarAnalysis == nil && $0.endTime >= time && $0.startTime < time + 300
      })
  }
  func enqueueGrammarRetry(_ sentences: [Sentence]) {
    guard let scheduler else { return }
    let sid = session
    let previous = grammarError == nil ? nil : backgroundTask
    previous?.cancel()
    Task {
      await previous?.value
      guard sid == session else { return }
      grammarError = nil
      grammarErrorDetails = nil
      mark(sentences, status: .queued)
      await scheduler.enqueue(sentences, priority: true, retryFailed: true)
      guard sid == session else { return }
      startBackground()
    }
  }
  func continuePlayback() {
    loading = false
    ready = true
    phase = .ready
    grammarError = nil
    stage = "再生できます。文法は現在位置の前後から解析します"
    if let d = document { timeline = Timeline(d.sentences) }
    prefetchDictionary(at: time)
    startBackground()
  }
  func grammarDemand(at time: Double) -> [Sentence] {
    let nearby =
      document?.sentences.filter {
        $0.endTime >= max(0, time - 10) && $0.startTime < time + 300 && $0.grammarAnalysis == nil
      } ?? []
    // Current/future speech first; recent past remains available for look-back.
    return nearby.filter { $0.endTime >= time } + nearby.filter { $0.endTime < time }.reversed()
  }
  func startBackground() {
    guard ready, !backgroundRunning, grammarError == nil, let scheduler else { return }
    backgroundRunning = true
    let sid = session
    backgroundTask = Task {
      defer {
        if sid == session {
          backgroundRunning = false
          let unfinished = document?.sentences.filter { $0.grammarStatus == .analyzing } ?? []
          mark(unfinished, status: grammarError == nil ? .queued : .failed)
          if !Task.isCancelled, grammarError == nil {
            // An enqueue can arrive while the group is draining its last child.
            // Hand off after clearing the running flag so that work is not stranded.
            Task {
              guard await scheduler.hasQueuedWork, sid == session, ready else { return }
              startBackground()
            }
          }
        }
      }
      // Seed the cache once, before any incremental grammar writes. Playback is
      // already available; a cached document requires no full rewrite.
      await persistProgress(changed: [], sid: sid)
      guard sid == session, !Task.isCancelled else { return }
      let demand = grammarDemand(at: time)
      mark(demand.filter { $0.grammarStatus != .failed }, status: .queued)
      let discarded = await scheduler.focus(on: demand)
      guard sid == session, !Task.isCancelled else { return }
      mark(discarded, status: .notQueued)
      phase = .backgroundAnalysis
      let workers = await scheduler.workerLimit
      await withTaskGroup(of: GrammarWorkResult.self) { group in
        for slot in 0..<workers {
          guard sid == session, !Task.isCancelled else {
            group.cancelAll()
            return
          }
          _ = await submitGrammar(
            to: &group, scheduler: scheduler, sid: sid,
            maxSentences: slot == 0 ? 2 : GrammarContract.maxSentences)
        }
        while let outcome = await group.next() {
          guard sid == session, !Task.isCancelled else {
            group.cancelAll()
            return
          }
          switch outcome.result {
          case .success(let results):
            apply(results)
            mark(
              outcome.batch.filter { sentence in !results.contains { $0.sentenceId == sentence.id }
              }, status: .failed)
            await persistProgress(changed: Set(outcome.batch.map(\.id)), sid: sid)
            guard sid == session, !Task.isCancelled else {
              group.cancelAll()
              return
            }
          case .failure(let error):
            if error is CancellationError {
              if Task.isCancelled {
                group.cancelAll()
                return
              }
              // A seek canceled work outside the new look-ahead window.
              mark(outcome.batch, status: .notQueued)
              _ = await submitGrammar(to: &group, scheduler: scheduler, sid: sid, maxSentences: 2)
              continue
            }
            mark(outcome.batch, status: .failed)
            if (error as? AppFailure)?.code != .grammarInvalidResponse {
              grammarError = error.localizedDescription
              grammarErrorDetails = (error as? AppFailure)?.details
              stage = "文法解析を中断しました。動画・字幕・辞書は引き続き使えます"
              group.cancelAll()
              return
            }
          }
          let demand = grammarDemand(at: time)
          let remaining = demand.filter { $0.grammarStatus != .failed }.count
          stage =
            remaining > 0
            ? "文法をバックグラウンド解析中… 先読み範囲の残り\(remaining)文"
            : demand.isEmpty ? "現在位置から5分先までの文法を解析済みです" : "文法表示を準備しました。一部の文は再解析できます"
          _ = await submitGrammar(
            to: &group, scheduler: scheduler, sid: sid, maxSentences: GrammarContract.maxSentences)
        }
      }
      if sid == session, grammarError == nil, !Task.isCancelled { phase = .ready }
      await refreshStorage()
    }
  }
  func submitGrammar(
    to group: inout TaskGroup<GrammarWorkResult>, scheduler: GrammarScheduler, sid: UUID,
    maxSentences: Int
  ) async -> Bool {
    let batch = await scheduler.next(maxSentences: maxSentences)
    guard !batch.isEmpty, sid == session, !Task.isCancelled else { return false }
    mark(batch, status: .analyzing)
    group.addTask {
      do {
        return GrammarWorkResult(batch: batch, result: .success(try await scheduler.analyze(batch)))
      } catch { return GrammarWorkResult(batch: batch, result: .failure(error)) }
    }
    return true
  }
  func persistProgress(changed: Set<UUID>, sid: UUID) async {
    guard sid == session, let document else { return }
    let key = fingerprint
    let limit = settings.cacheMB * 1024 * 1024
    do {
      try await store?.saveProgress(document, changed: changed, fingerprint: key, limit: limit)
    } catch { if sid == session { self.error = "キャッシュを保存できませんでした：" + error.localizedDescription } }
  }
  func mark(_ batch: [Sentence], status: GrammarStatus) {
    let ids = Set(batch.map(\.id))
    guard var d = document else { return }
    for i in d.sentences.indices where ids.contains(d.sentences[i].id) {
      d.sentences[i].grammarStatus = status
    }
    document = d
    refreshCurrentSentence()
  }
  func apply(_ analyses: [Analysis]) {
    guard var d = document else { return }
    let results = Dictionary(uniqueKeysWithValues: analyses.map { ($0.sentenceId, $0) })
    for i in d.sentences.indices {
      if let a = results[d.sentences[i].id] {
        d.sentences[i].grammarAnalysis = a
        d.sentences[i].grammarStatus = .completed
        for j in d.sentences[i].tokens.indices {
          d.sentences[i].tokens[j].grammarRole =
            a.displaySpans(at: j).first?.role
        }
      }
    }
    document = d
    refreshCurrentSentence()
  }
  func refreshCurrentSentence() {
    if let i = activeSentenceIndex, let d = document, i < d.sentences.count {
      currentSentence = d.sentences[i]
    }
  }
  func update(time t: Double, duration d: Double, state: Int) {
    guard ready else { return }
    let resumedPlayback = !playing && state == 1
    let discontinuity = abs(t - time) > 1.0
    if abs(t - time) >= 0.1 || discontinuity || playing != (state == 1) { time = t }
    if d > 0, d != duration { duration = d }
    if playing != (state == 1) { playing = state == 1 }
    guard let timeline else { return }
    if let line = timeline.line(at: t), currentLineIndex != line.index {
      currentLineIndex = line.index
    }
    let sentence = timeline.sentence(at: t)
    if currentSentence?.id != sentence?.id {
      activeSentenceIndex = sentence?.index
      currentSentence = sentence.flatMap { document?.sentences[$0.index] }
    }
    let token = timeline.token(at: t)
    let tokenChanged = currentToken?.id != token?.id
    let resumeRealtime =
      realtime && state == 1 && pinnedToken != nil
      && (resumedPlayback || tokenChanged)
    if resumeRealtime {
      pinnedToken = nil
      hoverToken = nil
    }
    if tokenChanged {
      currentToken = token
      prefetchDictionary(at: t)
    }
    if (tokenChanged || resumeRealtime) && hoverToken == nil { lookup() }
    if discontinuity || t - lastPriorityTime > 15 {
      prioritize(t, cancelObsolete: discontinuity)
    }
  }
  func seek(_ t: Double) {
    bridge.seek(t)
    update(time: t, duration: duration, state: playing ? 1 : 2)
    prioritize(t, cancelObsolete: true)
  }
  func prioritize(_ t: Double, cancelObsolete: Bool = false) {
    lastPriorityTime = t
    guard grammarError == nil, let scheduler else { return }
    let pending = grammarDemand(at: t)
    let sid = session
    Task {
      guard sid == session else { return }
      let discarded = await scheduler.focus(on: pending, cancelObsolete: cancelObsolete)
      guard sid == session else { return }
      mark(discarded, status: .notQueued)
      let ids = Set(pending.map(\.id))
      mark(
        document?.sentences.filter { ids.contains($0.id) && $0.grammarStatus == .notQueued } ?? [],
        status: .queued)
      startBackground()
    }
  }
  func hover(_ token: Token?, exiting: UUID? = nil) {
    guard pinnedToken == nil else { return }
    if let exiting, hoverToken?.id != exiting { return }
    hoverToken = token
    lookup()
  }
  func pinDictionary(_ token: Token) {
    guard token.lexical else { return }
    pinnedToken = token
    hoverToken = nil
    lookup()
  }
  func releaseDictionaryPin() {
    pinnedToken = nil
    hoverToken = nil
    lookup()
  }
  func dictionaryModeChanged() {
    if realtime && playing { releaseDictionaryPin() } else { lookup() }
  }
  var displayedToken: Token? { pinnedToken ?? hoverToken ?? (realtime ? currentToken : nil) }
  var subtitleLines: [CaptionLine] { timeline?.lines ?? [] }
  func dictionaryKey(_ token: Token) -> String {
    settings.dictionary + ":" + token.normalized + ":" + (token.partOfSpeech ?? "") + ":"
      + (token.lemma ?? "")
  }
  func prefetchDictionary(at time: Double) {
    dictionaryPrefetchTask?.cancel()
    let tokens = timeline?.upcomingWords(at: time, limit: 10) ?? []
    let sid = session
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    dictionaryPrefetchTask = Task {
      for token in tokens {
        guard !Task.isCancelled, sid == session else { return }
        let key = dictionaryKey(token)
        if dictionaryCache[key] != nil || dictionaryMisses.contains(key) { continue }
        let entry = await provider.lookup(token)
        guard !Task.isCancelled, sid == session else { return }
        if let entry { dictionaryCache[key] = entry } else { dictionaryMisses.insert(key) }
      }
    }
  }
  func lookup() {
    let token = displayedToken
    guard selectedDictionaryID != token?.id else { return }
    dictionaryTask?.cancel()
    selectedDictionaryID = token?.id
    dictionaryEntry = nil
    dictionaryLoading = false
    guard let token, token.lexical else { return }
    let key = dictionaryKey(token)
    if dictionaryMisses.contains(key) { return }
    if let entry = dictionaryCache[key] {
      dictionaryLoading = false
      dictionaryEntry = entry
      return
    }
    let sid = session
    let provider: any DictionaryProvider =
      settings.dictionary == "eijiro" && eijiro != nil ? eijiro! : MacDictionaryProvider()
    dictionaryLoading = true
    dictionaryTask = Task {
      let entry = await provider.lookup(token)
      guard !Task.isCancelled, sid == session, displayedToken?.id == token.id else { return }
      StudyLog.dictionary.debug("Updated dictionary token")
      dictionaryLoading = false
      dictionaryEntry = entry
      if let entry {
        if dictionaryCache.count > 2000 { dictionaryCache.removeAll() }
        dictionaryCache[key] = entry
      } else {
        dictionaryMisses.insert(key)
      }
    }
  }
  func closeVideo() {
    loadTask?.cancel()
    backgroundTask?.cancel()
    dictionaryTask?.cancel()
    dictionaryPrefetchTask?.cancel()
    bridge.pause()
    bridge.stopClock()
    session = UUID()
    scheduler = nil
    backgroundRunning = false
    loading = false
    ready = false
    playing = false
    document = nil
    timeline = nil
    currentSentence = nil
    currentToken = nil
    hoverToken = nil
    pinnedToken = nil
    dictionaryEntry = nil
    dictionaryLoading = false
    selectedDictionaryID = nil
    activeSentenceIndex = nil
    currentLineIndex = 0
    fingerprint = ""
    lastPriorityTime = -300
    time = 0
    duration = 0
    error = nil
    errorDetails = nil
    grammarError = nil
    grammarErrorDetails = nil
    phase = .idle
    stage = "YouTube の英語動画 URL を入力してください"
    confirmCloseVideo = false
  }
  func saveSettings(previous: AppSettings? = nil) {
    guard settings.timeout.isFinite, (5...3600).contains(settings.timeout) else {
      settingsMessage = "タイムアウトは5〜3600秒で指定してください。この変更は未保存です。"
      return
    }
    settings.save(defaults: defaults)
    settingsMessage = "変更は自動で保存されます"
    if previous?.dictionary != settings.dictionary {
      invalidateDictionary()
    }
    if previous?.cacheMB != settings.cacheMB {
      Task {
        do {
          try await store?.evict(
            limit: settings.cacheMB * 1024 * 1024, protecting: document?.video.id)
          await refreshStorage()
        } catch { cacheMessage = error.localizedDescription }
      }
    }
  }
  func scheduleAPIKeySave(_ key: String) {
    pendingAPIKey = key
    apiKeyTask?.cancel()
    apiKeyTask = Task {
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      flushAPIKey()
    }
  }
  func flushAPIKey() {
    apiKeyTask?.cancel()
    guard let key = pendingAPIKey else { return }
    do {
      try APISecret.save(key)
      pendingAPIKey = nil
      settingsMessage = "変更は自動で保存されます"
    } catch { settingsMessage = error.localizedDescription }
  }
  func invalidateDictionary() {
    dictionaryTask?.cancel()
    dictionaryPrefetchTask?.cancel()
    dictionaryCache.removeAll()
    dictionaryMisses.removeAll()
    selectedDictionaryID = nil
    lookup()
  }
  func changeCacheDirectory(to directory: URL?) {
    guard !isChangingCacheDirectory else { return }
    let path = directory?.standardizedFileURL.path ?? ""
    guard path != settings.cacheDirectory else { return }
    isChangingCacheDirectory = true
    cacheMessage = "キャッシュの保存先を変更しています…"
    let target = directory ?? AppSettings.defaultCacheURL
    cacheOperation = Task {
      defer { isChangingCacheDirectory = false }
      do {
        // Wait for startup before replacing the active store.
        _ = try? await storageTask?.value
        let newStore = try await Task.detached { try StudyStore(directory: target) }.value
        let dictionary: EijiroProvider
        if let existing = eijiro {
          dictionary = existing
        } else {
          dictionary = try await Task.detached { try EijiroProvider() }.value
        }
        if let document {
          try await newStore.save(
            document, fingerprint: fingerprint, limit: settings.cacheMB * 1024 * 1024)
        }
        store = newStore
        eijiro = dictionary
        if error?.hasPrefix("永続データを開けませんでした") == true { error = nil }
        settings.cacheDirectory = path
        settings.save(defaults: defaults)
        await refreshStorage()
        cacheMessage = "保存先を変更しました。既存のキャッシュは元の場所に残ります。"
      } catch { cacheMessage = "保存先を変更できませんでした：" + error.localizedDescription }
    }
  }
  func refreshStorage() async {
    cacheUsage = (try? await store?.usage()) ?? 0
    eijiroCount = (try? await eijiro?.count()) ?? 0
  }
  func importDictionary(_ url: URL) {
    guard !dictionaryBusy else { return }
    isImportingDictionary = true
    dictionaryMessage = "英辞郎データをインポートしています…"
    dictionaryOperation = Task {
      defer { isImportingDictionary = false }
      let granted = url.startAccessingSecurityScopedResource()
      defer { if granted { url.stopAccessingSecurityScopedResource() } }
      do {
        if eijiro == nil, let storageTask { eijiro = try await storageTask.value.1 }
        guard let eijiro else { throw AppFailure("辞書データベースが準備できていません") }
        let n = try await eijiro.importFile(url)
        invalidateDictionary()
        await refreshStorage()
        dictionaryMessage = "\(n)項目をインポートしました"
      } catch { dictionaryMessage = "インポートできませんでした：" + error.localizedDescription }
    }
  }
  func removeDictionary() {
    guard !dictionaryBusy else { return }
    isRemovingDictionary = true
    dictionaryMessage = "英辞郎データを削除しています…"
    dictionaryOperation = Task {
      defer { isRemovingDictionary = false }
      do {
        guard let eijiro else { throw AppFailure("辞書データベースが準備できていません") }
        try await eijiro.remove()
        invalidateDictionary()
        await refreshStorage()
        dictionaryMessage = "英辞郎データを削除しました"
      } catch { dictionaryMessage = error.localizedDescription }
    }
  }
  func clearCache() {
    guard !isChangingCacheDirectory else { return }
    Task {
      do {
        try await store?.clear()
        await refreshStorage()
        cacheMessage = "動画キャッシュを削除しました"
      } catch { cacheMessage = error.localizedDescription }
    }
  }
}

struct GrammarWorkResult {
  let batch: [Sentence]
  let result: Result<[Analysis], Error>
}
