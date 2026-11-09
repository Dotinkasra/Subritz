import Charts
import StudyCore
import SwiftUI

@MainActor final class ListeningStatisticsModel: ObservableObject {
  @Published var period = ListeningPeriod.week {
    didSet {
      if oldValue != period {
        bins = []
        loading = true
      }
    }
  }
  @Published var anchor = Date() {
    didSet {
      if oldValue != anchor {
        bins = []
        loading = true
      }
    }
  }
  @Published private(set) var bins: [ListeningTimeBin] = []
  @Published private(set) var error: String?
  @Published private(set) var loading = false
  var calendar = Calendar.current
  var range: ListeningCalendarRange {
    ListeningCalendarRange(period: period, anchor: anchor, calendar: calendar)
  }
  var videoSeconds: Double { bins.reduce(0) { $0 + $1.videoSeconds } }
  var speechSeconds: Double { bins.reduce(0) { $0 + $1.speechSeconds } }
  var total: Double { videoSeconds + speechSeconds }
  func move(_ direction: Int) {
    anchor =
      calendar.date(byAdding: period.component, value: direction, to: range.interval.start)
      ?? anchor
  }
  var canMoveForward: Bool {
    range.interval.end
      <= (calendar.dateInterval(of: period.component, for: Date())?.start ?? Date())
  }
  var title: String {
    let date = range.interval.start
    switch period {
    case .year: return date.formatted(.dateTime.year().locale(Locale(identifier: "ja_JP")))
    case .month: return date.formatted(.dateTime.year().month().locale(Locale(identifier: "ja_JP")))
    case .day:
      return date.formatted(
        .dateTime.year().month().day().weekday().locale(Locale(identifier: "ja_JP")))
    case .week:
      let end = calendar.date(byAdding: .day, value: -1, to: range.interval.end) ?? date
      let style = Date.FormatStyle.dateTime.year().month().day().locale(Locale(identifier: "ja_JP"))
      return date.formatted(style) + " 〜 " + end.formatted(style)
    }
  }
  func axisLabel(_ index: Int) -> String {
    guard bins.indices.contains(index) else { return "" }
    let date = bins[index].start
    switch period {
    case .year: return "\(calendar.component(.month, from: date))月"
    case .month: return "\(calendar.component(.day, from: date))日"
    case .week:
      return date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    case .day: return "\(calendar.component(.hour, from: date))時"
    }
  }
  func selectionLabel(_ date: Date) -> String {
    let style: Date.FormatStyle
    switch period {
    case .year: style = .dateTime.year().month()
    case .month, .week: style = .dateTime.month().day().weekday()
    case .day: style = .dateTime.month().day().hour()
    }
    return date.formatted(style.locale(Locale(identifier: "ja_JP")))
  }
  func refresh(from study: StudyModel) async {
    let requestedPeriod = period
    let requestedAnchor = anchor
    calendar = .current
    let range = self.range
    loading = bins.isEmpty
    defer { loading = false }
    do {
      let result = try await study.listeningTotals(in: range)
      guard !Task.isCancelled, period == requestedPeriod, anchor == requestedAnchor else { return }
      if result != bins { bins = result }
      if error != nil { error = nil }
    } catch {
      guard !Task.isCancelled, period == requestedPeriod, anchor == requestedAnchor else { return }
      self.error = error.localizedDescription
    }
  }
}

