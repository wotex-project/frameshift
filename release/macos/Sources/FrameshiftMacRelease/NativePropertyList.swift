import CoreFoundation
import Foundation

/// The bounded JSON-compatible subset used by native bundle metadata.
///
/// Booleans, signed integers and finite reals remain distinct. This value is not
/// a portable release-wire encoder. Data/date/UID/set/null and OpenStep inputs
/// are outside this profile; consumers separately validate their exact fields.
public indirect enum NativePlistValue: Equatable, Sendable {
  case string(String)
  case boolean(Bool)
  case integer(Int64)
  case real(Double)
  case array([NativePlistValue])
  case dictionary([String: NativePlistValue])
}

/// Admits immutable XML/bplist00 bundle dictionaries before typed Foundation decoding.
///
/// A 64 KiB input, depth 32, 8192 expanded nodes and 1 MiB expanded string budget
/// apply before decoding. Binary references/offsets, cycles, dictionary keys and
/// aggregate expansion are preflighted. XML parsing has external resolution
/// disabled and rejects declared entities, duplicate/ambiguous keys and invalid
/// element structure. Foundation performs the actual property-list decode; no
/// pathname is reopened and no subprocess or network operation is used.
public struct NativePropertyList: Equatable, Sendable {
  public let values: [String: NativePlistValue]

  public static func read(_ path: String, protection: FileProtection = .protected) throws -> Self {
    let bytes = try AdmittedFile.read(
      path, policy: FileReadPolicy(maximum: 64 * 1024, protection: protection, singleLink: true)
    )
    return try decode(bytes)
  }

  public static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 64 * 1024 else { throw ReleaseToolError.invalidPropertyList }
    let binary = data.starts(with: Data("bplist00".utf8))
    if binary {
      var preflight = try BinaryPlistPreflight(data)
      try preflight.check()
    } else {
      let preflight = XMLPlistPreflight()
      let parser = XMLParser(data: data)
      parser.shouldResolveExternalEntities = false
      parser.externalEntityResolvingPolicy = .never
      parser.delegate = preflight
      guard parser.parse(), !preflight.refused, preflight.complete, preflight.stack.isEmpty
      else { throw ReleaseToolError.invalidPropertyList }
    }
    do {
      var format = PropertyListSerialization.PropertyListFormat.xml
      let object = try PropertyListSerialization.propertyList(
        from: data, options: [], format: &format)
      guard format == (binary ? .binary : .xml) else { throw ReleaseToolError.invalidPropertyList }
      var budget = PlistBudget()
      guard case .dictionary(let values) = try convert(object, depth: 1, budget: &budget)
      else { throw ReleaseToolError.invalidPropertyList }
      // Retain the old converter's bounded JSON-compatible metadata admission.
      // These bytes are a size check only, never a release-wire record.
      guard try JSONSerialization.data(withJSONObject: object).count <= 256 * 1024
      else { throw ReleaseToolError.invalidPropertyList }
      return Self(values: values)
    } catch { throw ReleaseToolError.invalidPropertyList }
  }

  private static func convert(_ value: Any, depth: Int, budget: inout PlistBudget) throws
    -> NativePlistValue
  {
    try budget.node(depth)
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
      let type = String(cString: number.objCType)
      if type == "f" || type == "d" {
        guard number.doubleValue.isFinite else { throw ReleaseToolError.invalidPropertyList }
        return .real(number.doubleValue)
      }
      guard let integer = Int64(number.stringValue) else {
        throw ReleaseToolError.invalidPropertyList
      }
      return .integer(integer)
    }
    if let text = value as? String {
      try budget.string(text)
      return .string(text)
    }
    if let list = value as? NSArray {
      guard list.count <= 8192 else { throw ReleaseToolError.invalidPropertyList }
      return .array(try list.map { try convert($0, depth: depth + 1, budget: &budget) })
    }
    if let dictionary = value as? NSDictionary {
      guard dictionary.count <= 4096 else { throw ReleaseToolError.invalidPropertyList }
      var entries: [String: NativePlistValue] = [:]
      for (key, value) in dictionary {
        guard let key = key as? String, entries[key] == nil else {
          throw ReleaseToolError.invalidPropertyList
        }
        try budget.node(depth + 1)
        try budget.string(key)
        entries[key] = try convert(value, depth: depth + 1, budget: &budget)
      }
      return .dictionary(entries)
    }
    throw ReleaseToolError.invalidPropertyList
  }
}

