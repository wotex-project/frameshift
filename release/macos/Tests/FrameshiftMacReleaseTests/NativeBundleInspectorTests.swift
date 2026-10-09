import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class NativeBundleInspectorTests: XCTestCase {
  func testActualCompiledRequiredRolesForBothCPUsAndUniversal() async throws {
    for architecture: NativeBundleArchitecture in [.arm64, .intel, .universal] {
      let fixture = try await NativeBundleFixture(architecture: architecture)
      defer { fixture.remove() }
      let result = try NativeBundleInspector.inspect(fixture.app, architecture: architecture)
      XCTAssertEqual(result.natives.count, 7)
      XCTAssertEqual(result.nativeMinimum, "14.0.0")
      XCTAssertEqual(result.declaredMinimum, "14.0")
      XCTAssertNil(result.links)
      let bytes = try result.observationBytes()
      XCTAssertTrue(
        bytes.starts(with: Data("{\"schemaVersion\":2,\"publicationAuthority\":\"none\"".utf8)))
      let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      XCTAssertEqual(fields["schemaVersion"] as? Int, 2)
      XCTAssertEqual(fields["architecture"] as? String, architecture.rawValue)
      XCTAssertEqual(fields["publicationAuthority"] as? String, "none")
      XCTAssertEqual(
        try result.observationBytes(),
        try NativeBundleInspector.inspect(fixture.app, architecture: architecture)
          .observationBytes())
      if architecture != .universal {
        XCTAssertThrowsError(
          try NativeBundleInspector.inspect(fixture.app, architecture: .universal))
        XCTAssertThrowsError(
          try NativeBundleInspector.inspect(
            fixture.app, architecture: architecture == .arm64 ? .intel : .arm64))
      }
    }
  }

  func testRequiredRoleAndTypedMinimumRefusalsPreserveInput() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let plist = fixture.app + "/Contents/Info.plist"
    let original = try Data(contentsOf: URL(fileURLWithPath: plist))
    for minimum in ["13.0", "14", "014.0", "14.256", "65536.0", "14.0\n"] {
      try fixture.writePlist(minimum: minimum)
      XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
      XCTAssertEqual(
        try Data(contentsOf: URL(fileURLWithPath: plist)), fixture.plist(minimum: minimum))
    }
    try original.write(to: URL(fileURLWithPath: plist))
    let shell = fixture.app + "/Contents/MacOS/Frameshift"
    XCTAssertEqual(chmod(shell, 0o644), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(chmod(shell, 0o755), 0)
    let missing = fixture.root + "/retained"
    XCTAssertEqual(rename(shell, missing), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(rename(missing, shell), 0)
    let duplicate = fixture.app + "/Contents/Resources/core/erts-other/bin/beam.smp"
    try fixture.copy(shell, to: duplicate)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
  }

  func testOutsideMissingAndInheritedLoaderContextRefuses() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let shell = fixture.app + "/Contents/MacOS/Frameshift"
    try await fixture.tool(["install_name_tool", "-add_rpath", "/opt/homebrew/lib", shell])
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    try await fixture.tool(["install_name_tool", "-delete_rpath", "/opt/homebrew/lib", shell])
    try await fixture.tool([
      "install_name_tool", "-change", "/usr/lib/libSystem.B.dylib", "@loader_path/missing.dylib",
      shell,
    ])
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    try fixture.copy(fixture.library, to: fixture.app + "/Contents/MacOS/missing.dylib")
    XCTAssertEqual(
      try NativeBundleInspector.inspect(fixture.app, architecture: .arm64).natives.count, 8)
    try await fixture.tool([
      "install_name_tool", "-change", "@loader_path/missing.dylib", "@rpath/missing.dylib", shell,
    ])
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
  }

  func testLinksModesDevicesSparseAndPathBudgetsRefuse() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let extra = fixture.app + "/extra"
    XCTAssertEqual(symlink("Contents/MacOS/Frameshift", extra), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(unlink(extra), 0)
    XCTAssertEqual(link(fixture.app + "/Contents/MacOS/Frameshift", extra), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(unlink(extra), 0)
    XCTAssertEqual(mkfifo(extra, 0o600), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(unlink(extra), 0)
    try Data().write(to: URL(fileURLWithPath: extra))
    XCTAssertEqual(truncate(extra, 128 * 1024 * 1024 + 1), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(unlink(extra), 0)
    XCTAssertEqual(chmod(fixture.app + "/Contents", 0o777), 0)
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    XCTAssertEqual(chmod(fixture.app + "/Contents", 0o755), 0)
    var deep = fixture.app
    for _ in 0..<33 {
      deep += "/d"
      try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: false)
    }
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
  }

  func testTreeCustodyIncludesSameByteRewriteAndAddedEmptyDirectories() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let file = fixture.app + "/Contents/Resources/note"
    try Data("unchanged bytes".utf8).write(to: URL(fileURLWithPath: file))
    let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
    for change in [0, 1] {
      XCTAssertThrowsError(
        try NativeBundleInspector.inspect(fixture.app, architecture: .arm64) { phase in
          guard phase == .checked else { return }
          if change == 0 {
            try Data("unchanged bytes".utf8).write(to: URL(fileURLWithPath: file))
          } else {
            try FileManager.default.createDirectory(
              atPath: fixture.app + "/new-empty", withIntermediateDirectories: false)
          }
        }
      ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
    }
  }

  func testNativeAndEntryCapsRefuseBeforeReturningAnObservation() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let folder = fixture.app + "/natives"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    for index in 0..<129 { try fixture.copy(fixture.executable, to: folder + "/\(index)") }
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
    try FileManager.default.removeItem(atPath: folder)
    let entries = fixture.app + "/entries"
    let base = try NativeBundleInspector.inspect(fixture.app, architecture: .arm64)
    let remaining = 8192 - base.files.count - base.directories.count - 1
    try FileManager.default.createDirectory(atPath: entries, withIntermediateDirectories: false)
    for index in 0..<remaining { try Data().write(to: URL(fileURLWithPath: entries + "/\(index)")) }
    let exact = try NativeBundleInspector.inspect(fixture.app, architecture: .arm64)
    XCTAssertEqual(exact.files.count + exact.directories.count, 8192)
    try Data().write(to: URL(fileURLWithPath: entries + "/next"))
    XCTAssertThrowsError(try NativeBundleInspector.inspect(fixture.app, architecture: .arm64))
  }
}

@MainActor
final class NativeBundleFixture {
  let root: String
  let app: String
  let executable: String
  let library: String
  init(architecture: NativeBundleArchitecture = .arm64, rpath: String? = nil) async throws {
    root = "/tmp/frameshift-bundle-\(UUID().uuidString)"
    app = root + "/Frameshift.app"
    executable = root + "/exe"
    library = root + "/lib"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
      let source = root + "/input.c"
      try Data("int fixture(void) { return 7; }\nint main(void) { return 0; }\n".utf8).write(
        to: URL(fileURLWithPath: source))
      let architectures =
        architecture == .universal ? ["arm64", "x86_64"] : [architecture.rawValue]
      for (kind, output) in [("exe", executable), ("lib", library)] {
        var slices: [String] = []
        for arch in architectures {
          let path = root + "/\(kind)-\(arch)"
          let flags =
            kind == "lib" ? ["-dynamiclib", "-install_name", "@loader_path/fixture.dylib"] : []
          // Link the initial search path without depending on spare load-command space.
          let search = rpath.map { ["-Wl,-rpath,\($0)"] } ?? []
          try await tool(
            ["clang", "-target", "\(arch)-apple-macos14.0", "-Wl,-headerpad_max_install_names"]
              + flags + search + [source, "-o", path])
          slices.append(path)
        }
        if slices.count == 2 {
          _ = try await OwnedCommand().run(
            AppleCommand(.lipo, arguments: ["-create"] + slices + ["-output", output]))
        } else {
          try FileManager.default.copyItem(atPath: slices[0], toPath: output)
        }
      }
      let roles = [
        ("Contents/MacOS/Frameshift", executable), ("Contents/MacOS/frameshiftctl", executable),
        ("Contents/Resources/bin/frameshift-raster", executable),
        ("Contents/Resources/core/erts-fixture/bin/beam.smp", executable),
        ("Contents/Resources/core/lib/exile-fixture/priv/exile.so", library),
        ("Contents/Resources/core/lib/exile-fixture/priv/spawner", executable),
        ("Contents/Resources/core/lib/exqlite-fixture/priv/sqlite3_nif.so", library),
      ]
      for (relative, input) in roles { try copy(input, to: app + "/" + relative) }
      try writePlist(minimum: "14.0")
    } catch {
      remove()
      throw error
    }
  }
  func remove() { try? FileManager.default.removeItem(atPath: root) }
  func copy(_ input: String, to output: String) throws {
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: output).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: input, toPath: output)
    guard chmod(output, 0o755) == 0 else { throw ReleaseToolError.readFailed }
  }
  func tool(_ arguments: [String]) async throws {
    _ = try await OwnedCommand().run(AppleCommand(.xcrun, arguments: arguments))
  }
  func plist(minimum: String) -> Data {
    Data(
      "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Frameshift</string><key>CFBundleIdentifier</key><string>io.frameshift.native-fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>0.1.0</string><key>LSMinimumSystemVersion</key><string>\(minimum)</string></dict></plist>"
        .utf8)
  }
  func writePlist(minimum: String) throws {
    try plist(minimum: minimum).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
  }
}
