import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class SparkleFrameworkStagerTests: XCTestCase {
  func testActualBothCPUsPreserveCommonBytesAliasesSourceCustodyAndOneShot() async throws {
    for architecture: NativeBundleArchitecture in [.arm64, .intel] {
      let fixture = try SparkleStageFixture(actualArchive: true)
      defer { fixture.remove() }
      let before = try SparkleInventory.named(fixture.archive)
      let note = try SparkleInventory.named(fixture.note)
      let parent = try SparkleInventory.named(fixture.parent)
      let producer = SparkleFrameworkStager()
      let result = try await producer.stage(
        archive: fixture.archive, app: fixture.app, architecture: architecture,
        work: fixture.work, observe: nil)
      XCTAssertEqual(result.source.files.count, 85)
      XCTAssertEqual(result.derived.files.count, 85)
      XCTAssertEqual(result.source.directories, result.derived.directories)
      XCTAssertEqual(result.source.links, result.derived.links)
      XCTAssertEqual(result.source.links.count, 9)
      XCTAssertEqual(result.derived.native.count, 5)
      for (original, derived) in zip(result.source.native, result.derived.native) {
        XCTAssertEqual(original.path, derived.path)
        XCTAssertEqual(original.slices.filter { $0.arch == architecture.rawValue }, derived.slices)
        XCTAssertEqual(
          try MachOInspector.inspect(fixture.app + "/" + BundleSparkle.root + "/" + original.path),
          derived.slices)
      }
      let native = Set(result.source.native.map(\.path))
      XCTAssertEqual(
        result.source.files.filter { !native.contains($0.path) },
        result.derived.files.filter { !native.contains($0.path) })
      XCTAssertEqual(before, try SparkleInventory.named(fixture.archive))
      XCTAssertEqual(note, try SparkleInventory.named(fixture.note))
      XCTAssertEqual(parent, try SparkleInventory.named(fixture.parent))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.app + "/Contents/Frameworks/.sparkle-work"))
      let bytes = try result.observationBytes()
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      XCTAssertEqual(json["architecture"] as? String, architecture.rawValue)
      XCTAssertEqual(json["publicationAuthority"] as? String, "none")
      XCTAssertLessThan(bytes.count, 64 * 1024)
      XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.parent))
      let status = await producer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
      do {
        _ = try await producer.stage(
          archive: fixture.archive, app: fixture.app, architecture: architecture)
        XCTFail("One-shot producer reused")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .childAlreadyStarted) }
    }
  }

  func testUnsafeStageExistingFrameworksAndUniversalRefuseBeforeChild() async throws {
    let fixture = try SparkleStageFixture()
    defer { fixture.remove() }
    let alias = fixture.root + "/.package.Alias"
    XCTAssertEqual(symlink(fixture.parent, alias), 0)
    for input in [
      fixture.root + "/Frameshift.app", alias + "/Frameshift.app", fixture.parent + "/wrong.app",
    ] {
      let producer = SparkleFrameworkStager()
      await refuses(producer, fixture: fixture, app: input)
      let status = await producer.childStatus()
      XCTAssertEqual(status, .notStarted)
    }
    for change in 0..<5 {
      switch change {
      case 0: XCTAssertEqual(chmod(fixture.parent, 0o755), 0)
      case 1: XCTAssertEqual(chmod(fixture.app, 0o777), 0)
      case 2: XCTAssertEqual(chmod(fixture.app + "/Contents", 0o777), 0)
      case 3: XCTAssertEqual(mkdir(fixture.app + "/Contents/Frameworks", 0o755), 0)
      default: XCTAssertEqual(symlink("missing", fixture.app + "/Contents/Frameworks"), 0)
      }
      let producer = SparkleFrameworkStager()
      await refuses(producer, fixture: fixture)
      let status = await producer.childStatus()
      XCTAssertEqual(status, .notStarted)
      XCTAssertEqual(chmod(fixture.parent, 0o700), 0)
      XCTAssertEqual(chmod(fixture.app, 0o755), 0)
      XCTAssertEqual(chmod(fixture.app + "/Contents", 0o755), 0)
      if change >= 3 {
        try FileManager.default.removeItem(atPath: fixture.app + "/Contents/Frameworks")
      }
    }
    let producer = SparkleFrameworkStager()
    do {
      _ = try await producer.stage(
        archive: fixture.archive, app: fixture.app, architecture: .universal)
      XCTFail("Universal derivation admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .invalidBundle) }
    let status = await producer.childStatus()
    XCTAssertEqual(status, .notStarted)
  }

  func testWrongArchiveAndPreExtractionStageChangeNeverCreateFrameworks() async throws {
    let fixture = try SparkleStageFixture()
    defer { fixture.remove() }
    try Data([0]).write(to: URL(fileURLWithPath: fixture.archive))
    XCTAssertEqual(chmod(fixture.archive, 0o600), 0)
    let producer = SparkleFrameworkStager()
    await refuses(producer, fixture: fixture)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app + "/Contents/Frameworks"))
    let changed = SparkleFrameworkStager()
    do {
      _ = try await changed.stage(
        archive: fixture.archive, app: fixture.app, architecture: .arm64,
        observe: { phase in
          guard phase == .admittedStage else { return }
          try Data("unchanged note".utf8).write(to: URL(fileURLWithPath: fixture.note))
        })
      XCTFail("Same-byte input replacement admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
    let status = await changed.childStatus()
    XCTAssertEqual(status, .notStarted)
  }

  func testActualLateRoleCommonAliasNamespaceArchiveAndParentMutationsRetainFailedStage()
    async throws
  {
    for change in 0..<8 {
      let fixture = try SparkleStageFixture(actualArchive: true)
      defer { fixture.remove() }
      let producer = SparkleFrameworkStager()
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      do {
        _ = try await producer.stage(
          archive: fixture.archive, app: fixture.app, architecture: .arm64,
          work: fixture.work,
          observe: { phase in
            guard phase == .derived else { return }
            let target = fixture.app + "/" + BundleSparkle.root
            switch change {
            case 0:
              let file = target + "/Versions/B/Headers/SPUUpdater.h"
              try Data(contentsOf: URL(fileURLWithPath: file)).write(to: URL(fileURLWithPath: file))
            case 1:
              let file = target + "/Versions/B/Sparkle"
              try Data(contentsOf: URL(fileURLWithPath: file)).write(to: URL(fileURLWithPath: file))
            case 2:
              try FileManager.default.createDirectory(
                atPath: target + "/foreign-empty", withIntermediateDirectories: false)
            case 3:
              let link = target + "/Versions/Current"
              guard unlink(link) == 0, symlink("missing", link) == 0 else {
                throw ReleaseToolError.readFailed
              }
            case 4:
              try Data(contentsOf: URL(fileURLWithPath: fixture.archive)).write(
                to: URL(fileURLWithPath: fixture.archive))
            case 5:
              try Data("unchanged note".utf8).write(to: URL(fileURLWithPath: fixture.note))
            case 6:
              try FileManager.default.createDirectory(
                atPath: fixture.parent + "/foreign-empty", withIntermediateDirectories: false)
            default:
              try Data().write(
                to: URL(fileURLWithPath: fixture.app + "/Contents/Frameworks/.sparkle-work/foreign")
              )
            }
          })
        XCTFail("Changed derivation admitted")
      } catch {
        XCTAssertTrue([.inputChanged, .invalidBundle].contains(error as? ReleaseToolError))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work + "/sdk.zip"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app))
      let status = await producer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
      // The actor retains one private-stage descriptor while its custody is live.
      XCTAssertEqual(
        (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count, descriptors.count + 1)
    }
  }

  func testActualIntermediateThinMutationAndCancellationNeverReturnOrCleanFailedWork() async throws
  {
    for cancel in [false, true] {
      let fixture = try SparkleStageFixture(actualArchive: true)
      defer { fixture.remove() }
      let producer = SparkleFrameworkStager()
      let task = Task {
        try await producer.stage(
          archive: fixture.archive, app: fixture.app, architecture: .arm64,
          work: fixture.work,
          observe: { phase in
            guard phase == .thinWritten else { return }
            if cancel {
              withUnsafeCurrentTask { $0?.cancel() }
            } else {
              let path = fixture.app + "/Contents/Frameworks/.sparkle-work/thin"
              try Data(contentsOf: URL(fileURLWithPath: path)).write(to: URL(fileURLWithPath: path))
            }
          })
      }
      do {
        _ = try await task.value
        XCTFail("Changed/cancelled thin output admitted")
      } catch {
        XCTAssertEqual(error as? ReleaseToolError, cancel ? .admissionCancelled : .inputChanged)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work + "/sdk.zip"))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.app + "/Contents/Frameworks/.sparkle-work/thin"))
      let status = await producer.retainUntilExitAfterRefusal()
      XCTAssertEqual(status, .stopped(.exited(0)))
    }
  }

  func testActualOwnedExtractionDeadlineKeepsMonitorAndOriginalCustody() async throws {
    let fixture = try SparkleStageFixture(actualArchive: true)
    var removable = false
    defer { if removable { fixture.remove() } }
    let before = try SparkleInventory.named(fixture.archive)
    let producer = SparkleFrameworkStager()
    do {
      _ = try await producer.stage(
        archive: fixture.archive, app: fixture.app, architecture: .arm64,
        childSeconds: 0.000001, work: fixture.work, observe: nil)
      XCTFail("Child deadline admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childDeadline) }
    let status = await producer.retainUntilExitAfterRefusal()
    guard case .stopped = status else {
      return XCTFail("Failed child remains owned; fixture retained")
    }
    removable = true
    XCTAssertEqual(before, try SparkleInventory.named(fixture.archive))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work + "/sdk.zip"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app + "/Contents/Frameworks"))
  }

  private func refuses(
    _ producer: SparkleFrameworkStager, fixture: SparkleStageFixture, app: String? = nil
  ) async {
    do {
      _ = try await producer.stage(
        archive: fixture.archive, app: app ?? fixture.app, architecture: .arm64)
      XCTFail("Unsafe stage admitted")
    } catch {}
  }
}

private final class SparkleStageFixture: Sendable {
  let root = "/tmp/frameshift-sparkle-stage-test-" + UUID().uuidString
  var parent: String { root + "/.package.Test" }
  var app: String { parent + "/Frameshift.app" }
  var archive: String { root + "/sdk.zip" }
  var work: String { root + "/work" }
  var note: String { app + "/Contents/Resources/note" }
  init(actualArchive: Bool = false) throws {
    let original: String?
    if actualArchive {
      guard let path = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
        throw XCTSkip("FRAMESHIFT_SPARKLE_ARCHIVE is required for actual pinned SDK derivation")
      }
      original = path
    } else {
      original = nil
    }
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (path, mode) in [
      (parent, 0o700), (app, 0o755), (app + "/Contents", 0o755),
      (app + "/Contents/Resources", 0o755),
    ] {
      try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
    }
    try Data("unchanged note".utf8).write(to: URL(fileURLWithPath: note))
    if let original {
      try FileManager.default.copyItem(atPath: original, toPath: archive)
      guard chmod(archive, 0o600) == 0 else { throw ReleaseToolError.readFailed }
    }
  }
  func remove() { try? FileManager.default.removeItem(atPath: root) }
}
