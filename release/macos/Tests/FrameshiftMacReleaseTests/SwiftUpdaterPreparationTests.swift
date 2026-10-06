import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class SwiftUpdaterPreparationTests: XCTestCase {
  func testActualSwiftBothCPUAndUniversalProfilesFinishWithStrictClosureAndStoppedController()
    async throws
  {
    for architecture: NativeBundleArchitecture in [.arm64, .intel, .universal] {
      for selected in [false, true] {
        let fixture = try await SwiftUpdaterFixture(architecture: architecture, selected: selected)
        defer { fixture.remove() }
        let initial = try NativeBundleInspector.preparationSnapshot(fixture.app)
        let slices = try MachOInspector.inspect(fixture.shell)
        XCTAssertThrowsError(
          try NativeBundleInspector.inspect(fixture.app, architecture: architecture))
        let legacy = DevelopmentBundlePreparer()
        do {
          _ = try await legacy.prepare(fixture.app, architecture: architecture)
          XCTFail("Legacy producer accepted a different loader profile")
        } catch { XCTAssertEqual(error as? ReleaseToolError, .invalidBundle) }
        XCTAssertEqual(initial, try NativeBundleInspector.preparationSnapshot(fixture.app))
        let legacyExit = await legacy.retainUntilExitAfterRefusal()
        XCTAssertEqual(legacyExit, .stopped(.exited(0)))
        let result = try await DevelopmentBundlePreparer().prepareSwiftUpdater(
          fixture.app, architecture: architecture)
        XCTAssertEqual(result.links?.count, 9)
        XCTAssertEqual(result.natives.count, 12)
        for (left, right) in zip(slices, try MachOInspector.inspect(fixture.shell)) {
          XCTAssertEqual(left.minimum, right.minimum)
          XCTAssertEqual(left.dependencies, right.dependencies)
          XCTAssertEqual(right.rpaths, ["@executable_path/../Frameworks"])
        }
        let final = try NativeBundleInspector.preparationSnapshot(fixture.app)
        XCTAssertEqual(initial.links, final.links)
        XCTAssertEqual(
          initial.files.first { $0.value.path == fixture.header },
          final.files.first { $0.value.path == fixture.header })
        XCTAssertEqual(
          try result.observationBytes(),
          try NativeSignatureVerifier.verifyDevelopmentBundle(
            fixture.app, architecture: architecture
          ).observationBytes())
        #if arch(arm64)
          let native = architecture == .arm64 || architecture == .universal
        #else
          let native = architecture == .intel || architecture == .universal
        #endif
        if native {
          let physical = try XCTUnwrap(realpath(fixture.shell, nil))
          defer { free(physical) }
          let output = try await OwnedCommand().run(
            AppleCommand(executable: String(cString: physical), arguments: []))
          XCTAssertEqual(output.standardOutput, Data("controller stopped\n".utf8))
          XCTAssertEqual(
            output.standardError.count, 0, String(decoding: output.standardError, as: UTF8.self))
        }
      }
    }
  }

  func testAdditionalChangedRuntimeAndImportedPathsRefuseBeforeMutation() async throws {
    for change in 0..<6 {
      let fixture = try await SwiftUpdaterFixture()
      defer { fixture.remove() }
      let own = "@executable_path/../Frameworks"
      switch change {
      case 0:
        try await fixture.base.tool([
          "install_name_tool", "-add_rpath", "/usr/lib/extra", fixture.shell,
        ])
      case 1:
        try await fixture.base.tool([
          "install_name_tool", "-rpath", fixture.library + "swift-6.2/macosx",
          fixture.library + "swift-6.3/macosx", fixture.shell,
        ])
      case 2:
        try await fixture.base.tool([
          "install_name_tool", "-rpath", own, "@loader_path/foreign", fixture.shell,
        ])
      case 3:
        try await fixture.base.tool([
          "install_name_tool", "-change", "/usr/lib/libSystem.B.dylib", "@rpath/foreign.dylib",
          fixture.shell,
        ])
      case 4:
        try await fixture.base.tool([
          "install_name_tool", "-rpath", fixture.library + "swift-6.2/macosx",
          fixture.library + "swift-6.2/../swift-6.2/macosx", fixture.shell,
        ])
      default:
        try await fixture.base.tool([
          "install_name_tool", "-change", "/usr/lib/libSystem.B.dylib", BundleSparkle.importPath,
          fixture.app + "/Contents/MacOS/frameshiftctl",
        ])
      }
      let before = try NativeBundleInspector.preparationSnapshot(fixture.app)
      do {
        _ = try await DevelopmentBundlePreparer().prepareSwiftUpdater(
          fixture.app, architecture: .arm64)
        XCTFail("Different loader profile admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .invalidBundle) }
      XCTAssertEqual(before, try NativeBundleInspector.preparationSnapshot(fixture.app))
    }
  }

  func testLateMutationAndCancellationKeepRefusalAfterOwnedPreparation() async throws {
    for change in 0..<3 {
      let fixture = try await SwiftUpdaterFixture()
      defer { fixture.remove() }
      let note = fixture.app + "/Contents/Resources/note"
      try Data("retained bytes".utf8).write(to: URL(fileURLWithPath: note))
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      let preparer = DevelopmentBundlePreparer()
      do {
        _ = try await preparer.prepare(fixture.app, architecture: .arm64, swiftUpdater: true) {
          phase in
          if change == 2 && phase == .metadataPrepared {
            withUnsafeCurrentTask { $0?.cancel() }
          } else if phase == (change == 0 ? .pathsPrepared : .verified) {
            try Data("retained bytes".utf8).write(to: URL(fileURLWithPath: note))
          }
        }
        XCTFail("Late producer refusal became success")
      } catch {
        XCTAssertEqual(
          error as? ReleaseToolError, change == 2 ? .admissionCancelled : .inputChanged)
      }
      let status = await preparer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app))
    }
  }

  func testExplicitSwiftProfileRefusesAStageWithoutThePinnedFramework() async throws {
    let fixture = try await PreparationFixture()
    defer { fixture.remove() }
    let before = try NativeBundleInspector.preparationSnapshot(fixture.app)
    do {
      _ = try await DevelopmentBundlePreparer().prepareSwiftUpdater(
        fixture.app, architecture: .arm64)
      XCTFail("Missing updater became a Swift updater producer")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .invalidBundle) }
    XCTAssertEqual(before, try NativeBundleInspector.preparationSnapshot(fixture.app))
  }
}

