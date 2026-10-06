import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class UniversalBundleMergerTests: XCTestCase {
  func testWholeSliceComparisonRefusesChangedCodeWithIdenticalLoaderMetadata() async throws {
    let fixture = try await UniversalFixture()
    defer { fixture.remove() }
    let inputs = [fixture.arm.app, fixture.intel.app].map { $0 + "/Contents/MacOS/Frameshift" }
    let output = fixture.arm.base.root + "/merged"
    _ = try await OwnedCommand().run(
      AppleCommand(.lipo, arguments: ["-create"] + inputs + ["-output", output]))
    let metadata = try MachOInspector.inspect(output)
    try MachOInspector.verifyMerge(output, inputs: inputs)
    var bytes = try Data(contentsOf: URL(fileURLWithPath: output))
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: URL(fileURLWithPath: output))
    XCTAssertEqual(try MachOInspector.inspect(output), metadata)
    XCTAssertThrowsError(try MachOInspector.verifyMerge(output, inputs: inputs)) {
      XCTAssertEqual($0 as? ReleaseToolError, .digestMismatch)
    }
  }

  func testActualCLIObservationAndUsageRefusalKeepSourcesAndStage() async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().path
    let tool = package + "/.build/debug/frameshift-mac-release"
    let fixture = try await UniversalFixture()
    defer { fixture.remove() }
    let before = try fixture.sources()
    let command = OwnedCommand()
    let output = try await command.run(
      AppleCommand(
        executable: tool,
        arguments: [
          "merge-development-bundles", fixture.arm.app, fixture.intel.app, fixture.stage,
        ]))
    var expected = try NativeSignatureVerifier.verifyDevelopmentBundle(
      fixture.stage, architecture: .universal
    ).observationBytes()
    expected.append(10)
    XCTAssertEqual(output.standardOutput, expected)
    XCTAssertTrue(output.standardError.isEmpty)
    XCTAssertEqual(try fixture.sources(), before)
    let retained = try NativeBundleInspector.preparationSnapshot(fixture.stage)
    for (arguments, exitCode) in [
      (["merge-development-bundles"], Int32(64)),
      (["merge-development-bundles", fixture.arm.app, fixture.intel.app, fixture.stage], Int32(1)),
    ] {
      let refused = OwnedCommand()
      do {
        _ = try await refused.run(AppleCommand(executable: tool, arguments: arguments))
        XCTFail("Invalid/repeated CLI admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .childFailed) }
      let status = await refused.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(exitCode)))
      XCTAssertEqual(try NativeBundleInspector.preparationSnapshot(fixture.stage), retained)
    }
  }

  func testActualPinnedSDKBothCPUJoinKeepsAliasesAndExecutesStoppedController() async throws {
    guard let archive = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
      throw XCTSkip("FRAMESHIFT_SPARKLE_ARCHIVE is required for actual SDK merging")
    }
    let original = try SparkleInventory.named(archive)
    let fixture = try await UniversalFixture()
    defer { fixture.remove() }
    for (value, architecture) in [
      (fixture.arm, NativeBundleArchitecture.arm64), (fixture.intel, .intel),
    ] {
      _ = try await SparkleFrameworkStager().stage(
        archive: archive, app: value.app, architecture: architecture)
      let source = value.base.root + "/updater.m"
      try Data(
        """
        #import <Cocoa/Cocoa.h>
        #import <Sparkle/Sparkle.h>
        int main(void) { @autoreleasepool {
          SPUStandardUpdaterController *controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:nil userDriverDelegate:nil];
          BOOL active = controller.updater.canCheckForUpdates;
          puts(active ? "unexpected active check" : "controller stopped");
          return active ? 1 : 0;
        } }
        """.utf8
      ).write(to: URL(fileURLWithPath: source))
      let output = value.base.root + "/sdkmain"
      try await value.base.tool([
        "clang", "-arch", architecture.rawValue, "-mmacosx-version-min=15.0", "-fobjc-arc",
        "-F", value.app + "/Contents/Frameworks", "-framework", "Sparkle", "-framework", "Cocoa",
        "-Wl,-rpath,@loader_path/../Frameworks", "-Wl,-headerpad_max_install_names", source, "-o",
        output,
      ])
      XCTAssertEqual(rename(output, value.app + "/Contents/MacOS/Frameshift"), 0)
      _ = try await DevelopmentBundlePreparer().prepare(value.app, architecture: architecture)
    }
    let before = try fixture.sources()
    let result = try await UniversalBundleMerger().merge(
      arm: fixture.arm.app, intel: fixture.intel.app, stage: fixture.stage)
    XCTAssertEqual(result.natives.count, 12)
    XCTAssertEqual(result.links?.count, 9)
    XCTAssertEqual(result.declaredMinimum, "15.0.0")
    XCTAssertEqual(try fixture.sources(), before)
    XCTAssertEqual(try SparkleInventory.named(archive), original)
    let execution = try await OwnedCommand().run(
      AppleCommand(executable: fixture.stage + "/Contents/MacOS/Frameshift", arguments: []))
    XCTAssertEqual(
      String(decoding: execution.standardOutput, as: UTF8.self), "controller stopped\n")
  }

  func testActualBothCPUJoinPreservesSourcesHeadersCommonBytesAndSeals() async throws {
    let fixture = try await UniversalFixture()
    defer { fixture.remove() }
    let before = try fixture.sources()
    let merger = UniversalBundleMerger()
    let result = try await merger.merge(
      arm: fixture.arm.app, intel: fixture.intel.app, stage: fixture.stage)
    XCTAssertEqual(result.architecture, .universal)
    XCTAssertEqual(result.natives.count, 7)
    XCTAssertTrue(result.natives.allSatisfy { $0.slices.map(\.arch) == ["arm64", "x86_64"] })
    XCTAssertEqual(result.declaredMinimum, "14.0.0")
    XCTAssertEqual(try fixture.sources(), before)
    XCTAssertEqual(
      try result.observationBytes(),
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.stage, architecture: .universal)
        .observationBytes())
    _ = try await OwnedCommand().run(
      AppleCommand(
        executable: fixture.stage + "/Contents/MacOS/Frameshift", arguments: []))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.stage + "/Contents/.universal-work"))
    let status = await merger.retainUntilExitAfterRefusal()
    XCTAssertEqual(status, .stopped(.exited(0)))
    do {
      _ = try await merger.merge(
        arm: fixture.arm.app, intel: fixture.intel.app, stage: fixture.stage)
      XCTFail("Repeated producer admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childAlreadyStarted) }
  }

  func testCommonMetadataModesFileSetsTypesAndCPURefuseBeforeCopy() async throws {
    for variation in 0..<6 {
      let fixture = try await UniversalFixture()
      defer { fixture.remove() }
      switch variation {
      case 0:
        try Data("different common bytes".utf8).write(
          to: URL(fileURLWithPath: fixture.intel.app + "/Contents/Resources/common"))
      case 1:
        let info = fixture.intel.app + "/Contents/Info.plist"
        let text = try String(contentsOfFile: info, encoding: .utf8)
        try Data(
          text.replacingOccurrences(of: "io.frameshift.native-fixture", with: "io.frameshift.other")
            .utf8
        ).write(to: URL(fileURLWithPath: info))
      case 2:
        try FileManager.default.createDirectory(
          atPath: fixture.intel.app + "/Contents/Resources/extra-empty",
          withIntermediateDirectories: false)
      case 3:
        XCTAssertEqual(chmod(fixture.intel.app + "/Contents/Resources/common", 0o640), 0)
      case 4:
        try fixture.arm.base.copy(
          fixture.arm.base.executable, to: fixture.arm.app + "/Contents/Resources/extra-native")
        try fixture.intel.base.copy(
          fixture.intel.base.library, to: fixture.intel.app + "/Contents/Resources/extra-native")
        _ = try await DevelopmentBundlePreparer().prepare(fixture.arm.app, architecture: .arm64)
      default: break
      }
      _ = try await DevelopmentBundlePreparer().prepare(fixture.intel.app, architecture: .intel)
      let merger = UniversalBundleMerger()
      do {
        _ = try await merger.merge(
          arm: variation == 5 ? fixture.intel.app : fixture.arm.app,
          intel: fixture.intel.app, stage: fixture.stage)
        XCTFail("Conflicting pair admitted: \(variation)")
      } catch { XCTAssertTrue(error is ReleaseToolError) }
      let status = await merger.childStatus()
      XCTAssertEqual(status, .notStarted)
      XCTAssertTrue(try NativeBundleInspector.preparationSnapshot(fixture.stage).files.isEmpty)
    }
  }

  func testUnsafeNonemptyStageAndPhysicalOverlapRefuseWithoutChildren() async throws {
    let fixture = try await UniversalFixture()
    defer { fixture.remove() }
    let note = fixture.stage + "/retain"
    try Data("retained".utf8).write(to: URL(fileURLWithPath: note))
    let nonempty = UniversalBundleMerger()
    await refuses(nonempty, fixture: fixture)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: note)), Data("retained".utf8))
    try FileManager.default.removeItem(atPath: note)
    let unsafe = UniversalBundleMerger()
    XCTAssertEqual(chmod(fixture.parent, 0o755), 0)
    await refuses(unsafe, fixture: fixture)
    XCTAssertEqual(chmod(fixture.parent, 0o700), 0)
    let overlap = UniversalBundleMerger()
    do {
      _ = try await overlap.merge(
        arm: fixture.stage, intel: fixture.intel.app, stage: fixture.stage)
      XCTFail("Overlap admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    let alias = fixture.arm.base.root + "/source-app-alias"
    XCTAssertEqual(symlink(fixture.arm.app, alias), 0)
    let aliasInput = UniversalBundleMerger()
    do {
      _ = try await aliasInput.merge(arm: alias, intel: fixture.intel.app, stage: fixture.stage)
      XCTFail("Source leaf alias admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    for producer in [nonempty, unsafe, overlap, aliasInput] {
      let status = await producer.childStatus()
      XCTAssertEqual(status, .notStarted)
    }
  }

  func testSameByteSourceStageIntermediateAndPreparationChangesRetainWork() async throws {
    for variation in 0..<6 {
      let fixture = try await UniversalFixture()
      defer { fixture.remove() }
      let source = fixture.intel.app + "/Contents/Resources/common"
      let stage = fixture.stage
      let aliasParent = fixture.arm.base.root + "/source-parent-alias"
      let armParent = fixture.arm.parent
      if variation == 5 { XCTAssertEqual(symlink(fixture.intel.parent, aliasParent), 0) }
      let merger = UniversalBundleMerger()
      let counter = MergeCheckpointCounter()
      do {
        _ = try await merger.merge(
          arm: fixture.arm.app,
          intel: variation == 5 ? aliasParent + "/Frameshift.app" : fixture.intel.app, stage: stage
        ) {
          phase in
          if variation == 4 {
            guard phase == .preparationCheckpoint, counter.next() == 8 else { return }
            try Data("same common bytes".utf8).write(to: URL(fileURLWithPath: source))
          } else {
            guard phase == (variation == 3 ? .mergeWritten : .copied) else { return }
            switch variation {
            case 0: try Data("same common bytes".utf8).write(to: URL(fileURLWithPath: source))
            case 1:
              try Data("same common bytes".utf8).write(
                to: URL(fileURLWithPath: source), options: .atomic)
            case 2:
              try Data("same common bytes".utf8).write(
                to: URL(fileURLWithPath: stage + "/Contents/Resources/common"))
            case 3:
              try Data("changed intermediate".utf8).write(
                to: URL(fileURLWithPath: stage + "/Contents/.universal-work/merged"))
            default:
              guard unlink(aliasParent) == 0, symlink(armParent, aliasParent) == 0 else {
                throw ReleaseToolError.readFailed
              }
            }
          }
        }
        XCTFail("Changed custody admitted: \(variation)")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      let status = await merger.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
      XCTAssertTrue(FileManager.default.fileExists(atPath: stage + "/Contents/MacOS/Frameshift"))
    }
  }

  func testCancellationAndActualAppleDeadlineRetainDirectChild() async throws {
    for cancelled in [true, false] {
      let fixture = try await UniversalFixture()
      defer { fixture.remove() }
      let merger = UniversalBundleMerger()
      do {
        _ = try await Task {
          try await merger.merge(
            arm: fixture.arm.app, intel: fixture.intel.app, stage: fixture.stage,
            childSeconds: cancelled ? 15 : 0.000001,
            observe: { phase in
              if cancelled && phase == .copied { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }.value
        XCTFail("Cancelled/deadline producer admitted")
      } catch {
        XCTAssertEqual(error as? ReleaseToolError, cancelled ? .admissionCancelled : .childDeadline)
      }
      let status = await merger.retainUntilExitAfterRefusal()
      if case .stopped = status {} else { XCTFail("Direct child not reaped") }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stage))
    }
  }

  private func refuses(_ merger: UniversalBundleMerger, fixture: UniversalFixture) async {
    do {
      _ = try await merger.merge(
        arm: fixture.arm.app, intel: fixture.intel.app, stage: fixture.stage)
      XCTFail("Unsafe stage admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
  }
}

@MainActor
private final class UniversalFixture {
  let arm: PreparationFixture
  let intel: PreparationFixture
  let parent: String
  let stage: String

  init() async throws {
    arm = try await PreparationFixture(architecture: .arm64)
    intel = try await PreparationFixture(architecture: .intel)
    parent =
      arm.base.root + "/.package." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    stage = parent + "/Frameshift.app"
    try FileManager.default.createDirectory(
      atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      atPath: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    for (fixture, architecture) in [(arm, NativeBundleArchitecture.arm64), (intel, .intel)] {
      try Data("same common bytes".utf8).write(
        to: URL(fileURLWithPath: fixture.app + "/Contents/Resources/common"))
      _ = try await DevelopmentBundlePreparer().prepare(fixture.app, architecture: architecture)
    }
  }

  func sources() throws -> [BundleSnapshot] {
    try [arm.app, intel.app].map { try NativeBundleInspector.preparationSnapshot($0) }
  }

  func remove() {
    arm.remove()
    intel.remove()
  }
}

private final class MergeCheckpointCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
