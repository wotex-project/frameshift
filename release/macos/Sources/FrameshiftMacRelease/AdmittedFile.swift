import CryptoKit
import Darwin
import Foundation

/// Ownership and mode requirements applied to both the name and open descriptor.
public enum FileProtection: Sendable {
  /// A regular file; the consumer owns any additional parent/owner policy.
  case regular
  /// Root/current-user ownership, no group/other writes or special permission bits.
  case protected
  /// Current-user ownership, mode 0400/0600 and exactly one link.
  case privateFile
}

/// A finite input profile, validated before pathname or descriptor work begins.
///
/// Streaming hashes admit at most 8 GiB. Buffered reads additionally cap at
/// 16 MiB. Monotonic budgets are checked between synchronous filesystem calls;
/// they cannot preempt a kernel/filesystem operation that has already blocked.
public struct FileReadPolicy: Sendable {
  public let minimum: Int64
  public let maximum: Int64
  public let protection: FileProtection
  public let singleLink: Bool
  let budget: Duration

  public init(
    minimum: Int64 = 1, maximum: Int64, protection: FileProtection = .regular,
    singleLink: Bool = false, seconds: Double = 60
  ) throws {
    guard minimum >= 0, maximum >= minimum, maximum <= 8 * 1024 * 1024 * 1024,
      seconds.isFinite, seconds > 0, seconds <= 900
    else { throw ReleaseToolError.invalidBounds }
    self.minimum = minimum
    self.maximum = maximum
    self.protection = protection
    self.singleLink = singleLink
    budget = .nanoseconds(Int64(seconds * 1_000_000_000))
  }
}

/// Digest of the exact bytes read from a descriptor whose custody was rechecked.
public struct FileDigest: Equatable, Sendable {
  public let bytes: Int64
  public let sha256: String
}

/// Reads local release inputs without following a final symlink or blocking on a FIFO.
///
/// Admission compares device/inode, size, mode, owner/group, link count and
/// nanosecond modification/change times across the named file and descriptor,
/// before and after a bounded 64 KiB stream. Short reads, growth, replacement
/// and metadata changes refuse. The descriptor is always closed. This primitive
/// does not establish parent-directory custody, native closure or a signature;
/// those remain the consuming profile's responsibility.
public enum AdmittedFile {
  public static func read(_ path: String, policy: FileReadPolicy) throws -> Data {
    try read(path, policy: policy, observe: nil)
  }

  public static func sha256(_ path: String, policy: FileReadPolicy) throws -> FileDigest {
    try sha256(path, policy: policy, observe: nil)
  }

  static func read(
    _ path: String, policy: FileReadPolicy, observe: ((FileReadPhase) throws -> Void)?
  ) throws -> Data {
    guard policy.maximum <= 16 * 1024 * 1024 else { throw ReleaseToolError.invalidBounds }
    var bytes = Data()
    try stream(path, policy: policy, observe: observe) { block in bytes.append(contentsOf: block) }
    return bytes
  }

