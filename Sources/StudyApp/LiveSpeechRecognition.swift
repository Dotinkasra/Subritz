import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import StudyCore

@MainActor protocol LiveSpeechRecognizing: AnyObject {
  func start(source: SpeechAudioSource, microphoneID: String,
    onUpdate: @escaping @MainActor (LiveSpeechUpdate) -> Void,
    onStatus: @escaping @MainActor (String) -> Void,
    onFailure: @escaping @MainActor (String) -> Void) async throws
  func stop(finalize: Bool) async
}

@MainActor final class SpeechMicrophones: ObservableObject {
  struct Device: Identifiable, Equatable { let id: String; let name: String }
  @Published private(set) var devices: [Device] = []
  private var observers: [NSObjectProtocol] = []
  init() {
    refresh()
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.refresh() }
      })
    }
  }
  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
  func refresh() {
    devices = Self.availableDevices().map { Device(id: $0.uniqueID, name: $0.localizedName) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  nonisolated static func availableDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
      mediaType: .audio, position: .unspecified).devices.filter { $0.hasMediaType(.audio) }
  }
}

@available(macOS 26.0, *)
@MainActor final class AppleLiveSpeechRecognizer: LiveSpeechRecognizing {
  private var analyzer: SpeechAnalyzer?
  private var capture: LiveSpeechAudioCapture?
  private var resultsTask: Task<Void, Never>?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var stopping = false

  func start(source: SpeechAudioSource, microphoneID: String,
    onUpdate: @escaping @MainActor (LiveSpeechUpdate) -> Void,
    onStatus: @escaping @MainActor (String) -> Void,
    onFailure: @escaping @MainActor (String) -> Void) async throws {
    stopping = false
    guard SpeechTranscriber.isAvailable else {
      throw AppFailure("このMacではAppleの音声認識モデルを利用できません。macOS 26以降の対応Macが必要です。")
    }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
      throw AppFailure("このMacでは英語の音声認識を利用できません。")
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    onStatus("英語の音声認識モデルを確認しています…")
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      onStatus("英語の音声認識モデルをダウンロードしています…")
      try await withTaskCancellationHandler {
        try await request.downloadAndInstall()
      } onCancel: { request.progress.cancel() }
    }
    try Task.checkCancellation()
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw AppFailure("音声認識に対応する音声形式を取得できませんでした。")
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    do {
      onStatus("音声認識を準備しています…")
      try await analyzer.prepareToAnalyze(in: format)
      try Task.checkCancellation()
      let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
      input = continuation
      resultsTask = Task {
        do {
          for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = result.text
            let words = text.runs.compactMap { run -> LiveSpeechWord? in
              guard let range = run.audioTimeRange else { return nil }
              return LiveSpeechWord(text: String(text[run.range].characters),
                start: range.start.seconds, end: range.end.seconds)
            }
            let plain = String(text.characters)
            onUpdate(LiveSpeechUpdate(text: plain, start: result.range.start.seconds,
              end: result.range.end.seconds, isFinal: result.isFinal,
              words: words.map(\.text).joined() == plain ? words : []))
          }
        } catch is CancellationError {} catch {
          if !Task.isCancelled, !stopping { onFailure("音声認識が停止しました：" + error.localizedDescription) }
        }
      }
      let capture = LiveSpeechAudioCapture(format: format, continuation: continuation,
        onFailure: { message in Task { @MainActor in onFailure(message) } })
      self.capture = capture
      try await analyzer.start(inputSequence: stream)
      onStatus(source == .system ? "Macの再生音へのアクセスを確認しています…" : "マイクへのアクセスを確認しています…")
      try await capture.start(source: source, microphoneID: microphoneID)
      try Task.checkCancellation()
    } catch {
      await stop(finalize: false)
      throw error
    }
  }

  func stop(finalize: Bool) async {
    stopping = true
    let capture = self.capture, analyzer = self.analyzer, task = resultsTask, input = self.input
    self.capture = nil; self.analyzer = nil; resultsTask = nil; self.input = nil
    await capture?.stop()
    input?.finish()
    if finalize {
      do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
      catch { await analyzer?.cancelAndFinishNow() }
    } else {
      task?.cancel()
      await analyzer?.cancelAndFinishNow()
    }
    await task?.value
  }
}

