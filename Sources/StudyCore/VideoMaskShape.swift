import Foundation
import CoreGraphics

public struct VideoMaskShape: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var red: Double
  public var green: Double
  public var blue: Double
  public var opacity: Double
  public static let initial = VideoMaskShape(x: 0.1, y: 0.7, width: 0.8, height: 0.15)

  public init(x: Double, y: Double, width: Double, height: Double,
    red: Double = 0, green: Double = 0, blue: Double = 0, opacity: Double = 1) {
    func unit(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
    self.width = max(0.01, unit(width, fallback: 0.8))
    self.height = max(0.01, unit(height, fallback: 0.15))
    self.x = min(1 - self.width, unit(x, fallback: 0.1))
    self.y = min(1 - self.height, unit(y, fallback: 0.7))
    self.red = unit(red, fallback: 0); self.green = unit(green, fallback: 0)
    self.blue = unit(blue, fallback: 0); self.opacity = unit(opacity, fallback: 1)
  }
  public var normalized: Self {
    Self(x: x, y: y, width: width, height: height, red: red, green: green, blue: blue, opacity: opacity)
  }
  public func rect(in size: CGSize) -> CGRect {
    let origin = CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
    let extent = CGSize(width: CGFloat(width) * size.width, height: CGFloat(height) * size.height)
    return CGRect(origin: origin, size: extent)
  }
  public func moved(by delta: CGSize, in size: CGSize) -> Self {
    guard size.width > 0, size.height > 0 else { return self }
    var value = self
    value.x = min(1 - width, max(0, x + Double(delta.width / size.width)))
    value.y = min(1 - height, max(0, y + Double(delta.height / size.height)))
    return value
  }
  public enum Corner: Int, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
  public func resized(at corner: Corner, by delta: CGSize, in size: CGSize) -> Self {
    guard size.width > 0, size.height > 0 else { return self }
    let minWidth = min(1, 16 / Double(size.width)), minHeight = min(1, 16 / Double(size.height))
    let dx = Double(delta.width / size.width), dy = Double(delta.height / size.height)
    var left = x, right = x + width, top = y, bottom = y + height
    if corner == .topLeft || corner == .bottomLeft { left = min(right - minWidth, max(0, x + dx)) }
    else { right = max(left + minWidth, min(1, right + dx)) }
    if corner == .topLeft || corner == .topRight { top = min(bottom - minHeight, max(0, y + dy)) }
    else { bottom = max(top + minHeight, min(1, bottom + dy)) }
    var value = self
    value.x = max(0, left); value.y = max(0, top)
    value.width = min(1, right - left); value.height = min(1, bottom - top)
    return value.normalized
  }
}