private struct PlistBudget {
  private var nodes = 0
  private var strings = 0

  mutating func node(_ depth: Int) throws {
    nodes += 1
    guard depth <= 32, nodes <= 8192 else { throw ReleaseToolError.invalidPropertyList }
  }

  mutating func string(_ value: String) throws {
    strings += value.utf8.count
    guard strings <= 1024 * 1024 else { throw ReleaseToolError.invalidPropertyList }
  }
}

private struct BinaryPlistPreflight {
  let bytes: [UInt8]
  let offsets: [Int]
  let ends: [Int]
  let referenceWidth: Int
  let root: Int
  var budget = PlistBudget()
  var ancestors = Set<Int>()

  init(_ data: Data) throws {
    bytes = Array(data)
    guard bytes.count >= 42 else { throw ReleaseToolError.invalidPropertyList }
    let trailer = bytes.count - 32
    let offsetWidth = Int(bytes[trailer + 6])
    referenceWidth = Int(bytes[trailer + 7])
    guard [1, 2, 4, 8].contains(offsetWidth), [1, 2, 4, 8].contains(referenceWidth)
    else { throw ReleaseToolError.invalidPropertyList }
    let count = try Self.integer(bytes, at: trailer + 8, width: 8, end: bytes.count)
    let top = try Self.integer(bytes, at: trailer + 16, width: 8, end: bytes.count)
    let table = try Self.integer(bytes, at: trailer + 24, width: 8, end: bytes.count)
    guard count > 0, count <= 8192, top < count, table >= 8, table < UInt64(trailer),
      count * UInt64(offsetWidth) == UInt64(trailer) - table
    else { throw ReleaseToolError.invalidPropertyList }
    root = Int(top)
    var found: [Int] = []
    for index in 0..<Int(count) {
      let offset = try Self.integer(
        bytes, at: Int(table) + index * offsetWidth, width: offsetWidth, end: trailer)
      guard offset >= 8, offset < table else { throw ReleaseToolError.invalidPropertyList }
      found.append(Int(offset))
    }
    guard Set(found).count == found.count else { throw ReleaseToolError.invalidPropertyList }
    offsets = found
    let ordered = found.sorted() + [Int(table)]
    let extent = Dictionary(uniqueKeysWithValues: zip(ordered.dropLast(), ordered.dropFirst()))
    ends = found.map { extent[$0]! }
  }

  mutating func check() throws {
    guard bytes[offsets[root]] & 0xf0 == 0xd0 else { throw ReleaseToolError.invalidPropertyList }
    _ = try visit(root, depth: 1)
  }

  private mutating func visit(_ object: Int, depth: Int) throws -> String? {
    try budget.node(depth)
    guard object >= 0, object < offsets.count, ancestors.insert(object).inserted
    else { throw ReleaseToolError.invalidPropertyList }
    defer { ancestors.remove(object) }
    let start = offsets[object]
    let end = ends[object]
    let marker = bytes[start]
    var position = start + 1
    let type = marker & 0xf0
    if marker == 0x08 || marker == 0x09 { return nil }
    if type == 0x10 || type == 0x20 {
      let power = Int(marker & 0x0f)
      guard power <= 3, type != 0x20 || power == 2 || power == 3 else {
        throw ReleaseToolError.invalidPropertyList
      }
      try range(position, count: 1 << power, end: end)
      return nil
    }
    guard [UInt8(0x50), 0x60, 0xa0, 0xd0].contains(type) else {
      throw ReleaseToolError.invalidPropertyList
    }
    var count = Int(marker & 0x0f)
    if count == 15 {
      try range(position, count: 1, end: end)
      let size = bytes[position]
      guard size & 0xf0 == 0x10, size & 0x0f <= 3 else {
        throw ReleaseToolError.invalidPropertyList
      }
      let width = 1 << Int(size & 0x0f)
      let length = try Self.integer(bytes, at: position + 1, width: width, end: end)
      guard length <= UInt64(bytes.count) else { throw ReleaseToolError.invalidPropertyList }
      count = Int(length)
      position += width + 1
    }
    if type == 0x50 || type == 0x60 {
      let width = type == 0x60 ? 2 : 1
      try range(position, count: count * width, end: end)
      let content = Data(bytes[position..<(position + count * width)])
      guard let text = String(data: content, encoding: type == 0x60 ? .utf16BigEndian : .ascii)
      else { throw ReleaseToolError.invalidPropertyList }
      try budget.string(text)
      return text
    }
    guard count <= 8192 else { throw ReleaseToolError.invalidPropertyList }
    try range(position, count: count * referenceWidth * (type == 0xd0 ? 2 : 1), end: end)
    func reference(_ index: Int) throws -> Int {
      let value = try Self.integer(
        bytes, at: position + index * referenceWidth, width: referenceWidth, end: end)
      guard value < UInt64(offsets.count) else { throw ReleaseToolError.invalidPropertyList }
      return Int(value)
    }
    if type == 0xd0 {
      var keys = Set<String>()
      for index in 0..<count {
        guard let key = try visit(reference(index), depth: depth + 1), keys.insert(key).inserted
        else { throw ReleaseToolError.invalidPropertyList }
      }
      for index in count..<(count * 2) { _ = try visit(reference(index), depth: depth + 1) }
    } else {
      for index in 0..<count { _ = try visit(reference(index), depth: depth + 1) }
    }
    return nil
  }

