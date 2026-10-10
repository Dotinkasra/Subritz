import AppKit
import ImageIO
import UniformTypeIdentifiers

// Deterministic icon generation from the original artwork. No image generation service.
// Supply the untouched square artwork; corners and transparent margins are applied here.
let arguments = CommandLine.arguments
let sourceURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "scripts/Assets/AppIconSource.png")
let iconURL = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "scripts/Resources/AppIcon.icns")
let previewURL = URL(fileURLWithPath: arguments.count > 3 ? arguments[3] : "scripts/Assets/AppIcon.png")
let sourceOptions: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions),
  let artwork = CGImageSourceCreateThumbnailAtIndex(source, 0, [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 1024,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
  ] as CFDictionary) else { fatalError("Cannot read icon artwork: \(sourceURL.path)") }
guard artwork.width == artwork.height else { fatalError("Icon artwork must be square") }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Subritz-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func render(size: Int, to url: URL) throws {
  guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create icon canvas") }
  context.interpolationQuality = .high
  context.setAllowsAntialiasing(true)
  // macOS 15-compatible .icns artwork includes its own transparent margin and mask.
  let scale = CGFloat(size) / 1024
  let tile = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  let path = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
  context.addPath(path)
  context.clip()
  context.draw(artwork, in: tile)
  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("Cannot write PNG") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save \(url.path)") }
}
for points in [16, 32, 128, 256, 512] {
  for multiplier in [1, 2] {
    let suffix = multiplier == 2 ? "@2x" : ""
    try render(size: points * multiplier,
      to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
  }
}
try FileManager.default.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(size: 1024, to: previewURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", iconURL.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("App icon: \(iconURL.path)")
