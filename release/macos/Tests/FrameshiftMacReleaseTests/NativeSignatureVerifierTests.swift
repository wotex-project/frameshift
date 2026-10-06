import Darwin
import Foundation
import Security
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class NativeSignatureVerifierTests: XCTestCase {
  func testActualSignedBothCPUAndUniversalBundlesRetainObservationAndCustody() async throws {
    for architecture: NativeBundleArchitecture in [.arm64, .intel, .universal] {
      let fixture = try await NativeBundleFixture(architecture: architecture)
      defer { fixture.remove() }
      XCTAssertThrowsError(
        try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: architecture)
      )
      try await seal(fixture, architecture: architecture)
      let before = try NativeBundleInspector.inspectWithCustody(
        fixture.app, architecture: architecture)
      let result = try NativeSignatureVerifier.verifyDevelopmentBundle(
        fixture.app, architecture: architecture)
      let after = try NativeBundleInspector.inspectWithCustody(
        fixture.app, architecture: architecture)
      XCTAssertEqual(try result.observationBytes(), try before.observation.observationBytes())
      XCTAssertEqual(before.custody, after.custody)
      try await command(["--verify", "--all-architectures", "--deep", "--strict", fixture.app])
    }
  }

  func testUnsignedNonstandardLeafRefusesDespiteResealedOuterApp() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    try await seal(fixture)
    let nif = fixture.app + "/Contents/Resources/core/lib/exile-fixture/priv/exile.so"
    try await command(["--remove-signature", nif])
    try await command(["--force", "--sign", "-", "--timestamp=none", fixture.app])
    try await command(["--verify", "--deep", "--strict", fixture.app])
    let before = try NativeBundleInspector.inspectWithCustody(fixture.app, architecture: .arm64)
    XCTAssertThrowsError(
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: .arm64)
    ) { XCTAssertEqual($0 as? ReleaseToolError, .invalidSignature) }
    let after = try NativeBundleInspector.inspectWithCustody(fixture.app, architecture: .arm64)
    XCTAssertEqual(before.custody, after.custody)
  }

  func testCorruptIntelSlicePassesDefaultNativeCheckButAllArchitectureChecksRefuse() async throws {
    let fixture = try await NativeBundleFixture(architecture: .universal)
    defer { fixture.remove() }
    try await seal(fixture, architecture: .universal)
    let nif = fixture.app + "/Contents/Resources/core/lib/exile-fixture/priv/exile.so"
    var bytes = try Data(contentsOf: URL(fileURLWithPath: nif))
    func big(_ offset: Int) -> UInt32 {
      bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    XCTAssertEqual(big(0), 0xcafe_babe)
    XCTAssertEqual(big(4), 2)
    let entry = try XCTUnwrap([8, 28].first { big($0) == 0x0100_0007 })
    let offset = Int(big(entry + 8))
    let commands = bytes[(offset + 20)..<(offset + 24)].enumerated().reduce(0) {
      $0 | (Int($1.element) << (8 * $1.offset))
    }
    let changed = offset + 32 + commands + 16
    XCTAssertLessThan(changed, offset + Int(big(entry + 12)))
    bytes[changed] ^= 1
    try bytes.write(to: URL(fileURLWithPath: nif))
    var code: SecStaticCode?
    XCTAssertEqual(
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: nif) as CFURL, SecCSFlags(), &code),
      errSecSuccess)
    let native = try XCTUnwrap(code)
    XCTAssertEqual(SecStaticCodeCheckValidity(native, SecCSFlags(), nil), errSecSuccess)
    XCTAssertNotEqual(
      SecStaticCodeCheckValidity(native, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil),
      errSecSuccess)
    await assertCommandRefuses(["--verify", "--all-architectures", "--strict", nif])
    try await command(["--force", "--sign", "-", "--timestamp=none", fixture.app])
    let before = try NativeBundleInspector.inspectWithCustody(fixture.app, architecture: .universal)
    XCTAssertThrowsError(
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: .universal)
    ) { XCTAssertEqual($0 as? ReleaseToolError, .invalidSignature) }
    XCTAssertEqual(
      before.custody,
      try NativeBundleInspector.inspectWithCustody(fixture.app, architecture: .universal).custody)
  }

  func testOuterResourceTamperAndPostCheckSameBytesOrEmptyTreeRefuse() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    let note = fixture.app + "/Contents/Resources/note"
    try Data("retained resource".utf8).write(to: URL(fileURLWithPath: note))
    try await seal(fixture)
    try Data("changed resource".utf8).write(to: URL(fileURLWithPath: note))
    XCTAssertThrowsError(
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: .arm64)
    ) { XCTAssertEqual($0 as? ReleaseToolError, .invalidSignature) }
    await assertCommandRefuses(["--verify", "--deep", "--strict", fixture.app])
    try await seal(fixture)
    let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
    for change in [0, 1] {
      XCTAssertThrowsError(
        try NativeSignatureVerifier.verifyDevelopmentBundle(
          fixture.app, architecture: .arm64,
          observe: {
            if change == 0 {
              try Data("changed resource".utf8).write(to: URL(fileURLWithPath: note))
            } else {
              try FileManager.default.createDirectory(
                atPath: fixture.app + "/new-empty", withIntermediateDirectories: false)
            }
          })
      ) { XCTAssertEqual($0 as? ReleaseToolError, .inputChanged) }
      XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
    }
  }

  func testStrictResourceForkRefusesWithoutRemovingCandidateMetadata() async throws {
    let fixture = try await NativeBundleFixture()
    defer { fixture.remove() }
    try await seal(fixture)
    let shell = fixture.app + "/Contents/MacOS/Frameshift"
    let bytes = Data("fixture sideband".utf8)
    let written = bytes.withUnsafeBytes {
      setxattr(shell, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
    }
    XCTAssertEqual(written, 0)
    XCTAssertThrowsError(
      try NativeSignatureVerifier.verifyDevelopmentBundle(fixture.app, architecture: .arm64)
    ) { XCTAssertEqual($0 as? ReleaseToolError, .invalidSignature) }
    await assertCommandRefuses(["--verify", "--deep", "--strict", fixture.app])
    XCTAssertEqual(getxattr(shell, "com.apple.ResourceFork", nil, 0, 0, 0), bytes.count)
  }

  private func seal(
    _ fixture: NativeBundleFixture, architecture: NativeBundleArchitecture = .arm64
  ) async throws {
    let observation = try NativeBundleInspector.inspect(fixture.app, architecture: architecture)
    for file in observation.natives where file.path != "Contents/MacOS/Frameshift" {
      try await command([
        "--force", "--sign", "-", "--timestamp=none", fixture.app + "/" + file.path,
      ])
    }
    try await command(["--force", "--sign", "-", "--timestamp=none", fixture.app])
  }

  private func command(_ arguments: [String]) async throws {
    _ = try await OwnedCommand().run(AppleCommand(.codesign, arguments: arguments))
  }

  private func assertCommandRefuses(_ arguments: [String]) async {
    do {
      try await command(arguments)
      XCTFail("Expected signature refusal")
    } catch {
      XCTAssertEqual(error as? ReleaseToolError, .childFailed)
    }
  }
}
