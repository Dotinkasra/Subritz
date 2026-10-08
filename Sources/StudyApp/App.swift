import StudyCore
import SwiftUI

@main struct StudyApp: App {
  @StateObject private var model = StudyModel()
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  var body: some Scene {
    Window("Subritz", id: "main") {
      MainView(model: model).frame(minWidth: 1100, minHeight: 700)
        .background(MainWindowLifecycle(model: model).frame(width: 0, height: 0))
        .onAppear { lifecycle.model = model }
    }.commands { SubritzCommands(model: model) }
    Settings { SettingsView(model: model) }
  }
}
struct MainView: View {
  @ObservedObject var model: StudyModel
  @Environment(\.openSettings) private var openSettings
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
        Text("Subritz").font(.headline)
        Spacer()
        if model.hasOpenVideo {
          Button("動画を閉じる", systemImage: "xmark") { model.confirmCloseVideo = true }
        } else {
          TextField("https://www.youtube.com/watch?v=…", text: $model.url)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 520).onSubmit { model.load() }
            .disabled(model.isChangingCacheDirectory)
          Button("読み込む") { model.load() }.keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isChangingCacheDirectory)
        }
        Button {
          model.showSettings = true
        } label: {
          Image(systemName: "gearshape")
        }.help("設定")
      }.padding(16)
      Divider()
      if model.ready, let document = model.document {
        HStack(spacing: 0) {
          VStack(spacing: 8) {
            YouTubePlayer(videoID: document.video.id, bridge: model.bridge).id(model.session)
            HStack {
              Button {
                model.playing ? model.bridge.pause() : model.bridge.play()
              } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
              }
              Text(timestamp(model.time)).monospacedDigit().font(.caption)
              Slider(
                value: Binding(get: { model.time }, set: { model.seek($0) }),
                in: 0...max(1, model.duration))
              Text(timestamp(model.duration)).monospacedDigit().font(.caption)
            }
            Text(document.video.title).font(.caption).lineLimit(2)
          }.padding(12).frame(maxWidth: .infinity)
          Divider()
          DictionaryPane(model: model).frame(maxWidth: .infinity)
        }.frame(minHeight: 280, maxHeight: .infinity)
        Divider()
        SubtitlePane(model: model).frame(minHeight: 270, maxHeight: 380)
      } else {
        Spacer()
        VStack(spacing: 18) {
          Image(systemName: "captions.bubble").font(.system(size: 48)).foregroundStyle(.secondary)
          Text("英語を、動画と一緒に読み解く").font(.title2)
          Text("英語の自動字幕がある YouTube 動画を読み込みます。\n字幕の単語にマウスを置くと詳細辞書を表示し、クリックすると固定します。")
            .multilineTextAlignment(
              .center
            ).foregroundStyle(.secondary)
          if model.loading { ProgressView() }
          Text(model.stage).font(.callout)
          if let error = model.grammarError {
            Text(error).foregroundStyle(.orange).frame(maxWidth: 600)
            if let details = model.grammarErrorDetails { ErrorDetails(text: details) }
            HStack {
              Button("再試行") { model.retryGrammar() }
              Button("Provider 設定を開く") { model.showSettings = true }
              Button("文法表示なしで動画を開く") { model.continuePlayback() }
            }
          }
        }.padding()
        Spacer()
      }
      if let error = model.error {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
            Spacer()
            if !model.ready { Button("再試行") { model.load() } }
            Button("設定") { model.showSettings = true }
          }.foregroundStyle(.red)
          if let details = model.errorDetails { ErrorDetails(text: details) }
        }.padding(12).background(.red.opacity(0.06))
      }
      HStack {
        Text(model.stage).lineLimit(2)
        Spacer()
        if model.ready { Text("自動生成英語字幕 · ローカル辞書").foregroundStyle(.secondary) }
      }.font(.caption).padding(10)
    }
    .onChange(of: model.showSettings) { _, shown in
      if shown {
        openSettings()
        model.showSettings = false
      }
    }
    .alert("本当に動画を閉じますか？", isPresented: $model.confirmCloseVideo) {
      Button("キャンセル", role: .cancel) {}
      Button("動画を閉じる", role: .destructive) { model.closeVideo() }
    } message: {
      Text("字幕の解析と再生を終了し、URL入力画面に戻ります。保存済みのキャッシュは残ります。")
    }
  }
  func timestamp(_ t: Double) -> String {
    let n = Int(max(0, t))
    return String(format: "%d:%02d", n / 60, n % 60)
  }
}
struct ErrorDetails: View {
  let text: String
  var body: some View {
    DisclosureGroup("エラーの詳細") {
      ScrollView {
        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(10)
      }.frame(maxHeight: 140)
    }.font(.caption).frame(maxWidth: 650)
  }
}
struct DictionaryPane: View {
  @ObservedObject var model: StudyModel
  var detailed: Bool { model.pinnedToken != nil || model.hoverToken != nil || !model.realtime }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("辞書", systemImage: "book.closed").font(.headline)
        if model.pinnedToken != nil {
          Button {
            model.releaseDictionaryPin()
          } label: {
            Label("固定を解除", systemImage: "pin.slash")
          }.font(.caption)
        }
        Spacer()
        Text(model.settings.dictionary == "eijiro" ? "英辞郎" : "macOS 辞書").font(.caption)
          .foregroundStyle(.secondary)
      }
      Picker("辞書モード", selection: $model.realtime) {
        Text("リアルタイム").tag(true)
        Text("通常 / 詳細").tag(false)
      }.pickerStyle(.segmented).onChange(of: model.realtime) { model.dictionaryModeChanged() }
      if model.realtime && !detailed {
        GeometryReader { geometry in
          VStack(spacing: 22) {
            if let token = model.displayedToken {
              Text(token.surface).font(
                .system(size: min(68, geometry.size.width / 8), weight: .bold)
              )
              .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
              Text(pos(token.partOfSpeech)).font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
              if let entry = model.dictionaryEntry {
                let meanings = realtimeMeanings(entry.shortGloss)
                VStack(spacing: 12) {
                  Text(meanings.first ?? entry.shortGloss).font(
                    .system(size: min(48, geometry.size.width / 8), weight: .semibold)
                  )
                  .multilineTextAlignment(.center).lineSpacing(8)
                  .fixedSize(horizontal: false, vertical: true)
                  if meanings.count > 1 {
                    Text(meanings.dropFirst().joined(separator: "、"))
                      .font(.system(size: 18)).foregroundStyle(.primary.opacity(0.55))
                      .multilineTextAlignment(.center).lineSpacing(4)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              } else if model.dictionaryLoading {
                ProgressView()
              } else {
                Text("語義が見つかりません").font(.title2).foregroundStyle(.secondary)
              }
            } else {
              Text("発話中の単語を表示します").font(.title2).foregroundStyle(.secondary)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      } else if let token = model.displayedToken {
        VStack(alignment: .leading, spacing: 12) {
          Text(token.surface).font(.system(size: 42, weight: .semibold)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Text(pos(token.partOfSpeech)).font(.system(size: 13, weight: .medium))
              .padding(.horizontal, 10).padding(.vertical, 5)
              .background(Color.accentColor.opacity(0.12), in: Capsule())
            if model.pinnedToken != nil {
              Label("クリックで固定中", systemImage: "pin.fill").font(.caption).foregroundStyle(.orange)
            } else if model.hoverToken != nil {
              Text("マウスで選択中").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Divider()
        if let entry = model.dictionaryEntry {
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              VStack(alignment: .leading, spacing: 10) {
                Text("意味").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.shortGloss).font(.system(size: 30, weight: .medium)).lineSpacing(8)
                  .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
              }
              if detailed {
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                  Text("詳細定義").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  ForEach(
                    Array(DictionaryText.paragraphs(entry.definition).enumerated()), id: \.offset
                  ) { _, paragraph in
                    Text(paragraph).font(.system(size: 19)).lineSpacing(7)
                      .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                  }
                }
              }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
              .background(
                Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.dictionaryLoading {
          ProgressView("辞書を検索しています…").frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          Text("辞書項目が見つかりませんでした").font(.body).foregroundStyle(.secondary)
          Spacer()
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "text.cursor").font(.system(size: 30)).foregroundStyle(.tertiary)
          Text(model.realtime ? "発話中の単語と意味を表示します" : "字幕の単語にマウスを置くか、クリックしてください").font(.body)
            .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor))
  }
  func realtimeMeanings(_ gloss: String) -> [String] {
    var meanings: [String] = []
    var current = ""
    var closingBrackets: [Character] = []
    let brackets: [Character: Character] = [
      "(": ")", "（": "）", "[": "]", "［": "］", "「": "」", "『": "』",
    ]
    for character in gloss {
      if let closing = brackets[character] {
        closingBrackets.append(closing)
      } else if closingBrackets.last == character {
        closingBrackets.removeLast()
      }
      if closingBrackets.isEmpty && ["、", ",", "；", ";"].contains(character) {
        meanings.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    meanings.append(current)
    return meanings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
  }
  func pos(_ value: String?) -> String {
    switch value {
    case "Noun": return "N · 名詞"
    case "Verb": return "V · 動詞"
    case "Adjective": return "Adj · 形容詞"
    case "Adverb": return "Adv · 副詞"
    case "Pronoun": return "代名詞"
    case "Preposition": return "前置詞"
    case "Determiner": return "限定詞"
    case "Conjunction": return "接続詞"
    default: return value ?? "品詞不明"
    }
  }
}
struct SubtitlePane: View {
  @ObservedObject var model: StudyModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("字幕 / 文法").font(.headline)
        Spacer()
        Text(model.playing ? "再生位置に追従" : "過去・未来へスクロールできます")
          .font(.caption).foregroundStyle(.secondary)
      }
      ScrollViewReader { proxy in
        GeometryReader { geometry in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(model.subtitleLines) { line in
                SubtitleLineView(
                  model: model, line: line, current: line.index == model.currentLineIndex
                )
                .frame(minHeight: max(60, (geometry.size.height - 16) / 3), alignment: .center)
                .id(line.id)
              }
            }.padding(.vertical, max(0, (geometry.size.height - 60) / 3))
          }
          .onAppear { follow(proxy) }
          .onChange(of: model.currentLineIndex) { follow(proxy) }
          .onChange(of: model.playing) { if model.playing { follow(proxy) } }
        }
      }
    }.padding(16).background(Color(nsColor: .windowBackgroundColor))
  }
  func follow(_ proxy: ScrollViewProxy) {
    let lines = model.subtitleLines
    guard lines.indices.contains(model.currentLineIndex) else { return }
    // Follow on line changes, not on every clock tick: scrolling still works within a line.
    proxy.scrollTo(lines[model.currentLineIndex].id, anchor: .center)
  }
}
struct SubtitleLineView: View {
  @ObservedObject var model: StudyModel
  let line: CaptionLine
  let current: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FlowLayout(spacing: 5) {
        ForEach(line.tokens) { token in
          VStack(spacing: 2) {
            Button {
              model.pinDictionary(token)
            } label: {
              Text(token.surface).font(
                .system(size: current ? 26 : 21, weight: current ? .medium : .regular)
              )
              .padding(.horizontal, 2).padding(.vertical, 3)
              .background(
                model.currentToken?.id == token.id ? Color.accentColor.opacity(0.24) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 4)
                  .stroke(model.pinnedToken?.id == token.id ? Color.orange : .clear, lineWidth: 1.5)
              }
            }.buttonStyle(.plain).disabled(!token.lexical)
              .help(token.lexical ? "クリックして辞書を固定" : "")
            if abs(line.index - model.currentLineIndex) <= 1 {
              ForEach(Array(spans(token).enumerated()), id: \.offset) { _, span in
                VStack(spacing: 2) {
                  Underline(role: span.role).frame(height: 5)
                  Text(label(span.role)).font(.system(size: 12, weight: .bold)).foregroundStyle(
                    color(span.role)
                  ).help(roleExplanation(span.role) + (span.evidence.map { "\n句: " + $0 } ?? ""))
                }
              }
            }
          }.onHover { inside in
            if token.lexical {
              if inside { model.hover(token) } else { model.hover(nil, exiting: token.id) }
            }
          }
        }
      }
      if current, let sentence = model.currentSentence {
        if let analysis = sentence.grammarAnalysis, let clauses = analysis.clauses {
          let complete = clauses.filter { $0.status == .COMPLETE && $0.parentID == nil }
          let patterns = Array(Set(complete.map { $0.pattern.rawValue })).sorted()
          if !patterns.isEmpty {
            Text("節の文型: " + patterns.joined(separator: " / ")).font(.caption).foregroundStyle(
              .secondary)
          }
          let embedded = clauses.flatMap(\.constituents).filter { $0.childClauseID != nil }
          ForEach(Array(embedded.enumerated()), id: \.offset) { _, constituent in
            Text(label(constituent.role) + "（全体）: " + constituent.text)
              .font(.caption).foregroundStyle(color(constituent.role)).lineLimit(1)
              .help("まとまり全体の役割です。単語の下には、内部の節の役割を表示しています。")
          }
          if clauses.contains(where: { $0.status == .RESTART || $0.status == .FRAGMENT }) {
            Text("言い直し・途中の句を含みます").font(.caption).foregroundStyle(.secondary)
          }
          if let reasons = analysis.unresolvedReasons, !reasons.isEmpty {
            Text(analysis.spans.isEmpty ? "この部分の構造は未確定です" : "一部の語は未確定です")
              .font(.caption).foregroundStyle(.secondary).help(
                Array(Set(reasons)).sorted().joined(separator: "\n"))
            Button("この文を再解析") { model.retryCurrentGrammar() }.font(.caption)
          }
        } else if let analysis = sentence.grammarAnalysis, analysis.pattern == .UNKNOWN {
          Text(analysis.spans.isEmpty ? "この部分の構造は未確定です" : "判別できた部分を表示しています")
            .font(.caption).foregroundStyle(.secondary)
        } else if sentence.grammarStatus == .failed {
          HStack {
            Text("この文の文法表示は省略しました").font(.caption).foregroundStyle(.secondary)
            Button("この文を再解析") { model.retryCurrentGrammar() }.font(.caption)
          }
        }
      }
    }.padding(.horizontal, 10).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        current ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .foregroundStyle(current ? .primary : .secondary)
  }
  func spans(_ token: Token) -> [Span] {
    guard let sentence = model.document?.sentences.first(where: { $0.id == token.sentenceID }),
      let analysis = sentence.grammarAnalysis
    else { return [] }
    return analysis.displaySpans(at: token.index)
  }
}

