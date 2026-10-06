import Darwin
import Foundation

/// Exact original updater archive/cache facts, distinct from derived CPU code and seals.
public struct PinnedSparkleFrameworkObservation: Sendable {
  public struct Native: Sendable {
    public let path: String
    public let slices: [MachOSlice]
  }
  public let files: [NativeBundleObservation.File]
  public let directories: [NativeBundleObservation.Directory]
  public let links: [NativeBundleObservation.Link]
  public let native: [Native]

  /// Existing schema-one ordered native observation JSON, without LF, below 64 KiB.
  public func observationBytes() throws -> Data {
    var output = NativeObservationWriter()
    try output.raw(#"{"schemaVersion":1,"publicationAuthority":"none","archive":{"version":"#)
    try output.string(PinnedSparkleArchive.version)
    try output.raw(#","commit":"#)
    try output.string(PinnedSparkleArchive.commit)
    try output.raw(",\"bytes\":\(PinnedSparkleArchive.bytes),\"sha256\":")
    try output.string(PinnedSparkleArchive.sha256)
    try output.raw(#","url":"#)
    try output.string(PinnedSparkleArchive.url)
    try output.raw(#"},"framework":{"files":["#)
    for (index, file) in files.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw(#"{"path":"#)
      try output.string(file.path)
      try output.raw(",\"mode\":\(file.mode),\"bytes\":\(file.bytes),\"sha256\":")
      try output.string(file.sha256)
      try output.raw("}")
    }
    try output.raw(#"],"directories":["#)
    for (index, directory) in directories.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw(#"{"path":"#)
      try output.string(directory.path)
      try output.raw(",\"mode\":\(directory.mode)}")
    }
    try output.raw(#"],"links":["#)
    for (index, link) in links.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw(#"{"path":"#)
      try output.string(link.path)
      try output.raw(#","target":"#)
      try output.string(link.target)
      try output.raw("}")
    }
    try output.raw(#"]},"native":["#)
    for (index, member) in native.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw(#"{"path":"#)
      try output.string(member.path)
      try output.raw(#","slices":["#)
      for (sliceIndex, slice) in member.slices.enumerated() {
        if sliceIndex > 0 { try output.raw(",") }
        try output.raw(#"{"arch":"#)
        try output.string(slice.arch)
        try output.raw(",\"filetype\":\(slice.filetype),\"minimum\":")
        try output.string(slice.minimum)
        try output.raw(#","dependencies":"#)
        try output.strings(slice.dependencies)
        try output.raw(#","rpaths":"#)
        try output.strings(slice.rpaths)
        try output.raw("}")
      }
      try output.raw("]}")
    }
    try output.raw("]}")
    guard output.bytes.count < 64 * 1024 else { throw ReleaseToolError.inputLimit }
    return output.bytes
  }
}

/// Compares the actual compiler framework to a separately pinned original ZIP.
///
/// A new private scratch holds an admitted archive copy and bounded Apple unzip
/// output. Every file, mode and exact versioned alias must equal the cache.
/// Two-CPU native metadata and repeated complete tree/archive custody bracket
/// comparison. Original archive/cache bytes are never repaired, thinned or signed.
///
/// This read-only source gate performs no compiler resolution, SDK execution or
/// network operation. It does not prove upstream derivation, license clearance,
/// installed compatibility or publication authority. Failed scratch remains
/// retained, including cancellation/deadline with a still-monitored owned child.
/// Software budgets cannot preempt a blocked filesystem operation.
public enum PinnedSparkleFramework {
  public static func verify(archive: String, framework: String) async throws
    -> PinnedSparkleFrameworkObservation
  {
    try await verify(archive: archive, framework: framework, child: OwnedCommand())
  }

  /// Uses a caller-retained owner so a one-shot CLI can observe exit after refusal.
  public static func verify(archive: String, framework: String, child: OwnedCommand) async throws
    -> PinnedSparkleFrameworkObservation
  {
    try await verify(archive: archive, framework: framework, work: nil, child: child)
  }

  static func verify(
    archive: String, framework: String, work: String?, child: OwnedCommand,
    limits: ChildLimits? = nil, seconds: Double = 120,
    observe: (@Sendable (SparkleAdmissionPhase) throws -> Void)? = nil
  ) async throws -> PinnedSparkleFrameworkObservation {
    guard !archive.isEmpty, !framework.isEmpty, !archive.utf8.contains(0),
      !framework.utf8.contains(0)
    else { throw ReleaseToolError.unsafeInput }
    let budget = try SparkleBudget(seconds: seconds)
    let source = URL(fileURLWithPath: archive).standardizedFileURL.path
    let cache = URL(fileURLWithPath: framework).standardizedFileURL.path
    let archiveIdentity = try SparkleInventory.named(source)
    let archivePolicy = try FileReadPolicy(
      minimum: PinnedSparkleArchive.bytes, maximum: PinnedSparkleArchive.bytes,
      protection: .protected, singleLink: true, seconds: budget.fileSeconds())
    try PinnedSparkleArchive.verify(source)
    let bytes = try AdmittedFile.read(source, policy: archivePolicy)
    guard try SparkleInventory.named(source) == archiveIdentity else {
      throw ReleaseToolError.inputChanged
    }
    try budget.check()
    let scratch = work ?? "/tmp/frameshift-sparkle-admission-\(UUID().uuidString)"
    guard scratch.hasPrefix("/"), !scratch.utf8.contains(0), mkdir(scratch, 0o700) == 0 else {
      throw ReleaseToolError.unsafeInput
    }
    let directory = open(scratch, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard directory >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(directory) }
    var state = stat()
    guard fstat(directory, &state) == 0 else { throw ReleaseToolError.readFailed }
    let scratchIdentity = FileIdentity(state)
    func scratchCustody() throws {
      let named = try SparkleInventory.named(scratch)
      guard fstat(directory, &state) == 0, named == FileIdentity(state),
        named.device == scratchIdentity.device, named.inode == scratchIdentity.inode,
        named.user == getuid(), named.mode & 0o7777 == 0o700,
        named.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else { throw ReleaseToolError.inputChanged }
    }
    try scratchCustody()
    let retained = scratch + "/sdk.zip"
    let copiedIdentity = try writeArchive(
      bytes, directory: directory, path: retained, budget: budget)
    try observe?(.archiveCopied)
    try scratchCustody()
    let bounds = try limits ?? ChildLimits(seconds: min(30, budget.fileSeconds()))
    guard bounds.duration <= .seconds(30), bounds.outputBytes <= 64 * 1024 else {
      throw ReleaseToolError.invalidBounds
    }
    _ = try await child.run(
      AppleCommand(
        .unzip,
        arguments: [
          "-q", retained, "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*", "-d",
          scratch,
        ]), limits: bounds)
    try budget.check()
    try scratchCustody()
    let completedScratch = try SparkleInventory.named(scratch)
    try observe?(.extracted)
    let extracted = scratch + "/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    let expected = try SparkleInventory(root: extracted, budget: budget).scan()
    guard expected.files.count == 85, expected.directories.count == 57, expected.links.count == 9,
      Dictionary(uniqueKeysWithValues: expected.links.map { ($0.path, $0.target) })
        == SparkleInventory.aliases
    else { throw ReleaseToolError.invalidBundle }
    var native: [PinnedSparkleFrameworkObservation.Native] = []
    for role in BundleSparkle.orderedRoles {
      let slices = try MachOInspector.inspect(
        extracted + "/" + role.path, seconds: budget.fileSeconds(), observe: nil)
      guard slices.map(\.arch) == ["arm64", "x86_64"],
        slices.allSatisfy({ $0.filetype == role.type })
      else { throw ReleaseToolError.invalidMachO }
      native.append(.init(path: role.path, slices: slices))
    }
    let before = try SparkleInventory(root: cache, budget: budget).scan()
    guard before.files == expected.files, before.directories == expected.directories,
      before.links == expected.links
    else { throw ReleaseToolError.digestMismatch }
    try observe?(.cacheChecked)
    guard try SparkleInventory(root: cache, budget: budget).scan() == before,
      try SparkleInventory(root: extracted, budget: budget).scan() == expected,
      try SparkleInventory.named(source) == archiveIdentity,
      try AdmittedFile.read(
        source,
        policy: FileReadPolicy(
          minimum: PinnedSparkleArchive.bytes, maximum: PinnedSparkleArchive.bytes,
          protection: .protected, singleLink: true, seconds: budget.fileSeconds())) == bytes,
      try SparkleInventory.named(source) == archiveIdentity,
      try SparkleInventory.named(retained) == copiedIdentity,
      try AdmittedFile.read(
        retained,
        policy: FileReadPolicy(
          minimum: PinnedSparkleArchive.bytes, maximum: PinnedSparkleArchive.bytes,
          protection: .privateFile, seconds: budget.fileSeconds())) == bytes,
      try SparkleInventory.named(retained) == copiedIdentity
    else { throw ReleaseToolError.inputChanged }
    try scratchCustody()
    guard try SparkleInventory.named(scratch) == completedScratch else {
      throw ReleaseToolError.inputChanged
    }
    try budget.check()
    let observation = PinnedSparkleFrameworkObservation(
      files: expected.files, directories: expected.directories, links: expected.links,
      native: native)
    _ = try observation.observationBytes()
    try budget.check()
    try FileManager.default.removeItem(atPath: scratch)
    return observation
  }

  /// Capture joins bracket the material gate with the same bounded complete inventory.
  static func custody(framework: String, seconds: Double) throws -> [String: FileIdentity] {
    try SparkleInventory(root: framework, budget: SparkleBudget(seconds: seconds)).scan().custody
  }

  private static func writeArchive(
    _ bytes: Data, directory: Int32, path: String, budget: SparkleBudget
  ) throws -> FileIdentity {
    let descriptor = openat(
      directory, "sdk.zip", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600
    )
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(descriptor) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < bytes.count {
        try budget.check()
        let count = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset)
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ReleaseToolError.readFailed }
        offset += count
      }
    }
    try budget.check()
    guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw ReleaseToolError.readFailed }
    var state = stat()
    guard fstat(descriptor, &state) == 0 else { throw ReleaseToolError.readFailed }
    let identity = FileIdentity(state)
    guard identity.isRegular, identity.user == getuid(), identity.mode & 0o7777 == 0o600,
      identity.links == 1, identity.size == PinnedSparkleArchive.bytes,
      try SparkleInventory.named(path) == identity
    else { throw ReleaseToolError.inputChanged }
    return identity
  }
}

enum SparkleAdmissionPhase: Sendable { case archiveCopied, extracted, cacheChecked }

private struct SparkleBudget {
  let deadline: ContinuousClock.Instant
  init(seconds: Double = 120) throws {
    guard seconds.isFinite, seconds > 0, seconds <= 120 else {
      throw ReleaseToolError.invalidBounds
    }
    deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(seconds * 1_000_000_000)))
  }
  func check() throws {
    guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
    guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
  }
  func fileSeconds() throws -> Double {
    try check()
    let value = ContinuousClock.now.duration(to: deadline).components
    return min(60, Double(value.seconds) + Double(value.attoseconds) / 1e18)
  }
}

private struct SparkleSnapshot: Equatable {
  var files: [NativeBundleObservation.File] = []
  var directories: [NativeBundleObservation.Directory] = []
  var links: [NativeBundleObservation.Link] = []
  var custody: [String: FileIdentity] = [:]
}

private final class SparkleInventory {
  static let aliases = Dictionary(
    uniqueKeysWithValues: BundleSparkle.links.map {
      (String($0.key.dropFirst(BundleSparkle.root.count + 1)), $0.value)
    })
  let root: String
  let budget: SparkleBudget
  var entries = 1
  var total: Int64 = 0
  var snapshot = SparkleSnapshot()
  init(root: String, budget: SparkleBudget) {
    self.root = root
    self.budget = budget
  }
  static func named(_ path: String) throws -> FileIdentity {
    var state = stat()
    guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(state)
  }
  func scan() throws -> SparkleSnapshot {
    try visit("", depth: 0)
    func ordered(_ first: String, _ second: String) -> Bool {
      first.compare(second, locale: Locale(identifier: "en_US")) == .orderedAscending
    }
    snapshot.files.sort { ordered($0.path, $1.path) }
    snapshot.directories.sort { ordered($0.path, $1.path) }
    snapshot.links.sort { ordered($0.path, $1.path) }
    return snapshot
  }
  private func visit(_ relative: String, depth: Int) throws {
    try budget.check()
    guard depth <= 24, relative.utf8.count <= 512,
      !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      snapshot.custody[relative] == nil
    else { throw ReleaseToolError.inputLimit }
    let path = root + (relative.isEmpty ? "" : "/" + relative)
    let before = try Self.named(path)
    guard before.user == 0 || before.user == getuid() else { throw ReleaseToolError.unsafeInput }
    snapshot.custody[relative] = before
    let kind = before.mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFLNK) {
      guard let expected = Self.aliases[relative], before.links == 1 else {
        throw ReleaseToolError.unsafeInput
      }
      func target() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = readlink(path, &bytes, bytes.count)
        guard count >= 0, count < bytes.count,
          let string = String(bytes: bytes.prefix(count), encoding: .utf8)
        else { throw ReleaseToolError.readFailed }
        return string
      }
      guard try target() == expected, try Self.named(path) == before, try target() == expected
      else {
        throw ReleaseToolError.inputChanged
      }
      snapshot.links.append(.init(path: relative, target: expected))
    } else {
      guard before.mode & 0o7022 == 0, before.mode & 0o400 != 0 else {
        throw ReleaseToolError.unsafeInput
      }
      if kind == mode_t(S_IFDIR) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
          let count = Int(entry.pointee.d_namlen)
          guard count > 0, count < 1024 else { throw ReleaseToolError.unsafeInput }
          let name = withUnsafeBytes(of: entry.pointee.d_name) {
            String(bytes: $0.prefix(count), encoding: .utf8)
          }
          guard let name, !name.contains("/"), !name.utf8.contains(0) else {
            throw ReleaseToolError.unsafeInput
          }
          if name == "." || name == ".." { continue }
          guard entries < 512 else { throw ReleaseToolError.inputLimit }
          entries += 1
          names.append(name)
        }
        guard Set(names).count == names.count else { throw ReleaseToolError.unsafeInput }
        for name in names.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
          try visit(relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
        }
        guard fstat(descriptor, &state) == 0, FileIdentity(state) == before else {
          throw ReleaseToolError.inputChanged
        }
        snapshot.directories.append(.init(path: relative, mode: before.mode & 0o7777))
      } else if before.isRegular {
        guard before.links == 1, before.size >= 0, before.size <= 16 * 1024 * 1024 else {
          throw ReleaseToolError.inputLimit
        }
        total += before.size
        guard total <= 64 * 1024 * 1024 else { throw ReleaseToolError.inputLimit }
        let digest = try AdmittedFile.sha256(
          path,
          policy: FileReadPolicy(
            minimum: 0, maximum: 16 * 1024 * 1024, protection: .protected,
            singleLink: true, seconds: budget.fileSeconds()))
        snapshot.files.append(
          .init(
            path: relative, mode: before.mode & 0o7777, bytes: digest.bytes, sha256: digest.sha256))
      } else {
        throw ReleaseToolError.unsafeInput
      }
      guard try Self.named(path) == before else { throw ReleaseToolError.inputChanged }
    }
  }
}
