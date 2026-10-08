import Foundation

/// Monotonic interpolation between authoritative player samples. No advancement while paused/buffering.
public struct PlaybackClock {
  private var media: Double = 0
  private var wall: Double = 0
  private var lastSample: Double?
  private var state = -1
  private var rate: Double = 1
  public init() {}
  public mutating func sample(time: Double, now: Double, state: Int, rate: Double) {
    guard time.isFinite, now.isFinite, rate.isFinite, rate > 0 else { return }
    // YouTube can repeat a coarse timestamp. Resetting on each duplicate would freeze interpolation.
    if lastSample != time || self.state != state || self.rate != rate {
      media = max(0, time)
      wall = now
    }
    lastSample = time
    self.state = state
    self.rate = rate
  }
  public func position(now: Double) -> Double {
    media + (state == 1 ? min(0.25, max(0, now - wall)) * rate : 0)
  }
  public mutating func seek(to time: Double, now: Double) {
    media = max(0, time)
    wall = now
    lastSample = nil
  }
}
