import Foundation
import Security

/// Read-only static seal admission for the existing ad-hoc development profile.
///
/// Complete bounded closure admission brackets fresh Security API checks of
/// every native file, all pinned updater containers and the outer app. Every
/// code reference requests strict, all-architecture and nested validation;
/// separately checking nonstandard OTP/NIF/renderer leaves avoids relying on
/// Apple's standard bundle discovery. The outer signing flags must be ad-hoc.
///
/// Returned observations retain publication authority none. This does not
/// qualify Developer ID, certificate trust, notarization, Gatekeeper, older-OS
/// symbols or installed execution. The two-minute budget checks between calls
/// and cannot preempt a blocked Security or filesystem operation. No network
/// evaluation, candidate code execution, repair or re-signing is performed.
public enum NativeSignatureVerifier {
  public static func verifyDevelopmentBundle(
    _ input: String, architecture: NativeBundleArchitecture
  ) throws -> NativeBundleObservation {
    try verifyDevelopmentBundle(input, architecture: architecture, observe: nil)
  }

  static func verifyDevelopmentBundle(
    _ input: String, architecture: NativeBundleArchitecture,
    observe: (() throws -> Void)?
  ) throws -> NativeBundleObservation {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    func checkBudget() throws {
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
    }
    let before = try NativeBundleInspector.inspectWithCustody(input, architecture: architecture)
    try checkBudget()
    let root = URL(fileURLWithPath: input).standardizedFileURL.path
    var members = before.observation.natives.map { root + "/" + $0.path }
    if before.observation.links != nil {
      members += BundleSparkle.containers.map { root + "/" + $0 }
    }
    members.append(root)
    for path in members {
      try checkBudget()
      try verify(path, requireAdHoc: path == root)
      try checkBudget()
    }
    try observe?()
    try checkBudget()
    let after = try NativeBundleInspector.inspectWithCustody(input, architecture: architecture)
    guard before.custody == after.custody,
      try before.observation.observationBytes() == after.observation.observationBytes()
    else { throw ReleaseToolError.inputChanged }
    try checkBudget()
    return before.observation
  }

  private static func verify(_ path: String, requireAdHoc: Bool) throws {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code
    else { throw ReleaseToolError.invalidSignature }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        | kSecCSRestrictSymlinks | kSecCSRestrictSidebandData)
    guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
      throw ReleaseToolError.invalidSignature
    }
    if requireAdHoc {
      var information: CFDictionary?
      guard SecCodeCopySigningInformation(code, SecCSFlags(), &information) == errSecSuccess,
        let dictionary = information as? [String: Any],
        let number = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
        CFGetTypeID(number) == CFNumberGetTypeID(),
        let value = UInt32(exactly: number.int64Value),
        value & SecCodeSignatureFlags.adhoc.rawValue != 0
      else { throw ReleaseToolError.invalidSignature }
    }
  }
}
