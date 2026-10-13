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
  @State private var meaningVisible = false
  var revealed: Bool { !initiallyMasked || meaningVisible }
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
          Text(entry.shortGloss).font(.system(size: 30, weight: .medium)).lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if detailed {
        Divider()
        MaskedDictionaryContent(revealed: revealed, onReveal: { meaningVisible = true }) {
          VStack(alignment: .leading, spacing: 14) {
            Text("詳細定義").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !entry.sections.isEmpty {
              if let pronunciation = entry.pronunciation, !pronunciation.isEmpty {
                Text(pronunciation).font(.system(size: 17)).foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              ForEach(Array(entry.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 14) {
                  Text(section.partOfSpeech).font(.headline).foregroundStyle(.secondary)
                  ForEach(Array(section.senses.enumerated()), id: \.offset) { index, sense in
                    VStack(alignment: .leading, spacing: 8) {
                      Text("\(index + 1). " + sense.meaning).font(.system(size: 21, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                      ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                        Text(example).font(.system(size: 16)).foregroundStyle(.secondary)
                          .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                          .textSelection(.enabled)
                      }
                    }
                  }
                }.lineSpacing(7).padding(.vertical, 6)
              }
            } else {
              ForEach(
                Array(DictionaryText.paragraphs(entry.definition).enumerated()), id: \.offset
              ) { _, paragraph in
                Text(paragraph).font(.system(size: 19)).lineSpacing(7)
                  .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
  }
}
