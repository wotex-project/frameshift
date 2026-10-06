// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FrameshiftMac",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "FrameshiftShell", targets: ["FrameshiftShell"]),
    .executable(name: "frameshift-menu", targets: ["FrameshiftMenu"]),
    .executable(name: "frameshift-shell-checks", targets: ["FrameshiftShellChecks"]),
    .executable(name: "frameshift-updater-probe", targets: ["FrameshiftUpdaterProbe"]),
    .executable(name: "frameshift-ipc-probe", targets: ["FrameshiftIPCProbe"]),
    .executable(name: "frameshift-keychain-probe", targets: ["FrameshiftKeychainProbe"]),
    .executable(name: "frameshiftctl", targets: ["FrameshiftCTL"]),
  ],
  targets: [
    .target(name: "FrameshiftShell"),
    .binaryTarget(
      name: "Sparkle",
      url:
        "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
      checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
    ),
    .target(name: "FrameshiftUpdater", dependencies: ["FrameshiftShell", "Sparkle"]),
    .executableTarget(
      name: "FrameshiftUpdaterProbe", dependencies: ["FrameshiftUpdater", "FrameshiftShell"],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
      ]),
    .executableTarget(
      name: "FrameshiftMenu",
      dependencies: ["FrameshiftShell", "FrameshiftUpdater"],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
      ]
    ),
    .executableTarget(
      name: "FrameshiftShellChecks",
      dependencies: ["FrameshiftShell"]
    ),
    .executableTarget(
      name: "FrameshiftIPCProbe",
      dependencies: ["FrameshiftShell"]
    ),
    .executableTarget(
      name: "FrameshiftKeychainProbe",
      dependencies: ["FrameshiftShell"]
    ),
    .executableTarget(
      name: "FrameshiftCTL",
      dependencies: ["FrameshiftShell"]
    ),
    .testTarget(
      name: "FrameshiftShellTests",
      dependencies: ["FrameshiftShell"]
    ),
    .testTarget(
      name: "FrameshiftUpdaterTests",
      dependencies: ["FrameshiftUpdater"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