func roleExplanation(_ role: Role) -> String {
  switch role {
  case .SUBJECT: return "S: 主語"
  case .VERB: return "V: 動詞"
  case .OBJECT, .OBJECT1, .OBJECT2: return "O: 動詞の目的語。節全体が目的語になる場合もあります"
  case .COMPLEMENT: return "C: 補語"
  case .PREPOSITIONAL_PHRASE: return "PP: 前置詞と、それに続く名詞句や節のまとまり"
  case .PREPOSITION: return "P: 前置詞"
  case .MODIFIER: return "MOD: 修飾語"
  case .CONJUNCTION: return "CONJ: 接続詞"
  case .CLAUSE: return "節"
  }
}

func label(_ role: Role) -> String {
  switch role {
  case .SUBJECT: return "S"
  case .VERB: return "V"
  case .OBJECT: return "O"
  case .OBJECT1: return "O1"
  case .OBJECT2: return "O2"
  case .COMPLEMENT: return "C"
  case .PREPOSITIONAL_PHRASE: return "PP"
  case .PREPOSITION: return "P"
  case .MODIFIER: return "MOD"
  case .CONJUNCTION: return "CONJ"
  case .CLAUSE: return "CL"
  }
}
func color(_ role: Role) -> Color {
  switch role {
  case .SUBJECT: return .blue
  case .VERB: return .red
  case .OBJECT, .OBJECT1, .OBJECT2: return .green
  case .COMPLEMENT: return .purple
  case .PREPOSITION, .PREPOSITIONAL_PHRASE: return .orange
  default: return .secondary
  }
}
struct Underline: View {
  let role: Role
  var body: some View {
    Canvas { context, size in
      var p = Path()
      p.move(to: CGPoint(x: 0, y: 1))
      p.addLine(to: CGPoint(x: size.width, y: 1))
      if role == .VERB {
        p.move(to: CGPoint(x: 0, y: 4))
        p.addLine(to: CGPoint(x: size.width, y: 4))
      }
      context.stroke(
        p, with: .color(color(role)),
        style: StrokeStyle(lineWidth: 1.5, dash: role == .PREPOSITIONAL_PHRASE ? [4, 3] : []))
    }
  }
}
struct FlowLayout: Layout {
  var spacing: CGFloat = 5
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 1000, subviews: subviews).size
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let layout = arrange(width: bounds.width, subviews: subviews)
    for i in subviews.indices {
      subviews[i].place(
        at: CGPoint(x: bounds.minX + layout.points[i].x, y: bounds.minY + layout.points[i].y),
        proposal: .unspecified)
    }
  }
  func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var points: [CGPoint] = []
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += row + spacing
        row = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      row = max(row, size.height)
    }
    return (CGSize(width: width, height: y + row), points)
  }
}
