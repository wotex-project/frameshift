import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class DevelopmentBundlePreparerTests: XCTestCase {
  func testRealBothCPUsAndUniversalRemoveUnusedSelectedPathsAndDeriveMinimum() async throws {
    let toolchain = try await selectedLibrary()
    for architecture: NativeBundleArchitecture in [.arm64, .intel, .universal] {
      let fixture = try await PreparationFixture(architecture: architecture)
      defer { fixture.remove() }
      let shell = fixture.app + "/Contents/MacOS/Frameshift"
      let unused = toolchain + "swift-fixture/macosx"
      try await fixture.base.tool(["install_name_tool", "-add_rpath", unused, shell])
      try fixture.base.plist(minimum: "13.0").write(
        to: URL(fileURLWithPath: fixture.app + "/Contents/Info.plist"))
      let before = try MachOInspector.inspect(shell)
      let accepted = fixture.base.root + "/accepted"
      try Data("retained accepted output".utf8).write(to: URL(fileURLWithPath: accepted))
      let acceptedIdentity = try named(accepted)
      let preparer = DevelopmentBundlePreparer()
      let result = try await preparer.prepare(fixture.app, architecture: architecture)
      XCTAssertEqual(result.declaredMinimum, "14.0.0")
      XCTAssertEqual(result.nativeMinimum, "14.0.0")
      XCTAssertEqual(result.natives.count, 7)
      let after = try MachOInspector.inspect(shell)
      for (left, right) in zip(before, after) {
        XCTAssertEqual(left.minimum, right.minimum)
        XCTAssertEqual(left.dependencies, right.dependencies)
        XCTAssertEqual(left.rpaths.filter { $0 != unused }, right.rpaths)
      }
      XCTAssertEqual(
        try result.observationBytes(),
        try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: architecture)
          .observationBytes())
      XCTAssertEqual(acceptedIdentity, try named(accepted))
      XCTAssertEqual(
        try Data(contentsOf: URL(fileURLWithPath: accepted)), Data("retained accepted output".utf8))
      let status = await preparer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
      do {
        _ = try await preparer.prepare(fixture.app, architecture: architecture)
        XCTFail("One-shot producer reused")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .childAlreadyStarted) }
    }
  }

  func testWrongStageNameParentModeAndAliasRefuseBeforeAnyChild() async throws {
    let fixture = try await PreparationFixture()
    defer { fixture.remove() }
    let aliasParent = fixture.base.root + "/.package.Alias"
    XCTAssertEqual(symlink(fixture.parent, aliasParent), 0)
    let cases = [
      fixture.base.root + "/Frameshift.app", fixture.parent + "/existing.app",
      aliasParent + "/Frameshift.app",
      fixture.base.root + "/.package.A\n/Frameshift.app",
    ]
    for input in cases {
      let preparer = DevelopmentBundlePreparer()
      await refuses(preparer, input: input, error: .unsafeInput)
      let status = await preparer.childStatus()
      XCTAssertEqual(status, .notStarted)
    }
    XCTAssertEqual(chmod(fixture.parent, 0o755), 0)
    let preparer = DevelopmentBundlePreparer()
    await refuses(preparer, input: fixture.app, error: .unsafeInput)
    let status = await preparer.childStatus()
    XCTAssertEqual(status, .notStarted)
  }

  func testForeignNoncanonicalAndRunPathImportsRefuseWithoutMutation() async throws {
    let library = try await selectedLibrary()
    for change in 0..<3 {
      let fixture = try await PreparationFixture()
      defer { fixture.remove() }
      let shell = fixture.app + "/Contents/MacOS/Frameshift"
      let rpath =
        change == 0
        ? "/opt/homebrew/lib" : library + (change == 1 ? "swift/../foreign" : "swift-fixture")
      try await fixture.base.tool(["install_name_tool", "-add_rpath", rpath, shell])
      if change == 2 {
        try await fixture.base.tool([
          "install_name_tool", "-change", "/usr/lib/libSystem.B.dylib", "@rpath/native.dylib",
          shell,
        ])
      }
      let before = try NativeBundleInspector.preparationSnapshot(fixture.app)
      let preparer = DevelopmentBundlePreparer()
      await refuses(preparer, input: fixture.app, error: .invalidBundle)
      XCTAssertEqual(before, try NativeBundleInspector.preparationSnapshot(fixture.app))
      let status = await preparer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
    }
  }

  func testUnrelatedSameByteNamespaceAndParentMutationRefuseAndRetainStage() async throws {
    for change in 0..<4 {
      let fixture = try await PreparationFixture()
      defer { fixture.remove() }
      let note = fixture.app + "/Contents/Resources/note"
      try Data("same bytes".utf8).write(to: URL(fileURLWithPath: note))
      let parent = fixture.parent
      let extra = change == 1 ? fixture.app + "/extra-empty" : parent + "/foreign-empty"
      let preparer = DevelopmentBundlePreparer()
      do {
        _ = try await preparer.prepare(fixture.app, architecture: .arm64) { phase in
          guard phase == (change == 3 ? .verified : .inventoried) else { return }
          if change == 0 || change == 3 {
            try Data("same bytes".utf8).write(to: URL(fileURLWithPath: note))
          } else {
            try FileManager.default.createDirectory(
              atPath: extra, withIntermediateDirectories: false)
          }
        }
        XCTFail("Changed stage admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app))
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: note)), Data("same bytes".utf8))
      let status = await preparer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
    }
  }

  func testCancellationAfterRealPreparationPhaseNeverSealsOrPromotes() async throws {
    let fixture = try await PreparationFixture()
    defer { fixture.remove() }
    let preparer = DevelopmentBundlePreparer()
    do {
      _ = try await preparer.prepare(fixture.app, architecture: .arm64) { phase in
        if phase == .metadataPrepared {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
      XCTFail("Cancelled stage admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .admissionCancelled) }
    let status = await preparer.retainUntilExitAfterRefusal()
    XCTAssertEqual(status, .stopped(.exited(0)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app + "/Contents/_CodeSignature"))
    XCTAssertEqual(
      try NativePropertyList.read(fixture.app + "/Contents/Info.plist").values[
        "LSMinimumSystemVersion"],
      .string("14.0.0"))
  }

  func testRealOwnedAppleChildDeadlineRetainsStageAndReadOnlyExit() async throws {
    let fixture = try await PreparationFixture()
    defer { fixture.remove() }
    let before = try NativeBundleInspector.preparationSnapshot(fixture.app)
    let preparer = DevelopmentBundlePreparer()
    do {
      _ = try await preparer.prepare(
        fixture.app, architecture: .arm64, childSeconds: 0.000001, observe: nil)
      XCTFail("Child deadline admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childDeadline) }
    let status = await preparer.retainUntilExitAfterRefusal()
    if case .stopped = status {} else { XCTFail("Actual child exit remains unknown: \(status)") }
    XCTAssertEqual(before, try NativeBundleInspector.preparationSnapshot(fixture.app))
  }

  func testActualPinnedSDKContainersReceiveInsideOutSeals() async throws {
    guard let archive = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
      throw XCTSkip("FRAMESHIFT_SPARKLE_ARCHIVE is required for actual updater bytes")
    }
    try PinnedSparkleArchive.verify(archive)
    let fixture = try await PreparationFixture(architecture: .universal)
    defer { fixture.remove() }
    let extracted = fixture.base.root + "/sdk"
    _ = try await OwnedCommand().run(
      AppleCommand(
        .unzip,
        arguments: [
          "-q", archive, "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*", "-d",
          extracted,
        ]))
    let framework = extracted + "/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    let destination = fixture.app + "/" + BundleSparkle.root
    try FileManager.default.createDirectory(
      atPath: fixture.app + "/Contents/Frameworks", withIntermediateDirectories: false)
    try FileManager.default.copyItem(atPath: framework, toPath: destination)
    let original = try NativeBundleInspector.preparationSnapshot(fixture.app)
    var shells: [String] = []
    for arch in ["arm64", "x86_64"] {
      let output = fixture.base.root + "/sdk-\(arch)"
      try await fixture.base.tool([
        "clang", "-target", "\(arch)-apple-macos14.0", "-F",
        URL(fileURLWithPath: framework).deletingLastPathComponent().path,
        "-framework", "Sparkle", "-Wl,-rpath,@executable_path/../Frameworks",
        fixture.base.root + "/input.c", "-o", output,
      ])
      shells.append(output)
    }
    _ = try await OwnedCommand().run(
      AppleCommand(
        .lipo,
        arguments: ["-create"] + shells + ["-output", fixture.app + "/Contents/MacOS/Frameshift"]))
    let result = try await DevelopmentBundlePreparer().prepare(
      fixture.app, architecture: .universal)
    XCTAssertEqual(result.links?.count, 9)
    XCTAssertEqual(result.natives.count, 12)
    XCTAssertEqual(
      try result.observationBytes(),
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: .universal)
        .observationBytes())
    let final = try NativeBundleInspector.preparationSnapshot(fixture.app)
    XCTAssertEqual(original.links, final.links)
    let header = BundleSparkle.root + "/Versions/B/Headers/Sparkle.h"
    XCTAssertEqual(
      original.files.first { $0.value.path == header },
      final.files.first { $0.value.path == header })
  }

  private func refuses(
    _ preparer: DevelopmentBundlePreparer, input: String, error: ReleaseToolError
  ) async {
    do {
      _ = try await preparer.prepare(input, architecture: .arm64)
      XCTFail("Unsafe preparation admitted")
    } catch let actual { XCTAssertEqual(actual as? ReleaseToolError, error) }
  }
  private func selectedLibrary() async throws -> String {
    let output = try await OwnedCommand().run(AppleCommand(.xcrun, arguments: ["--find", "swift"]))
    let compiler = String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return String(compiler.dropLast("bin/swift".count)) + "lib/"
  }
  private func named(_ path: String) throws -> FileIdentity {
    var state = stat()
    guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(state)
  }
}

@MainActor
private final class PreparationFixture {
  let base: NativeBundleFixture
  let parent: String
  let app: String
  init(architecture: NativeBundleArchitecture = .arm64) async throws {
    base = try await NativeBundleFixture(architecture: architecture)
    parent = base.root + "/.package." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    app = parent + "/Frameshift.app"
    try FileManager.default.createDirectory(
      atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard rename(base.app, app) == 0 else { throw ReleaseToolError.readFailed }
  }
  func remove() { base.remove() }
}
