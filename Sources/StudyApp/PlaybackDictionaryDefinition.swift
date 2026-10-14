import StudyCore
import SwiftUI

// The identity changes with the selection, video, dictionary or immersion toggle.
// A previously revealed definition cannot carry over to a new word.
struct PlaybackDictionaryDefinition: View {
  struct Identity: Hashable {
    let session: UUID
    let token: UUID
    let dictionary: String
    let immersion: Bool
  }
  let entry: DictionaryEntry
  let detailed: Bool
  let initiallyMasked: Bool
  var initiallyExpanded: Bool = true
  @State private var meaningVisible = false
  @State private var fullDefinitionExpanded: Bool?
  var revealed: Bool { !initiallyMasked || meaningVisible }
  var primaryGloss: String {
    let section = entry.sections.first(where: { $0.partOfSpeech == entry.partOfSpeech })
      ?? entry.sections.first
    return section?.senses.first?.shortMeaning ?? entry.shortGloss
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("意味").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Spacer()
          if initiallyMasked {
            Button(meaningVisible ? "日本語を隠す" : "日本語を表示",
              systemImage: meaningVisible ? "eye.slash" : "eye") { meaningVisible.toggle() }
              .help("日本語の意味・詳細定義の表示を切り替える")
          }
        }
        MaskedDictionaryContent(revealed: revealed, onReveal: { meaningVisible = true }) {
          Text(primaryGloss).font(.system(size: 28, weight: .medium)).lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if detailed {
        Divider()
        if !initiallyExpanded, let section = entry.sections.first(where: { $0.partOfSpeech == entry.partOfSpeech })
          ?? entry.sections.first {
          MaskedDictionaryContent(revealed: revealed, onReveal: { meaningVisible = true }, maskedHeight: 100) {
            VStack(alignment: .leading, spacing: 18) {
              Text("語義と例文").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              ForEach(Array(section.senses.prefix(3).enumerated()), id: \.offset) { index, sense in
                HStack(alignment: .top, spacing: 12) {
                  Text("\(index + 1)").font(.callout.weight(.bold)).foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .leading)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(sense.meaning).font(.system(size: 18, weight: .medium))
                    if let example = sense.examples.first {
                      Text(example).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                  }
                }.padding(12)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
              }
            }.textSelection(.enabled)
          }
        }
        DisclosureGroup(isExpanded: Binding(
          get: { fullDefinitionExpanded ?? initiallyExpanded },
          set: { fullDefinitionExpanded = $0 })) {
          if fullDefinitionExpanded ?? initiallyExpanded {
            MaskedDictionaryContent(revealed: revealed, onReveal: { meaningVisible = true }, maskedHeight: 120) {
              DictionaryBodyText(text: entry.definition, blocks: entry.blocks)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
          }
        } label: {
          Text("すべての語義・例文・用法").font(.callout.weight(.semibold))
        }
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct DictionaryPronunciation: View {
  let value: String?
  var size: CGFloat = 26
  var body: some View {
    if let value, !value.isEmpty {
      Text(value).font(.system(size: size, weight: .medium))
        .foregroundStyle(.primary.opacity(0.85)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("発音記号：" + value)
    }
  }
}
