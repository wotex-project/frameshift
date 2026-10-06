import Darwin
import Foundation

/// Native image facts after exact read-only mounted readback and confirmed detach.
///
/// These bounded observations are not a portable receipt, installed acceptance
/// or publication credential. The source bundle remains independently owned.
public struct NativeDiskImageObservation: Sendable {
  public let architecture: NativeBundleArchitecture
  public let bundle: NativeBundleObservation
  public let archive: String
  public let image: FileDigest

  public func observationBytes() throws -> Data {
    let source = try bundle.observationBytes()
    guard source.count <= 1024 * 1024,
      let body = String(data: source, encoding: .utf8)
    else { throw ReleaseToolError.inputLimit }
    var output = NativeObservationWriter()
    try output.raw(
      #"{"schemaVersion":1,"publicationAuthority":"none","producer":"native-development-dmg-v1","architecture":"#
    )
    try output.string(architecture.rawValue)
    try output.raw(#","bundle":"#)
    try output.raw(body)
    try output.raw(#","archive":"#)
    try output.string(archive)
    try output.raw(#","bytes":\#(image.bytes),"sha256":"#)
    try output.string(image.sha256)
    try output.raw("}")
    return output.bytes
  }
}

/// Distinguishes a retained OS mount effect from direct-child exit.
public enum DiskImageMountStatus: Equatable, Sendable {
  case notAttempted, attachmentPending, mounted, restored, uncertain
}

/// Creates a private development image and validates its exact mounted contents.
///
/// `create(app:architecture:workspace:)` admits a sealed source and an empty
/// caller-owned mode-0700 `.dmg.` workspace. Fixed Apple commands create a local
/// compressed HFS+ image, verify it and attach read-only without browsing,
/// opening or automatic filesystem checking. Mounted bytes, aliases and every
/// native/container seal must match the original source; mounted code never runs.
/// Complete source, image, copied payload and private namespace custody bracket
/// every child. One five-minute budget and bounded output apply; image hashing
/// streams at most 1 GiB. Success requires restoration of the exact original
/// mountpoint before successful private work is removed and facts are returned.
///
/// Refusal retains all work and actual child/mount custody. A one-shot caller
/// first uses `retainUntilExitAfterRefusal()`, then may call the one-shot
/// `detachAfterRefusal()` independently of its canceled task. That recovery
/// targets only this owned read-only mount, never forces ejection, retries,
/// cleans work, promotes an image or proves descendant/device effects stopped.
/// The producer writes no portable receipt, accepted output or release artifact.
public actor DevelopmentDiskImageProducer {
  private var attempted = false
  private var child: OwnedCommand?
  private var work: DiskImageWork?
  private var source: DevelopmentBundleSource?
  private var payload: BundleSnapshot?
  private var image: (FileIdentity, FileDigest)?
  private var mountIdentity: FileIdentity?
  private var mountedIdentity: FileIdentity?
  private var attachmentAttempted = false
  private var detachAttempted = false
  private var recoveryAttempted = false
  public private(set) var mountStatus: DiskImageMountStatus = .notAttempted

  public init() {}

  public func create(app: String, architecture: NativeBundleArchitecture, workspace: String)
    async throws -> NativeDiskImageObservation
  {
    try await create(app: app, architecture: architecture, workspace: workspace, observe: nil)
  }

  public func childStatus() async -> OwnedChildStatus {
    await child?.status() ?? .notStarted
  }

  public func retainUntilExitAfterRefusal() async -> OwnedChildStatus {
    await child?.retainUntilExitAfterRefusal() ?? .notStarted
  }

  /// One owned recovery attempt after actual direct exit; failed work stays intact.
  public nonisolated func detachAfterRefusal() async throws -> DiskImageMountStatus {
    try await Task.detached { [self] in try await recoverDetach() }.value
  }

  func create(
    app: String, architecture: NativeBundleArchitecture, workspace: String,
    seconds: Double = 300, childSeconds: Double = 120,
    imageChildSeconds: Double? = nil, attachmentChildSeconds: Double? = nil,
    detachmentChildSeconds: Double? = nil,
    observe: (@Sendable (DiskImagePhase, String) throws -> Void)?
  ) async throws -> NativeDiskImageObservation {
    guard !attempted else { throw ReleaseToolError.childAlreadyStarted }
    attempted = true
    guard seconds.isFinite, seconds > 0, seconds <= 300,
      childSeconds.isFinite, childSeconds > 0, childSeconds <= 120
    else { throw ReleaseToolError.invalidBounds }
    for value in [imageChildSeconds, attachmentChildSeconds, detachmentChildSeconds].compactMap({
      $0
    }) {
      guard value.isFinite, value > 0, value <= childSeconds else {
        throw ReleaseToolError.invalidBounds
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    let sourceRoot = try DiskImageWork.physical(app)
    let privateWork = try DiskImageWork(workspace, architecture: architecture)
    work = privateWork
    guard !sourceRoot.hasPrefix(privateWork.root + "/"),
      !privateWork.root.hasPrefix(sourceRoot + "/"), sourceRoot != privateWork.root
    else { throw ReleaseToolError.unsafeInput }
    let original = try DevelopmentBundleSource(
      root: sourceRoot, namedRoot: app, architecture: architecture)
    source = original
    guard try original.observation.observationBytes().count <= 1024 * 1024 else {
      throw ReleaseToolError.inputLimit
    }
    let estimate = original.observation.files.reduce(Int64(0)) { $0 + $1.bytes }
    var space = statfs()
    guard statfs(privateWork.root, &space) == 0 else { throw ReleaseToolError.readFailed }
    let available = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_bsize))
    guard !available.overflow, available.partialValue >= UInt64(estimate * 2 + 256 * 1024 * 1024)
    else { throw ReleaseToolError.inputLimit }
    try check(deadline)
    try observe?(.admitted, privateWork.root)
    try check(deadline)
    try privateWork.createDirectories()
    try await run(
      .ditto, [sourceRoot, privateWork.app], deadline: deadline, seconds: min(120, childSeconds))
    let copied = try NativeBundleInspector.inspectWithCustody(
      privateWork.app, architecture: architecture)
    guard try copied.observation.observationBytes() == original.observation.observationBytes()
    else {
      throw ReleaseToolError.digestMismatch
    }
    payload = copied.custody
    _ = try NativeSignatureVerifier.verifyDevelopmentBundle(
      privateWork.app, architecture: architecture)
    try privateWork.finishPayload()
    try observe?(.copied, privateWork.root)
    try check(deadline)
    try privateWork.beginImage()
    try await run(
      .hdiutil,
      [
        "create", "-srcfolder", privateWork.payload, "-fs", "HFS+", "-format", "UDZO",
        "-volname", "Frameshift Development", "-nospotlight", "-noskipunreadable",
        privateWork.archive,
      ], deadline: deadline, seconds: min(120, imageChildSeconds ?? childSeconds))
    try privateWork.protectImage()
    let facts = try imageFacts(deadline)
    image = (try SparkleInventory.named(privateWork.archive), facts)
    try observe?(.created, privateWork.root)
    try check(deadline)
    try await run(
      .hdiutil, ["verify", "-nocache", privateWork.archive], deadline: deadline,
      seconds: min(120, childSeconds))
    try privateWork.prepareMount()
    mountIdentity = try SparkleInventory.named(privateWork.mount)
    try check(deadline)
    try observe?(.attaching, privateWork.root)
    try check(deadline)
    attachmentAttempted = true
    mountStatus = .attachmentPending
    let attachment = try await run(
      .hdiutil,
      [
        "attach", privateWork.archive, "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
        "-noverify",
        "-mountpoint", privateWork.mount, "-plist",
      ], deadline: deadline, seconds: min(30, attachmentChildSeconds ?? childSeconds))
    try validateAttachment(attachment.standardOutput)
    mountedIdentity = try SparkleInventory.named(privateWork.mount)
    mountStatus = .mounted
    try observe?(.mounted, privateWork.root)
    try check(deadline)
    try validateMounted(architecture)
    try check(deadline)
    try observe?(.detaching, privateWork.root)
    try check(deadline)
    detachAttempted = true
    _ = try await run(
      .hdiutil, ["detach", privateWork.mount], deadline: deadline,
      seconds: min(30, detachmentChildSeconds ?? childSeconds))
    try restored()
    mountStatus = .restored
    try observe?(.detached, privateWork.root)
    try check(deadline)
    guard try imageFacts(deadline) == facts else { throw ReleaseToolError.inputChanged }
    try privateWork.synchronizeImage()
    try privateWork.removeSuccessfulWork()
    payload = nil
    try check(deadline)
    return NativeDiskImageObservation(
      architecture: architecture, bundle: original.observation,
      archive: URL(fileURLWithPath: privateWork.archive).lastPathComponent, image: facts)
  }

  @discardableResult
  private func run(
    _ tool: AppleTool, _ arguments: [String], deadline: ContinuousClock.Instant,
    seconds: Double
  ) async throws -> OwnedCommandOutput {
    try check(deadline)
    let owned = OwnedCommand()
    child = owned
    let result = try await owned.run(
      AppleCommand(tool, arguments: arguments),
      limits: ChildLimits(outputBytes: 64 * 1024, seconds: min(seconds, try remaining(deadline))))
    try check(deadline)
    return result
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
    _ = try remaining(deadline)
    guard let work else { throw ReleaseToolError.unsafeInput }
    try work.check()
    try source?.check()
    if let payload {
      guard try NativeBundleInspector.preparationSnapshot(work.app) == payload else {
        throw ReleaseToolError.inputChanged
      }
    }
    if let image {
      let current = try SparkleInventory.named(work.archive)
      guard current == image.0 else {
        throw ReleaseToolError.inputChanged
      }
    }
  }

  private func remaining(_ deadline: ContinuousClock.Instant) throws -> Double {
    let duration = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    guard seconds > 0 else { throw ReleaseToolError.deadline }
    return seconds
  }

  private func imageFacts(_ deadline: ContinuousClock.Instant) throws -> FileDigest {
    guard let work else { throw ReleaseToolError.unsafeInput }
    return try AdmittedFile.sha256(
      work.archive,
      policy: FileReadPolicy(
        maximum: 1024 * 1024 * 1024, protection: .privateFile, singleLink: true,
        seconds: min(120, try remaining(deadline))))
  }

  private func validateAttachment(_ data: Data) throws {
    guard let work,
      case .array(let entities) = try NativePropertyList.decode(data).values["system-entities"]
    else {
      throw ReleaseToolError.invalidPropertyList
    }
    let mounts = entities.compactMap { value -> String? in
      guard case .dictionary(let fields) = value, case .string(let point) = fields["mount-point"]
      else { return nil }
      return point
    }
    guard mounts == [work.mount] else { throw ReleaseToolError.invalidPropertyList }
    try readonlyMount()
  }

  private func readonlyMount() throws {
    guard let work, let original = mountIdentity else { throw ReleaseToolError.unsafeInput }
    let current = try SparkleInventory.named(work.mount)
    var space = statfs()
    guard current.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), current.device != original.device,
      statfs(work.mount, &space) == 0, space.f_flags & UInt32(MNT_RDONLY) != 0
    else { throw ReleaseToolError.unsafeInput }
    if let mountedIdentity {
      guard current == mountedIdentity else { throw ReleaseToolError.inputChanged }
    }
  }

  private func validateMounted(_ architecture: NativeBundleArchitecture) throws {
    guard let work, let source else { throw ReleaseToolError.unsafeInput }
    try readonlyMount()
    let names = try DiskImageWork.names(work.mount)
    let required: Set<String> = ["Frameshift.app", "Applications", "Read Me.txt"]
    let allowed = required.union([".fseventsd", ".Trashes", ".Spotlight-V100"])
    guard required.isSubset(of: Set(names)), Set(names).isSubset(of: allowed) else {
      throw ReleaseToolError.invalidBundle
    }
    for name in names where !required.contains(name) {
      guard
        try SparkleInventory.named(work.mount + "/" + name).mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else {
        throw ReleaseToolError.unsafeInput
      }
    }
    try DiskImageWork.checkReading(work.mount)
    let observation = try NativeSignatureVerifier.verifyDevelopmentBundle(
      work.mount + "/Frameshift.app", architecture: architecture)
    guard try observation.observationBytes() == source.observation.observationBytes() else {
      throw ReleaseToolError.digestMismatch
    }
    try readonlyMount()
  }

  private func restored() throws {
    guard let work, let original = mountIdentity,
      try SparkleInventory.named(work.mount) == original,
      try DiskImageWork.names(work.mount).isEmpty
    else { throw ReleaseToolError.inputChanged }
  }

  private func recoverDetach() async throws -> DiskImageMountStatus {
    guard !recoveryAttempted else { throw ReleaseToolError.childAlreadyStarted }
    recoveryAttempted = true
    let status = await childStatus()
    guard
      status == .notStarted
        || {
          if case .stopped = status { return true }
          return false
        }()
    else {
      throw ReleaseToolError.childCustodyUnknown
    }
    if !attachmentAttempted || mountStatus == .restored { return mountStatus }
    guard let work else { throw ReleaseToolError.unsafeInput }
    try work.checkRecoveryParents()
    if detachAttempted {
      do {
        try restored()
        mountStatus = .restored
        return .restored
      } catch {
        mountStatus = .uncertain
        throw error
      }
    }
    do { try readonlyMount() } catch {
      mountStatus = .uncertain
      throw error
    }
    detachAttempted = true
    let owner = OwnedCommand()
    child = owner
    do {
      _ = try await owner.run(
        AppleCommand(.hdiutil, arguments: ["detach", work.mount]),
        limits: ChildLimits(outputBytes: 64 * 1024, seconds: 30))
      try work.checkRecoveryParents()
      try restored()
      mountStatus = .restored
      return .restored
    } catch {
      mountStatus = .uncertain
      throw error
    }
  }
}

enum DiskImagePhase: Sendable {
  case admitted, copied, created, attaching, mounted, detaching, detached
}

private final class DiskImageWork {
  static let reading = Data(
    "Frameshift development build\n\nThis local disk image is an unpublished development candidate. It carries no production installation or update qualification. Do not distribute it as a release.\n"
      .utf8)
  let namedRoot: String
  let root: String
  let descriptor: Int32
  let original: FileIdentity
  let archive: String
  var payload: String { root + "/.work/payload" }
  var app: String { payload + "/Frameshift.app" }
  var mount: String { root + "/.work/mount" }
  private var directories: [String: FileIdentity] = [:]
  private var readingIdentity: FileIdentity?
  private var linkIdentity: FileIdentity?
  private var allowArchive = false

  init(_ input: String, architecture: NativeBundleArchitecture) throws {
    namedRoot = input
    root = try Self.physical(input)
    let name = URL(fileURLWithPath: root).lastPathComponent
    let suffix = name.dropFirst(".dmg.".count)
    original = try SparkleInventory.named(input)
    guard name.hasPrefix(".dmg."), !suffix.isEmpty,
      suffix.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      }),
      original.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), original.user == getuid(),
      original.mode & 0o7777 == 0o700,
      try Self.names(root).isEmpty
    else { throw ReleaseToolError.unsafeInput }
    archive = root + "/Frameshift-development-\(architecture.rawValue).dmg"
    descriptor = open(root, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    do { try check() } catch {
      Darwin.close(descriptor)
      throw error
    }
  }
  deinit { Darwin.close(descriptor) }

