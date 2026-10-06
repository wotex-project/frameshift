import Foundation

/// Static loader observations for one admitted CPU slice, preserving load-command order.
///
/// These facts do not establish import resolution, a valid signature, installed
/// execution, symbol compatibility or release authority. The closure consumer
/// joins them to the exact hashed file, parent inventory and selected CPU profile.
public struct MachOSlice: Codable, Equatable, Sendable {
  public let arch: String
  public let filetype: UInt32
  public let minimum: String
  public let dependencies: [String]
  public let rpaths: [String]
}

/// Inspects supported thin/fat native loader metadata through a scoped descriptor.
///
/// Files cap at 128 MiB; each command region caps at 1 MiB and 4096 commands.
/// Only arm64 and x86_64 executable/dylib/bundle slices are admitted. Imports
/// and run paths preserve their original order and UTF-8 bytes. Other structurally valid
/// structural commands are skipped; this is not a general Mach-O validator.
/// No input code executes and no Apple tool, cache or input file is mutated.
public enum MachOInspector {
  public static func inspect(_ path: String) throws -> [MachOSlice] {
    try inspect(path, observe: nil)
  }

  static func inspect(_ path: String, observe: ((FileReadPhase) throws -> Void)?) throws
    -> [MachOSlice]
  {
    let policy = try FileReadPolicy(maximum: 128 * 1024 * 1024)
    return try AdmittedFile.withRegions(path, policy: policy, observe: observe) { reader in
      let first = try reader.read(offset: 0, count: 8)
      let marker = try word(first, 0, bigEndian: true)
      let regions: [Region]
      if marker == 0xcafe_babe || marker == 0xcafe_babf {
        regions = try fatRegions(first, reader: reader, wide: marker == 0xcafe_babf)
      } else {
        guard marker == 0xcffa_edfe else { throw ReleaseToolError.invalidMachO }
        regions = [Region(offset: 0, size: reader.size, type: nil, subtype: nil)]
      }
      return try regions.map { try thin($0, reader: reader) }.sorted { $0.arch < $1.arch }
    }
  }

  private struct Region {
    let offset: Int64
    let size: Int64
    let type: UInt32?
    let subtype: UInt32?
  }

  private static func fatRegions(_ first: Data, reader: NativeRegionReader, wide: Bool) throws
    -> [Region]
  {
    let count = Int(try word(first, 4, bigEndian: true))
    guard (1...2).contains(count) else { throw ReleaseToolError.invalidMachO }
    let width = wide ? 32 : 20
    let table = try reader.read(offset: 8, count: count * width)
    var regions: [Region] = []
    var architectures = Set<String>()
    for index in 0..<count {
      let start = index * width
      let type = try word(table, start, bigEndian: true)
      let subtype = try word(table, start + 4, bigEndian: true)
      let arch = try architecture(type, subtype)
      let offset =
        wide ? try wideWord(table, start + 8) : UInt64(try word(table, start + 8, bigEndian: true))
      let size =
        wide
        ? try wideWord(table, start + 16) : UInt64(try word(table, start + 12, bigEndian: true))
      let alignment = try word(table, start + (wide ? 24 : 16), bigEndian: true)
      let reserved = wide ? try word(table, start + 28, bigEndian: true) : 0
      guard offset >= UInt64(8 + count * width), offset <= UInt64(reader.size), size >= 32,
        size <= UInt64(reader.size) - offset, alignment <= 30,
        offset % (UInt64(1) << alignment) == 0,
        reserved == 0,
        architectures.insert(arch).inserted
      else { throw ReleaseToolError.invalidMachO }
      regions.append(Region(offset: Int64(offset), size: Int64(size), type: type, subtype: subtype))
    }
    let ordered = regions.sorted { $0.offset < $1.offset }
    if ordered.count == 2, ordered[0].size > ordered[1].offset - ordered[0].offset {
      throw ReleaseToolError.invalidMachO
    }
    return regions
  }