@MainActor
private final class SwiftUpdaterFixture {
  let fixture: PreparationFixture
  var base: NativeBundleFixture { fixture.base }
  var app: String { fixture.app }
  var shell: String { app + "/Contents/MacOS/Frameshift" }
  let library: String
  let header = BundleSparkle.root + "/Versions/B/Headers/Sparkle.h"

  init(architecture: NativeBundleArchitecture = .arm64, selected: Bool = true) async throws {
    guard let archive = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
      throw XCTSkip("FRAMESHIFT_SPARKLE_ARCHIVE is required for the actual Swift updater profile")
    }
    try PinnedSparkleArchive.verify(archive)
    fixture = try await PreparationFixture(architecture: architecture)
    let tool = try await Self.command(.xcrun, ["--find", "swift"])
    let compiler = String(decoding: tool.standardOutput, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    library = String(compiler.dropLast("bin/swift".count)) + "lib/"
    do {
      let extracted = base.root + "/sdk"
      _ = try await Self.command(
        .unzip,
        [
          "-q", archive, "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*", "-d",
          extracted,
        ])
      let framework = extracted + "/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
      try FileManager.default.createDirectory(
        atPath: app + "/Contents/Frameworks", withIntermediateDirectories: false)
      try FileManager.default.copyItem(atPath: framework, toPath: app + "/" + BundleSparkle.root)
      let source = base.root + "/updater.swift"
      try Data(
        """
        import AppKit
        import Sparkle
        @main struct Probe {
          @MainActor static func main() {
            _ = NSApplication.shared
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            print(controller.updater.canCheckForUpdates ? "unexpected active check" : "controller stopped")
          }
        }
        """.utf8
      ).write(to: URL(fileURLWithPath: source))
      var outputs: [String] = []
      let architectures =
        architecture == .universal ? ["arm64", "x86_64"] : [architecture.rawValue]
      for arch in architectures {
        let output = base.root + "/updater-\(arch)"
        let extra =
          selected ? ["-Xlinker", "-rpath", "-Xlinker", library + "swift-6.2/macosx"] : []
        _ = try await Self.command(
          .xcrun,
          [
            "swiftc", "-parse-as-library", "-O", "-target", "\(arch)-apple-macos14.0", "-F",
            URL(fileURLWithPath: framework).deletingLastPathComponent().path, "-framework",
            "Sparkle",
          ] + extra + [
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", source, "-o",
            output,
          ])
        outputs.append(output)
      }
      XCTAssertEqual(unlink(shell), 0)
      if outputs.count == 2 {
        _ = try await Self.command(.lipo, ["-create"] + outputs + ["-output", shell])
      } else {
        try FileManager.default.copyItem(atPath: outputs[0], toPath: shell)
      }
      guard chmod(shell, 0o755) == 0 else { throw ReleaseToolError.readFailed }
    } catch {
      // Retain an incomplete fixture rather than deleting a failed producer stage.
      throw error
    }
  }
  func remove() { fixture.remove() }

  private static func command(_ tool: AppleTool, _ arguments: [String]) async throws
    -> OwnedCommandOutput
  {
    let child = OwnedCommand()
    do { return try await child.run(AppleCommand(tool, arguments: arguments)) } catch {
      _ = await child.retainUntilExitAfterRefusal()
      throw error
    }
  }
}
