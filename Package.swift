// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "YouTubeEnglishStudy", platforms: [.macOS(.v15)],
  products: [.executable(name: "YouTubeEnglishStudy", targets: ["StudyApp"])],
  targets: [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(name: "StudyCore", dependencies: ["CSQLite"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "StudyApp", dependencies: ["StudyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "StudyCoreTests", dependencies: ["StudyCore"], resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]),
  ])
