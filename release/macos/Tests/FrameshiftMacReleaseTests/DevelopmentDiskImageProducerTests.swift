import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class DevelopmentDiskImageProducerTests: XCTestCase {
  func testActualFullSDKAppCLIImageReadbackAndNonemptyRerunRefusal() async throws {
    guard let app = ProcessInfo.processInfo.environment["FRAMESHIFT_PACKAGED_APP_FIXTURE"] else {
      throw XCTSkip(
        "FRAMESHIFT_PACKAGED_APP_FIXTURE is required for complete native image readback")
    }
    let architecture: NativeBundleArchitecture
    #if arch(arm64)
      architecture = .arm64
    #else
      architecture = .intel
    #endif
    let source = try NativeBundleInspector.inspectWithCustody(app, architecture: architecture)
    let fixture = try await ImageFixture()
    defer { fixture.removeIfSafe() }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().path
    let tool = package + "/.build/debug/frameshift-mac-release"
    fixture.cleanupAllowed = false
    let command = OwnedCommand()
    let output = try await command.run(
      AppleCommand(
        executable: tool,
        arguments: [
          "create-development-image", app, architecture.rawValue, fixture.workspace,
        ]), limits: ChildLimits(outputBytes: 2 * 1024 * 1024, seconds: 300))
    fixture.cleanupAllowed = true  // Successful CLI returns only after confirmed detach.
    let value = try XCTUnwrap(
      JSONSerialization.jsonObject(with: output.standardOutput) as? [String: Any])
    XCTAssertEqual(value["producer"] as? String, "native-development-dmg-v1")
    XCTAssertEqual(value["publicationAuthority"] as? String, "none")
    let observed = try XCTUnwrap(value["bundle"] as? [String: Any])
    XCTAssertEqual((observed["files"] as? [Any])?.count, source.observation.files.count)
    XCTAssertEqual((observed["natives"] as? [Any])?.count, source.observation.natives.count)
    XCTAssertEqual(try NativeBundleInspector.preparationSnapshot(app), source.custody)
    let file = fixture.workspace + "/Frameshift-development-\(architecture.rawValue).dmg"
    let original = try SparkleInventory.named(file)
    let refusal = OwnedCommand()
    do {
      _ = try await refusal.run(
        AppleCommand(
          executable: tool,
          arguments: [
            "create-development-image", app, architecture.rawValue, fixture.workspace,
          ]))
      XCTFail("Nonempty native output rebuilt")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childFailed) }
    let status = await refusal.retainUntilExitAfterRefusal()
    XCTAssertEqual(status, .stopped(.exited(1)))
    XCTAssertEqual(try SparkleInventory.named(file), original)
    let usage = OwnedCommand()
    do {
      _ = try await usage.run(
        AppleCommand(executable: tool, arguments: ["create-development-image"]))
      XCTFail("Missing image arguments admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childFailed) }
    let usageStatus = await usage.retainUntilExitAfterRefusal()
    XCTAssertEqual(usageStatus, .stopped(.exited(64)))
  }

  func testActualImageAttachAndDetachDeadlinesRetainDistinctEffectCustody() async throws {
    for phase in 0..<3 {
      let fixture = try await ImageFixture()
      defer { fixture.removeIfSafe() }
      let producer = DevelopmentDiskImageProducer()
      fixture.cleanupAllowed = false
      do {
        _ = try await producer.create(
          app: fixture.app, architecture: .arm64,
          workspace: fixture.workspace, imageChildSeconds: phase == 0 ? 0.000001 : nil,
          attachmentChildSeconds: phase == 1 ? 0.000001 : nil,
          detachmentChildSeconds: phase == 2 ? 0.000001 : nil, observe: nil)
        XCTFail("Actual image child deadline admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .childDeadline) }
      let child = await producer.retainUntilExitAfterRefusal()
      if case .stopped = child {} else { XCTFail("Direct exit remains unknown") }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace + "/.work"))
      await fixture.recover(producer)
      if phase == 2 && !fixture.cleanupAllowed {
        // The product deliberately refuses a second detach. This fixture owns
        // its exact point and explicitly cleans that retained read-only effect.
        let mount = fixture.workspace + "/.work/mount"
        var space = statfs()
        guard statfs(mount, &space) == 0, space.f_flags & UInt32(MNT_RDONLY) != 0 else {
          XCTFail("Retained mount is not read-only")
          continue
        }
        _ = try await OwnedCommand().run(AppleCommand(.hdiutil, arguments: ["detach", mount]))
        fixture.cleanupAllowed = true
      }
      // An uncertain attach with no confirmed point stays retained. Direct
      // child exit does not prove that an OS device effect has stopped.
    }
  }

  func testActualUniversalImageReadbackDetachesAndPreservesSourceAndFacts() async throws {
    let fixture = try await ImageFixture(architecture: .universal)
    defer { fixture.removeIfSafe() }
    let before = try NativeBundleInspector.preparationSnapshot(fixture.app)
    let producer = DevelopmentDiskImageProducer()
    fixture.cleanupAllowed = false
    let result: NativeDiskImageObservation
    do {
      result = try await producer.create(
        app: fixture.app, architecture: .universal, workspace: fixture.workspace
      ) { phase, root in
        if phase == .mounted {
          let fd = open(root + "/.work/mount/should-refuse", O_WRONLY | O_CREAT | O_EXCL, 0o600)
          let failure = errno
          if fd >= 0 { Darwin.close(fd) }
          XCTAssertEqual(fd, -1)
          XCTAssertEqual(failure, EROFS)
        }
      }
    } catch {
      await fixture.recover(producer)
      throw error
    }
    fixture.cleanupAllowed = true
    XCTAssertEqual(result.architecture, .universal)
    XCTAssertEqual(result.bundle.natives.count, 7)
    XCTAssertEqual(result.bundle.declaredMinimum, "14.0.0")
    XCTAssertGreaterThan(result.image.bytes, 0)
    XCTAssertEqual(try NativeBundleInspector.preparationSnapshot(fixture.app), before)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixture.workspace), [result.archive])
    let digest = try AdmittedFile.sha256(
      fixture.workspace + "/" + result.archive,
      policy: FileReadPolicy(
        maximum: 1024 * 1024 * 1024, protection: .privateFile, singleLink: true))
    XCTAssertEqual(digest, result.image)
    let wire = try XCTUnwrap(
      JSONSerialization.jsonObject(with: result.observationBytes()) as? [String: Any])
    XCTAssertEqual(wire["publicationAuthority"] as? String, "none")
    XCTAssertEqual(wire["producer"] as? String, "native-development-dmg-v1")
    let state = await producer.mountStatus
    XCTAssertEqual(state, .restored)
  }

  func testNonemptyUnsafeAliasAndOverlappingWorkspaceRefuseBeforeChildren() async throws {
    let fixture = try await ImageFixture()
    defer { fixture.removeIfSafe() }
    let retained = fixture.workspace + "/retain"
    try Data("retain".utf8).write(to: URL(fileURLWithPath: retained))
    let cases = [fixture.workspace, fixture.workspace + "/missing"]
    for path in cases {
      let producer = DevelopmentDiskImageProducer()
      do {
        _ = try await producer.create(app: fixture.app, architecture: .arm64, workspace: path)
        XCTFail("Unsafe workspace admitted")
      } catch { XCTAssertTrue(error is ReleaseToolError) }
      let child = await producer.childStatus()
      XCTAssertEqual(child, .notStarted)
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retained)), Data("retain".utf8))
    try FileManager.default.removeItem(atPath: retained)
    let alias = fixture.base.base.root + "/.dmg.Alias"
    XCTAssertEqual(symlink(fixture.workspace, alias), 0)
    let aliased = DevelopmentDiskImageProducer()
    do {
      _ = try await aliased.create(app: fixture.app, architecture: .arm64, workspace: alias)
      XCTFail("Alias admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    XCTAssertEqual(chmod(fixture.workspace, 0o755), 0)
    let unsafe = DevelopmentDiskImageProducer()
    do {
      _ = try await unsafe.create(
        app: fixture.app, architecture: .arm64, workspace: fixture.workspace)
      XCTFail("Shared workspace admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    XCTAssertEqual(chmod(fixture.workspace, 0o700), 0)
    let overlap = fixture.app + "/.dmg.Overlap"
    XCTAssertEqual(mkdir(overlap, 0o700), 0)
    let overlapping = DevelopmentDiskImageProducer()
    do {
      _ = try await overlapping.create(
        app: fixture.app, architecture: .arm64, workspace: overlap)
      XCTFail("Overlapping workspace admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .unsafeInput) }
    let child = await overlapping.childStatus()
    XCTAssertEqual(child, .notStarted)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: overlap).isEmpty)
  }

  func testPayloadReadingLinkModeAndImageCollisionRefuseBeforeCreation() async throws {
    for variation in 0..<4 {
      let fixture = try await ImageFixture()
      defer { fixture.removeIfSafe() }
      let producer = DevelopmentDiskImageProducer()
      do {
        _ = try await producer.create(
          app: fixture.app, architecture: .arm64, workspace: fixture.workspace
        ) { phase, root in
          guard phase == .copied else { return }
          let payload = root + "/.work/payload"
          switch variation {
          case 0:
            XCTAssertEqual(unlink(payload + "/Applications"), 0)
            XCTAssertEqual(symlink("/tmp", payload + "/Applications"), 0)
          case 1:
            try Data("changed reading".utf8).write(
              to: URL(fileURLWithPath: payload + "/Read Me.txt"))
          case 2:
            XCTAssertEqual(chmod(payload + "/Read Me.txt", 0o600), 0)
          default:
            try Data("retain collision".utf8).write(
              to: URL(fileURLWithPath: root + "/Frameshift-development-arm64.dmg"))
          }
        }
        XCTFail("Changed payload or image collision admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      let child = await producer.retainUntilExitAfterRefusal()
      XCTAssertEqual(child, .stopped(.exited(0)))
      let mount = await producer.mountStatus
      XCTAssertEqual(mount, .notAttempted)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace + "/.work/payload"))
      if variation == 3 {
        XCTAssertEqual(
          try Data(
            contentsOf: URL(
              fileURLWithPath: fixture.workspace + "/Frameshift-development-arm64.dmg")),
          Data("retain collision".utf8))
      }
    }
  }

  func testSameByteSourceImageAndPayloadChangesRefuseWithPrivateWork() async throws {
    for variation in 0..<3 {
      let fixture = try await ImageFixture()
      defer { fixture.removeIfSafe() }
      let note = fixture.app + "/Contents/Resources/note"
      let producer = DevelopmentDiskImageProducer()
      fixture.cleanupAllowed = false
      do {
        _ = try await producer.create(
          app: fixture.app, architecture: .arm64, workspace: fixture.workspace
        ) { phase, root in
          guard phase == (variation == 1 ? .created : .copied) else { return }
          if variation == 1 {
            let fd = open(root + "/Frameshift-development-arm64.dmg", O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { throw ReleaseToolError.readFailed }
            defer { Darwin.close(fd) }
            var byte: UInt8 = 0
            guard pread(fd, &byte, 1, 0) == 1, pwrite(fd, &byte, 1, 0) == 1 else {
              throw ReleaseToolError.readFailed
            }
          } else {
            let target =
              variation == 0 ? note : root + "/.work/payload/Frameshift.app/Contents/Resources/note"
            try Data("same note".utf8).write(to: URL(fileURLWithPath: target))
          }
        }
        XCTFail("Changed custody admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      await fixture.recover(producer)
      XCTAssertTrue(fixture.cleanupAllowed)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace + "/.work"))
    }
  }

  func testMountedNamespaceRefusalRecoversExactMountAndRetainsAddedEvidence() async throws {
    let fixture = try await ImageFixture()
    defer { fixture.removeIfSafe() }
    let producer = DevelopmentDiskImageProducer()
    fixture.cleanupAllowed = false
    do {
      _ = try await producer.create(
        app: fixture.app, architecture: .arm64, workspace: fixture.workspace
      ) { phase, root in
        if phase == .mounted {
          try Data("retain unknown".utf8).write(to: URL(fileURLWithPath: root + "/unknown"))
        }
      }
      XCTFail("Changed namespace admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
    await fixture.recover(producer)
    XCTAssertTrue(fixture.cleanupAllowed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace + "/unknown"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fixture.workspace + "/.work/payload/Frameshift.app"))
    let status = await producer.mountStatus
    XCTAssertEqual(status, .restored)
  }

  func testCancellationWithLiveMountUsesIndependentOneShotRecovery() async throws {
    let fixture = try await ImageFixture()
    defer { fixture.removeIfSafe() }
    let producer = DevelopmentDiskImageProducer()
    fixture.cleanupAllowed = false
    let app = fixture.app
    let workspace = fixture.workspace
    do {
      _ = try await Task {
        try await producer.create(app: app, architecture: .arm64, workspace: workspace) {
          phase, _ in
          if phase == .detaching { withUnsafeCurrentTask { $0?.cancel() } }
        }
      }.value
      XCTFail("Cancelled mounted image admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .admissionCancelled) }
    await fixture.recover(producer)
    XCTAssertTrue(fixture.cleanupAllowed)
    do {
      _ = try await producer.detachAfterRefusal()
      XCTFail("Recovery replay admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childAlreadyStarted) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/.work"))
  }

  func testActualOwnedCopyDeadlineRetainsWorkspaceAndReapedChild() async throws {
    let fixture = try await ImageFixture()
    defer { fixture.removeIfSafe() }
    let producer = DevelopmentDiskImageProducer()
    fixture.cleanupAllowed = false
    do {
      _ = try await producer.create(
        app: fixture.app, architecture: .arm64, workspace: fixture.workspace,
        childSeconds: 0.000001, observe: nil)
      XCTFail("Deadline admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .childDeadline) }
    await fixture.recover(producer)
    XCTAssertTrue(fixture.cleanupAllowed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspace + "/.work"))
  }
}

@MainActor
private final class ImageFixture {
  let base: PreparationFixture
  var app: String { base.app }
  let workspace: String
  var cleanupAllowed = true

  init(architecture: NativeBundleArchitecture = .arm64) async throws {
    base = try await PreparationFixture(architecture: architecture)
    try Data("same note".utf8).write(
      to: URL(fileURLWithPath: base.app + "/Contents/Resources/note"))
    _ = try await DevelopmentBundlePreparer().prepare(base.app, architecture: architecture)
    workspace =
      base.base.root + "/.dmg." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try FileManager.default.createDirectory(
      atPath: workspace, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  func recover(_ producer: DevelopmentDiskImageProducer) async {
    let child = await producer.retainUntilExitAfterRefusal()
    guard
      child == .notStarted
        || {
          if case .stopped = child { return true }
          return false
        }()
    else { return }
    if let status = try? await producer.detachAfterRefusal(),
      status == .notAttempted || status == .restored
    {
      cleanupAllowed = true
    }
  }

  func removeIfSafe() {
    if cleanupAllowed { base.remove() }
  }
}
