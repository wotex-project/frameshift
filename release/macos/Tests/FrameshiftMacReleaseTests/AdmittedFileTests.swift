import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

final class AdmittedFileTests: XCTestCase {
  func testStreamingHashAndBufferedReadPreserveInput() throws {
    try fixture { root in
      let bytes = Data((0..<170_123).map { UInt8($0 % 251) })
      let path = try file(root, bytes: bytes)
      let policy = try FileReadPolicy(maximum: 200_000, protection: .privateFile)
      let before = try metadata(path)
      XCTAssertEqual(try AdmittedFile.read(path, policy: policy), bytes)
      XCTAssertEqual(
        try AdmittedFile.sha256(path, policy: policy),
        FileDigest(
          bytes: Int64(bytes.count),
          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      )
      XCTAssertEqual(try metadata(path), before)
    }
  }

  func testEmptyFileRequiresExplicitZeroMinimum() throws {
    try fixture { root in
      let path = try file(root, bytes: Data())
      XCTAssertThrowsError(try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1))) {
        XCTAssertEqual($0 as? ReleaseToolError, .inputLimit)
      }
      XCTAssertEqual(
        try AdmittedFile.read(path, policy: FileReadPolicy(minimum: 0, maximum: 0)), Data())
      XCTAssertEqual(
        try AdmittedFile.sha256(path, policy: FileReadPolicy(minimum: 0, maximum: 0)).sha256,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      )
    }
  }

  func testBoundsRefuseBeforePathAccess() throws {
    for bounds in [(Int64(-1), Int64(1)), (2, 1), (0, Int64.max)] {
      XCTAssertThrowsError(try FileReadPolicy(minimum: bounds.0, maximum: bounds.1)) {
        XCTAssertEqual($0 as? ReleaseToolError, .invalidBounds)
      }
    }
    for seconds in [0, -1, .infinity, .nan, 901] {
      XCTAssertThrowsError(try FileReadPolicy(maximum: 1, seconds: seconds)) {
        XCTAssertEqual($0 as? ReleaseToolError, .invalidBounds)
      }
    }
    XCTAssertThrowsError(
      try AdmittedFile.read("absent", policy: FileReadPolicy(maximum: 16 * 1024 * 1024 + 1))
    ) {
      XCTAssertEqual($0 as? ReleaseToolError, .invalidBounds)
    }
    XCTAssertThrowsError(try AdmittedFile.read("a\0b", policy: FileReadPolicy(maximum: 1))) {
      XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
    }
  }

  func testFIFODeviceDirectoryAndSymlinkRefuseWithoutOpeningTargets() throws {
    try fixture { root in
      let path = try file(root)
      let alias = root + "/alias"
      XCTAssertEqual(symlink(path, alias), 0)
      let fifo = root + "/fifo"
      XCTAssertEqual(mkfifo(fifo, 0o600), 0)
      for input in [alias, fifo, root, "/dev/null"] {
        XCTAssertThrowsError(try AdmittedFile.read(input, policy: FileReadPolicy(maximum: 1024))) {
          XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
        }
      }
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("original".utf8))
      var state = stat()
      XCTAssertEqual(lstat(fifo, &state), 0)
      XCTAssertEqual(state.st_mode & mode_t(S_IFMT), mode_t(S_IFIFO))
    }
  }

  func testFIFOReplacementBetweenNameAndOpenCannotBlock() throws {
    try fixture { root in
      let path = try file(root)
      let started = ContinuousClock.now
      XCTAssertThrowsError(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024)) { phase in
          if phase == .named {
            XCTAssertEqual(unlink(path), 0)
            XCTAssertEqual(mkfifo(path, 0o600), 0)
          }
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput) }
      XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }
  }

  func testSymlinkReplacementBetweenNameAndOpenCannotReadTarget() throws {
    try fixture { root in
      let path = try file(root)
      let target = try file(root, name: "secret", bytes: Data("private target".utf8))
      XCTAssertThrowsError(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024)) { phase in
          if phase == .named {
            XCTAssertEqual(unlink(path), 0)
            XCTAssertEqual(symlink(target, path), 0)
          }
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .readFailed) }
      XCTAssertEqual(
        try Data(contentsOf: URL(fileURLWithPath: target)), Data("private target".utf8))
    }
  }

  func testPermissionsAndHardLinksRefuseWithoutRepair() throws {
    try fixture { root in
      let path = try file(root)
      for mode: mode_t in [0o666, 0o640, 0o4600] {
        XCTAssertEqual(chmod(path, mode), 0)
        let before = try metadata(path)
        XCTAssertThrowsError(
          try AdmittedFile.read(
            path, policy: FileReadPolicy(maximum: 1024, protection: .privateFile))
        ) {
          XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
        }
        XCTAssertEqual(try metadata(path), before)
      }
      XCTAssertEqual(chmod(path, 0o644), 0)
      XCTAssertEqual(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024, protection: .protected)),
        Data("original".utf8))
      XCTAssertEqual(chmod(path, 0o664), 0)
      XCTAssertThrowsError(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024, protection: .protected))
      ) {
        XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
      }
      XCTAssertEqual(chmod(path, 0o600), 0)
      XCTAssertEqual(link(path, root + "/second-name"), 0)
      for policy in [
        try FileReadPolicy(maximum: 1024, protection: .privateFile),
        try FileReadPolicy(maximum: 1024, singleLink: true),
      ] {
        XCTAssertThrowsError(try AdmittedFile.read(path, policy: policy)) {
          XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
        }
      }
      XCTAssertEqual(try metadata(path)["links"], 2)
    }
  }

  func testReplacementAfterOpenAndAfterReadRefuseNewInode() throws {
    for replaceAt: FileReadPhase in [.opened, .finished] {
      try fixture { root in
        let path = try file(root)
        let replacement = try file(root, name: "replacement")
        XCTAssertThrowsError(
          try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024)) { phase in
            if phase == replaceAt { XCTAssertEqual(rename(replacement, path), 0) }
          }
        ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("original".utf8))
      }
    }
  }

  func testTruncationGrowthSameByteRewriteAndModeChangeRefuse() throws {
    for mutation in 0..<4 {
      try fixture { root in
        let bytes = Data(repeating: 42, count: 70_000)
        let path = try file(root, bytes: bytes)
        var changed = false
        XCTAssertThrowsError(
          try AdmittedFile.sha256(path, policy: FileReadPolicy(maximum: 100_000)) { phase in
            guard case .chunk = phase, !changed else { return }
            changed = true
            switch mutation {
            case 0: XCTAssertEqual(truncate(path, 1), 0)
            case 1:
              let descriptor = open(path, O_WRONLY | O_APPEND)
              XCTAssertGreaterThanOrEqual(descriptor, 0)
              defer { close(descriptor) }
              var extra: UInt8 = 43
              XCTAssertEqual(write(descriptor, &extra, 1), 1)
            case 2:
              usleep(1000)
              try bytes.write(to: URL(fileURLWithPath: path))
            default: XCTAssertEqual(chmod(path, 0o644), 0)
            }
          }
        ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
        XCTAssertTrue(changed)
      }
    }
  }

  func testSparseOversizeAndSizeUnderflowRefuseBeforeStream() throws {
    try fixture { root in
      let path = try file(root)
      XCTAssertThrowsError(
        try AdmittedFile.read(path, policy: FileReadPolicy(minimum: 9, maximum: 1024))
      ) {
        XCTAssertEqual($0 as? ReleaseToolError, .inputLimit)
      }
      let descriptor = open(path, O_WRONLY)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      defer { close(descriptor) }
      XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024 * 1024 + 1), 0)
      XCTAssertThrowsError(
        try AdmittedFile.sha256(path, policy: FileReadPolicy(maximum: 8 * 1024 * 1024 * 1024))
      ) {
        XCTAssertEqual($0 as? ReleaseToolError, .inputLimit)
      }
      XCTAssertEqual(try metadata(path)["size"], 8 * 1024 * 1024 * 1024 + 1)
    }
  }

  func testDeadlineAndThrowingConsumerCloseDescriptor() throws {
    try fixture { root in
      let path = try file(root)
      let before = try metadata(path)
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      for _ in 0..<80 {
        XCTAssertThrowsError(
          try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024)) { phase in
            if phase == .opened { throw ReleaseToolError.deadline }
          }
        ) { XCTAssertEqual($0 as? ReleaseToolError, .deadline) }
      }
      XCTAssertThrowsError(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024, seconds: 0.01)) { phase in
          if phase == .opened { usleep(20_000) }
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .deadline) }
      XCTAssertEqual(try metadata(path), before)
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
      XCTAssertEqual(
        try AdmittedFile.read(path, policy: FileReadPolicy(maximum: 1024)), Data("original".utf8))
    }
  }

  func testPinnedArchiveWrongSizeAndWrongDigestLeaveBytesUnchanged() throws {
    try fixture { root in
      let path = try file(root)
      XCTAssertThrowsError(try PinnedSparkleArchive.verify(path)) {
        XCTAssertEqual($0 as? ReleaseToolError, .inputLimit)
      }
      let descriptor = open(path, O_WRONLY)
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      XCTAssertEqual(ftruncate(descriptor, off_t(PinnedSparkleArchive.bytes)), 0)
      close(descriptor)
      let before = try metadata(path)
      XCTAssertThrowsError(try PinnedSparkleArchive.verify(path)) {
        XCTAssertEqual($0 as? ReleaseToolError, .digestMismatch)
      }
      XCTAssertEqual(try metadata(path), before)
    }
  }

  private func fixture(_ action: (String) throws -> Void) throws {
    let root = NSTemporaryDirectory() + "frameshift-mac-release-test." + UUID().uuidString
    XCTAssertEqual(mkdir(root, 0o700), 0)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try action(root)
  }

  private func file(_ root: String, name: String = "input", bytes: Data = Data("original".utf8))
    throws -> String
  {
    let path = root + "/" + name
    try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    XCTAssertEqual(chmod(path, 0o600), 0)
    return path
  }

  private func metadata(_ path: String) throws -> [String: Int64] {
    var value = stat()
    guard lstat(path, &value) == 0 else { throw ReleaseToolError.readFailed }
    return [
      "inode": Int64(value.st_ino), "size": value.st_size, "mode": Int64(value.st_mode),
      "links": Int64(value.st_nlink), "modified": Int64(value.st_mtimespec.tv_sec),
      "modifiedNano": Int64(value.st_mtimespec.tv_nsec),
      "changed": Int64(value.st_ctimespec.tv_sec),
      "changedNano": Int64(value.st_ctimespec.tv_nsec),
    ]
  }
}
