import Darwin
import Foundation

/// CPU membership required of every native member; extra supported slices remain observable.
public enum NativeBundleArchitecture: String, Sendable {
  case arm64
  case intel = "x86_64"
  case universal

  fileprivate var required: [String] { self == .universal ? ["arm64", "x86_64"] : [rawValue] }
}

/// Bounded static bundle observation, with publication authority fixed to none.
///
/// The fixed observation bytes preserve the existing schema-two field and array
/// order. This report does not prove seals, notarization, runtime loading or
/// installed compatibility. Consumers must join their separate source/signature
/// and platform evidence before admitting a release candidate.
public struct NativeBundleObservation: Sendable {
  public struct Directory: Equatable, Sendable {
    public let path: String
    public let mode: UInt16
  }
  public struct File: Equatable, Sendable {
    public let path: String
    public let mode: UInt16
    public let bytes: Int64
    public let sha256: String
  }
  public struct Link: Equatable, Sendable {
    public let path: String
    public let target: String
  }
  public struct Native: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let mode: UInt16
    public let slices: [MachOSlice]
  }
  public let architecture: NativeBundleArchitecture
  public let declaredMinimum: String
  public let nativeMinimum: String
  public let directories: [Directory]
  public let files: [File]
  public let links: [Link]?
  public let natives: [Native]

  /// Existing ordered native observation JSON, without LF, bounded to 16 MiB.
  public func observationBytes() throws -> Data {
    var output = NativeObservationWriter()
    try output.raw("{\"schemaVersion\":2,\"publicationAuthority\":\"none\",\"architecture\":")
    try output.string(architecture.rawValue)
    try output.raw(",\"declaredMinimum\":")
    try output.string(declaredMinimum)
    try output.raw(",\"nativeMinimum\":")
    try output.string(nativeMinimum)
    try output.raw(",\"directories\":[")
    for (index, item) in directories.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw("{\"path\":")
      try output.string(item.path)
      try output.raw(",\"mode\":\(item.mode)}")
    }
    try output.raw("]")
    if let links {
      try output.raw(",\"links\":[")
      for (index, item) in links.enumerated() {
        if index > 0 { try output.raw(",") }
        try output.raw("{\"path\":")
        try output.string(item.path)
        try output.raw(",\"target\":")
        try output.string(item.target)
        try output.raw("}")
      }
      try output.raw("]")
    }
    try output.raw(",\"files\":[")
    for (index, item) in files.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw("{\"path\":")
      try output.string(item.path)
      try output.raw(",\"mode\":\(item.mode),\"bytes\":\(item.bytes),\"sha256\":")
      try output.string(item.sha256)
      try output.raw("}")
    }
    try output.raw("],\"natives\":[")
    for (index, item) in natives.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw("{\"path\":")
      try output.string(item.path)
      try output.raw(",\"sha256\":")
      try output.string(item.sha256)
      try output.raw(",\"mode\":\(item.mode),\"slices\":[")
      for (sliceIndex, slice) in item.slices.enumerated() {
        if sliceIndex > 0 { try output.raw(",") }
        try output.raw("{\"arch\":")
        try output.string(slice.arch)
        try output.raw(",\"filetype\":\(slice.filetype),\"minimum\":")
        try output.string(slice.minimum)
        try output.raw(",\"dependencies\":")
        try output.strings(slice.dependencies)
        try output.raw(",\"rpaths\":")
        try output.strings(slice.rpaths)
        try output.raw("}")
      }
      try output.raw("]}")
    }
    try output.raw("]}")
    return output.bytes
  }
}

/// Checks the bounded native closure of one Mac bundle without executing its code.
///
/// Every file is hashed, every recognized Mach-O is inspected, required roles
/// and CPU membership are checked, and explicit imports resolve against the
/// admitted inventory. A second complete inventory must match bytes and native
/// filesystem custody. Directory enumeration streams through a no-follow open
/// descriptor. Budgets are software checks and cannot preempt blocked syscalls.
/// Sparkle uses only its exact pinned aliases and one explicit shell run path;
/// signatures, SDK/archive equality and installed execution remain separate.
public enum NativeBundleInspector {
  public static func inspect(_ input: String, architecture: NativeBundleArchitecture) throws
    -> NativeBundleObservation
  {
    try inspect(input, architecture: architecture, observe: nil)
  }

