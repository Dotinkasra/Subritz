import StudyCore
import SwiftUI

struct LiveSpeechInputs: View {
  @ObservedObject var model: StudyModel
  @StateObject private var microphones = SpeechMicrophones()
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("音声の入力元", selection: Binding(get: { model.settings.speechAudioSource },
        set: { model.setSpeechAudioSource($0) })) {
        ForEach(SpeechAudioSource.allCases, id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      if model.settings.speechAudioSource == .microphone {
        Picker("入力デバイス", selection: Binding(get: { model.settings.speechMicrophoneID },
          set: { model.setSpeechMicrophone($0) })) {
          Text("システムのデフォルト").tag("")
          ForEach(microphones.devices) { Text($0.name).tag($0.id) }
          if !model.settings.speechMicrophoneID.isEmpty,
            !microphones.devices.contains(where: { $0.id == model.settings.speechMicrophoneID }) {
            Text("選択したマイクは未接続です").tag(model.settings.speechMicrophoneID)
          }
        }
      }
    }.disabled(model.isLiveSpeech && model.liveSpeechState == .preparing)
      .onAppear { microphones.refresh() }
  }
}

struct LiveSpeechLaunchCard: View {
  @ObservedObject var model: StudyModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("リアルタイム音声認識モード", systemImage: "waveform").font(.headline)
      Text("Macの再生音やマイクの英語を、その場で字幕と辞書に表示します。")
        .font(.callout).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 20) {
        LiveSpeechInputs(model: model).frame(maxWidth: 420)
        Button("音声認識を開始", systemImage: "waveform") { model.startLiveSpeech() }
          .controlSize(.large).disabled(!model.liveSpeechSupported || model.isChangingCacheDirectory)
        if !model.cachedSpeechSessions.isEmpty {
          Menu("認識履歴") {
            ForEach(model.cachedSpeechSessions) { cached in
              Button(cached.date.formatted(date: .abbreviated, time: .shortened) + " · " + cached.source.title) {
                model.restoreLiveSpeech(cached.id)
              }
            }
          }.fixedSize()
        }
      }
      Text(model.liveSpeechSupported
        ? "Appleの音声認識を使用します。初回は英語モデルをダウンロードします。認識キャッシュはアプリ終了時に削除されます。"
        : "リアルタイム音声認識にはmacOS 26以降の対応Macが必要です。")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(0.05)).padding(16)
  }
}

struct LiveSpeechPanel: View {
  @ObservedObject var model: StudyModel
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Label("リアルタイム音声認識", systemImage: "waveform").font(.headline)
            Spacer()
            Label(model.liveSpeechState == .listening ? "認識中" : model.liveSpeechState == .preparing ? "準備中" : "停止中",
              systemImage: model.liveSpeechState == .listening ? "circle.fill" : "pause.circle")
              .font(.caption).foregroundStyle(model.liveSpeechState == .listening ? Color.green : Color.secondary)
          }
          LiveSpeechInputs(model: model)
          Spacer(minLength: 0)
          VStack(spacing: 14) {
            Image(systemName: model.settings.speechAudioSource == .system ? "speaker.wave.2" : "mic")
              .font(.system(size: 42)).foregroundStyle(.secondary)
            Text(model.liveSpeechStatus).font(.callout).multilineTextAlignment(.center)
            if model.liveSpeechState == .preparing { ProgressView().controlSize(.small) }
            Text("認識した英文が下の字幕に追加されます。\n単語にマウスを置くか、クリックして調べられます。")
              .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.frame(maxWidth: .infinity)
          Spacer(minLength: 0)
          HStack {
            Button(model.liveSpeechState == .listening ? "一時停止" : "認識を再開",
              systemImage: model.liveSpeechState == .listening ? "pause.fill" : "play.fill") {
              model.toggleLiveSpeech()
            }.disabled(model.liveSpeechState == .preparing)
            Spacer()
            Text("認識した範囲 " + PlaybackTime.format(model.duration)).font(.caption).monospacedDigit()
          }
          Text("認識途中の英文は修正されることがあります。音声は保存されないため、字幕の時刻へ戻る操作はできません。")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
      }
    }
  }
}

struct LiveSpeechSettings: View {
  @ObservedObject var model: StudyModel
  var body: some View {
    Section("リアルタイム音声認識") {
      LiveSpeechInputs(model: model)
      Picker("英文キャッシュの上限", selection: $model.settings.liveSpeechCacheMB) {
        ForEach([1, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) MB").tag($0) }
      }
      Text("使用量：\(model.liveSpeechCacheBytes.formatted()) バイト（英文テキスト）")
        .font(.caption).foregroundStyle(.secondary)
      Text("キャッシュはメモリ内だけに保持し、上限を超えると古い英文から削除します。アプリ終了時に全削除されます。音声は保存しません。")
        .font(.caption).foregroundStyle(.secondary)
      Text("AppleのSpeechAnalyzerを使用します。macOS 26以降の対応Macが必要です。モデルはmacOSが管理するため、パスの指定は不要です。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
