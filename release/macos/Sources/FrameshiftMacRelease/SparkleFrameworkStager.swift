import Darwin
import Foundation

/// Original pinned material and private single-CPU derivation facts before sealing.
///
/// The source retains both CPU slices; the derived tree retains all common bytes,
/// modes and fixed aliases. This ordered schema-one native observation has no
/// publication authority and is not a portable source receipt or final app seal.
public struct SparkleFrameworkDerivation: Sendable {
  public let architecture: NativeBundleArchitecture
  public let source: PinnedSparkleFrameworkObservation
  public let derived: PinnedSparkleFrameworkObservation

  /// Existing derivation JSON field/array bytes without LF; bounded below 64 KiB.
  public func observationBytes() throws -> Data {
    var output = NativeObservationWriter()
    try output.raw(#"{"schemaVersion":1,"publicationAuthority":"none","archive":"#)
    try PinnedSparkleFrameworkObservation.writeArchive(to: &output)
    try output.raw(#","architecture":"#)
    try output.string(architecture.rawValue)
    try output.raw(#","source":"#)
    try source.writeContent(to: &output)
    try output.raw(#","derived":"#)
    try derived.writeContent(to: &output)
    try output.raw(#","native":"#)
    try PinnedSparkleFrameworkObservation.writeNative(derived.native, to: &output)
    try output.raw("}")
    guard output.bytes.count < 64 * 1024 else { throw ReleaseToolError.inputLimit }
    return output.bytes
  }
}

/// One-shot derivation of pinned Sparkle into an unpublished private app stage.
///
/// `stage(archive:app:architecture:)` accepts only arm64 or x86_64 and a real,
/// current-user `Frameshift.app` within a mode-0700 `.package.` directory. The
/// app and Contents must be protected current-user directories; Frameworks
/// must be absent. Original ZIP admission and closing custody use the same
/// bounded reader as `PinnedSparkleFramework.verify(archive:framework:)`.
///
/// An owned `ditto` copies the original framework. Five owned `lipo -thin`
/// commands write into an exclusive private work directory inside Frameworks,
/// then checked files replace only their corresponding copied native roles.
/// Complete app checkpoints preserve all other bytes, aliases and identities;
/// native CPU, type, minimum, imports and search paths must equal the original
/// selected slices. The shared compiler cache is neither read nor changed.
///
/// The two-minute monotonic job budget and 15-second/64-KiB-per-pipe child bounds
/// do not preempt blocked filesystem calls. No signing, publication, accepted
/// output replacement, cache repair, network or SDK execution occurs. On refusal
/// the app and incomplete scratch remain. Retain this actor and call
/// `retainUntilExitAfterRefusal()` before terminating a one-shot CLI: the exact
/// last direct child is observed without retry, additional signal or promotion.
public actor SparkleFrameworkStager {
  private var attempted = false
  private var child: OwnedCommand?
  private var stage: DevelopmentStage?
  private var checkpoint: BundleSnapshot?
  private var budget: SparkleBudget?

  public init() {}

  public func stage(archive: String, app: String, architecture: NativeBundleArchitecture)
    async throws -> SparkleFrameworkDerivation
  {
    try await stage(archive: archive, app: app, architecture: architecture, observe: nil)
  }

  public func childStatus() async -> OwnedChildStatus {
    guard let child else { return .notStarted }
    return await child.status()
  }

  /// Read-only retention after refusal; unknown custody may keep a CLI alive indefinitely.
  public func retainUntilExitAfterRefusal() async -> OwnedChildStatus {
    guard let child else { return .notStarted }
    return await child.retainUntilExitAfterRefusal()
  }

  func stage(
    archive: String, app: String, architecture: NativeBundleArchitecture,
    seconds: Double = 120, childSeconds: Double = 15, work: String? = nil,
    observe: (@Sendable (SparkleDerivationPhase) throws -> Void)?
  ) async throws -> SparkleFrameworkDerivation {
    guard !attempted else { throw ReleaseToolError.childAlreadyStarted }
    attempted = true
    guard architecture != .universal else { throw ReleaseToolError.invalidBundle }
    guard childSeconds.isFinite, childSeconds > 0, childSeconds <= 15 else {
      throw ReleaseToolError.invalidBounds
    }
    let initialBudget = try SparkleBudget(seconds: seconds)
    let privateStage = try DevelopmentStage(app)
    stage = privateStage
    budget = initialBudget
    for path in [privateStage.root, privateStage.root + "/Contents"] {
      let identity = try SparkleInventory.named(path)
      guard identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), identity.user == getuid(),
        identity.mode & 0o7022 == 0, identity.mode & 0o400 != 0
      else { throw ReleaseToolError.unsafeInput }
    }
    var named = stat()
    guard lstat(privateStage.root + "/Contents/Frameworks", &named) == -1, errno == ENOENT else {
      throw ReleaseToolError.unsafeInput
    }
    checkpoint = try NativeBundleInspector.preparationSnapshot(privateStage.root)
    try observe?(.admittedStage)
    try checkCheckpoint()
    let extraction = OwnedCommand()
    child = extraction
    let result = try await PinnedSparkleFramework.withOriginal(
      archive: archive, framework: nil, work: work, child: extraction,
      limits: ChildLimits(seconds: min(childSeconds, try initialBudget.fileSeconds())),
      seconds: try initialBudget.remainingSeconds()
    ) { [self] originalPath, original, deadline in
      try await derive(
        originalPath, original: original, architecture: architecture,
        deadline: deadline, childSeconds: childSeconds, observe: observe)
    }
    try checkCheckpoint()
    let workRelative = "Contents/Frameworks/.sparkle-work"
    guard rmdir(privateStage.root + "/" + workRelative) == 0 else {
      throw ReleaseToolError.inputChanged
    }
    try acceptMutation(files: [workRelative + "/thin"], directories: [workRelative])
    try checkCheckpoint()
    return result
  }

  private func derive(
    _ originalPath: String, original: PinnedSparkleFrameworkObservation,
    architecture: NativeBundleArchitecture, deadline: ContinuousClock.Instant,
    childSeconds: Double, observe: (@Sendable (SparkleDerivationPhase) throws -> Void)?
  ) async throws -> SparkleFrameworkDerivation {
    guard let stage, let before = checkpoint else { throw ReleaseToolError.unsafeInput }
    // Use the earlier outer deadline; extraction cannot restart the producer budget.
    guard let outerBudget = budget else { throw ReleaseToolError.unsafeInput }
    budget = SparkleBudget(deadline: min(deadline, outerBudget.deadline))
    try checkCheckpoint()
    let frameworks = stage.root + "/Contents/Frameworks"
    let workRelative = "Contents/Frameworks/.sparkle-work"
    let work = stage.root + "/" + workRelative
    guard mkdir(frameworks, 0o755) == 0, mkdir(work, 0o700) == 0 else {
      throw ReleaseToolError.readFailed
    }
    try check()
    let created = try NativeBundleInspector.preparationSnapshot(stage.root)
    try DevelopmentTransition.check(
      before, created, mutableFiles: [workRelative + "/thin"],
      sealDirectories: ["Contents/Frameworks", workRelative])
    checkpoint = created
    try await run(
      .ditto, [originalPath, stage.root + "/" + BundleSparkle.root], seconds: childSeconds)
    try check()
    let copied = try NativeBundleInspector.preparationSnapshot(stage.root)
    try preserveOutsideFramework(before: created, after: copied)
    let target = stage.root + "/" + BundleSparkle.root
    let expected = try scan(target)
    guard expected.files == original.files, expected.directories == original.directories,
      expected.links == original.links
    else { throw ReleaseToolError.digestMismatch }
    checkpoint = copied
    try observe?(.copied)
    try checkCheckpoint()
    var native: [PinnedSparkleFrameworkObservation.Native] = []
    for member in original.native {
      let output = work + "/thin"
      let selected = member.slices.filter { $0.arch == architecture.rawValue }
      guard selected.count == 1,
        let mode = original.files.first(where: { $0.path == member.path })?.mode
      else { throw ReleaseToolError.invalidMachO }
      var existing = stat()
      guard lstat(output, &existing) == -1, errno == ENOENT else {
        throw ReleaseToolError.inputChanged
      }
      try checkCheckpoint()
      try await run(
        .lipo,
        ["-thin", architecture.rawValue, originalPath + "/" + member.path, "-output", output],
        seconds: childSeconds)
      try check()
      try prepareOutput(output, mode: mode, expected: selected)
      try acceptMutation(files: [workRelative + "/thin"], directories: [workRelative])
      try observe?(.thinWritten)
      try checkCheckpoint()
      guard rename(output, target + "/" + member.path) == 0 else {
        throw ReleaseToolError.readFailed
      }
      try acceptMutation(
        files: [workRelative + "/thin", BundleSparkle.root + "/" + member.path],
        directories: [workRelative])
      let actual = try MachOInspector.inspect(
        target + "/" + member.path, seconds: try fileSeconds(), observe: nil)
      guard actual == selected else { throw ReleaseToolError.inputChanged }
      native.append(.init(path: member.path, slices: actual))
      try observe?(.roleReplaced)
      try checkCheckpoint()
    }
    let final = try scan(target)
    let nativePaths = Set(original.native.map(\.path))
    guard final.directories == original.directories, final.links == original.links,
      final.files.filter({ !nativePaths.contains($0.path) })
        == original.files.filter({ !nativePaths.contains($0.path) }),
      final.files.count == original.files.count,
      zip(final.files, original.files).allSatisfy({ $0.path == $1.path && $0.mode == $1.mode })
    else { throw ReleaseToolError.inputChanged }
    let derived = PinnedSparkleFrameworkObservation(
      files: final.files, directories: final.directories, links: final.links, native: native)
    let result = SparkleFrameworkDerivation(
      architecture: architecture, source: original, derived: derived)
    _ = try result.observationBytes()
    try observe?(.derived)
    try checkCheckpoint()
    return result
  }

  private func prepareOutput(_ path: String, mode: mode_t, expected: [MachOSlice]) throws {
    let descriptor = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(descriptor) }
    var state = stat()
    guard fstat(descriptor, &state) == 0 else { throw ReleaseToolError.readFailed }
    let before = FileIdentity(state)
    guard before.isRegular, before.user == getuid(), before.links == 1,
      before.size > 0, before.size <= 16 * 1024 * 1024, before.mode & 0o7022 == 0,
      try SparkleInventory.named(path) == before
    else { throw ReleaseToolError.unsafeInput }
    guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0,
      fstat(descriptor, &state) == 0, try SparkleInventory.named(path) == FileIdentity(state),
      try MachOInspector.inspect(path, seconds: try fileSeconds(), observe: nil) == expected,
      try SparkleInventory.named(path) == FileIdentity(state)
    else { throw ReleaseToolError.inputChanged }
  }

  private func preserveOutsideFramework(before: BundleSnapshot, after: BundleSnapshot) throws {
    func outside(_ snapshot: BundleSnapshot) -> BundleSnapshot {
      var result = snapshot
      let prefix = BundleSparkle.root + "/"
      result.files.removeAll { $0.value.path.hasPrefix(prefix) }
      result.links.removeAll { $0.value.path.hasPrefix(prefix) }
      result.directories.removeAll {
        $0.value.path == BundleSparkle.root || $0.value.path.hasPrefix(prefix)
      }
      return result
    }
    try DevelopmentTransition.check(
      outside(before), outside(after), mutableFiles: [BundleSparkle.root + "/copy"],
      sealDirectories: [])
  }

  private func acceptMutation(files: Set<String>, directories: Set<String>) throws {
    try check()
    guard let stage, let before = checkpoint else { throw ReleaseToolError.unsafeInput }
    let after = try NativeBundleInspector.preparationSnapshot(stage.root)
    try DevelopmentTransition.check(
      before, after, mutableFiles: files, sealDirectories: directories)
    checkpoint = after
    try check()
  }

  private func checkCheckpoint() throws {
    try check()
    guard let stage, let checkpoint,
      try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint
    else { throw ReleaseToolError.inputChanged }
    try check()
  }

  private func check() throws {
    guard let stage, let budget else { throw ReleaseToolError.unsafeInput }
    try budget.check()
    try stage.check()
  }

  private func fileSeconds() throws -> Double {
    try check()
    return try budget!.fileSeconds()
  }

  private func scan(_ root: String) throws -> SparkleSnapshot {
    try check()
    return try SparkleInventory(root: root, budget: budget!).scan()
  }

  private func run(_ tool: AppleTool, _ arguments: [String], seconds: Double) async throws {
    try checkCheckpoint()
    let owned = OwnedCommand()
    child = owned
    _ = try await owned.run(
      AppleCommand(tool, arguments: arguments),
      limits: ChildLimits(seconds: min(seconds, try fileSeconds())))
    try check()
  }
}

enum SparkleDerivationPhase: Sendable {
  case admittedStage, copied, thinWritten, roleReplaced, derived
}