  static func physical(_ input: String) throws -> String {
    guard !input.isEmpty, !input.utf8.contains(0), let path = realpath(input, nil) else {
      throw ReleaseToolError.unsafeInput
    }
    defer { free(path) }
    return String(cString: path)
  }

  func check() throws {
    try checkRecoveryParents()
    let names = try Self.names(root)
    let allowed: Set<String> =
      allowArchive ? [".work", URL(fileURLWithPath: archive).lastPathComponent] : [".work"]
    guard Set(names).isSubset(of: allowed) else { throw ReleaseToolError.inputChanged }
    for (path, identity) in directories {
      guard sameDirectory(try SparkleInventory.named(path), identity) else {
        throw ReleaseToolError.inputChanged
      }
    }
    if directories[root + "/.work"] != nil {
      guard Set(try Self.names(root + "/.work")).isSubset(of: ["payload", "mount"]) else {
        throw ReleaseToolError.inputChanged
      }
      guard
        Set(try Self.names(payload)).isSubset(of: ["Frameshift.app", "Applications", "Read Me.txt"])
      else { throw ReleaseToolError.inputChanged }
    }
    if let readingIdentity, let linkIdentity {
      guard try SparkleInventory.named(payload + "/Read Me.txt") == readingIdentity,
        try SparkleInventory.named(payload + "/Applications") == linkIdentity
      else { throw ReleaseToolError.inputChanged }
      try Self.checkReading(payload)
    }
  }

