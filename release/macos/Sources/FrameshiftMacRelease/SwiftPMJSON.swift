import Foundation

/// Bounded typed JSON for SwiftPM observations only; no portable receipt encoding.
indirect enum SwiftPMJSON: Equatable, Sendable {
  case object([String: SwiftPMJSON])
  case array([SwiftPMJSON])
  case string(String)
  case number(String)
  case boolean(Bool)
  case null

  static func read(_ data: Data, maximum: Int, check: @escaping () throws -> Void) throws -> Self {
    guard !data.isEmpty, data.count <= maximum, maximum <= 512 * 1024,
      String(data: data, encoding: .utf8) != nil
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    var parser = SwiftPMJSONParser(bytes: Array(data), check: check)
    let value = try parser.value(depth: 0)
    parser.space()
    guard parser.offset == data.count else { throw ReleaseToolError.invalidSwiftPMInputs }
    try check()
    return value
  }

  func object(keys: Set<String>? = nil) throws -> [String: Self] {
    guard case .object(let value) = self, keys.map({ Set(value.keys) == $0 }) ?? true else {
      throw ReleaseToolError.invalidSwiftPMInputs
    }
    return value
  }

  func array() throws -> [Self] {
    guard case .array(let value) = self else { throw ReleaseToolError.invalidSwiftPMInputs }
    return value
  }
}

private struct SwiftPMJSONParser {
  let bytes: [UInt8]
  let check: () throws -> Void
  var offset = 0
  var nodes = 0
  var stringBytes = 0

  mutating func space() {
    while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
  }

  mutating func take(_ byte: UInt8) -> Bool {
    space()
    guard offset < bytes.count, bytes[offset] == byte else { return false }
    offset += 1
    return true
  }

  mutating func value(depth: Int) throws -> SwiftPMJSON {
    try check()
    nodes += 1
    guard nodes <= 8192 else { throw ReleaseToolError.inputLimit }
    space()
    guard offset < bytes.count else { throw ReleaseToolError.invalidSwiftPMInputs }
    switch bytes[offset] {
    case 123:
      guard depth < 32 else { throw ReleaseToolError.inputLimit }
      offset += 1
      var members: [String: SwiftPMJSON] = [:]
      if take(125) { return .object(members) }
      repeat {
        let key = try string()
        guard members[key] == nil, take(58) else { throw ReleaseToolError.invalidSwiftPMInputs }
        members[key] = try value(depth: depth + 1)
        if take(125) { return .object(members) }
      } while take(44)
      throw ReleaseToolError.invalidSwiftPMInputs
    case 91:
      guard depth < 32 else { throw ReleaseToolError.inputLimit }
      offset += 1
      var members: [SwiftPMJSON] = []
      if take(93) { return .array(members) }
      repeat {
        members.append(try value(depth: depth + 1))
        if take(93) { return .array(members) }
      } while take(44)
      throw ReleaseToolError.invalidSwiftPMInputs
    case 34: return .string(try string())
    case 116:
      try literal("true")
      return .boolean(true)
    case 102:
      try literal("false")
      return .boolean(false)
    case 110:
      try literal("null")
      return .null
    case 45, 48...57: return .number(try number())
    default: throw ReleaseToolError.invalidSwiftPMInputs
    }
  }

  mutating func literal(_ text: String) throws {
    let token = Array(text.utf8)
    guard token.count <= bytes.count - offset,
      bytes[offset..<offset + token.count].elementsEqual(token)
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    offset += token.count
  }

  mutating func string() throws -> String {
    space()
    let start = offset
    guard take(34) else { throw ReleaseToolError.invalidSwiftPMInputs }
    while offset < bytes.count {
      guard offset - start <= 384 * 1024 + 1 else { throw ReleaseToolError.inputLimit }
      let byte = bytes[offset]
      offset += 1
      if byte == 34 {
        let value: String
        do {
          value = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
        } catch { throw ReleaseToolError.invalidSwiftPMInputs }
        stringBytes += value.utf8.count
        guard value.utf8.count <= 64 * 1024, stringBytes <= 512 * 1024 else {
          throw ReleaseToolError.inputLimit
        }
        try check()
        return value
      }
      guard byte >= 32 else { throw ReleaseToolError.invalidSwiftPMInputs }
      if byte == 92 {
        guard offset < bytes.count else { throw ReleaseToolError.invalidSwiftPMInputs }
        let escape = bytes[offset]
        offset += 1
        if escape == 117 {
          guard bytes.count - offset >= 4,
            bytes[offset..<offset + 4].allSatisfy({
              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
          else { throw ReleaseToolError.invalidSwiftPMInputs }
          offset += 4
        } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) {
          throw ReleaseToolError.invalidSwiftPMInputs
        }
      }
    }
    throw ReleaseToolError.invalidSwiftPMInputs
  }

  mutating func number() throws -> String {
    let start = offset
    if bytes[offset] == 45 { offset += 1 }
    guard offset < bytes.count else { throw ReleaseToolError.invalidSwiftPMInputs }
    if bytes[offset] == 48 {
      offset += 1
    } else {
      guard (49...57).contains(bytes[offset]) else { throw ReleaseToolError.invalidSwiftPMInputs }
      digits()
    }
    if offset < bytes.count, bytes[offset] == 46 {
      offset += 1
      try requiredDigits()
    }
    if offset < bytes.count, [69, 101].contains(bytes[offset]) {
      offset += 1
      if offset < bytes.count, [43, 45].contains(bytes[offset]) { offset += 1 }
      try requiredDigits()
    }
    return String(decoding: bytes[start..<offset], as: UTF8.self)
  }

  mutating func requiredDigits() throws {
    guard offset < bytes.count, (48...57).contains(bytes[offset]) else {
      throw ReleaseToolError.invalidSwiftPMInputs
    }
    digits()
  }

  mutating func digits() {
    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
  }
}
