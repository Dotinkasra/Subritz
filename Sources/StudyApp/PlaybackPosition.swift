import Combine

/// UI position updates must not invalidate the complete study view hierarchy.
@MainActor final class PlaybackPosition: ObservableObject {
  @Published var time: Double = 0
  @Published var duration: Double = 0
}
