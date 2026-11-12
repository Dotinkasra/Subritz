import Foundation
import CoreGraphics
import Testing
@testable import StudyCore

struct VideoMaskShapeTests {
  let shape = VideoMaskShape(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
  let canvas = CGSize(width: 1000, height: 600)

  @Test func geometryStaysRelativeToTheVideoAndMovementStaysInside() {
    let small = shape.rect(in: canvas)
    let large = shape.rect(in: CGSize(width: 2000, height: 1200))
    #expect(large.origin.x == small.origin.x * 2 && large.height == small.height * 2)
    let moved = shape.moved(by: CGSize(width: 9000, height: -9000), in: canvas)
    #expect(moved.x == 0.5 && moved.y == 0)
    #expect(moved.width == shape.width && moved.height == shape.height)
    #expect(shape.moved(by: CGSize(width: 10, height: 10), in: .zero) == shape)
  }
  @Test(arguments: VideoMaskShape.Corner.allCases)
  func resizingFixesTheOppositeCornerAndChangesBothDimensions(corner: VideoMaskShape.Corner) {
    let next = shape.resized(at: corner, by: CGSize(width: 50, height: 30), in: canvas)
    let left = corner == .topLeft || corner == .bottomLeft
    let top = corner == .topLeft || corner == .topRight
    #expect(abs((left ? next.x + next.width : next.x) - (left ? shape.x + shape.width : shape.x)) < 0.000001)
    #expect(abs((top ? next.y + next.height : next.y) - (top ? shape.y + shape.height : shape.y)) < 0.000001)
    #expect(next.width != shape.width && next.height != shape.height)
    let clamped = shape.resized(at: corner, by: CGSize(width: 9000, height: -9000), in: canvas)
    #expect(clamped.x >= 0 && clamped.y >= 0 && clamped.x + clamped.width <= 1.000001 && clamped.y + clamped.height <= 1.000001)
    #expect(clamped.width >= 0.016 - 0.000001 && clamped.height >= 16.0 / 600 - 0.000001)
  }
  @Test func settingsRememberTheTemplateAndOlderSettingsRemainReadable() throws {
    var settings = AppSettings()
    settings.videoMaskTemplate = VideoMaskShape(x: 0.4, y: 0.5, width: 0.3, height: 0.2,
      red: 0.2, green: 0.3, blue: 0.4, opacity: 0.8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.videoMaskTemplate == settings.videoMaskTemplate)
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).videoMaskTemplate == .initial)
    #expect(VideoMaskShape(x: .nan, y: -1, width: 2, height: 0, opacity: 5).normalized
      == VideoMaskShape(x: 0, y: 0, width: 1, height: 0.01))
  }
}
