import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class PinnedSparkleFrameworkTests: XCTestCase {
  func testActualArchiveCacheObservationAndRepeatedAdmissionPreserveAllCustody() async throws {
    let fixture = try await SparkleMaterialFixture()
    defer { fixture.remove() }
    let before = try fixture.identities()
    let owner = OwnedCommand()
    let result = try await PinnedSparkleFramework.verify(
      archive: fixture.archive, framework: fixture.framework, child: owner)
    let stopped = await owner.retainUntilExitAfterRefusal()
    XCTAssertEqual(stopped, .stopped(.exited(0)))
    XCTAssertEqual(result.files.count, 85)
    XCTAssertEqual(result.directories.count, 57)
    XCTAssertEqual(result.links.count, 9)
    XCTAssertEqual(result.native.count, 5)
    XCTAssertTrue(result.native.allSatisfy { $0.slices.map(\.arch) == ["arm64", "x86_64"] })
    let bytes = try result.observationBytes()
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(json["schemaVersion"] as? Int, 1)
    XCTAssertEqual(json["publicationAuthority"] as? String, "none")
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.parent))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
    XCTAssertEqual(before, try fixture.identities())
    let repeated = try await fixture.verify()
    XCTAssertEqual(bytes, try repeated.observationBytes())
    XCTAssertEqual(before, try fixture.identities())
  }

  func testWrongArchiveSizeDigestAndAliasRefuseBeforeCreatingScratch() async throws {
    let parent = "/tmp/frameshift-sparkle-invalid-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: parent) }
    let archive = parent + "/sdk.zip"
    let work = parent + "/work"
    try Data([0]).write(to: URL(fileURLWithPath: archive))
    XCTAssertEqual(chmod(archive, 0o600), 0)
    for size in [Int64(1), PinnedSparkleArchive.bytes] {
      XCTAssertEqual(truncate(archive, size), 0)
      do {
        _ = try await PinnedSparkleFramework.verify(
          archive: archive, framework: parent + "/missing", work: work, child: OwnedCommand())
        XCTFail("Wrong archive admitted")
      } catch {
        XCTAssertEqual(
          error as? ReleaseToolError, size == 1 ? .inputLimit : .digestMismatch)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: work))
    }
    XCTAssertEqual(unlink(archive), 0)
    XCTAssertEqual(symlink("missing", archive), 0)
    do {
      _ = try await PinnedSparkleFramework.verify(
        archive: archive, framework: parent + "/missing", work: work, child: OwnedCommand())
      XCTFail("Archive alias admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: work))
  }

  func testActualMissingChangedUnsealedExtraAliasModeLinkAndFIFORefuseWithoutRepair() async throws {
    for change in 0..<8 {
      let fixture = try await SparkleMaterialFixture()
      defer { fixture.remove() }
      let file = fixture.framework + "/Versions/B/Updater.app/Contents/PkgInfo"
      switch change {
      case 0:
        var bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        bytes[0] ^= 1
        try bytes.write(to: URL(fileURLWithPath: file))
      case 1:
        XCTAssertEqual(unlink(file), 0)
      case 2:
        try FileManager.default.createDirectory(
          atPath: fixture.framework + "/extra-empty", withIntermediateDirectories: false)
      case 3:
        let alias = fixture.framework + "/Versions/Current"
        XCTAssertEqual(unlink(alias), 0)
        XCTAssertEqual(symlink("missing", alias), 0)
      case 4:
        XCTAssertEqual(chmod(file, 0o600), 0)
      case 5:
        // This Mac refuses creating PkgInfo links; a header exercises an actual accepted link.
        XCTAssertEqual(
          Darwin.link(
            fixture.framework + "/Versions/B/Headers/SPUUpdater.h",
            fixture.parent + "/retained-link"), 0)
      case 6:
        XCTAssertEqual(unlink(file), 0)
        XCTAssertEqual(mkfifo(file, 0o600), 0)
      default:
        XCTAssertEqual(unlink(file), 0)
        XCTAssertEqual(symlink("Info.plist", file), 0)
      }
      let before = try fixture.identities()
      do {
        _ = try await fixture.verify()
        XCTFail("Changed cached SDK admitted")
      } catch {}
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work))
      XCTAssertEqual(before, try fixture.identities())
    }
  }

  func testActualLateOriginalCopyCacheExpectedAndScratchMutationsRefuseAndCloseDescriptors()
    async throws
  {
    for change in 0..<6 {
      let fixture = try await SparkleMaterialFixture()
      defer { fixture.remove() }
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      do {
        _ = try await PinnedSparkleFramework.verify(
          archive: fixture.archive, framework: fixture.framework, work: fixture.work,
          child: OwnedCommand(),
          observe: { phase in
            guard phase == .cacheChecked else { return }
            let file: String
            switch change {
            case 0: file = fixture.framework + "/Versions/B/Headers/SPUUpdater.h"
            case 1:
              try FileManager.default.createDirectory(
                atPath: fixture.framework + "/late-empty", withIntermediateDirectories: false)
              return
            case 2: file = fixture.archive
            case 3: file = fixture.work + "/sdk.zip"
            case 4:
              file =
                fixture.work
                + "/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Headers/SPUUpdater.h"
            default:
              try FileManager.default.createDirectory(
                atPath: fixture.work + "/late-empty", withIntermediateDirectories: false)
              return
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
            try bytes.write(to: URL(fileURLWithPath: file))
          })
        XCTFail("Late custody mutation admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work))
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
    }
  }

  func testActualUnzipDeadlineRetainsScratchAndConfirmsOnlyExistingOwnedExit() async throws {
    let fixture = try await SparkleMaterialFixture()
    var removable = false
    defer { if removable { fixture.remove() } }
    let before = try fixture.identities()
    let child = OwnedCommand()
    do {
      _ = try await PinnedSparkleFramework.verify(
        archive: fixture.archive, framework: fixture.framework, work: fixture.work, child: child,
        limits: ChildLimits(seconds: 0.001))
      XCTFail("Unzip deadline admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childDeadline) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work + "/sdk.zip"))
    let status = try await child.observeExit(seconds: 5)
    guard case .stopped = status else {
      XCTFail("Owned unzip exit remains unconfirmed; scratch retained")
      return
    }
    removable = true
    let repeated = await child.status()
    let observed = try await child.observeExit(seconds: 0)
    XCTAssertEqual(status, repeated)
    XCTAssertEqual(status, observed)
    XCTAssertEqual(before, try fixture.identities())
  }

  func testActualCancellationAfterChildExitKeepsScratchAndNeverReturnsLateObservation() async throws
  {
    let fixture = try await SparkleMaterialFixture()
    defer { fixture.remove() }
    let before = try fixture.identities()
    let child = OwnedCommand()
    let task = Task {
      try await PinnedSparkleFramework.verify(
        archive: fixture.archive, framework: fixture.framework, work: fixture.work, child: child,
        observe: { phase in
          if phase == .cacheChecked { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled admission returned an observation")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .admissionCancelled) }
    let status = await child.status()
    guard case .stopped = status else {
      XCTFail("Successful unzip lost actual exit custody")
      return
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work + "/sdk.zip"))
    XCTAssertEqual(before, try fixture.identities())
  }

  func testActualEntrySparseAndDepthBudgetsRefuseBeforeObservation() async throws {
    let fixture = try await SparkleMaterialFixture()
    defer { fixture.remove() }
    let extra = fixture.framework + "/extra"
    try FileManager.default.createDirectory(atPath: extra, withIntermediateDirectories: false)
    for index in 0..<360 { try Data().write(to: URL(fileURLWithPath: extra + "/\(index)")) }
    do {
      _ = try await fixture.verify(work: fixture.parent + "/exact")
      XCTFail("Extra cache names admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .digestMismatch) }
    try Data().write(to: URL(fileURLWithPath: extra + "/next"))
    do {
      _ = try await fixture.verify(work: fixture.parent + "/over")
      XCTFail("Entry overflow admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputLimit) }
    try FileManager.default.removeItem(atPath: extra)
    try Data().write(to: URL(fileURLWithPath: extra))
    XCTAssertEqual(truncate(extra, 16 * 1024 * 1024 + 1), 0)
    do {
      _ = try await fixture.verify(work: fixture.parent + "/sparse")
      XCTFail("Sparse overflow admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputLimit) }
    XCTAssertEqual(unlink(extra), 0)
    try FileManager.default.createDirectory(atPath: extra, withIntermediateDirectories: false)
    for index in 0..<4 {
      let path = extra + "/\(index)"
      try Data().write(to: URL(fileURLWithPath: path))
      XCTAssertEqual(truncate(path, 16 * 1024 * 1024), 0)
    }
    do {
      _ = try await fixture.verify(work: fixture.parent + "/aggregate")
      XCTFail("Aggregate byte overflow admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputLimit) }
    try FileManager.default.removeItem(atPath: extra)
    var long = fixture.framework
    for _ in 0..<4 {
      long += "/" + String(repeating: "p", count: 128)
      try FileManager.default.createDirectory(atPath: long, withIntermediateDirectories: false)
    }
    do {
      _ = try await fixture.verify(work: fixture.parent + "/long")
      XCTFail("Relative path overflow admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputLimit) }
    try FileManager.default.removeItem(
      atPath: fixture.framework + "/" + String(repeating: "p", count: 128))
    var deep = fixture.framework
    for _ in 0..<25 {
      deep += "/d"
      try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: false)
    }
    do {
      _ = try await fixture.verify(work: fixture.parent + "/deep")
      XCTFail("Depth overflow admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputLimit) }
  }
}

private final class SparkleMaterialFixture: Sendable {
  let parent: String
  let archive: String
  let framework: String
  let work: String
  init() async throws {
    guard let original = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
      throw XCTSkip("FRAMESHIFT_SPARKLE_ARCHIVE is required for exact upstream SDK bytes")
    }
    try PinnedSparkleArchive.verify(original)
    parent = "/tmp/frameshift-sparkle-test-\(UUID().uuidString)"
    archive = parent + "/sdk.zip"
    framework = parent + "/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    work = parent + "/work"
    try FileManager.default.createDirectory(
      atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let producer = OwnedCommand()
    do {
      try FileManager.default.copyItem(atPath: original, toPath: archive)
      guard chmod(archive, 0o600) == 0 else { throw ReleaseToolError.readFailed }
      _ = try await producer.run(
        AppleCommand(
          .unzip,
          arguments: [
            "-q", archive, "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*", "-d",
            parent,
          ]))
    } catch {
      switch await producer.status() {
      case .stopped, .notStarted: remove()
      case .running, .unconfirmed: break
      }
      throw error
    }
  }
  func verify(work: String? = nil) async throws -> PinnedSparkleFrameworkObservation {
    try await PinnedSparkleFramework.verify(
      archive: archive, framework: framework, work: work ?? self.work, child: OwnedCommand())
  }
  func remove() { try? FileManager.default.removeItem(atPath: parent) }
  func identities() throws -> [String: FileIdentity] {
    var values: [String: FileIdentity] = [:]
    let enumerator = FileManager.default.enumerator(atPath: framework)
    let names = ["", "/sdk.zip"] + (enumerator?.allObjects as? [String] ?? [])
    for name in names {
      let path = name == "/sdk.zip" ? archive : framework + (name.isEmpty ? "" : "/" + name)
      var state = stat()
      guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
      values[name] = FileIdentity(state)
    }
    return values
  }
}
