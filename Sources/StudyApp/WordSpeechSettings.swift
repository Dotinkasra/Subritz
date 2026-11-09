import AppKit
import AVFoundation
import StudyCore
import SwiftUI

struct WordSpeechVoice: Equatable, Identifiable {
  let id: String
  let name: String
  let language: String
  let quality: WordSpeechQuality
}

enum WordSpeechVoices {
  static func installed() -> [WordSpeechVoice] {
    AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
      guard voice.identifier.hasPrefix("com.apple."), isEnglish(voice.language),
        !voice.voiceTraits.contains(.isNoveltyVoice), !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
      let quality: WordSpeechQuality
      switch voice.quality {
      case .default: quality = .standard
      case .enhanced: quality = .enhanced
      case .premium: quality = .premium
      @unknown default: return nil
      }
      return WordSpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
    }
  }
  static func select(_ quality: WordSpeechQuality, from voices: [WordSpeechVoice]) -> WordSpeechVoice? {
    voices.filter { $0.quality == quality && isEnglish($0.language) }.sorted {
      let lhs = priority($0), rhs = priority($1)
      if lhs != rhs { return lhs < rhs }
      return $0.id < $1.id
    }.first
  }
  private static func isEnglish(_ language: String) -> Bool {
    language == "en" || language.hasPrefix("en-") || language.hasPrefix("en_")
  }
  private static func priority(_ voice: WordSpeechVoice) -> Int {
    let us = voice.language.replacingOccurrences(of: "_", with: "-") == "en-US"
    let name = voice.id.split(separator: ".").last?.lowercased()
    return (us ? 0 : 10) + (name == "ava" ? 0 : name == "samantha" ? 1 : 2)
  }
}

struct WordSpeechSettings: View {
  @ObservedObject var model: StudyModel
  @State private var voices: [WordSpeechVoice] = []
  @State private var settingsError: String?
  @StateObject private var preview = WordSpeechPlayer()
  private var selectedVoice: WordSpeechVoice? {
    WordSpeechVoices.select(model.settings.wordSpeechQuality, from: voices)
  }
  private var voiceNameExample: String {
    model.settings.wordSpeechQuality == .standard ? "Ava" : "Ava（\(model.settings.wordSpeechQuality.title)）"
  }
  var body: some View {
    Section("単語の読み上げ") {
      Picker("音声の品質", selection: $model.settings.wordSpeechQuality) {
        ForEach(WordSpeechQuality.allCases) { quality in
          Text(quality.title).tag(quality)
        }
      }
      Text("macOSの声一覧での表記例：「\(voiceNameExample)」")
        .font(.caption).foregroundStyle(.secondary)
      if let voice = selectedVoice {
        LabeledContent("使用する英語音声", value: voice.name + "（" + voice.language + "）")
        Button(preview.speakingText == nil ? "試聴" : "試聴を停止",
          systemImage: preview.speakingText == nil ? "speaker.wave.2" : "stop.fill") {
          preview.toggle("A paper robot carries a blue lantern.", quality: model.settings.wordSpeechQuality)
        }
      } else {
        Label("この品質の英語音声は未インストールです", systemImage: "arrow.down.circle")
          .foregroundStyle(.secondary)
        Text("macOSの「システムの声」の詳細から、英語の「\(voiceNameExample)」などの声を追加してください。追加後は自動で検出します。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button(selectedVoice == nil ? "音声を追加（macOS設定）…" : "macOSの音声管理を開く…") {
        openVoiceManagement()
      }
      Text("音声はmacOSが管理し、他の対応アプリと共有します。未インストールの品質を選ぶと、音声を追加するためmacOS設定を開きます。別の品質の音声には切り替えません。")
        .font(.caption).foregroundStyle(.secondary)
      if let message = settingsError ?? preview.error {
        Text(message).font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear { refresh() }
    .onChange(of: model.settings.wordSpeechQuality) {
      preview.stop()
      refresh()
      if selectedVoice == nil { openVoiceManagement() }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
      refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    .onDisappear { preview.stop() }
  }
  private func refresh() {
    voices = WordSpeechVoices.installed()
  }
  private func openVoiceManagement() {
    preview.stop()
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!
    settingsError = NSWorkspace.shared.open(url) ? nil
      : "システム設定の「アクセシビリティ」から音声の管理を開いてください。"
  }
}
