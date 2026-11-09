import AVFoundation
import StudyCore
import SwiftUI

@MainActor protocol WordSpeechSynthesizing: AnyObject {
  var onEnd: ((UUID) -> Void)? { get set }
  func speak(_ text: String, quality: WordSpeechQuality, request: UUID) -> Bool
  func stop()
}

@MainActor final class WordSpeechPlayer: ObservableObject {
  @Published private(set) var speakingText: String?
  @Published var error: String?
  private var request: UUID?
  private var speakingQuality: WordSpeechQuality?
  private var synthesizer: (any WordSpeechSynthesizing)?
  private let makeSynthesizer: @MainActor () -> any WordSpeechSynthesizing

  init(makeSynthesizer: @escaping @MainActor () -> any WordSpeechSynthesizing = { SystemWordSpeechSynthesizer() }) {
    self.makeSynthesizer = makeSynthesizer
  }
  func toggle(_ text: String, quality: WordSpeechQuality = .standard) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if speakingText == text, speakingQuality == quality { stop(); return }
    stop()
    error = nil
    if synthesizer == nil {
      synthesizer = makeSynthesizer()
      synthesizer?.onEnd = { [weak self] request in
        guard self?.request == request else { return }
        self?.request = nil
        self?.speakingQuality = nil
        self?.speakingText = nil
      }
    }
    let id = UUID()
    request = id
    speakingQuality = quality
    speakingText = text
    if synthesizer?.speak(text, quality: quality, request: id) != true {
      request = nil
      speakingQuality = nil
      speakingText = nil
      error = "\(quality.title)の英語音声が見つかりません。Subritzの設定からmacOSの音声管理を開き、この品質の英語音声を追加してください。"
    }
  }
  func stop() {
    // Invalidate before stopping: an old cancellation callback must not clear a new request.
    request = nil
    speakingQuality = nil
    speakingText = nil
    synthesizer?.stop()
  }
}

@MainActor final class SystemWordSpeechSynthesizer: NSObject, WordSpeechSynthesizing, AVSpeechSynthesizerDelegate {
  var onEnd: ((UUID) -> Void)?
  private let synthesizer = AVSpeechSynthesizer()
  private var current: (request: UUID, utterance: AVSpeechUtterance)?
  override init() {
    super.init()
    synthesizer.delegate = self
  }
  func speak(_ text: String, quality: WordSpeechQuality, request: UUID) -> Bool {
    guard let selected = WordSpeechVoices.select(quality, from: WordSpeechVoices.installed()),
      let voice = AVSpeechSynthesisVoice(identifier: selected.id) else { return false }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    current = (request, utterance)
    synthesizer.speak(utterance)
    return true
  }
  func stop() {
    current = nil
    synthesizer.stopSpeaking(at: .immediate)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.ended(utterance) }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.ended(utterance) }
  }
  private func ended(_ utterance: AVSpeechUtterance) {
    guard let current, current.utterance === utterance else { return }
    self.current = nil
    onEnd?(current.request)
  }
}

struct WordSpeechButton: View {
  let word: String
  let session: UUID
  let quality: WordSpeechQuality
  @StateObject private var player = WordSpeechPlayer()
  private var speakingThisWord: Bool { !word.isEmpty && player.speakingText == word }
  var body: some View {
    Button { player.toggle(word, quality: quality) } label: {
      Image(systemName: speakingThisWord ? "stop.fill" : "speaker.wave.2.fill")
        .font(.title3).foregroundStyle(speakingThisWord ? Color.accentColor : Color.secondary)
    }
    // Keep appearance stable through caption gaps; an empty word never starts speech.
    .help(speakingThisWord ? "読み上げを停止" : word.isEmpty
      ? "字幕の単語を選択すると英語で読み上げられます" : "「\(word)」を英語で読み上げる")
    .accessibilityLabel(speakingThisWord ? "読み上げを停止" : "単語を英語で読み上げる")
    .onChange(of: session) { player.stop() }
    .onChange(of: quality) { player.stop() }
    .onDisappear { player.stop() }
    .alert("読み上げできませんでした", isPresented: Binding(
      get: { player.error != nil }, set: { if !$0 { player.error = nil } }
    )) { Button("OK") { player.error = nil } } message: { Text(player.error ?? "") }
  }
}
