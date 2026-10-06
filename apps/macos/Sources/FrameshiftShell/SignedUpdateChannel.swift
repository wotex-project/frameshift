import CoreFoundation
import Foundation

/// A pinned feed and public key admitted before a native updater may start.
///
/// `admit(info:feedURL:publicKey:)` compares typed bundle defaults with separate
/// release pins. A channel is not a distribution credential: the caller must
/// independently qualify the distribution profile before starting Sparkle.
/// Development or missing-pin callers leave updates unavailable. This SDK-free
/// gate performs no network, signature, Keychain or preference operation and
/// never supplies a fallback feed or production key.
///
/// Feed URLs use a bounded HTTPS/DNS profile; public keys are canonical base64
/// encodings of 32 bytes. Signed-feed and extraction enforcement, zero stale
/// feed tolerance, manual initial checking, disabled automatic installation and
/// disabled profiling are typed initial plist defaults. The running adapter
/// preserves later user choices and returns this feed through the documented
/// delegate hook so stored URL overrides cannot select another channel.
public struct SignedUpdateChannel: Equatable, Sendable {
  public let feedURL: String
  public let publicKey: String

  private init(feedURL: String, publicKey: String) {
    self.feedURL = feedURL
    self.publicKey = publicKey
  }

  /// Returns no channel for absent, mistyped, unsafe or mismatched metadata/pins.
  public static func admit(info: [String: Any], feedURL: String, publicKey: String) -> Self? {
    guard validFeed(feedURL), validKey(publicKey),
      let recordedFeed = info["SUFeedURL"] as? String, recordedFeed == feedURL,
      let recordedKey = info["SUPublicEDKey"] as? String, recordedKey == publicKey,
      ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"].allSatisfy({
        boolean(info[$0]) == true
      }),
      [
        "SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate",
        "SUSendProfileInfo",
      ].allSatisfy({
        boolean(info[$0]) == false
      }),
      let expiration = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber,
      CFGetTypeID(expiration) == CFNumberGetTypeID(), expiration.doubleValue.isFinite,
      expiration.doubleValue == 0
    else { return nil }
    return Self(feedURL: feedURL, publicKey: publicKey)
  }

  private static func boolean(_ input: Any?) -> Bool? {
    guard let value = input as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
      return nil
    }
    return value.boolValue
  }

  private static func validKey(_ value: String) -> Bool {
    guard value.utf8.count == 44, let bytes = Data(base64Encoded: value), bytes.count == 32 else {
      return false
    }
    return bytes.base64EncodedString() == value
  }

  private static func validFeed(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 2048,
      value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 92 }),
      let parts = URLComponents(string: value), parts.scheme == "https",
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      let host = parts.host, !host.isEmpty, host.utf8.count <= 253,
      host == host.lowercased(), !host.hasSuffix("."),
      parts.percentEncodedHost == host,
      parts.port == nil || ((1...65535).contains(parts.port!) && parts.port != 443),
      parts.url?.absoluteString == value
    else { return false }
    let authority = value.dropFirst("https://".count).prefix { $0 != "/" }
    guard authority == host + (parts.port.map { ":\($0)" } ?? "") else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, !labels.allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) })
    else { return false }
    return labels.allSatisfy { label in
      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
    }
  }
}