  private func range(_ position: Int, count: Int, end: Int) throws {
    guard position >= 8, position <= end, count >= 0, count <= end - position
    else { throw ReleaseToolError.invalidPropertyList }
  }

  private static func integer(_ bytes: [UInt8], at position: Int, width: Int, end: Int) throws
    -> UInt64
  {
    guard width > 0, width <= 8, position >= 0, position <= end, width <= end - position
    else { throw ReleaseToolError.invalidPropertyList }
    return bytes[position..<(position + width)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }
}

private final class XMLPlistPreflight: NSObject, XMLParserDelegate {
  struct Element {
    let name: String
    var text = ""
    var children = 0
    var keys = Set<String>()
    var expectsKey = true
  }

  var stack: [Element] = []
  var refused = false
  var complete = false
  private var budget = PlistBudget()

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    guard !complete else {
      reject(parser)
      return
    }
    do { if !stack.isEmpty { try budget.node(stack.count) } } catch {
      reject(parser)
      return
    }
    if stack.isEmpty {
      guard name == "plist", attributes == ["version": "1.0"] else {
        reject(parser)
        return
      }
    } else {
      guard attributes.isEmpty, let parent = stack.last else {
        reject(parser)
        return
      }
      if parent.name == "plist" {
        guard name == "dict", parent.children == 0 else {
          reject(parser)
          return
        }
      } else if parent.name == "dict" {
        guard (name == "key") == parent.expectsKey else {
          reject(parser)
          return
        }
      } else if parent.name != "array" {
        reject(parser)
        return
      }
      guard ["dict", "array", "key", "string", "integer", "real", "true", "false"].contains(name),
        name != "key" || parent.name == "dict"
      else {
        reject(parser)
        return
      }
      stack[stack.count - 1].children += 1
    }
    stack.append(Element(name: name))
  }

  func parser(_ parser: XMLParser, foundCharacters text: String) {
    guard let element = stack.last else {
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
      return
    }
    do { try budget.string(text) } catch {
      reject(parser)
      return
    }
    if ["plist", "dict", "array", "true", "false"].contains(element.name) {
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
    } else {
      stack[stack.count - 1].text += text
    }
  }

  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    guard let text = String(data: block, encoding: .utf8) else {
      reject(parser)
      return
    }
    self.parser(parser, foundCharacters: text)
  }

  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard let element = stack.popLast(), element.name == name,
      name != "dict" || element.expectsKey, name != "plist" || element.children == 1
    else {
      reject(parser)
      return
    }
    if name == "integer", Int64(element.text.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
    {
      reject(parser)
      return
    }
    if !stack.isEmpty, stack[stack.count - 1].name == "dict" {
      let index = stack.count - 1
      if name == "key" {
        guard stack[index].keys.insert(element.text).inserted else {
          reject(parser)
          return
        }
        stack[index].expectsKey = false
      } else {
        stack[index].expectsKey = true
      }
    }
    if name == "plist" { complete = true }
  }

  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) { reject(parser) }
  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) { reject(parser) }
  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
    -> Data?
  {
    reject(parser)
    return nil
  }

  private func reject(_ parser: XMLParser) {
    refused = true
    parser.abortParsing()
  }
}