  private static func thin(_ region: Region, reader: NativeRegionReader) throws -> MachOSlice {
    guard region.size >= 32 else { throw ReleaseToolError.invalidMachO }
    let header = try reader.read(offset: region.offset, count: 32)
    guard try word(header, 0, bigEndian: true) == 0xcffa_edfe else {
      throw ReleaseToolError.invalidMachO
    }
    let type = try word(header, 4)
    let subtype = try word(header, 8)
    let arch = try architecture(type, subtype)
    let filetype = try word(header, 12)
    let count = Int(try word(header, 16))
    let length = Int(try word(header, 20))
    guard [UInt32(2), 6, 8].contains(filetype), (1...4096).contains(count),
      length <= 1024 * 1024, length >= count * 8, Int64(length) <= region.size - 32,
      region.type == nil || (region.type == type && region.subtype == subtype)
    else { throw ReleaseToolError.invalidMachO }
    let commands = try reader.read(offset: region.offset + 32, count: length)
    var offset = 0
    var minimum: UInt32?
    var dependencies: [String] = []
    var rpaths: [String] = []
    for _ in 0..<count {
      try reader.checkBudget()
      let command = try word(commands, offset)
      let size = Int(try word(commands, offset + 4))
      guard size >= 8, size % 8 == 0, size <= length - offset else {
        throw ReleaseToolError.invalidMachO
      }
      let body = commands.subdata(in: offset..<(offset + size))
      switch command {
      case 0xc, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023:
        dependencies.append(try loaderString(body, base: 24))
      case 0x8000_001c: rpaths.append(try loaderString(body, base: 12))
      case 0xe:
        guard try loaderString(body, base: 12) == "/usr/lib/dyld" else {
          throw ReleaseToolError.invalidMachO
        }
      case 0x6, 0x7, 0xf, 0x25, 0x27, 0x2f, 0x30, 0x8000_0035:
        throw ReleaseToolError.invalidMachO
      case 0x24, 0x32:
        guard minimum == nil else { throw ReleaseToolError.invalidMachO }
        if command == 0x24 {
          guard size == 16 else { throw ReleaseToolError.invalidMachO }
        } else {
          guard size >= 24, try word(body, 8) == 1 else { throw ReleaseToolError.invalidMachO }
          let tools = Int(try word(body, 20))
          guard tools <= 32, size == 24 + tools * 8 else { throw ReleaseToolError.invalidMachO }
        }
        let version = try word(body, command == 0x32 ? 12 : 8)
        guard version >> 16 >= 10 else { throw ReleaseToolError.invalidMachO }
        minimum = version
      default: break
      }
      offset += size
    }
    guard offset == length, let minimum else { throw ReleaseToolError.invalidMachO }
    return MachOSlice(
      arch: arch, filetype: filetype,
      minimum: "\(minimum >> 16).\((minimum >> 8) & 255).\(minimum & 255)",
      dependencies: dependencies, rpaths: rpaths)
  }

  private static func architecture(_ type: UInt32, _ subtype: UInt32) throws -> String {
    if type == 0x0100_000c, subtype == 0 { return "arm64" }
    if type == 0x0100_0007, subtype == 3 || subtype == 0x8000_0003 { return "x86_64" }
    throw ReleaseToolError.invalidMachO
  }

  private static func loaderString(_ body: Data, base: Int) throws -> String {
    guard body.count >= base else { throw ReleaseToolError.invalidMachO }
    let start = Int(try word(body, 8))
    guard start >= base, start < body.count,
      let end = body[start...].firstIndex(of: 0), end - start <= 512, end > start,
      let value = String(data: body.subdata(in: start..<end), encoding: .utf8),
      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw ReleaseToolError.invalidMachO }
    return value
  }

  private static func word(_ bytes: Data, _ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
    guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else {
      throw ReleaseToolError.invalidMachO
    }
    let indices =
      bigEndian ? Array(offset..<(offset + 4)) : Array((offset..<(offset + 4)).reversed())
    return indices.reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }
  }

  private static func wideWord(_ bytes: Data, _ offset: Int) throws -> UInt64 {
    guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 8 else {
      throw ReleaseToolError.invalidMachO
    }
    return bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }
}
