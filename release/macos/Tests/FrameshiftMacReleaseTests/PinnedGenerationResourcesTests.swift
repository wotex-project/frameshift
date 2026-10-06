import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class PinnedGenerationResourcesTests: XCTestCase {
  func testActualPinnedBytesReturnFixedOrderedObservationAndUnchangedCustody() throws {
    let fixture = try GenerationResourceFixture(actual: true)
    defer { fixture.remove() }
    let before = try fixture.identities()
    let bytes = try PinnedGenerationResources.verify(fixture.resources)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(fields["schemaVersion"] as? Int, 1)
    XCTAssertEqual(fields["kind"] as? String, "pinned-generation-sdk-resource-custody")
    XCTAssertEqual(fields["publicationAuthority"] as? String, "none")
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.parent))
    XCTAssertEqual(bytes, try PinnedGenerationResources.verify(fixture.resources))
    XCTAssertEqual(try fixture.identities(), before)
    let facts = try XCTUnwrap(fields["resources"] as? [[String: Any]])
    XCTAssertEqual(facts.compactMap { $0["path"] as? String }, ["configs.json", "models.json"])
    XCTAssertEqual(facts.compactMap { $0["bytes"] as? Int }, [47_709, 125_897])
  }

  func testRootNamesModesAliasesHardLinksAndSpecialFilesRefuseBeforeHashing() throws {
    let fixture = try GenerationResourceFixture()
    defer { fixture.remove() }
    let file = fixture.resources + "/configs.json"
    func refused(_ root: String? = nil) {
      var admitted = false
      XCTAssertThrowsError(
        try PinnedGenerationResources.verify(root ?? fixture.resources) { _ in admitted = true })
      XCTAssertFalse(admitted)
    }
    XCTAssertEqual(chmod(fixture.resources, 0o755), 0)
    refused()
    XCTAssertEqual(chmod(fixture.resources, 0o700), 0)
    let alias = fixture.parent + "/alias"
    XCTAssertEqual(symlink("Resources", alias), 0)
    refused(alias)
    XCTAssertEqual(unlink(alias), 0)
    try Data("retained".utf8).write(to: URL(fileURLWithPath: fixture.resources + "/unknown"))
    refused()
    XCTAssertEqual(unlink(fixture.resources + "/unknown"), 0)
    for mode: mode_t in [0o400, 0o644, 0o660, 0o1600] {
      XCTAssertEqual(chmod(file, mode), 0)
      refused()
    }
    XCTAssertEqual(chmod(file, 0o600), 0)
    XCTAssertEqual(link(file, alias), 0)
    refused()
    XCTAssertEqual(unlink(alias), 0)
    XCTAssertEqual(unlink(file), 0)
    XCTAssertEqual(symlink("models.json", file), 0)
    refused()
    XCTAssertEqual(unlink(file), 0)
    XCTAssertEqual(mkfifo(file, 0o600), 0)
    refused()
    XCTAssertEqual(unlink(file), 0)
    try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
    refused()
  }

  func testWrongDigestSparseSizeMissingAndInvalidInputsPreserveBytes() throws {
    let fixture = try GenerationResourceFixture()
    defer { fixture.remove() }
    let file = fixture.resources + "/configs.json"
    let original = try Data(contentsOf: URL(fileURLWithPath: file))
    XCTAssertThrowsError(try PinnedGenerationResources.verify(fixture.resources)) {
      XCTAssertEqual($0 as? ReleaseToolError, .digestMismatch)
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), original)
    XCTAssertEqual(truncate(file, 256 * 1024 + 1), 0)
    XCTAssertThrowsError(try PinnedGenerationResources.verify(fixture.resources))
    var state = stat()
    XCTAssertEqual(lstat(file, &state), 0)
    XCTAssertEqual(state.st_size, 256 * 1024 + 1)
    XCTAssertEqual(unlink(file), 0)
    XCTAssertThrowsError(try PinnedGenerationResources.verify(fixture.resources))
    for input in ["", "\0", fixture.parent + "/missing"] {
      XCTAssertThrowsError(try PinnedGenerationResources.verify(input))
    }
  }

  func testActualPostReadFileNamespaceAndDirectoryChangesRefuseAndCloseDescriptors() throws {
    for change in 0..<4 {
      let fixture = try GenerationResourceFixture(actual: true)
      defer { fixture.remove() }
      let before = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      XCTAssertThrowsError(
        try PinnedGenerationResources.verify(fixture.resources) { phase in
          guard phase == .read(1) else { return }
          let file = fixture.resources + "/configs.json"
          switch change {
          case 0:
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
            try bytes.write(to: URL(fileURLWithPath: file))
          case 1:
            try FileManager.default.createDirectory(
              atPath: fixture.resources + "/empty", withIntermediateDirectories: false)
          case 2:
            XCTAssertEqual(chmod(fixture.resources, 0o755), 0)
          default:
            XCTAssertEqual(rename(file, fixture.parent + "/retained"), 0)
            try FileManager.default.copyItem(
              atPath: fixture.parent + "/retained", toPath: file)
          }
        })
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, before)
    }
  }
}

private final class GenerationResourceFixture {
  let parent: String
  let resources: String
  init(actual: Bool = false) throws {
    let source = ProcessInfo.processInfo.environment["FRAMESHIFT_SDK_RESOURCES_FIXTURE"]
    if actual && source == nil {
      throw XCTSkip(
        "FRAMESHIFT_SDK_RESOURCES_FIXTURE is required for exact upstream resource bytes")
    }
    parent = "/tmp/frameshift-generation-resource-\(UUID().uuidString)"
    resources = parent + "/Resources"
    try FileManager.default.createDirectory(
      atPath: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      for (name, size) in [("configs.json", 47_709), ("models.json", 125_897)] {
        let path = resources + "/" + name
        if let source, actual {
          try FileManager.default.copyItem(atPath: source + "/" + name, toPath: path)
        } else {
          try Data(count: size).write(to: URL(fileURLWithPath: path))
        }
        guard chmod(path, 0o600) == 0 else { throw ReleaseToolError.readFailed }
      }
    } catch {
      remove()
      throw error
    }
  }
  func remove() { try? FileManager.default.removeItem(atPath: parent) }
  func identities() throws -> [FileIdentity] {
    try [resources, resources + "/configs.json", resources + "/models.json"].map { path in
      var state = stat()
      guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
      return FileIdentity(state)
    }
  }
}