  static func sha256(
    _ path: String, policy: FileReadPolicy, observe: ((FileReadPhase) throws -> Void)?
  ) throws -> FileDigest {
    var hash = SHA256()
    let size = try stream(path, policy: policy, observe: observe) { hash.update(data: Data($0)) }
    return FileDigest(
      bytes: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
  }

  @discardableResult
  private static func stream(
    _ path: String, policy: FileReadPolicy, observe: ((FileReadPhase) throws -> Void)?,
    consume: (UnsafeRawBufferPointer) -> Void
  ) throws -> Int64 {
    try withDescriptor(path, policy: policy, observe: observe) { descriptor, size, budget in
      var block = [UInt8](repeating: 0, count: 64 * 1024)
      var offset: Int64 = 0
      while offset < size {
        try budget()
        let requested = Int(min(Int64(block.count), size - offset))
        let count = try block.withUnsafeMutableBytes { buffer in
          try read(
            descriptor, into: buffer.baseAddress!, count: requested, offset: offset, budget: budget)
        }
        guard count > 0 else { throw ReleaseToolError.inputChanged }
        block.withUnsafeBytes { consume(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        offset += Int64(count)
        try observe?(.chunk(offset))
      }
      try budget()
      let extra = try block.withUnsafeMutableBytes { buffer in
        try read(descriptor, into: buffer.baseAddress!, count: 1, offset: offset, budget: budget)
      }
      guard extra == 0 else { throw ReleaseToolError.inputChanged }
      return offset
    }
  }

  /// Scoped random-access reads for bounded native headers; the descriptor never escapes.
  static func withRegions<Result>(
    _ path: String, policy: FileReadPolicy, observe: ((FileReadPhase) throws -> Void)? = nil,
    consume: (NativeRegionReader) throws -> Result
  ) throws -> Result {
    try withDescriptor(path, policy: policy, observe: observe) { descriptor, size, budget in
      let reader = NativeRegionReader(descriptor: descriptor, size: size, budget: budget)
      defer { reader.invalidate() }
      return try consume(reader)
    }
  }

  private static func withDescriptor<Result>(
    _ path: String, policy: FileReadPolicy, observe: ((FileReadPhase) throws -> Void)?,
    consume: (Int32, Int64, @escaping () throws -> Void) throws -> Result
  ) throws -> Result {
    guard !path.isEmpty, !path.utf8.contains(0) else { throw ReleaseToolError.unsafeInput }
    let deadline = ContinuousClock.now.advanced(by: policy.budget)
    func budget() throws {
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
    }
    try budget()
    let named = try identity(path)
    try named.admit(policy)
    try observe?(.named)
    try budget()
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(descriptor) }
    let before = try identity(descriptor)
    try before.admit(policy)
    guard named == before else { throw ReleaseToolError.inputChanged }
    try observe?(.opened)
    let result = try consume(descriptor, before.size, budget)
    try observe?(.finished)
    try budget()
    let after = try identity(descriptor)
    let final = try identity(path)
    guard before == after, after == final, final.isRegular else {
      throw ReleaseToolError.inputChanged
    }
    try budget()
    return result
  }

  private static func read(
    _ descriptor: Int32, into buffer: UnsafeMutableRawPointer, count: Int, offset: Int64,
    budget: () throws -> Void
  ) throws -> Int {
    while true {
      try budget()
      let result = Darwin.pread(descriptor, buffer, count, off_t(offset))
      if result >= 0 { return result }
      guard errno == EINTR else { throw ReleaseToolError.readFailed }
    }
  }

  private static func identity(_ path: String) throws -> FileIdentity {
    var value = stat()
    guard Darwin.lstat(path, &value) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(value)
  }

  private static func identity(_ descriptor: Int32) throws -> FileIdentity {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(value)
  }
}

/// A synchronous borrowed view. Invalidation precedes descriptor closure; even
/// an accidentally retained view refuses before a recycled descriptor is used.
/// It is deliberately not Sendable and exposes no raw descriptor.
final class NativeRegionReader {
  let size: Int64
  private let descriptor: Int32
  private let budget: () throws -> Void
  private var valid = true

  fileprivate init(descriptor: Int32, size: Int64, budget: @escaping () throws -> Void) {
    self.descriptor = descriptor
    self.size = size
    self.budget = budget
  }

  fileprivate func invalidate() { valid = false }

  func checkBudget() throws {
    guard valid else { throw ReleaseToolError.unsafeInput }
    try budget()
  }

  func read(offset: Int64, count: Int) throws -> Data {
    try checkBudget()
    guard offset >= 0, offset <= size, count >= 0, count <= 1024 * 1024,
      Int64(count) <= size - offset
    else { throw ReleaseToolError.invalidMachO }
    var bytes = Data(count: count)
    try bytes.withUnsafeMutableBytes { buffer in
      var position = 0
      while position < count {
        try checkBudget()
        let received = Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: position), min(64 * 1024, count - position),
          off_t(offset + Int64(position)))
        if received < 0 && errno == EINTR { continue }
        guard received >= 0 else { throw ReleaseToolError.readFailed }
        guard received > 0 else { throw ReleaseToolError.inputChanged }
        position += received
      }
    }
    return bytes
  }
}

enum FileReadPhase: Equatable {
  case named
  case opened
  case chunk(Int64)
  case finished
}

struct FileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let size: Int64
  let mode: mode_t
  let user: uid_t
  let group: gid_t
  let links: nlink_t
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    size = value.st_size
    mode = value.st_mode
    user = value.st_uid
    group = value.st_gid
    links = value.st_nlink
    modifiedSeconds = value.st_mtimespec.tv_sec
    modifiedNanoseconds = value.st_mtimespec.tv_nsec
    changedSeconds = value.st_ctimespec.tv_sec
    changedNanoseconds = value.st_ctimespec.tv_nsec
  }

  var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }

  func admit(_ policy: FileReadPolicy) throws {
    guard isRegular else { throw ReleaseToolError.unsafeInput }
    guard size >= policy.minimum, size <= policy.maximum else { throw ReleaseToolError.inputLimit }
    if policy.singleLink && links != 1 { throw ReleaseToolError.unsafeInput }
    switch policy.protection {
    case .regular: break
    case .protected:
      guard user == 0 || user == getuid(), mode & 0o7022 == 0 else {
        throw ReleaseToolError.unsafeInput
      }
    case .privateFile:
      guard user == getuid(), links == 1, [mode_t(0o400), mode_t(0o600)].contains(mode & 0o7777)
      else { throw ReleaseToolError.unsafeInput }
    }
  }
}
