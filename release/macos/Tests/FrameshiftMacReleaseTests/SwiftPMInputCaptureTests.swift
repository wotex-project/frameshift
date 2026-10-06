import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class SwiftPMInputCaptureTests: XCTestCase {
  func testActualSwiftPMSevenAndSyntheticSixReturnExactFactsWithoutChangingInputs() async throws {
    let fixture = try await SwiftPMCaptureFixture.resolved()
    defer { fixture.remove() }
    let before = try fixture.identities()
    let result = try await fixture.capture()
    XCTAssertEqual(result.files.count, 86)
    XCTAssertEqual(result.inventoryEntries, 152)
    XCTAssertEqual(result.files.last?.path, SwiftPMInputCapture.archivePath)
    XCTAssertEqual(result.files.last?.mode, 0o600)
    let bytes = try result.observationBytes()
    XCTAssertLessThan(bytes.count, 64 * 1024)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.root))
    XCTAssertEqual(before, try fixture.identities())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
    let repeated = try await fixture.capture()
    XCTAssertEqual(bytes, try repeated.observationBytes())
    XCTAssertEqual(before, try fixture.identities())
    var state = try fixture.workspace()
    XCTAssertEqual(state["version"] as? Int, 7)
    state["version"] = 6
    var object = try XCTUnwrap(state["object"] as? [String: Any])
    object.removeValue(forKey: "prebuilts")
    var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
    artifacts[0]["kind"] = "xcframework"
    object["artifacts"] = artifacts
    state["object"] = object
    try fixture.writeState(state)
    let sixBefore = try fixture.identities()
    let six = try await fixture.capture()
    XCTAssertEqual(bytes, try six.observationBytes())
    XCTAssertEqual(sixBefore, try fixture.identities())
  }

  func testStrictWorkspaceProfilesRejectKeyTypeIdentityAndFormatConflicts() throws {
    let root = "/private/tmp/owned/apps/macos"
    let original = workspace(root)
    for version in [6, 7] {
      var state = original
      state["version"] = version
      var object = state["object"] as! [String: Any]
      if version == 6 {
        object.removeValue(forKey: "prebuilts")
        var artifacts = object["artifacts"] as! [[String: Any]]
        artifacts[0]["kind"] = "xcframework"
        object["artifacts"] = artifacts
      }
      state["object"] = object
      try SwiftPMInputCapture.validateWorkspace(
        JSONSerialization.data(withJSONObject: state), packageRoot: root, check: {})
    }
    for version: Any in [true, "7", 5, 8, 7.1] {
      var state = original
      state["version"] = version
      XCTAssertThrowsError(
        try SwiftPMInputCapture.validateWorkspace(
          JSONSerialization.data(withJSONObject: state), packageRoot: root, check: {}))
    }
    for change in 0..<15 {
      var state = original
      var object = state["object"] as! [String: Any]
      var artifacts = object["artifacts"] as! [[String: Any]]
      switch change {
      case 0: state["unknown"] = 1
      case 1: object["unknown"] = []
      case 2: object["dependencies"] = [[:]]
      case 3: object["prebuilts"] = [[:]]
      case 4: object.removeValue(forKey: "prebuilts")
      case 5: artifacts[0]["unknown"] = 1
      case 6: artifacts[0]["targetName"] = "Other"
      case 7: artifacts[0]["kind"] = "xcframework"
      case 8: artifacts[0]["kind"] = ["xcframework": ["unknown": 1]]
      case 9: artifacts[0]["path"] = "/outside/Sparkle.xcframework"
      case 10:
        var package = artifacts[0]["packageRef"] as! [String: Any]
        package["kind"] = "fileSystem"
        artifacts[0]["packageRef"] = package
      case 11:
        var package = artifacts[0]["packageRef"] as! [String: Any]
        package["location"] = root + "/../macos"
        artifacts[0]["packageRef"] = package
      case 12:
        var source = artifacts[0]["source"] as! [String: Any]
        source["checksum"] = String(repeating: "0", count: 64)
        artifacts[0]["source"] = source
      case 13: artifacts.append(artifacts[0])
      default: artifacts = []
      }
      object["artifacts"] = artifacts
      state["object"] = object
      XCTAssertThrowsError(
        try SwiftPMInputCapture.validateWorkspace(
          JSONSerialization.data(withJSONObject: state), packageRoot: root, check: {}))
    }
    for version in ["true", "7.0", "7e0", "07", "-7", "\"7\""] {
      XCTAssertThrowsError(
        try SwiftPMInputCapture.validateWorkspace(
          Data("{\"version\":\(version),\"object\":{}}".utf8), packageRoot: root, check: {}))
    }
  }

  func testJSONDuplicateEscapeUTF8DepthStringAndActualNodeBoundaries() throws {
    let invalid = [
      #"{"version":6,"version":7}"#, #"{"a":1,"\u0061":2}"#,
      #"{"é":1,"e\u0301":2}"#, #"[1,]"#, #"{"a":1,}"#,
      #"[01]"#, #"[-]"#, #"[1.]"#, #"[1e+]"#, #"[NaN]"#,
      #""\uD800""#, #""\q""#, #"{}[]"#, "\"raw\nnewline\"",
    ]
    for text in invalid {
      XCTAssertThrowsError(try SwiftPMJSON.read(Data(text.utf8), maximum: 512 * 1024, check: {}))
    }
    XCTAssertThrowsError(
      try SwiftPMJSON.read(Data([0x22, 0xff, 0x22]), maximum: 512 * 1024, check: {}))
    XCTAssertThrowsError(
      try SwiftPMJSON.read(
        Data(repeating: 32, count: 512 * 1024 + 1), maximum: 512 * 1024, check: {}))
    let exactDepth = String(repeating: "[", count: 32) + "null" + String(repeating: "]", count: 32)
    _ = try SwiftPMJSON.read(Data(exactDepth.utf8), maximum: 512 * 1024, check: {})
    XCTAssertThrowsError(
      try SwiftPMJSON.read(Data(("[" + exactDepth + "]").utf8), maximum: 512 * 1024, check: {}))
    let exactNodes = "[" + Array(repeating: "null", count: 8191).joined(separator: ",") + "]"
    XCTAssertEqual(
      try SwiftPMJSON.read(Data(exactNodes.utf8), maximum: 512 * 1024, check: {}).array().count,
      8191)
    XCTAssertThrowsError(
      try SwiftPMJSON.read(
        Data((String(exactNodes.dropLast()) + ",null]").utf8), maximum: 512 * 1024, check: {}))
    let exactString = "\"" + String(repeating: "s", count: 64 * 1024) + "\""
    _ = try SwiftPMJSON.read(Data(exactString.utf8), maximum: 512 * 1024, check: {})
    XCTAssertThrowsError(
      try SwiftPMJSON.read(
        Data((String(exactString.dropLast()) + "s\"").utf8), maximum: 512 * 1024, check: {}))
  }

  func testManifestRequiresActualSinglePinnedBinaryAndTypedTargets() throws {
    XCTAssertFalse(try SwiftPMInputCapture.binaryTarget(Data(#"{"targets":[]}"#.utf8), check: {}))
    let target: [String: Any] = [
      "type": "binary", "name": "Sparkle", "url": PinnedSparkleArchive.url,
      "checksum": PinnedSparkleArchive.sha256,
    ]
    XCTAssertTrue(
      try SwiftPMInputCapture.binaryTarget(
        JSONSerialization.data(withJSONObject: ["targets": [target]]), check: {}))
    for text in ["{}", #"{"targets":true}"#, #"{"targets":[{}]}"#, #"{"targets":[{"type":true}]}"#]
    {
      XCTAssertThrowsError(try SwiftPMInputCapture.binaryTarget(Data(text.utf8), check: {}))
    }
    for change in 0..<5 {
      var changed = target
      switch change {
      case 0: changed["name"] = "Other"
      case 1: changed["url"] = PinnedSparkleArchive.url + "?other"
      case 2: changed["checksum"] = String(repeating: "0", count: 64)
      case 3: changed["checksum"] = true
      default: break
      }
      let targets = change == 4 ? [target, target] : [changed]
      XCTAssertThrowsError(
        try SwiftPMInputCapture.binaryTarget(
          JSONSerialization.data(withJSONObject: ["targets": targets]), check: {}))
    }
  }

  func testAbsentPackageAndActualNoBinaryPreserveInventoryAndMalformedCompilerState() async throws {
    let fixture = try SwiftPMCaptureFixture(binary: false)
    defer { fixture.remove() }
    let state = Data("malformed retained compiler state\n".utf8)
    try FileManager.default.createDirectory(
      atPath: fixture.packageRoot + "/.build", withIntermediateDirectories: false)
    try state.write(to: URL(fileURLWithPath: fixture.statePath))
    let before = try fixture.identities()
    let result = try await fixture.capture()
    XCTAssertEqual(result.inventoryEntries, 0)
    XCTAssertEqual(try result.observationBytes(), Data("[]".utf8))
    XCTAssertEqual(before, try fixture.identities())
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.statePath)), state)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
    XCTAssertEqual(unlink(fixture.manifest), 0)
    let child = OwnedCommand()
    let absent = try await SwiftPMInputCapture.capture(
      repository: fixture.root, work: fixture.work, child: child)
    XCTAssertEqual(try absent.observationBytes(), Data("[]".utf8))
    let status = await child.status()
    XCTAssertEqual(status, .notStarted)
  }

  func testUnsafeManifestAndParentsRefuseBeforeLaunchingOrCreatingScratch() async throws {
    for change in 0..<7 {
      let fixture = try SwiftPMCaptureFixture(binary: false)
      defer { fixture.remove() }
      switch change {
      case 0:
        try FileManager.default.moveItem(
          atPath: fixture.manifest, toPath: fixture.root + "/retained.swift")
        XCTAssertEqual(symlink("../../retained.swift", fixture.manifest), 0)
      case 1: XCTAssertEqual(Darwin.link(fixture.manifest, fixture.root + "/linked.swift"), 0)
      case 2: XCTAssertEqual(chmod(fixture.manifest, 0o666), 0)
      case 3: XCTAssertEqual(truncate(fixture.manifest, 64 * 1024 + 1), 0)
      case 4:
        XCTAssertEqual(unlink(fixture.manifest), 0)
        XCTAssertEqual(mkfifo(fixture.manifest, 0o600), 0)
      case 5: XCTAssertEqual(chmod(fixture.packageRoot, 0o777), 0)
      default:
        try FileManager.default.moveItem(
          atPath: fixture.packageRoot, toPath: fixture.root + "/retained")
        XCTAssertEqual(symlink("../retained", fixture.packageRoot), 0)
      }
      let child = OwnedCommand()
      do {
        _ = try await SwiftPMInputCapture.capture(
          repository: fixture.root, work: fixture.work, child: child)
        XCTFail("Unsafe manifest/parent admitted")
      } catch {}
      let status = await child.status()
      XCTAssertEqual(status, .notStarted)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.work))
    }
  }

  func testActualUnknownStatePrivateArchiveAndRedirectedCacheRefuseWithoutRepair() async throws {
    let fixture = try await SwiftPMCaptureFixture.resolved()
    defer { fixture.remove() }
    let original = try Data(contentsOf: URL(fileURLWithPath: fixture.statePath))
    var state = try fixture.workspace()
    state["version"] = 5
    try fixture.writeState(state)
    let refused = try fixture.identities()
    await refuses(fixture, work: fixture.work)
    XCTAssertEqual(refused, try fixture.identities())
    try original.write(to: URL(fileURLWithPath: fixture.statePath))
    XCTAssertEqual(chmod(fixture.archive, 0o644), 0)
    let publicArchive = try fixture.identities()
    await refuses(fixture, work: fixture.root + "/public-archive-work")
    XCTAssertEqual(publicArchive, try fixture.identities())
    XCTAssertEqual(chmod(fixture.archive, 0o600), 0)
    let artifacts = fixture.packageRoot + "/.build/artifacts"
    try FileManager.default.moveItem(atPath: artifacts, toPath: artifacts + "-retained")
    XCTAssertEqual(symlink("artifacts-retained", artifacts), 0)
    await refuses(fixture, work: fixture.root + "/redirected-work")
    XCTAssertEqual(unlink(artifacts), 0)
    try FileManager.default.moveItem(atPath: artifacts + "-retained", toPath: artifacts)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.statePath)), original)
  }

  func testActualUnsafeWorkspaceLeavesRefuseWithoutRepairOrBlocking() async throws {
    let fixture = try await SwiftPMCaptureFixture.resolved()
    defer { fixture.remove() }
    for change in 0..<6 {
      let retained = fixture.statePath + "-retained"
      try FileManager.default.moveItem(atPath: fixture.statePath, toPath: retained)
      switch change {
      case 0: XCTAssertEqual(symlink("workspace-state.json-retained", fixture.statePath), 0)
      case 1: XCTAssertEqual(Darwin.link(retained, fixture.statePath), 0)
      case 2:
        try FileManager.default.copyItem(atPath: retained, toPath: fixture.statePath)
        XCTAssertEqual(chmod(fixture.statePath, 0o666), 0)
      case 3: XCTAssertEqual(mkfifo(fixture.statePath, 0o600), 0)
      case 4:
        try FileManager.default.copyItem(atPath: retained, toPath: fixture.statePath)
        XCTAssertEqual(truncate(fixture.statePath, 128 * 1024 + 1), 0)
      default:
        try FileManager.default.createDirectory(
          atPath: fixture.statePath, withIntermediateDirectories: false)
      }
      let before = try fixture.identities()
      await refuses(fixture, work: fixture.root + "/unsafe-state-\(change)")
      XCTAssertEqual(before, try fixture.identities())
      try FileManager.default.removeItem(atPath: fixture.statePath)
      try FileManager.default.moveItem(atPath: retained, toPath: fixture.statePath)
    }
  }

  func testActualLateManifestStateArchiveCacheAndParentChangesRefuseAndCloseDescriptors()
    async throws
  {
    let fixture = try await SwiftPMCaptureFixture.resolved()
    defer { fixture.remove() }
    for change in 0..<8 {
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      let work = fixture.root + "/changed-\(change)"
      do {
        _ = try await SwiftPMInputCapture.capture(
          repository: fixture.root, work: work, child: OwnedCommand(),
          observe: { phase in
            let selected: SwiftPMCapturePhase =
              change == 0 ? .manifestEvaluated : (change >= 6 ? .cacheRechecked : .materialChecked)
            guard phase == selected else { return }
            let file: String
            switch change {
            case 0, 1, 6: file = fixture.statePath
            case 2: file = fixture.manifest
            case 3, 7: file = fixture.archive
            case 4: file = fixture.framework + "/Versions/B/Headers/SPUUpdater.h"
            default:
              let original = fixture.packageRoot + "/.build/sparkle"
              try FileManager.default.moveItem(atPath: original, toPath: original + "-retained")
              try FileManager.default.copyItem(atPath: original + "-retained", toPath: original)
              return
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
            try bytes.write(to: URL(fileURLWithPath: file))
          })
        XCTFail("Late input mutation admitted")
      } catch { XCTAssertEqual(error as? ReleaseToolError, .inputChanged) }
      XCTAssertTrue(FileManager.default.fileExists(atPath: work))
      XCTAssertEqual(descriptors, (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 })
    }
  }

  func testActualManifestChildDeadlineAndOutputOverflowRetainScratchUntilReadOnlyExit() async throws
  {
    let fixture = try SwiftPMCaptureFixture(binary: false)
    var remove = true
    defer { if remove { fixture.remove() } }
    let before = try fixture.identities()
    for change in 0..<2 {
      let child = OwnedCommand()
      let work = fixture.root + "/child-\(change)"
      let limits = try ChildLimits(
        outputBytes: change == 0 ? 512 * 1024 : 16, seconds: change == 0 ? 0.001 : 60)
      do {
        _ = try await SwiftPMInputCapture.capture(
          repository: fixture.root, work: work, child: child, limits: limits)
        XCTFail("Incomplete manifest child admitted")
      } catch {
        XCTAssertEqual(error as? ReleaseToolError, change == 0 ? .childDeadline : .childOutputLimit)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: work))
      let stopped = try await child.observeExit(seconds: 5)
      guard case .stopped = stopped else {
        remove = false
        return XCTFail("Retain test fixture: child exit unconfirmed")
      }
      let repeated = try await child.observeExit(seconds: 0)
      XCTAssertEqual(stopped, repeated)
      XCTAssertEqual(before, try fixture.identities())
    }
  }

  func testCancellationAfterActualManifestSuccessRefusesLateEmptyObservation() async throws {
    let fixture = try SwiftPMCaptureFixture(binary: false)
    defer { fixture.remove() }
    let before = try fixture.identities()
    let child = OwnedCommand()
    let operation = Task {
      try await SwiftPMInputCapture.capture(
        repository: fixture.root, work: fixture.work, child: child,
        observe: { phase in
          guard phase == .manifestEvaluated else { return }
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    do {
      _ = try await operation.value
      XCTFail("Cancelled observation admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, .admissionCancelled) }
    let status = await child.status()
    XCTAssertEqual(status, .stopped(.exited(0)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.work))
    XCTAssertEqual(before, try fixture.identities())
  }

  private func refuses(_ fixture: SwiftPMCaptureFixture, work: String) async {
    do {
      _ = try await SwiftPMInputCapture.capture(
        repository: fixture.root, work: work, child: OwnedCommand())
      XCTFail("Unsafe compiler input admitted")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: work))
  }

  private func workspace(_ root: String) -> [String: Any] {
    [
      "version": 7,
      "object": [
        "dependencies": [], "prebuilts": [],
        "artifacts": [
          [
            "targetName": "Sparkle", "kind": ["xcframework": [:]],
            "packageRef": ["identity": "macos", "kind": "root", "location": root, "name": "macos"],
            "source": [
              "checksum": PinnedSparkleArchive.sha256, "type": "remote",
              "url": PinnedSparkleArchive.url,
            ],
            "path": root + "/.build/artifacts/macos/Sparkle/Sparkle.xcframework",
          ]
        ],
      ],
    ]
  }
}

private final class SwiftPMCaptureFixture: Sendable {
  let root: String
  let packageRoot: String
  let manifest: String
  let archive: String
  let framework: String
  let statePath: String
  let work: String
  init(binary: Bool) throws {
    guard let resolved = realpath("/tmp", nil) else { throw ReleaseToolError.readFailed }
    root = String(cString: resolved) + "/frameshift-swiftpm-test-\(UUID().uuidString)"
    free(resolved)
    packageRoot = root + "/apps/macos"
    manifest = packageRoot + "/Package.swift"
    archive = root + "/" + SwiftPMInputCapture.archivePath
    framework = root + "/" + String(SwiftPMInputCapture.frameworkPath.dropLast())
    statePath = packageRoot + "/.build/workspace-state.json"
    work = root + "/capture-work"
    try FileManager.default.createDirectory(
      atPath: packageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let target =
      binary
      ? #".binaryTarget(name: "Sparkle", url: "\#(PinnedSparkleArchive.url)", checksum: "\#(PinnedSparkleArchive.sha256)")"#
      : ""
    let text =
      "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"NativeCaptureFixture\", platforms: [.macOS(.v14)], targets: [\(target)])\n"
    try Data(text.utf8).write(to: URL(fileURLWithPath: manifest))
    guard chmod(manifest, 0o644) == 0 else { throw ReleaseToolError.readFailed }
  }
  static func resolved() async throws -> SwiftPMCaptureFixture {
    guard let input = ProcessInfo.processInfo.environment["FRAMESHIFT_SPARKLE_ARCHIVE"] else {
      throw XCTSkip(
        "FRAMESHIFT_SPARKLE_ARCHIVE is required for the actual SwiftPM compiler artifact")
    }
    try PinnedSparkleArchive.verify(input)
    let fixture = try SwiftPMCaptureFixture(binary: true)
    let child = OwnedCommand()
    do {
      try FileManager.default.createDirectory(
        atPath: fixture.packageRoot + "/.build/sparkle", withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.copyItem(atPath: input, toPath: fixture.archive)
      guard chmod(fixture.archive, 0o600) == 0 else { throw ReleaseToolError.readFailed }
      _ = try await child.run(
        AppleCommand(
          .swift, arguments: ["package", "--package-path", fixture.packageRoot, "resolve"]),
        limits: ChildLimits(outputBytes: 512 * 1024, seconds: 60))
      return fixture
    } catch {
      switch await child.status() {
      case .stopped, .notStarted: fixture.remove()
      case .running, .unconfirmed: break
      }
      throw error
    }
  }
  func capture() async throws -> SwiftPMInputObservation {
    try await SwiftPMInputCapture.capture(repository: root, work: work, child: OwnedCommand())
  }
  func workspace() throws -> [String: Any] {
    guard
      let state = try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: statePath))) as? [String: Any]
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    return state
  }
  func writeState(_ state: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: statePath))
  }
  func identities() throws -> [String: FileIdentity] {
    var values: [String: FileIdentity] = [:]
    for path in [manifest, statePath, archive, framework] {
      var state = stat()
      if lstat(path, &state) == 0 { values[path] = FileIdentity(state) }
    }
    let names = FileManager.default.enumerator(atPath: framework)?.allObjects as? [String] ?? []
    for name in names {
      var state = stat()
      let path = framework + "/" + name
      guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
      values[path] = FileIdentity(state)
    }
    return values
  }
  func remove() { try? FileManager.default.removeItem(atPath: root) }
}