  func checkRecoveryParents() throws {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, sameDirectory(FileIdentity(opened), original),
      sameDirectory(try SparkleInventory.named(root), original),
      sameDirectory(try SparkleInventory.named(namedRoot), original)
    else { throw ReleaseToolError.inputChanged }
    if let identity = directories[root + "/.work"] {
      guard sameDirectory(try SparkleInventory.named(root + "/.work"), identity) else {
        throw ReleaseToolError.inputChanged
      }
    }
  }

  private func sameDirectory(_ a: FileIdentity, _ b: FileIdentity) -> Bool {
    a.device == b.device && a.inode == b.inode && a.mode == b.mode && a.user == b.user
      && a.group == b.group
  }

  func createDirectories() throws {
    for path in [root + "/.work", payload] {
      guard mkdir(path, 0o700) == 0 else { throw ReleaseToolError.readFailed }
      directories[path] = try SparkleInventory.named(path)
    }
    try check()
  }

  func finishPayload() throws {
    guard symlink("/Applications", payload + "/Applications") == 0 else {
      throw ReleaseToolError.readFailed
    }
    let path = payload + "/Read Me.txt"
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(fd) }
    let written = Self.reading.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard written == Self.reading.count, fsync(fd) == 0 else { throw ReleaseToolError.readFailed }
    readingIdentity = try SparkleInventory.named(path)
    linkIdentity = try SparkleInventory.named(payload + "/Applications")
    try check()
  }

  func prepareMount() throws {
    guard mkdir(mount, 0o700) == 0 else { throw ReleaseToolError.readFailed }
    try check()
  }

  func protectImage() throws {
    let fd = open(archive, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(fd) }
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      value.st_uid == getuid(), value.st_nlink == 1, value.st_size > 0,
      value.st_size <= 1024 * 1024 * 1024,
      fchmod(fd, 0o600) == 0
    else { throw ReleaseToolError.unsafeInput }
    guard fstat(fd, &value) == 0, try SparkleInventory.named(archive) == FileIdentity(value) else {
      throw ReleaseToolError.inputChanged
    }
  }

  func beginImage() throws {
    var value = stat()
    guard lstat(archive, &value) == -1, errno == ENOENT else { throw ReleaseToolError.inputChanged }
    allowArchive = true
  }

  func synchronizeImage() throws {
    let fd = open(archive, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0, fsync(descriptor) == 0 else { throw ReleaseToolError.readFailed }
  }

  func removeSuccessfulWork() throws {
    try check()
    guard rmdir(mount) == 0 else { throw ReleaseToolError.inputChanged }
    try FileManager.default.removeItem(atPath: payload)
    directories.removeAll()
    readingIdentity = nil
    linkIdentity = nil
    guard rmdir(root + "/.work") == 0, fsync(descriptor) == 0 else {
      throw ReleaseToolError.inputChanged
    }
    try check()
  }

  static func checkReading(_ root: String) throws {
    let link = root + "/Applications"
    guard try SparkleInventory.named(link).mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else {
      throw ReleaseToolError.unsafeInput
    }
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = readlink(link, &bytes, bytes.count)
    guard count == 13, String(bytes: bytes.prefix(count), encoding: .utf8) == "/Applications",
      try AdmittedFile.read(root + "/Read Me.txt", policy: FileReadPolicy(maximum: 4096)) == reading
    else { throw ReleaseToolError.digestMismatch }
  }

  static func names(_ path: String) throws -> [String] {
    let before = try SparkleInventory.named(path)
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY)
    guard fd >= 0 else { throw ReleaseToolError.readFailed }
    guard let directory = fdopendir(fd) else {
      Darwin.close(fd)
      throw ReleaseToolError.readFailed
    }
    defer { closedir(directory) }
    var result: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw ReleaseToolError.readFailed }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard result.count < 16, !result.contains(name) else { throw ReleaseToolError.inputLimit }
      result.append(name)
    }
    var value = stat()
    guard fstat(dirfd(directory), &value) == 0, FileIdentity(value) == before,
      try SparkleInventory.named(path) == before
    else { throw ReleaseToolError.inputChanged }
    return result.sorted()
  }
}