struct ListeningStatisticsView: View, Equatable {
  let study: StudyModel
  @StateObject private var model = ListeningStatisticsModel()
  @State private var selectedIndex: Int?
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.study === rhs.study }
  private struct Request: Equatable {
    let period: ListeningPeriod
    let anchor: Date
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label("英語の視聴時間", systemImage: "chart.bar.xaxis").font(.title2.weight(.semibold))
        Spacer()
        Picker("表示期間", selection: $model.period) {
          ForEach(ListeningPeriod.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).frame(width: 240)
      }
      HStack {
        Button {
          selectedIndex = nil
          model.move(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .help("前の期間").accessibilityLabel("前の期間")
        Text(model.title).font(.headline).frame(maxWidth: .infinity)
        Button {
          selectedIndex = nil
          model.move(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(!model.canMoveForward).help("次の期間").accessibilityLabel("次の期間")
        Button("現在の期間") {
          selectedIndex = nil
          model.anchor = Date()
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Text("合計").font(.caption).foregroundStyle(.secondary)
          Text(Self.duration(model.total)).font(
            .system(size: 34, weight: .semibold, design: .rounded)
          )
          .monospacedDigit().accessibilityLabel("合計 " + Self.duration(model.total))
        }
        Spacer()
        Label("動画 " + Self.duration(model.videoSeconds), systemImage: "play.rectangle.fill")
          .foregroundStyle(.blue)
        Label("音声認識 " + Self.duration(model.speechSeconds), systemImage: "waveform")
          .foregroundStyle(.green)
      }
      chart
      if let selectedIndex, model.bins.indices.contains(selectedIndex) {
        let bin = model.bins[selectedIndex]
        HStack {
          Text(model.selectionLabel(bin.start)).bold()
          Spacer()
          Text("合計 " + Self.duration(bin.total))
          Text("動画 " + Self.duration(bin.videoSeconds)).foregroundStyle(.blue)
          Text("音声認識 " + Self.duration(bin.speechSeconds)).foregroundStyle(.green)
        }.font(.callout).monospacedDigit()
      } else {
        Text("グラフをクリック・ドラッグすると内訳を確認できます。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.error {
        HStack {
          Text(error).font(.callout).foregroundStyle(.red)
          Spacer()
          Button("再試行") { Task { await model.refresh(from: study) } }
        }
      }
      Divider()
      Text("英語字幕と音声認識結果に基づく推定時間です。一時停止・シーク・動画のミュート中は記録しません。倍速再生でも実際に経過した時間を数えます。")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(minWidth: 760, minHeight: 520)
      .onChange(of: model.period) { selectedIndex = nil }
      .task(id: Request(period: model.period, anchor: model.anchor)) {
        // Refresh only while this window is visible; playback adds no new timer
        // or observable updates. Library queries/writes run on its storage actor.
        while !Task.isCancelled {
          await model.refresh(from: study)
          do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
      }
  }
  private var chart: some View {
    let divisor: Double = (model.bins.map(\.total).max() ?? 0) >= 3600 ? 3600 : 60
    let maximum = max(1, (model.bins.map(\.total).max() ?? 0) / divisor * 1.15)
    let stride = model.period == .day ? 3 : model.period == .month ? 5 : 1
    let ticks = Array(model.bins.indices).filter { $0 % stride == 0 }
    return GeometryReader { geometry in
      Chart {
        ForEach(Array(model.bins.enumerated()), id: \.element.id) { index, bin in
          BarMark(
            x: .value("期間", index), y: .value("視聴時間", bin.videoSeconds / divisor),
            width: .fixed(
              max(2, (geometry.size.width - 40) / Double(max(1, model.bins.count)) * 0.72))
          )
          .foregroundStyle(by: .value("入力", "動画"))
          .accessibilityLabel(model.axisLabel(index) + " 動画")
          .accessibilityValue(Self.duration(bin.videoSeconds))
          BarMark(
            x: .value("期間", index), y: .value("視聴時間", bin.speechSeconds / divisor),
            width: .fixed(
              max(2, (geometry.size.width - 40) / Double(max(1, model.bins.count)) * 0.72))
          )
          .foregroundStyle(by: .value("入力", "音声認識"))
          .accessibilityLabel(model.axisLabel(index) + " 音声認識")
          .accessibilityValue(Self.duration(bin.speechSeconds))
        }
        if let selectedIndex, model.bins.indices.contains(selectedIndex) {
          RuleMark(x: .value("選択中", selectedIndex)).foregroundStyle(.secondary.opacity(0.35))
        }
      }
      .chartForegroundStyleScale(["動画": Color.blue, "音声認識": Color.green])
      .chartXScale(domain: -0.5...max(0.5, Double(model.bins.count) - 0.5))
      .chartYScale(domain: 0...maximum)
      .chartYAxisLabel(divisor == 3600 ? "時間" : "分")
      .chartXAxis {
        AxisMarks(values: ticks) { value in
          AxisGridLine()
          AxisValueLabel { if let index = value.as(Int.self) { Text(model.axisLabel(index)) } }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Color.clear.contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0).onChanged { value in
                guard let frame = proxy.plotFrame else { return }
                let plot = geometry[frame]
                let x = min(max(0, value.location.x - plot.minX), plot.width)
                if let index = proxy.value(atX: x, as: Double.self) {
                  selectedIndex = min(max(0, Int(index.rounded())), max(0, model.bins.count - 1))
                }
              }
            )
            .accessibilityHidden(true)
        }
      }
      .chartLegend(position: .bottom, alignment: .leading)
      .overlay {
        if model.loading {
          ProgressView()
        } else if model.total == 0, model.error == nil {
          VStack(spacing: 8) {
            Image(systemName: "headphones").font(.title)
            Text("この期間の記録はまだありません").font(.headline)
            Text("英語の動画を再生するか、音声認識を開始すると自動で記録します。")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
    }.frame(minHeight: 210, maxHeight: .infinity)
  }
  static func duration(_ seconds: Double) -> String {
    let finite = seconds.isFinite ? max(0, seconds) : 0
    let seconds = Int(min(Double(Int.max / 2), finite).rounded(.down))
    if seconds >= 3600 { return "\(seconds / 3600)時間\(seconds % 3600 / 60)分" }
    if seconds >= 60 { return "\(seconds / 60)分\(seconds % 60)秒" }
    return "\(seconds)秒"
  }
}
