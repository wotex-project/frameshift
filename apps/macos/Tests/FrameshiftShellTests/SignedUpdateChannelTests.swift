import CoreFoundation
import Foundation
import FrameshiftShell
import Testing

@Suite("Signed updater channel admission")
struct SignedUpdateChannelTests {
  private let feed = "https://updates.example.invalid/appcast.xml"
  private let key = Data(repeating: 0x7a, count: 32).base64EncodedString()

  @Test("Actual bundle defaults enforce signatures and start without a channel or preferences")
  func actualDevelopmentDefaults() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    var inputs = [package.appendingPathComponent("App/Info.plist")]
    if let fixture = ProcessInfo.processInfo.environment["FRAMESHIFT_PACKAGED_APP_FIXTURE"] {
      inputs.append(URL(fileURLWithPath: fixture).appendingPathComponent("Contents/Info.plist"))
    }
    for input in inputs {
      let bytes = try Data(contentsOf: input)
      let info = try #require(
        PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
      #expect(info["SUFeedURL"] == nil)
      #expect(info["SUPublicEDKey"] == nil)
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
      var withPins = info
      withPins["SUFeedURL"] = feed
      withPins["SUPublicEDKey"] = key
      #expect(SignedUpdateChannel.admit(info: withPins, feedURL: feed, publicKey: key) != nil)
      #expect(info["SUFeedURL"] == nil)
      #expect(info["SUPublicEDKey"] == nil)
      #expect(bytes == (try Data(contentsOf: input)))
    }
  }

  @Test("Real XML and binary plist types preserve exact pins with no defaults mutation")
  func realPlistRoundTripAndExactPins() throws {
    for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
      let bytes = try PropertyListSerialization.data(
        fromPropertyList: metadata(), format: format, options: 0)
      let info = try #require(
        PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
      let channel = try #require(
        SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key))
      #expect(channel.feedURL == feed)
      #expect(channel.publicKey == key)
      #expect(
        SignedUpdateChannel.admit(
          info: info, feedURL: "https://other.example.invalid/appcast.xml", publicKey: key) == nil)
      #expect(
        SignedUpdateChannel.admit(
          info: info, feedURL: feed,
          publicKey: Data(repeating: 0x01, count: 32).base64EncodedString()) == nil)
      #expect(SignedUpdateChannel.admit(info: info, feedURL: "", publicKey: key) == nil)
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: "") == nil)
      #expect((info["SUEnableAutomaticChecks"] as? NSNumber)?.boolValue == false)
    }
  }

  @Test("Signed policy and manual defaults require booleans; expiration requires numeric zero")
  func typedPolicies() {
    for name in [
      "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks",
      "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUSendProfileInfo",
    ] {
      for bad: Any in [NSNull(), "false", "true", 0, 1, 0.0, 1.0] {
        var info = metadata()
        info[name] = bad
        #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
      }
      var info = metadata()
      info.removeValue(forKey: name)
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
      info[name] = !(name == "SURequireSignedFeed" || name == "SUVerifyUpdateBeforeExtraction")
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
    }
    for bad: Any in [NSNull(), true, false, "0", 1, -1, 1e-300, Double.infinity, Double.nan] {
      var info = metadata()
      info["SUSignedFeedFailureExpirationInterval"] = bad
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
    }
    for zero: Any in [0, 0.0, -0.0] {
      var info = metadata()
      info["SUSignedFeedFailureExpirationInterval"] = zero
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) != nil)
    }
  }

  @Test("URLs refuse injection, alternative serialization, invalid hosts and actual byte bounds")
  func feedBounds() {
    let invalid = [
      "http://updates.example.invalid/appcast.xml", "HTTPS://updates.example.invalid/appcast.xml",
      "https://Updates.example.invalid/appcast.xml", "https://updates.example.invalid./appcast.xml",
      "https://user@updates.example.invalid/appcast.xml",
      "https://user:password@updates.example.invalid/appcast.xml",
      feed + "?x=1", feed + "#fragment", feed + "?", feed + "#", feed + "\n", feed + "\\file",
      "https://updates..example.invalid/appcast.xml",
      "https://-updates.example.invalid/appcast.xml",
      "https://updates-.example.invalid/appcast.xml", "https://localhost/appcast.xml",
      "https://127.0.0.1/appcast.xml", "https://[::1]/appcast.xml",
      "https://updates.example.invalid:443/appcast.xml",
      "https://updates.example.invalid:0/appcast.xml",
      "https://updates.example.invalid:65536/appcast.xml",
      "https://updates.example.invalid:/appcast.xml",
      "https://updates.example.invalid:999999999999999999999999/appcast.xml",
      "https://updates.example.invalid:abc/appcast.xml",
      "https://updates.example.invalid:08443/appcast.xml",
      "https://%75pdates.example.invalid/appcast.xml", "https://更新.example.invalid/appcast.xml",
      "https://" + String(repeating: "a", count: 64) + ".example.invalid/appcast.xml",
    ]
    for value in invalid { #expect(admitFeed(value) == nil) }
    let prefix = "https://updates.example.invalid/"
    let maximum = prefix + String(repeating: "a", count: 2048 - prefix.utf8.count)
    #expect(admitFeed(maximum) != nil)
    #expect(admitFeed(maximum + "a") == nil)
    #expect(admitFeed("https://updates.example.invalid:8443/escaped%20file.xml") != nil)
  }

  @Test("Public keys have an exact byte count and canonical base64 encoding")
  func keyBoundsAndTypes() {
    for bad in [
      "", key + "\n", String(key.dropLast()), String(key.dropLast(2)) + "B=",
      Data(repeating: 1, count: 31).base64EncodedString(),
      Data(repeating: 1, count: 33).base64EncodedString(), String(repeating: "A", count: 1024),
    ] {
      var info = metadata()
      info["SUPublicEDKey"] = bad
      #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: bad) == nil)
    }
    for field in ["SUFeedURL", "SUPublicEDKey"] {
      for bad: Any in [NSNull(), true, 1, Data([1]), [feed], ["value": key]] {
        var info = metadata()
        info[field] = bad
        #expect(SignedUpdateChannel.admit(info: info, feedURL: feed, publicKey: key) == nil)
      }
    }
  }

  private func admitFeed(_ input: String) -> SignedUpdateChannel? {
    var info = metadata()
    info["SUFeedURL"] = input
    return SignedUpdateChannel.admit(info: info, feedURL: input, publicKey: key)
  }
  private func metadata() -> [String: Any] {
    [
      "SUFeedURL": feed, "SUPublicEDKey": key,
      "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
      "SUSignedFeedFailureExpirationInterval": 0,
      "SUEnableAutomaticChecks": false, "SUAllowsAutomaticUpdates": false,
      "SUAutomaticallyUpdate": false, "SUSendProfileInfo": false,
    ]
  }
}