  static func inspect(
    _ input: String, architecture: NativeBundleArchitecture,
    observe: ((BundleInspectionPhase) throws -> Void)?
  ) throws -> NativeBundleObservation {
    try inspectWithCustody(input, architecture: architecture, observe: observe).observation
  }

  static func inspectWithCustody(
    _ input: String, architecture: NativeBundleArchitecture,
    observe: ((BundleInspectionPhase) throws -> Void)? = nil
  ) throws -> (observation: NativeBundleObservation, custody: BundleSnapshot) {
    guard !input.isEmpty, !input.utf8.contains(0) else { throw ReleaseToolError.unsafeInput }
    let root = URL(fileURLWithPath: input).standardizedFileURL.path
    let budget = BundleBudget()
    let before = try BundleInventory(root: root, budget: budget).scan()
    try observe?(.inventoried)
    var natives: [NativeBundleObservation.Native] = []
    for file in before.files where file.native {
      try budget.check()
      guard natives.count < 128 else { throw ReleaseToolError.inputLimit }
      let slices = try MachOInspector.inspect(
        root + "/" + file.value.path, seconds: budget.fileSeconds(), observe: nil)
      guard architecture.required.allSatisfy({ arch in slices.contains { $0.arch == arch } }),
        !slices.contains(where: { $0.filetype == 2 }) || file.value.mode & 0o111 != 0
      else { throw ReleaseToolError.invalidBundle }
      natives.append(
        .init(
          path: file.value.path, sha256: file.value.sha256, mode: file.value.mode, slices: slices))
    }
    let roles: [(String, UInt32)] = [
      (#"^Contents/MacOS/Frameshift$"#, 2), (#"^Contents/MacOS/frameshiftctl$"#, 2),
      (#"^Contents/Resources/bin/frameshift-raster$"#, 2),
      (#"^Contents/Resources/core/erts-[^/]+/bin/beam\.smp$"#, 2),
      (#"^Contents/Resources/core/lib/exqlite-[^/]+/priv/sqlite3_nif\.so$"#, 6),
      (#"^Contents/Resources/core/lib/exile-[^/]+/priv/exile\.so$"#, 6),
      (#"^Contents/Resources/core/lib/exile-[^/]+/priv/spawner$"#, 2),
    ]
    for (pattern, type) in roles {
      let found = natives.filter { $0.path.range(of: pattern, options: .regularExpression) != nil }
      guard found.count == 1, found[0].slices.allSatisfy({ $0.filetype == type }) else {
        throw ReleaseToolError.invalidBundle
      }
    }
    let framework = before.directories.contains { $0.value.path == BundleSparkle.root }
    let aliases = Dictionary(
      uniqueKeysWithValues: before.links.map { ($0.value.path, $0.value.target) })
    if framework {
      guard aliases.count == BundleSparkle.links.count else { throw ReleaseToolError.invalidBundle }
      let members = Set(before.files.map(\.value.path) + before.directories.map(\.value.path))
      for path in aliases.keys {
        guard members.contains(try frameworkPath(path, aliases: aliases)) else {
          throw ReleaseToolError.invalidBundle
        }
      }
      let frameworkNatives = natives.filter { $0.path.hasPrefix(BundleSparkle.root + "/") }
      guard frameworkNatives.count == BundleSparkle.roles.count,
        frameworkNatives.allSatisfy({ file in
          file.slices.allSatisfy { $0.filetype == BundleSparkle.roles[file.path] }
        })
      else { throw ReleaseToolError.invalidBundle }
      let info = try NativePropertyList.read(
        root + "/" + BundleSparkle.root + "/Versions/B/Resources/Info.plist", protection: .regular)
      guard info.values["CFBundleIdentifier"] == .string("org.sparkle-project.Sparkle"),
        info.values["CFBundleExecutable"] == .string("Sparkle"),
        info.values["CFBundleShortVersionString"] == .string(PinnedSparkleArchive.version),
        let shell = natives.first(where: { $0.path == "Contents/MacOS/Frameshift" }),
        shell.slices.allSatisfy({ $0.dependencies.contains(BundleSparkle.importPath) })
      else { throw ReleaseToolError.invalidBundle }
    } else if !aliases.isEmpty {
      throw ReleaseToolError.invalidBundle
    }
    let byPath = Dictionary(uniqueKeysWithValues: natives.map { ($0.path, $0) })
    let directories = Set(before.directories.map(\.value.path))
    for file in natives {
      for slice in file.slices {
        try budget.check()
        for path in slice.rpaths where !applePath(path) {
          guard directories.contains(try localPath(file.path, slice: slice, value: path)) else {
            throw ReleaseToolError.invalidBundle
          }
        }
        for path in slice.dependencies where !applePath(path) {
          let resolved: String
          if path.hasPrefix("@rpath/") {
            guard framework, file.path == "Contents/MacOS/Frameshift", slice.filetype == 2,
              path == BundleSparkle.importPath, slice.rpaths.count == 1,
              ["@loader_path/../Frameworks", "@executable_path/../Frameworks"].contains(
                slice.rpaths[0])
            else { throw ReleaseToolError.invalidBundle }
            resolved = BundleSparkle.root + "/Versions/B/Sparkle"
          } else {
            resolved = try frameworkPath(
              localPath(file.path, slice: slice, value: path), aliases: aliases)
          }
          guard
            byPath[resolved]?.slices.contains(where: { $0.arch == slice.arch && $0.filetype == 6 })
              == true
          else {
            throw ReleaseToolError.invalidBundle
          }
        }
      }
    }
    let info = try NativePropertyList.read(root + "/Contents/Info.plist", protection: .regular)
    guard info.values["CFBundleExecutable"] == .string("Frameshift"),
      case .string(let declared) = info.values["LSMinimumSystemVersion"]
    else { throw ReleaseToolError.invalidBundle }
    let minimum = try natives.flatMap(\.slices).map { try versionNumber($0.minimum) }.max()!
    guard try versionNumber(declared) >= minimum else { throw ReleaseToolError.invalidBundle }
    try observe?(.checked)
    try budget.check()
    let after = try BundleInventory(root: root, budget: budget).scan()
    guard before == after else { throw ReleaseToolError.inputChanged }
    try budget.check()
    let observation = NativeBundleObservation(
      architecture: architecture, declaredMinimum: declared,
      nativeMinimum: "\(minimum >> 16).\((minimum >> 8) & 255).\(minimum & 255)",
      directories: before.directories.map(\.value), files: before.files.map(\.value),
      links: framework ? before.links.map(\.value) : nil, natives: natives)
    return (observation, before)
  }

  private static func versionNumber(_ value: String) throws -> UInt32 {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count) else { throw ReleaseToolError.invalidBundle }
    var numbers: [UInt32] = []
    for (index, part) in parts.enumerated() {
      guard !part.isEmpty, part.utf8.count <= (index == 0 ? 5 : 3),
        part == "0" || part.first != "0", part.utf8.allSatisfy({ (48...57).contains($0) }),
        let number = UInt32(part), number <= (index == 0 ? 65535 : 255)
      else { throw ReleaseToolError.invalidBundle }
      numbers.append(number)
    }
    guard numbers[0] >= 10 else { throw ReleaseToolError.invalidBundle }
    return (numbers[0] << 16) | (numbers[1] << 8) | (numbers.count == 3 ? numbers[2] : 0)
  }

  private static func applePath(_ value: String) -> Bool {
    (value.hasPrefix("/usr/lib/") || value.hasPrefix("/System/Library/"))
      && normalized(value) == value
  }

  private static func localPath(_ source: String, slice: MachOSlice, value: String) throws -> String
  {
    let suffix: String
    if value == "@loader_path" {
      suffix = ""
    } else if value.hasPrefix("@loader_path/") {
      suffix = String(value.dropFirst(13))
    } else if value == "@executable_path", slice.filetype == 2 {
      suffix = ""
    } else if value.hasPrefix("@executable_path/"), slice.filetype == 2 {
      suffix = String(value.dropFirst(17))
    } else {
      throw ReleaseToolError.invalidBundle
    }
    let parent = source.split(separator: "/").dropLast().joined(separator: "/")
    let result = normalized(parent + (suffix.isEmpty ? "" : "/" + suffix))
    guard result != "..", !result.hasPrefix("../"), !result.hasPrefix("/") else {
      throw ReleaseToolError.invalidBundle
    }
    return result
  }

  private static func frameworkPath(_ input: String, aliases: [String: String]) throws -> String {
    var path = input
    for _ in 0...BundleSparkle.links.count {
      let parts = path.split(separator: "/").map(String.init)
      var changed = false
      for index in 1...parts.count {
        let prefix = parts.prefix(index).joined(separator: "/")
        guard let target = aliases[prefix] else { continue }
        let parent = parts.prefix(index - 1).joined(separator: "/")
        path = normalized(
          ([parent, target] + parts.dropFirst(index)).filter { !$0.isEmpty }.joined(separator: "/"))
        guard path.hasPrefix(BundleSparkle.root + "/") else { throw ReleaseToolError.invalidBundle }
        changed = true
        break
      }
      if !changed { return path }
    }
    throw ReleaseToolError.invalidBundle
  }

  private static func normalized(_ path: String) -> String {
    var parts: [String] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." {
        if let last = parts.last, last != ".." {
          parts.removeLast()
        } else if !path.hasPrefix("/") {
          parts.append("..")
        }
      } else {
        parts.append(String(part))
      }
    }
    var result = (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    if result.isEmpty { result = "." }
    if path.hasSuffix("/"), !result.hasSuffix("/") { result += "/" }
    return result
  }
}

enum BundleInspectionPhase { case inventoried, checked }

enum BundleSparkle {
  static let root = "Contents/Frameworks/Sparkle.framework"
  static let containers = [
    root + "/Versions/B/XPCServices/Downloader.xpc",
    root + "/Versions/B/XPCServices/Installer.xpc",
    root + "/Versions/B/Updater.app", root,
  ]
  static let importPath = "@rpath/Sparkle.framework/Versions/B/Sparkle"
  static let links = Dictionary(
    uniqueKeysWithValues: [("Versions/Current", "B")]
      + [
        "Autoupdate", "Headers", "Modules", "PrivateHeaders", "Resources", "Sparkle", "Updater.app",
        "XPCServices",
      ].map { ($0, "Versions/Current/" + $0) }
  ).reduce(into: [String: String]()) { $0[root + "/" + $1.key] = $1.value }
  static let roles = Dictionary(
    uniqueKeysWithValues: [
      ("Sparkle", UInt32(6)), ("Autoupdate", 2), ("Updater.app/Contents/MacOS/Updater", 2),
      ("XPCServices/Downloader.xpc/Contents/MacOS/Downloader", 2),
      ("XPCServices/Installer.xpc/Contents/MacOS/Installer", 2),
    ].map { (root + "/Versions/B/" + $0.0, $0.1) })
}

private struct BundleBudget {
  let deadline = ContinuousClock.now.advanced(by: .seconds(120))
  func check() throws {
    guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
  }
  func fileSeconds() throws -> Double {
    try check()
    let remaining = ContinuousClock.now.duration(to: deadline).components
    return min(60, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
  }
}

struct BundleSnapshot: Equatable {
  struct Member<Value: Equatable>: Equatable {
    let value: Value
    let identity: FileIdentity
  }
  struct File: Equatable {
    let value: NativeBundleObservation.File
    let native: Bool
    let identity: FileIdentity
  }
  var directories: [Member<NativeBundleObservation.Directory>] = []
  var links: [Member<NativeBundleObservation.Link>] = []
  var files: [File] = []
}

private final class BundleInventory {
  let root: String
  let budget: BundleBudget
  var entries = 1
  var total: Int64 = 0
  var result = BundleSnapshot()
  init(root: String, budget: BundleBudget) {
    self.root = root
    self.budget = budget
  }
  func scan() throws -> BundleSnapshot {
    try visit("", depth: 0)
    return result
  }

  private func named(_ path: String) throws -> FileIdentity {
    var state = stat()
    guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(state)
  }
  private func visit(_ relative: String, depth: Int) throws {
    try budget.check()
    guard entries <= 8192, depth <= 32, relative.utf8.count <= 512,
      !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw ReleaseToolError.inputLimit }
    let path = root + (relative.isEmpty ? "" : "/" + relative)
    let before = try named(path)
    let kind = before.mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFLNK) {
      guard let expected = BundleSparkle.links[relative], before.links == 1,
        before.user == 0 || before.user == getuid()
      else { throw ReleaseToolError.unsafeInput }
      func target() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = readlink(path, &bytes, bytes.count)
        guard count >= 0, count < bytes.count,
          let value = String(bytes: bytes.prefix(count), encoding: .utf8)
        else { throw ReleaseToolError.readFailed }
        return value
      }
      let first = try target()
      let after = try named(path)
      let last = try target()
      guard first == expected, after == before, last == expected else {
        throw ReleaseToolError.inputChanged
      }
      result.links.append(.init(value: .init(path: relative, target: expected), identity: before))
      return
    }
    guard before.mode & 0o7022 == 0 else { throw ReleaseToolError.unsafeInput }
    if kind == mode_t(S_IFDIR) {
      let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY)
      guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
      var owned = true
      defer { if owned { Darwin.close(descriptor) } }
      var state = stat()
      guard fstat(descriptor, &state) == 0, FileIdentity(state) == before else {
        throw ReleaseToolError.inputChanged
      }
      guard let directory = fdopendir(descriptor) else { throw ReleaseToolError.readFailed }
      owned = false
      defer { closedir(directory) }
      var names: [String] = []
      while true {
        try budget.check()
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw ReleaseToolError.readFailed }
          break
        }
        let length = Int(entry.pointee.d_namlen)
        guard length > 0, length < 1024 else { throw ReleaseToolError.unsafeInput }
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
          String(bytes: $0.prefix(length), encoding: .utf8)
        }
        guard let name, !name.contains("/"), !name.utf8.contains(0) else {
          throw ReleaseToolError.unsafeInput
        }
        if name == "." || name == ".." { continue }
        guard entries < 8192 else { throw ReleaseToolError.inputLimit }
        entries += 1
        names.append(name)
      }
      guard Set(names).count == names.count else { throw ReleaseToolError.unsafeInput }
      for name in names.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
        try visit(relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
      }
      guard fstat(descriptor, &state) == 0, FileIdentity(state) == before, try named(path) == before
      else { throw ReleaseToolError.inputChanged }
      result.directories.append(
        .init(value: .init(path: relative, mode: before.mode & 0o7777), identity: before))
    } else if before.isRegular {
      guard before.links == 1, before.size >= 0, before.size <= 128 * 1024 * 1024 else {
        throw ReleaseToolError.unsafeInput
      }
      total += before.size
      guard total <= 512 * 1024 * 1024 else { throw ReleaseToolError.inputLimit }
      let policy = try FileReadPolicy(
        minimum: 0, maximum: 128 * 1024 * 1024, singleLink: true, seconds: budget.fileSeconds())
      let prefix = try AdmittedFile.withRegions(path, policy: policy) {
        try $0.read(offset: 0, count: Int(min(8, $0.size)))
      }
      let digest = try AdmittedFile.sha256(path, policy: policy)
      guard try named(path) == before else { throw ReleaseToolError.inputChanged }
      let marker = prefix.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      let native =
        prefix.count >= 4
        && [
          UInt32(0xcffa_edfe), 0xfeed_facf, 0xcefa_edfe, 0xfeed_face, 0xcafe_babe, 0xcafe_babf,
          0xbeba_feca, 0xbfba_feca,
        ].contains(marker)
      result.files.append(
        .init(
          value: .init(
            path: relative, mode: before.mode & 0o7777, bytes: digest.bytes, sha256: digest.sha256),
          native: native, identity: before))
    } else {
      throw ReleaseToolError.unsafeInput
    }
  }
}

private struct NativeObservationWriter {
  var bytes = Data()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()
  mutating func raw(_ text: String) throws { try append(Data(text.utf8)) }
  mutating func string(_ text: String) throws { try append(encoder.encode(text)) }
  mutating func strings(_ values: [String]) throws {
    try raw("[")
    for (index, value) in values.enumerated() {
      if index > 0 { try raw(",") }
      try string(value)
    }
    try raw("]")
  }
  private mutating func append(_ block: Data) throws {
    guard block.count <= 16 * 1024 * 1024 - bytes.count else { throw ReleaseToolError.inputLimit }
    bytes.append(block)
  }
}
