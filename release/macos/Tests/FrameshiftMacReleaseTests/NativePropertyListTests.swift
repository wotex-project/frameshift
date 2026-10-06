import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

final class NativePropertyListTests: XCTestCase {
  func testAppleXMLAndBinaryRemainTypedAndPreserveUnicodeValues() throws {
    let text = "e\u{301} / 日本 / 🎨"
    let object: [String: Any] = [
      "CFBundleIdentifier": "org.frameshift.Frameshift", "text": text,
      "bool": true, "one": Int64(1), "zero": Int64(0),
      "real": NSNumber(value: 1.0), "negative": Int64(-1),
      "minimum": Int64.min, "maximum": Int64.max,
      "nested": ["array": [true, "value", Int64(42)]],
    ]
    for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
      let bytes = try PropertyListSerialization.data(
        fromPropertyList: object, format: format, options: 0)
      let plist = try NativePropertyList.decode(bytes)
      XCTAssertEqual(plist.values["bool"], .boolean(true))
      XCTAssertEqual(plist.values["one"], .integer(1))
      XCTAssertEqual(plist.values["zero"], .integer(0))
      XCTAssertEqual(plist.values["real"], .real(1.0))
      XCTAssertEqual(plist.values["negative"], .integer(-1))
      XCTAssertEqual(plist.values["minimum"], .integer(Int64.min))
      XCTAssertEqual(plist.values["maximum"], .integer(Int64.max))
      XCTAssertEqual(
        plist.values["nested"],
        .dictionary(["array": .array([.boolean(true), .string("value"), .integer(42)])]))
      guard case .string(let received) = plist.values["text"] else {
        return XCTFail("missing text")
      }
      XCTAssertEqual(Data(received.utf8), Data(text.utf8))
    }
  }

  func testXMLDuplicateAmbiguousKeysAndInvalidStructureRefuse() throws {
    let invalid = [
      "<dict><key>a</key><true/><key>a</key><false/></dict>",
      "<dict><key>é</key><true/><key>e\u{301}</key><false/></dict>",
      "<dict><key>a</key></dict>", "<dict><true/></dict>",
      "<dict><key>a</key><key>b</key></dict>",
      "<dict><key>a</key><array><key>b</key></array></dict>",
      "<dict><key>a</key><true>content</true></dict>",
      "<dict/><dict/>", "<array/>", "<dict><key>a</key><string><true/></string></dict>",
    ]
    for body in invalid { refuses(xml(body)) }
    refuses(Data("{ a = 1; }".utf8))
    refuses(Data("{}".utf8))
    refuses(Data())
    refuses(Data(repeating: 0, count: 64 * 1024 + 1))
  }

  func testDeclaredEntitiesCannotSupplyValuesOrRemainHidden() throws {
    for declaration in [
      "<!ENTITY x 'expanded'>", "<!ENTITY x SYSTEM 'file:///private/absent-secret'>",
      "<!ENTITY x SYSTEM 'https://invalid.example/metadata'>",
    ] {
      for value in ["&x;", "ordinary"] {
        let bytes = Data(
          """
          <?xml version="1.0"?><!DOCTYPE plist [\(declaration)]>
          <plist version="1.0"><dict><key>a</key><string>\(value)</string></dict></plist>
          """.utf8)
        refuses(bytes)
      }
    }
    let standard = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>a</key><string>Apple &amp; art</string></dict></plist>
      """.utf8)
    XCTAssertEqual(try NativePropertyList.decode(standard).values["a"], .string("Apple & art"))
    var utf16 = Data([0xfe, 0xff])
    utf16.append(
      try XCTUnwrap(
        String(data: standard, encoding: .utf8)?.replacingOccurrences(of: "UTF-8", with: "UTF-16")
          .data(using: .utf16BigEndian)))
    XCTAssertEqual(try NativePropertyList.decode(utf16).values["a"], .string("Apple & art"))
  }

  func testIntegerOverflowNonfiniteRealAndUnsupportedTypesRefuse() throws {
    for value in ["9223372036854775808", "-9223372036854775809", "18446744073709551616"] {
      refuses(xml("<dict><key>a</key><integer>\(value)</integer></dict>"))
    }
    for value in ["nan", "infinity", "-infinity", "1e1000"] {
      refuses(xml("<dict><key>a</key><real>\(value)</real></dict>"))
    }
    for value in ["<data>YWJj</data>", "<date>2026-10-06T00:00:00Z</date>"] {
      refuses(xml("<dict><key>a</key>\(value)</dict>"))
    }
    for value: [UInt8] in [
      [0x00], [0x40], [0x33] + [UInt8](repeating: 0, count: 8), [0x80, 1], [0xc0],
      [0x14] + [UInt8](repeating: 0, count: 16),
    ] {
      refuses(binary([[0xd1, 1, 2], [0x51, 0x61], value]))
    }
    let nan = [UInt8(0x23)] + bigEndian(Double.nan.bitPattern, width: 8)
    refuses(binary([[0xd1, 1, 2], [0x51, 0x61], nan]))
  }

  func testBinaryCyclesDuplicateKeysInvalidReferencesAndLengthsRefuse() throws {
    refuses(binary([[0xd1, 1, 2], [0x51, 0x61], [0xa1, 2]]))
    refuses(binary([[0xd2, 1, 1, 2, 3], [0x51, 0x61], [0x08], [0x09]]))
    refuses(binary([[0xd1, 1, 255], [0x51, 0x61], [0x09]]))
    refuses(
      binary([[0xd1, 1, 2], [0x51, 0x61], [0xaf, 0x13] + [UInt8](repeating: 255, count: 8)]))
    refuses(binary([[0xd1, 1, 2], [0x51, 0x61], [0xaf, 0x1f]]))
    refuses(binary([[0xd1, 1, 2], [0x51, 0x61], [0x62, 0xd8, 0x00, 0x00, 0x61]]))
    refuses(binary([[0xd1, 1, 2], [0x51, 0x61], [0x51, 0xff]]))
    let valid = binary([[0xd1, 1, 2], [0x51, 0x61], [0x09]])
    XCTAssertEqual(try NativePropertyList.decode(valid).values["a"], .boolean(true))
    for (position, value) in [(6, UInt8(0)), (7, 255)] {
      var changed = valid
      changed[changed.count - 32 + position] = value
      refuses(changed)
    }
    for position in [8, 16, 24] {
      var changed = valid
      changed.replaceSubrange(
        (changed.count - 32 + position)..<(changed.count - 24 + position),
        with: [UInt8](repeating: 255, count: 8))
      refuses(changed)
    }
    var duplicateOffset = valid
    let table = valid.count - 32 - 6
    duplicateOffset.replaceSubrange((table + 2)..<(table + 4), with: valid[table..<(table + 2)])
    refuses(duplicateOffset)
    for length in 1..<valid.count { refuses(valid.prefix(length)) }
  }

  func testDepthBoundaryPassesAndDeeperAppleGraphsRefuse() throws {
    for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
      var value: Any = "leaf"
      for _ in 0..<30 { value = [value] }
      let allowed = try PropertyListSerialization.data(
        fromPropertyList: ["a": value], format: format, options: 0)
      XCTAssertNoThrow(try NativePropertyList.decode(allowed))
      let tooDeep = try PropertyListSerialization.data(
        fromPropertyList: ["a": [value]], format: format, options: 0)
      refuses(tooDeep)
    }
  }

  func testExpandedNodeAndPayloadBoundsApplyBeforeFoundation() throws {
    func array(_ count: Int, value: [UInt8]) -> Data {
      binary([
        [0xd1, 1, 2], [0x51, 0x61],
        [0xaf, 0x11] + bigEndian(UInt64(count), width: 2) + [UInt8](repeating: 3, count: count),
        value,
      ])
    }
    XCTAssertNoThrow(try NativePropertyList.decode(array(8189, value: [0x09])))
    refuses(array(8190, value: [0x09]))
    XCTAssertNoThrow(
      try NativePropertyList.decode(
        xml(
          "<dict><key>a</key><array>" + String(repeating: "<true/>", count: 8189)
            + "</array></dict>")))
    refuses(
      xml(
        "<dict><key>a</key><array>" + String(repeating: "<true/>", count: 8190) + "</array></dict>")
    )
    let text = [UInt8(0x5f), 0x11, 0x04, 0x00] + [UInt8](repeating: 0x61, count: 1024)
    XCTAssertNoThrow(try NativePropertyList.decode(array(255, value: text)))
    refuses(array(256, value: text))
    refuses(array(1024, value: text))
  }

  func testDescriptorAdmissionDoesNotWriteOrFollowPlistAlias() throws {
    let root = NSTemporaryDirectory() + "frameshift-native-plist-test." + UUID().uuidString
    XCTAssertEqual(mkdir(root, 0o700), 0)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/Info.plist"
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "org.frameshift.Frameshift"], format: .binary,
      options: 0)
    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    XCTAssertEqual(chmod(path, 0o400), 0)
    var before = stat()
    XCTAssertEqual(lstat(path, &before), 0)
    XCTAssertEqual(
      try NativePropertyList.read(path).values["CFBundleIdentifier"],
      .string("org.frameshift.Frameshift"))
    var after = stat()
    XCTAssertEqual(lstat(path, &after), 0)
    XCTAssertEqual(before.st_ino, after.st_ino)
    XCTAssertEqual(before.st_mode, after.st_mode)
    XCTAssertEqual(before.st_ctimespec.tv_nsec, after.st_ctimespec.tv_nsec)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
    let alias = root + "/alias"
    XCTAssertEqual(symlink(path, alias), 0)
    XCTAssertThrowsError(try NativePropertyList.read(alias)) {
      XCTAssertEqual($0 as? ReleaseToolError, .unsafeInput)
    }
  }

  func testPinnedSDKIdentityRequiresExactTypedFields() throws {
    let root = NSTemporaryDirectory() + "frameshift-pinned-plist-test." + UUID().uuidString
    XCTAssertEqual(mkdir(root, 0o700), 0)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/Info.plist"
    let identity: [String: Any] = [
      "CFBundleIdentifier": "org.sparkle-project.Sparkle", "CFBundleExecutable": "Sparkle",
      "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "2.10.0",
      "CFBundleVersion": "2064", "LSMinimumSystemVersion": "12.0",
      "CFBundleSupportedPlatforms": ["MacOSX"],
    ]
    for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
      for (key, value) in [
        ("", "" as Any), ("CFBundleVersion", 2064 as Any), ("LSMinimumSystemVersion", true as Any),
        ("CFBundleIdentifier", "other" as Any), ("CFBundleSupportedPlatforms", ["iPhoneOS"] as Any),
        ("CFBundleShortVersionString", "2.9.0" as Any),
      ] {
        var input = identity
        if !key.isEmpty { input[key] = value }
        let data = try PropertyListSerialization.data(
          fromPropertyList: input, format: format, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
        if key.isEmpty {
          XCTAssertNoThrow(try PinnedSparkleArchive.verifyFrameworkInfo(path))
        } else {
          XCTAssertThrowsError(try PinnedSparkleArchive.verifyFrameworkInfo(path)) {
            XCTAssertEqual($0 as? ReleaseToolError, .invalidPropertyList)
          }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
      }
    }
  }

  private func refuses(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try NativePropertyList.decode(data), file: file, line: line) {
      XCTAssertEqual($0 as? ReleaseToolError, .invalidPropertyList, file: file, line: line)
    }
  }

  private func xml(_ body: String) -> Data {
    Data("<?xml version=\"1.0\"?><plist version=\"1.0\">\(body)</plist>".utf8)
  }

  private func bigEndian(_ value: UInt64, width: Int) -> [UInt8] {
    (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  private func binary(_ objects: [[UInt8]]) -> Data {
    var data = Data("bplist00".utf8)
    var offsets: [Int] = []
    for object in objects {
      offsets.append(data.count)
      data.append(contentsOf: object)
    }
    let table = data.count
    for offset in offsets { data.append(contentsOf: bigEndian(UInt64(offset), width: 2)) }
    data.append(contentsOf: [0, 0, 0, 0, 0, 0, 2, 1])
    data.append(contentsOf: bigEndian(UInt64(objects.count), width: 8))
    data.append(contentsOf: bigEndian(0, width: 8))
    data.append(contentsOf: bigEndian(UInt64(table), width: 8))
    return data
  }
}
