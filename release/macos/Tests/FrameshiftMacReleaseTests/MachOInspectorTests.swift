import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class MachOInspectorTests: XCTestCase {
  func testThinImportsRunPathsAndPackedMinimumPreserveOrderAndUTF8() throws {
    try fixture { root in
      let decomposed = "@loader_path/Cafe\u{301}.dylib"
      let commands = [
        buildVersion(minimum: 0x000e_0aff),
        stringCommand(0xc, "/usr/lib/libSystem.B.dylib", base: 24),
        stringCommand(0x8000_0018, decomposed, base: 24),
        stringCommand(0x8000_001c, "@executable_path/../Frameworks", base: 12),
        stringCommand(0xe, "/usr/lib/dyld", base: 12),
      ]
      let path = try file(root, thin(commands: commands))
      let slices = try MachOInspector.inspect(path)
      XCTAssertEqual(slices.count, 1)
      XCTAssertEqual(slices[0].arch, "arm64")
      XCTAssertEqual(slices[0].filetype, 2)
      XCTAssertEqual(slices[0].minimum, "14.10.255")
      XCTAssertEqual(slices[0].dependencies, ["/usr/lib/libSystem.B.dylib", decomposed])
      XCTAssertEqual(Array(slices[0].dependencies[1].utf8), Array(decomposed.utf8))
      XCTAssertEqual(slices[0].rpaths, ["@executable_path/../Frameworks"])
    }
  }

  func testLegacyMinimumAndAllAdmittedCPUsFileTypesAndImports() throws {
    try fixture { root in
      for (type, subtype, arch): (UInt32, UInt32, String) in [
        (0x0100_000c, 0, "arm64"), (0x0100_0007, 3, "x86_64"),
        (0x0100_0007, 0x8000_0003, "x86_64"),
      ] {
        for filetype: UInt32 in [2, 6, 8] {
          let imports: [UInt32] = [0xc, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023]
          let commands =
            [command(0x24, words: [0x000c_0102, 0x000e_0000])]
            + imports.map { stringCommand($0, "@loader_path/\($0).dylib", base: 24) }
          let slice = try MachOInspector.inspect(
            file(root, thin(type: type, subtype: subtype, filetype: filetype, commands: commands)))[
              0]
          XCTAssertEqual(slice.arch, arch)
          XCTAssertEqual(slice.minimum, "12.1.2")
          XCTAssertEqual(slice.filetype, filetype)
          XCTAssertEqual(slice.dependencies.count, 5)
        }
      }
    }
  }

  func testThinHeaderAndEveryTruncationRefuseWithoutUnsafeAllocation() throws {
    try fixture { root in
      let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
      defer { XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors) }
      let original = thin()
      for count in 0..<original.count {
        XCTAssertThrowsError(try MachOInspector.inspect(file(root, Data(original.prefix(count)))))
      }
      for (offset, value): (Int, UInt32) in [
        (0, 0xfeed_face), (4, 12), (8, 2), (12, 1), (16, 0), (16, 4097),
        (20, 1_048_584), (20, 64), (20, 16), (36, 7), (36, 16),
      ] {
        var bytes = original
        put(&bytes, offset, value)
        XCTAssertThrowsError(try MachOInspector.inspect(file(root, bytes)))
      }
    }
  }

  func testDeploymentLayoutPlatformCountAndConflictRefuse() throws {
    try fixture { root in
      var badPlatform = buildVersion()
      put(&badPlatform, 8, 2)
      var badTools = buildVersion()
      put(&badTools, 20, 33)
      var wrongSize = buildVersion()
      put(&wrongSize, 20, 1)
      for commands in [
        [badPlatform], [badTools], [wrongSize], [buildVersion(minimum: 0x0009_ffff)],
        [buildVersion(), buildVersion()],
        [buildVersion(), command(0x24, words: [0x000e_0000, 0])],
        [command(0x24, words: [0x000e_0000, 0, 0, 0])], [command(0x1b)],
      ] {
        XCTAssertThrowsError(try MachOInspector.inspect(file(root, thin(commands: commands))))
      }
      let tools = buildVersion(tools: 32)
      XCTAssertEqual(
        try MachOInspector.inspect(file(root, thin(commands: [tools])))[0].minimum, "14.0.0")
    }
  }

  func testLoaderStringsAndUnavailableCommandsRefuse() throws {
    try fixture { root in
      for code: UInt32 in [0x6, 0x7, 0xf, 0x25, 0x27, 0x2f, 0x30, 0x8000_0035] {
        XCTAssertThrowsError(
          try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), command(code)]))))
      }
      for text in ["", String(repeating: "a", count: 513), "@loader_path/\nsecret", "\u{7f}"] {
        let bad = stringCommand(0xc, text, base: 24)
        XCTAssertThrowsError(
          try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), bad]))))
      }
      let original = stringCommand(0xc, "a", base: 24)
      var noTerminator = original
      for index in 24..<noTerminator.count { noTerminator[index] = 65 }
      var badUTF8 = original
      badUTF8[24] = 0xff
      var beforeStructure = original
      put(&beforeStructure, 8, 8)
      var outside = original
      put(&outside, 8, UInt32.max)
      for bad in [noTerminator, badUTF8, beforeStructure, outside, command(0xc)] {
        XCTAssertThrowsError(
          try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), bad]))))
      }
      let outsideDyld = stringCommand(0xe, "/opt/dyld", base: 12)
      XCTAssertThrowsError(
        try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), outsideDyld]))))
      let exact = stringCommand(0xc, String(repeating: "a", count: 512), base: 24)
      XCTAssertEqual(
        try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), exact])))[0]
          .dependencies[0].utf8.count, 512)
    }
  }

  func testExactCommandCountAndRegionBudgets() throws {
    try fixture { root in
      // Synthetic structural metadata; skipped command payloads are not native execution proof.
      let many = [buildVersion()] + Array(repeating: command(0x1234), count: 4095)
      XCTAssertEqual(try MachOInspector.inspect(file(root, thin(commands: many))).count, 1)
      XCTAssertThrowsError(
        try MachOInspector.inspect(file(root, thin(commands: many + [command(0x1234)]))))
      var padded = Data(repeating: 0, count: 1_048_576 - 24)
      put(&padded, 0, 0x1234)
      put(&padded, 4, UInt32(padded.count))
      XCTAssertEqual(
        try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), padded]))).count, 1)
      padded.append(Data(repeating: 0, count: 8))
      put(&padded, 4, UInt32(padded.count))
      XCTAssertThrowsError(
        try MachOInspector.inspect(file(root, thin(commands: [buildVersion(), padded]))))
      var extra = thin()
      extra.append(command(0x1234))
      put(&extra, 20, 32)
      XCTAssertThrowsError(try MachOInspector.inspect(file(root, extra)))
    }
  }

  func testFatTablesAreAlignedContainedDistinctAndHeaderMatched() throws {
    try fixture { root in
      for wide in [false, true] {
        let original = fat(wide: wide)
        XCTAssertEqual(
          try MachOInspector.inspect(file(root, original)).map(\.arch), ["arm64", "x86_64"])
        for count in 0..<original.count {
          XCTAssertThrowsError(try MachOInspector.inspect(file(root, Data(original.prefix(count)))))
        }
        var duplicate = original
        put(&duplicate, wide ? 40 : 28, 0x0100_000c, big: true)
        var huge = original
        if wide { put64(&huge, 16, UInt64.max) } else { put(&huge, 16, UInt32.max, big: true) }
        var misaligned = original
        put(&misaligned, wide ? 32 : 24, 30, big: true)
        var mismatched = original
        put(&mismatched, 128 + 8, 2)
        var wrongIntel = original
        put(&wrongIntel, 256 + 8, 2)
        var wrongIntelPlatform = original
        put(&wrongIntelPlatform, 256 + 40, 2)
        var overlap = original
        if wide { put64(&overlap, 48, 128) } else { put(&overlap, 36, 128, big: true) }
        for bad in [
          duplicate, huge, misaligned, mismatched, wrongIntel, wrongIntelPlatform, overlap,
        ] {
          XCTAssertThrowsError(try MachOInspector.inspect(file(root, bad)))
        }
        if wide {
          var reserved = original
          put(&reserved, 36, 1, big: true)
          XCTAssertThrowsError(try MachOInspector.inspect(file(root, reserved)))
        }
      }
    }
  }

  func testNativeDescriptorCustodyAndSparseCeiling() throws {
    try fixture { root in
      let path = try file(root, thin())
      for phase: FileReadPhase in [.opened, .finished] {
        let replacement = try file(root, thin(), name: "replacement")
        XCTAssertThrowsError(
          try MachOInspector.inspect(path) { seen in
            if seen == phase { XCTAssertEqual(rename(replacement, path), 0) }
          }
        ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
      }
      for changedSize: Int64 in [0, 57] {
        _ = try file(root, thin())
        XCTAssertThrowsError(
          try MachOInspector.inspect(path) { phase in
            if phase == .opened { XCTAssertEqual(truncate(path, off_t(changedSize)), 0) }
          }
        ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
      }
      _ = try file(root, thin())
      XCTAssertThrowsError(
        try MachOInspector.inspect(path) { phase in
          if phase == .opened { XCTAssertEqual(chmod(path, 0o400), 0) }
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
      XCTAssertEqual(chmod(path, 0o600), 0)
      XCTAssertEqual(truncate(path, 128 * 1024 * 1024 + 1), 0)
      XCTAssertThrowsError(try MachOInspector.inspect(path)) {
        XCTAssertEqual($0 as? ReleaseToolError, .inputLimit)
      }
      let alias = root + "/alias"
      XCTAssertEqual(symlink(path, alias), 0)
      XCTAssertThrowsError(try MachOInspector.inspect(alias))
      let fifo = root + "/fifo"
      XCTAssertEqual(mkfifo(fifo, 0o600), 0)
      XCTAssertThrowsError(try MachOInspector.inspect(fifo))
    }
  }

  func testScopedRegionViewCannotReadARecycledDescriptorAndDeadlineRefuses() throws {
    try fixture { root in
      let path = try file(root, thin())
      let policy = try FileReadPolicy(maximum: 1024)
      let available = open(path, O_RDONLY)
      XCTAssertGreaterThanOrEqual(available, 0)
      XCTAssertEqual(Darwin.close(available), 0)
      let escaped = try AdmittedFile.withRegions(path, policy: policy) { reader in
        XCTAssertEqual(try reader.read(offset: 0, count: 8).count, 8)
        return reader
      }
      let replacement = try file(root, Data("must not read this".utf8), name: "other")
      let descriptor = open(replacement, O_RDONLY)
      defer { Darwin.close(descriptor) }
      XCTAssertEqual(descriptor, available)
      XCTAssertThrowsError(try escaped.read(offset: 0, count: 8)) {
        XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
      }
      XCTAssertThrowsError(
        try AdmittedFile.withRegions(path, policy: policy) { reader in
          try reader.read(offset: Int64.max, count: Int.max)
        })
      XCTAssertThrowsError(
        try AdmittedFile.withRegions(path, policy: FileReadPolicy(maximum: 1024, seconds: 0.01)) {
          reader in
          usleep(30_000)
          return try reader.read(offset: 0, count: 8)
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .deadline) }
    }
  }

  func testActualCompiledCPUsAndUniversalLoaderFacts() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data("int main(void) { return 0; }\n".utf8).write(
      to: URL(fileURLWithPath: root + "/main.c"))
    for arch in ["arm64", "x86_64"] {
      _ = try await OwnedCommand().run(
        AppleCommand(
          .xcrun,
          arguments: [
            "clang", "-target", "\(arch)-apple-macos14.0",
            "-Wl,-rpath,@executable_path/../Frameworks",
            "main.c", "-o", arch,
          ], workingDirectory: root))
      let slice = try MachOInspector.inspect(root + "/" + arch)[0]
      XCTAssertEqual(slice.arch, arch)
      XCTAssertEqual(slice.minimum, "14.0.0")
      XCTAssertEqual(slice.filetype, 2)
      XCTAssertEqual(slice.dependencies, ["/usr/lib/libSystem.B.dylib"])
      XCTAssertEqual(slice.rpaths, ["@executable_path/../Frameworks"])
    }
    _ = try await OwnedCommand().run(
      AppleCommand(
        .lipo, arguments: ["-create", "arm64", "x86_64", "-output", "universal"],
        workingDirectory: root))
    let slices = try MachOInspector.inspect(root + "/universal")
    XCTAssertEqual(slices.map(\.arch), ["arm64", "x86_64"])
    XCTAssertTrue(slices.allSatisfy { $0.minimum == "14.0.0" && $0.filetype == 2 })
  }
}

private func directory() throws -> String {
  let root = "/tmp/frameshift-native-\(UUID().uuidString)"
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}
private func fixture(_ body: (String) throws -> Void) throws {
  let root = try directory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try body(root)
}
private func file(_ root: String, _ bytes: Data, name: String = "native") throws -> String {
  let path = root + "/" + name
  try bytes.write(to: URL(fileURLWithPath: path))
  XCTAssertEqual(chmod(path, 0o600), 0)
  return path
}
private func put(_ bytes: inout Data, _ offset: Int, _ value: UInt32, big: Bool = false) {
  for index in 0..<4 {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((big ? 3 - index : index) * 8))
  }
}
private func put64(_ bytes: inout Data, _ offset: Int, _ value: UInt64) {
  for index in 0..<8 {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((7 - index) * 8))
  }
}
private func command(_ type: UInt32, words: [UInt32] = []) -> Data {
  var bytes = Data(repeating: 0, count: ((8 + words.count * 4 + 7) / 8) * 8)
  put(&bytes, 0, type)
  put(&bytes, 4, UInt32(bytes.count))
  for (index, value) in words.enumerated() { put(&bytes, 8 + index * 4, value) }
  return bytes
}
private func buildVersion(minimum: UInt32 = 0x000e_0000, tools: Int = 0) -> Data {
  command(
    0x32, words: [1, minimum, 0x000e_0000, UInt32(tools)] + Array(repeating: 0, count: tools * 2))
}
private func stringCommand(_ code: UInt32, _ text: String, base: Int) -> Data {
  let payload = Data(text.utf8) + Data([0])
  var bytes = Data(repeating: 0, count: ((base + payload.count + 7) / 8) * 8)
  put(&bytes, 0, code)
  put(&bytes, 4, UInt32(bytes.count))
  put(&bytes, 8, UInt32(base))
  bytes.replaceSubrange(base..<(base + payload.count), with: payload)
  return bytes
}
private func thin(
  type: UInt32 = 0x0100_000c, subtype: UInt32 = 0, filetype: UInt32 = 2,
  commands: [Data] = [buildVersion()]
) -> Data {
  var bytes = Data(repeating: 0, count: 32)
  put(&bytes, 0, 0xfeed_facf)
  put(&bytes, 4, type)
  put(&bytes, 8, subtype)
  put(&bytes, 12, filetype)
  put(&bytes, 16, UInt32(commands.count))
  put(&bytes, 20, UInt32(commands.reduce(0) { $0 + $1.count }))
  for command in commands { bytes.append(command) }
  return bytes
}
private func fat(wide: Bool) -> Data {
  var bytes = Data(repeating: 0, count: 312)
  put(&bytes, 0, wide ? 0xcafe_babf : 0xcafe_babe, big: true)
  put(&bytes, 4, 2, big: true)
  for (index, type, subtype, offset): (Int, UInt32, UInt32, Int) in [
    (0, 0x0100_000c, 0, 128), (1, 0x0100_0007, 3, 256),
  ] {
    let base = 8 + index * (wide ? 32 : 20)
    put(&bytes, base, type, big: true)
    put(&bytes, base + 4, subtype, big: true)
    if wide {
      put64(&bytes, base + 8, UInt64(offset))
      put64(&bytes, base + 16, 56)
    } else {
      put(&bytes, base + 8, UInt32(offset), big: true)
      put(&bytes, base + 12, 56, big: true)
    }
    put(&bytes, base + (wide ? 24 : 16), 3, big: true)
    bytes.replaceSubrange(offset..<(offset + 56), with: thin(type: type, subtype: subtype))
  }
  return bytes
}
