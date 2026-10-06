// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FrameshiftMacRelease",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "FrameshiftMacRelease", targets: ["FrameshiftMacRelease"]),
    .executable(name: "frameshift-mac-release", targets: ["FrameshiftMacReleaseCLI"]),
  ],
  targets: [
    .target(name: "FrameshiftMacRelease"),
    .executableTarget(
      name: "FrameshiftMacReleaseCLI", dependencies: ["FrameshiftMacRelease"]
    ),
    .testTarget(
      name: "FrameshiftMacReleaseTests", dependencies: ["FrameshiftMacRelease"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
