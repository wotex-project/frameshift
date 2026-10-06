import Darwin
import Foundation

/// Constructs one universal development app from two sealed single-CPU inputs.
///
/// `merge(arm:intel:stage:)` requires a caller-owned empty `Frameshift.app` in
/// a physical, current-user mode-0700 `.package.` directory. Sources must be
/// physically disjoint from that stage and each other. Exact common bytes,
/// modes, aliases and typed metadata agree except fixed regenerated seals and
/// the derived minimum. Every source native role contributes its actual slice.
///
/// Fixed owned copy/merge children and the existing development preparer share
/// five minutes. Complete source custody brackets every child, including nested
/// sealing; private stage checkpoints admit only each named native replacement.
/// Success returns the existing schema-two observation with authority none.
/// It does not write a portable receipt, replay legacy records, replace accepted
/// output or establish installed/production compatibility. Refusal retains the
/// stage and actual last direct child; keep this actor alive and observe exit
/// with `retainUntilExitAfterRefusal()` before ending a one-shot CLI.
public actor UniversalBundleMerger {
  private var attempted = false
  private var child: OwnedCommand?
  private let preparer = DevelopmentBundlePreparer()
  private var preparing = false

  public init() {}

  public func merge(arm: String, intel: String, stage: String) async throws
    -> NativeBundleObservation
  {
    try await merge(arm: arm, intel: intel, stage: stage, observe: nil)
  }

  public func childStatus() async -> OwnedChildStatus {
    if preparing { return await preparer.childStatus() }
    return await child?.status() ?? .notStarted
  }

  /// Observes custody only; never retries, escalates, cleans or promotes a stage.
  public func retainUntilExitAfterRefusal() async -> OwnedChildStatus {
    if preparing { return await preparer.retainUntilExitAfterRefusal() }
    return await child?.retainUntilExitAfterRefusal() ?? .notStarted
  }

  func merge(
    arm: String, intel: String, stage input: String, seconds: Double = 300,
    childSeconds: Double = 15,
    observe: (@Sendable (UniversalMergePhase) throws -> Void)?
  ) async throws -> NativeBundleObservation {
    guard !attempted else { throw ReleaseToolError.childAlreadyStarted }
    attempted = true
    guard seconds.isFinite, seconds > 0, seconds <= 300,
      childSeconds.isFinite, childSeconds > 0, childSeconds <= 15
    else { throw ReleaseToolError.invalidBounds }
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    let stage = try DevelopmentStage(input)
    let empty = try NativeBundleInspector.preparationSnapshot(stage.root)
    guard empty.files.isEmpty, empty.links.isEmpty, empty.directories.count == 1,
      empty.directories[0].identity.user == getuid(),
      empty.directories[0].value.mode & 0o7022 == 0
    else { throw ReleaseToolError.unsafeInput }
    let roots = try [arm, intel, stage.root].map(Self.physical)
    for a in roots.indices {
      for b in roots.indices where a < b {
        guard roots[a] != roots[b], !roots[a].hasPrefix(roots[b] + "/"),
          !roots[b].hasPrefix(roots[a] + "/")
        else { throw ReleaseToolError.unsafeInput }
      }
    }
    let sources = try [
      DevelopmentBundleSource(root: roots[0], namedRoot: arm, architecture: .arm64),
      DevelopmentBundleSource(root: roots[1], namedRoot: intel, architecture: .intel),
    ]
    let estimate = try Self.pair(sources[0].observation, sources[1].observation)
    try Self.comparePlists(sources.map(\.root))
    var space = statfs()
    guard statfs(stage.parent, &space) == 0 else { throw ReleaseToolError.readFailed }
    let available = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_bsize))
    guard !available.overflow, available.partialValue >= UInt64(estimate * 2 + 256 * 1024 * 1024)
    else { throw ReleaseToolError.inputLimit }
    func check() throws {
      guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
      try stage.check()
      for source in sources { try source.check() }
    }
    try check()
    try observe?(.admitted)
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == empty else {
      throw ReleaseToolError.inputChanged
    }
    try await run(.ditto, [sources[0].root, stage.root], deadline: deadline, seconds: childSeconds)
    try check()
    let copied = try NativeBundleInspector.inspectWithCustody(stage.root, architecture: .arm64)
    guard try copied.observation.observationBytes() == sources[0].observation.observationBytes(),
      copied.custody.directories.last?.identity.inode == empty.directories[0].identity.inode,
      copied.custody.directories.last?.identity.device == empty.directories[0].identity.device
    else { throw ReleaseToolError.inputChanged }
    var checkpoint = copied.custody
    try observe?(.copied)
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint else {
      throw ReleaseToolError.inputChanged
    }
    let workRelative = "Contents/.universal-work"
    let work = stage.root + "/" + workRelative
    let mergedRelative = workRelative + "/merged"
    let merged = stage.root + "/" + mergedRelative
    guard mkdir(work, 0o700) == 0 else { throw ReleaseToolError.readFailed }
    func accept(_ files: Set<String>) throws {
      let next = try NativeBundleInspector.preparationSnapshot(stage.root)
      try DevelopmentTransition.check(
        checkpoint, next, mutableFiles: files, sealDirectories: [workRelative])
      checkpoint = next
    }
    try accept([mergedRelative])
    for (armNative, intelNative) in zip(
      sources[0].observation.natives, sources[1].observation.natives)
    {
      try check()
      guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint else {
        throw ReleaseToolError.inputChanged
      }
      var named = stat()
      guard lstat(merged, &named) == -1, errno == ENOENT else {
        throw ReleaseToolError.inputChanged
      }
      try await run(
        .lipo,
        [
          "-create", sources[0].root + "/" + armNative.path,
          sources[1].root + "/" + intelNative.path, "-output", merged,
        ],
        deadline: deadline, seconds: childSeconds)
      try check()
      try Self.mode(merged, mode: armNative.mode)
      let slices = (armNative.slices + intelNative.slices).sorted { $0.arch < $1.arch }
      guard try MachOInspector.inspect(merged) == slices else {
        throw ReleaseToolError.invalidMachO
      }
      try MachOInspector.verifyMerge(
        merged,
        inputs: [sources[0].root + "/" + armNative.path, sources[1].root + "/" + intelNative.path],
        seconds: min(60, try Self.remaining(deadline)))
      try accept([mergedRelative])
      try observe?(.mergeWritten)
      try check()
      guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint else {
        throw ReleaseToolError.inputChanged
      }
      guard rename(merged, stage.root + "/" + armNative.path) == 0 else {
        throw ReleaseToolError.readFailed
      }
      try accept([mergedRelative, armNative.path])
      try observe?(.roleReplaced)
      try check()
    }
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint,
      rmdir(work) == 0
    else { throw ReleaseToolError.inputChanged }
    try accept([mergedRelative])
    try observe?(.preparing)
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint else {
      throw ReleaseToolError.inputChanged
    }
    preparing = true
    let result = try await preparer.prepare(
      stage.root, architecture: .universal, seconds: try Self.remaining(deadline),
      childSeconds: childSeconds,
      checkInputs: {
        for source in sources { try source.check() }
        try observe?(.preparationCheckpoint)
        for source in sources { try source.check() }
      }, observe: nil)
    try check()
    try Self.checkMerged(result, sources: sources)
    let final = try NativeBundleInspector.preparationSnapshot(stage.root)
    try observe?(.verified)
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == final else {
      throw ReleaseToolError.inputChanged
    }
    return result
  }

  private func run(
    _ tool: AppleTool, _ arguments: [String], deadline: ContinuousClock.Instant,
    seconds: Double
  ) async throws {
    let owner = OwnedCommand()
    child = owner
    _ = try await owner.run(
      AppleCommand(tool, arguments: arguments),
      limits: ChildLimits(
        outputBytes: 64 * 1024, seconds: min(seconds, try Self.remaining(deadline))))
  }

  private static func remaining(_ deadline: ContinuousClock.Instant) throws -> Double {
    let duration = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    guard seconds > 0 else { throw ReleaseToolError.deadline }
    return seconds
  }

  private static func physical(_ path: String) throws -> String {
    guard !path.isEmpty, !path.utf8.contains(0), let result = realpath(path, nil) else {
      throw ReleaseToolError.unsafeInput
    }
    defer { free(result) }
    return String(cString: result)
  }

  private static func mode(_ path: String, mode: UInt16) throws {
    let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(fd) }
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      value.st_uid == getuid(), value.st_nlink == 1, value.st_size > 0,
      value.st_size <= 128 * 1024 * 1024, fchmod(fd, mode_t(mode)) == 0,
      lstat(path, &value) == 0
    else { throw ReleaseToolError.unsafeInput }
    var opened = stat()
    guard fstat(fd, &opened) == 0, FileIdentity(value) == FileIdentity(opened) else {
      throw ReleaseToolError.inputChanged
    }
  }

  private static var seals: Set<String> {
    Set(
      ([""] + BundleSparkle.containers).flatMap {
        DevelopmentTransition.seals(forContainer: $0).files
      })
  }

  private static func pair(_ arm: NativeBundleObservation, _ intel: NativeBundleObservation) throws
    -> Int64
  {
    guard arm.natives.allSatisfy({ $0.slices.count == 1 && $0.slices[0].arch == "arm64" }),
      intel.natives.allSatisfy({ $0.slices.count == 1 && $0.slices[0].arch == "x86_64" }),
      arm.files.map(\.path) == intel.files.map(\.path), arm.directories == intel.directories,
      arm.links == intel.links, arm.natives.map(\.path) == intel.natives.map(\.path)
    else { throw ReleaseToolError.invalidBundle }
    let natives = Set(arm.natives.map(\.path))
    let ignored = seals.union(["Contents/Info.plist"])
    var estimate: Int64 = 0
    for (a, i) in zip(arm.files, intel.files) {
      guard a.mode == i.mode else { throw ReleaseToolError.invalidBundle }
      if natives.contains(a.path) {
        let bytes = a.bytes + i.bytes + 1024 * 1024
        guard bytes <= 128 * 1024 * 1024 else { throw ReleaseToolError.inputLimit }
        estimate += bytes
      } else {
        guard ignored.contains(a.path) || a == i else { throw ReleaseToolError.digestMismatch }
        estimate += max(a.bytes, i.bytes)
      }
    }
    guard
      zip(arm.natives, intel.natives).allSatisfy({ $0.slices[0].filetype == $1.slices[0].filetype }
      ),
      estimate <= 512 * 1024 * 1024
    else { throw ReleaseToolError.inputLimit }
    return estimate
  }

  private static func comparePlists(_ roots: [String]) throws {
    let values = try roots.map { root in
      var info = try NativePropertyList.read(root + "/Contents/Info.plist", protection: .regular)
        .values
      for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"] {
        guard case .string(let text) = info[key], !text.isEmpty, text.utf8.count <= 256,
          !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw ReleaseToolError.invalidPropertyList }
      }
      info.removeValue(forKey: "LSMinimumSystemVersion")
      return info
    }
    guard values[0] == values[1] else { throw ReleaseToolError.invalidPropertyList }
  }

  private static func checkMerged(
    _ result: NativeBundleObservation, sources: [DevelopmentBundleSource]
  )
    throws
  {
    let arm = sources[0].observation
    let intel = sources[1].observation
    let paths = Set(arm.natives.map(\.path))
    let ignored = paths.union(seals).union(["Contents/Info.plist"])
    guard result.directories == arm.directories, result.links == arm.links,
      result.files.map(\.path) == arm.files.map(\.path),
      result.files.filter({ !ignored.contains($0.path) })
        == arm.files.filter({ !ignored.contains($0.path) }),
      zip(result.files, arm.files).allSatisfy({ $0.mode == $1.mode }),
      result.natives.map(\.path) == arm.natives.map(\.path)
    else { throw ReleaseToolError.inputChanged }
    for index in result.natives.indices {
      let expected = (arm.natives[index].slices + intel.natives[index].slices).sorted {
        $0.arch < $1.arch
      }
      guard result.natives[index].slices == expected else { throw ReleaseToolError.inputChanged }
    }
  }
}

enum UniversalMergePhase: Sendable {
  case admitted, copied, mergeWritten, roleReplaced, preparing, preparationCheckpoint, verified
}
