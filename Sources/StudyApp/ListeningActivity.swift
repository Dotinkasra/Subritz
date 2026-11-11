import SwiftUI

/// Only the footer observes this object. Iframe samples must not invalidate the
/// complete study view hierarchy, and silence must not leave a stale green label.
@MainActor final class ListeningActivity: ObservableObject {
  @Published private(set) var isStudying = false
  private var deadline: ContinuousClock.Instant?
  private var expiration: Task<Void, Never>?
  private let inactivityTimeout: Duration = .seconds(5)

  func recordActivity(at now: ContinuousClock.Instant = .now) {
    deadline = now.advanced(by: inactivityTimeout)
    if !isStudying { isStudying = true }
    guard expiration == nil else { return }
    expiration = Task { [weak self] in
      while let target = self?.deadline {
        do { try await Task.sleep(until: target, clock: .continuous) }
        catch { return }
        guard !Task.isCancelled, let self else { return }
        if self.expireIfNeeded() { return }
      }
    }
  }
  @discardableResult func expireIfNeeded(at now: ContinuousClock.Instant = .now) -> Bool {
    guard let deadline, now >= deadline else { return false }
    stop()
    return true
  }
  func stop() {
    expiration?.cancel()
    expiration = nil
    deadline = nil
    if isStudying { isStudying = false }
  }
}

struct ListeningActivityIndicator: View {
  @ObservedObject var activity: ListeningActivity
  var body: some View {
    Text(activity.isStudying ? "●: 学習中" : "●: 休憩中")
      .foregroundStyle(activity.isStudying ? Color.green : Color.gray)
      .fixedSize()
  }
}
