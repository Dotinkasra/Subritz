import Foundation

public struct PlaybackResumePosition: Sendable, Equatable {
  public let time: Double
  public let duration: Double
  public let date: Date
  public init(time: Double, duration: Double, date: Date) {
    self.time = time
    self.duration = duration
    self.date = date
  }
  public var isValid: Bool {
    time.isFinite && duration.isFinite && duration > 0 && time >= 0 && time <= duration
      && date.timeIntervalSince1970.isFinite
  }
}

/// Piggybacks on iframe samples; no extra timer, UI updates or interpolated times.
public struct PlaybackResumeTracker {
  public private(set) var latest: PlaybackResumePosition?
  private var checkpointUptime: Double?
  private var checkpointTime: Double?
  private var previousState: Int?
  public init() {}

  public mutating func receive(time: Double, duration: Double, state: Int,
    uptime: Double, date: Date) -> PlaybackResumePosition? {
    let position = PlaybackResumePosition(time: time, duration: duration, date: date)
    guard position.isValid, uptime.isFinite, [0, 1, 2].contains(state) else { return nil }
    latest = position
    let stopped = previousState != state && (state == 0 || state == 2)
    previousState = state
    let due = checkpointUptime.map { uptime - $0 >= 5 } ?? true
    guard checkpointUptime == nil || stopped || (due && checkpointTime != time) else { return nil }
    checkpointUptime = uptime
    checkpointTime = time
    return position
  }
}