/// Both capture APIs deliver buffers on one serial queue. Conversion and input
/// buffering stay off the main thread; neither audio nor screen frames are saved.
@available(macOS 26.0, *)
private final class LiveSpeechAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "Subritz.live-audio", qos: .userInitiated)
  private let pcm: SpeechPCMConverter
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private let onFailure: @Sendable (String) -> Void
  private var screenStream: SCStream?
  private var microphone: AVCaptureSession?
  private var stopped = false
  private var failed = false
  private var observers: [NSObjectProtocol] = []
  init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
    onFailure: @escaping @Sendable (String) -> Void) {
    self.pcm = SpeechPCMConverter(format: format)
    self.continuation = continuation; self.onFailure = onFailure
  }
  func start(source: SpeechAudioSource, microphoneID: String) async throws {
    if source == .microphone {
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        throw AppFailure("マイクへのアクセスが許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」でSubritzを許可してください。")
      }
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
        queue.async { [self] in
          do {
            guard !stopped else { throw CancellationError() }
            let device: AVCaptureDevice?
            if microphoneID.isEmpty { device = AVCaptureDevice.default(for: .audio) }
            else { device = SpeechMicrophones.availableDevices().first { $0.uniqueID == microphoneID } }
            guard let device else { throw AppFailure("選択したマイクが見つかりません。入力デバイスを選び直してください。") }
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
              throw AppFailure("選択したマイクから音声を取得できません。")
            }
            session.beginConfiguration(); session.addInput(input); session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
            session.commitConfiguration()
            microphone = session
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureDevice.wasDisconnectedNotification] {
              let target: AnyObject = name == AVCaptureSession.runtimeErrorNotification ? session : device
              observers.append(NotificationCenter.default.addObserver(forName: name, object: target, queue: nil) {
                [weak self] _ in
                guard let self else { return }
                self.queue.async { self.fail("マイクの取得が停止しました。接続と入力デバイスを確認して再開してください。") }
              })
            }
            session.startRunning()
            result.resume()
          } catch { result.resume(throwing: error) }
        }
      }
    } else {
      let content: SCShareableContent
      do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
      catch { throw AppFailure("Macの再生音を取得できません。システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」でSubritzを許可してください。", details: error.localizedDescription) }
      try Task.checkCancellation()
      guard let display = content.displays.first else { throw AppFailure("音声取得に使用できるディスプレイが見つかりません。") }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.capturesAudio = true; config.excludesCurrentProcessAudio = true
      config.sampleRate = 48000; config.channelCount = 1
      config.width = 2; config.height = 2
      config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
      config.showsCursor = false
      let stream = SCStream(filter: filter, configuration: config, delegate: self)
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
      screenStream = stream
      try await stream.startCapture()
    }
  }
  func stop() async {
    await withCheckedContinuation { result in
      queue.async { [self] in
        stopped = true
        microphone?.stopRunning(); microphone = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        result.resume()
      }
    }
    let stream = screenStream; screenStream = nil
    try? await stream?.stopCapture()
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    queue.async { [self] in fail("Macの再生音の取得が停止しました：" + error.localizedDescription) }
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    if type == .audio { receive(sampleBuffer) }
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    receive(sampleBuffer)
  }
  private func fail(_ message: String) {
    guard !stopped, !failed else { return }
    failed = true; onFailure(message)
  }
  private func receive(_ sample: CMSampleBuffer) {
    guard !stopped, !failed, sample.isValid, sample.dataReadiness == .ready,
      let description = sample.formatDescription else { return }
    let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
    do {
      try sample.withAudioBufferList { list, _ in
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: list.unsafePointer) else { return }
        guard let input = try pcm.convert(source) else { return }
        if case .dropped = continuation.yield(input) {
          fail("音声認識の処理が入力に追いつきませんでした。いったん停止して再開してください。")
        }
      }
    } catch { fail("音声データを読み取れませんでした：" + error.localizedDescription) }
  }
}

/// A serial-queue-owned converter. Always returns an owned output buffer, since
/// capture buffers may be recycled before SpeechAnalyzer consumes the input.
@available(macOS 26.0, *)
final class SpeechPCMConverter {
  private let format: AVAudioFormat
  private var converter: AVAudioConverter?
  private var frames: Int64 = 0
  init(format: AVAudioFormat) { self.format = format }
  func convert(_ source: AVAudioPCMBuffer) throws -> AnalyzerInput? {
    if converter?.inputFormat != source.format {
      converter = AVAudioConverter(from: source.format, to: format)
      converter?.primeMethod = .none
    }
    guard let converter else { throw AppFailure("音声の形式を変換できません。") }
    let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 256
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw AppFailure("音声変換用のメモリを確保できません。")
    }
    var consumed: AVAudioFrameCount = 0
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { requested, inputStatus in
      guard consumed < source.frameLength, requested > 0 else {
        inputStatus.pointee = .noDataNow; return nil
      }
      // The converter can request less than a capture buffer. Returning the
      // entire buffer would silently lose its remaining frames on some rates.
      let count = min(requested, source.frameLength - consumed)
      guard let chunk = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else {
        inputStatus.pointee = .noDataNow; return nil
      }
      chunk.frameLength = count
      let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
      let targetBuffers = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
      for index in sourceBuffers.indices {
        let bytesPerFrame = Int(sourceBuffers[index].mDataByteSize) / Int(source.frameLength)
        if let from = sourceBuffers[index].mData, let to = targetBuffers[index].mData {
          memcpy(to, from.advanced(by: Int(consumed) * bytesPerFrame), Int(count) * bytesPerFrame)
        }
      }
      consumed += count
      inputStatus.pointee = .haveData
      return chunk
    }
    guard status != .error, error == nil else { throw AppFailure("音声の変換に失敗しました。") }
    guard output.frameLength > 0 else { return nil }
    let start = CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
    frames += Int64(output.frameLength)
    return AnalyzerInput(buffer: output, bufferStartTime: start)
  }
}
