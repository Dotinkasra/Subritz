import Foundation

public enum SubtitleAppearance {
  public static let characterRange = 20...140
  public static let defaultCharacters = 80
  public static let fontScaleRange = 0.65...1.35
  public static let defaultFontScale = 1.0
  public static func fontSize(current: Bool, scale: Double) -> Double {
    (current ? 26 : 21) * clampedFontScale(scale)
  }
  public static func clampedFontScale(_ scale: Double) -> Double {
    scale.isFinite
      ? min(fontScaleRange.upperBound, max(fontScaleRange.lowerBound, scale)) : defaultFontScale
  }
  public static func clampedCharacters(_ count: Int) -> Int {
    min(characterRange.upperBound, max(characterRange.lowerBound, count))
  }
}
