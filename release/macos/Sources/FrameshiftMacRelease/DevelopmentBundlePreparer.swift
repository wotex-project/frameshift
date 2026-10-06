import Darwin
import Foundation

/// One-shot preparation of an unpublished, caller-owned development app stage.
///
/// `prepare(_:architecture:)` admits only `Frameshift.app` inside a real,
/// current-user, mode-0700 `.package.` directory with an alphanumeric suffix.
/// It removes canonical unused search paths below the selected Swift
/// toolchain's `usr/lib`, derives the plist minimum from actual native slices,
/// and signs leaves, pinned updater containers and the outer app in order.
/// Deployment headers and imported library names are never rewritten.
///
/// Complete custody checkpoints bracket each fixed Apple command. Only its
/// named code, plist or fixed seal paths may change; unrelated bytes, aliases
/// and namespace changes refuse. The final bounded closure and strict
/// all-architecture signatures must pass before an observation is returned.
/// This is an ad-hoc build-time producer, with publication authority none.
/// It does not publish, replace an accepted app, qualify installed execution,
/// remove a failed stage or make an SDK-bearing Swift executable admissible.
///
/// The job has a five-minute processing budget, at most 512 children, and a
/// 15-second/64-KiB-per-pipe limit per child. Software budgets cannot interrupt
/// an already blocked filesystem or Security call. After refusal, the caller
/// must keep this object and its private stage alive and use
/// `retainUntilExitAfterRefusal()` before terminating a one-shot tool. That
/// read-only wait never signals, retries, promotes output or proves descendant
/// exit; an unconfirmed direct-child status can keep the tool alive indefinitely.
public actor DevelopmentBundlePreparer {
  private var attempted = false
  private var child: OwnedCommand?
  private var commands = 0

  public init() {}

  public func prepare(_ input: String, architecture: NativeBundleArchitecture) async throws
    -> NativeBundleObservation
  {
    try await prepare(input, architecture: architecture, observe: nil)
  }

  /// Retains the exact last child without changing the refused job's outcome.
  public func retainUntilExitAfterRefusal() async -> OwnedChildStatus {
    guard let child else { return .notStarted }
    return await child.retainUntilExitAfterRefusal()
  }

  /// Observes the current direct child; it does not signal or restart work.
  public func childStatus() async -> OwnedChildStatus {
    guard let child else { return .notStarted }
    return await child.status()
  }

  func prepare(
    _ input: String, architecture: NativeBundleArchitecture,
    seconds: Double = 300, childSeconds: Double = 15,
    observe: (@Sendable (DevelopmentPreparationPhase) throws -> Void)?
  ) async throws -> NativeBundleObservation {
    guard !attempted else { throw ReleaseToolError.childAlreadyStarted }
    attempted = true
    guard seconds.isFinite, seconds > 0, seconds <= 300,
      childSeconds.isFinite, childSeconds > 0, childSeconds <= 15
    else { throw ReleaseToolError.invalidBounds }
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    let stage = try DevelopmentStage(input)
    func check() throws {
      guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
      try stage.check()
    }
    try check()
    let compilerOutput = try await run(
      .xcrun, ["--find", "swift"], deadline: deadline, seconds: childSeconds)
    try check()
    guard let compiler = String(data: compilerOutput.standardOutput, encoding: .utf8) else {
      throw ReleaseToolError.invalidCommand
    }
    let selected = compiler.trimmingCharacters(in: .whitespacesAndNewlines)
    guard selected.hasPrefix("/"), selected.hasSuffix("/usr/bin/swift"),
      !selected.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      URL(fileURLWithPath: selected).standardizedFileURL.path == selected
    else { throw ReleaseToolError.invalidCommand }
    let library = String(selected.dropLast("bin/swift".count)) + "lib/"
    guard library != "/usr/lib/", !library.hasPrefix("/System/Library/") else {
      throw ReleaseToolError.invalidCommand
    }
    let initial = try NativeBundleInspector.inspectWithCustody(
      stage.root, architecture: architecture, preparationToolchainLibrary: library)
    var checkpoint = initial.custody
    let infoPath = "Contents/Info.plist"
    let initialInfo = try NativePropertyList.read(
      stage.root + "/" + infoPath, protection: .regular
    ).values
    try observe?(.inventoried)
    try check()

    for native in initial.observation.natives {
      let removable = Array(
        Set(native.slices.flatMap(\.rpaths).filter { $0.hasPrefix(library) })
      ).sorted()
      guard !removable.isEmpty else { continue }
      let seals = DevelopmentTransition.seals(forNative: native.path)
      checkpoint = try await mutation(
        .codesign, ["--remove-signature", stage.root + "/" + native.path],
        files: Set([native.path]).union(seals.files), sealDirectories: seals.directories,
        stage: stage, before: checkpoint, deadline: deadline, seconds: childSeconds)
      for path in removable {
        checkpoint = try await mutation(
          .installNameTool, ["-delete_rpath", path, stage.root + "/" + native.path],
          files: [native.path], stage: stage, before: checkpoint, deadline: deadline,
          seconds: childSeconds)
      }
    }
    try observe?(.pathsPrepared)
    checkpoint = try await mutation(
      .plutil,
      [
        "-replace", "LSMinimumSystemVersion", "-string", initial.observation.nativeMinimum,
        stage.root + "/" + infoPath,
      ], files: [infoPath], stage: stage, before: checkpoint, deadline: deadline,
      seconds: childSeconds)
    var expectedInfo = initialInfo
    expectedInfo["LSMinimumSystemVersion"] = .string(initial.observation.nativeMinimum)
    guard
      try NativePropertyList.read(stage.root + "/" + infoPath, protection: .regular).values
        == expectedInfo
    else { throw ReleaseToolError.inputChanged }
    let prepared = try NativeBundleInspector.inspectWithCustody(
      stage.root, architecture: architecture)
    guard prepared.custody == checkpoint else { throw ReleaseToolError.inputChanged }
    try DevelopmentTransition.checkNative(
      initial.observation.natives, prepared.observation.natives, removing: library)
    try observe?(.metadataPrepared)
    try check()

    for native in prepared.observation.natives where native.path != "Contents/MacOS/Frameshift" {
      let seals = DevelopmentTransition.seals(forNative: native.path)
      checkpoint = try await mutation(
        .codesign, ["--force", "--sign", "-", "--timestamp=none", stage.root + "/" + native.path],
        files: Set([native.path]).union(seals.files), sealDirectories: seals.directories,
        stage: stage, before: checkpoint, deadline: deadline, seconds: childSeconds)
    }
    if prepared.observation.links != nil {
      for container in BundleSparkle.containers {
        let seals = DevelopmentTransition.seals(forContainer: container)
        let native = DevelopmentTransition.main(forContainer: container)
        checkpoint = try await mutation(
          .codesign, ["--force", "--sign", "-", "--timestamp=none", stage.root + "/" + container],
          files: Set([native]).union(seals.files), sealDirectories: seals.directories, stage: stage,
          before: checkpoint, deadline: deadline, seconds: childSeconds)
      }
    }
    let seals = DevelopmentTransition.seals(forContainer: "")
    checkpoint = try await mutation(
      .codesign, ["--force", "--sign", "-", "--timestamp=none", stage.root],
      files: Set(["Contents/MacOS/Frameshift"]).union(seals.files),
      sealDirectories: seals.directories, stage: stage, before: checkpoint, deadline: deadline,
      seconds: childSeconds)
    try observe?(.sealed)
    try check()
    let result = try NativeSignatureVerifier.verifyDevelopmentBundle(
      stage.root, architecture: architecture)
    try DevelopmentTransition.checkNative(
      prepared.observation.natives, result.natives, removing: nil)
    try observe?(.verified)
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == checkpoint else {
      throw ReleaseToolError.inputChanged
    }
    try check()
    return result
  }

  private func mutation(
    _ tool: AppleTool, _ arguments: [String], files: Set<String>,
    sealDirectories: Set<String> = [], stage: DevelopmentStage, before: BundleSnapshot,
    deadline: ContinuousClock.Instant, seconds: Double
  ) async throws -> BundleSnapshot {
    func check() throws {
      guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
      try stage.check()
    }
    try check()
    guard try NativeBundleInspector.preparationSnapshot(stage.root) == before else {
      throw ReleaseToolError.inputChanged
    }
    _ = try await run(tool, arguments, deadline: deadline, seconds: seconds)
    try check()
    let next = try NativeBundleInspector.preparationSnapshot(stage.root)
    try DevelopmentTransition.check(
      before, next, mutableFiles: files, sealDirectories: sealDirectories)
    try check()
    return next
  }

  private func run(
    _ tool: AppleTool, _ arguments: [String], deadline: ContinuousClock.Instant, seconds: Double
  ) async throws -> OwnedCommandOutput {
    guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let available = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    guard available > 0 else { throw ReleaseToolError.deadline }
    guard commands < 512 else { throw ReleaseToolError.inputLimit }
    commands += 1
    let owned = OwnedCommand()
    child = owned
    return try await owned.run(
      AppleCommand(tool, arguments: arguments),
      limits: ChildLimits(outputBytes: 64 * 1024, seconds: min(seconds, available)))
  }
}

enum DevelopmentPreparationPhase: Sendable {
  case inventoried, pathsPrepared, metadataPrepared, sealed, verified
}

private final class DevelopmentStage {
  let root: String
  let parent: String
  let descriptor: Int32
  let identity: FileIdentity
  init(_ input: String) throws {
    guard !input.isEmpty, !input.utf8.contains(0) else { throw ReleaseToolError.unsafeInput }
    let url = URL(fileURLWithPath: input).standardizedFileURL
    root = url.path
    parent = url.deletingLastPathComponent().path
    let name = URL(fileURLWithPath: parent).lastPathComponent
    let suffix = name.dropFirst(".package.".count)
    guard url.lastPathComponent == "Frameshift.app",
      name.hasPrefix(".package."), !suffix.isEmpty,
      suffix.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      })
    else { throw ReleaseToolError.unsafeInput }
    var named = stat()
    guard lstat(parent, &named) == 0, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      named.st_uid == getuid(), named.st_mode & 0o7777 == 0o700
    else { throw ReleaseToolError.unsafeInput }
    identity = FileIdentity(named)
    descriptor = open(parent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    do { try check() } catch {
      Darwin.close(descriptor)
      throw error
    }
  }
  deinit { Darwin.close(descriptor) }
  func check() throws {
    var named = stat()
    var opened = stat()
    guard lstat(parent, &named) == 0, fstat(descriptor, &opened) == 0,
      FileIdentity(named) == identity, FileIdentity(opened) == identity
    else { throw ReleaseToolError.inputChanged }
  }
}

private enum DevelopmentTransition {
  static func main(forContainer container: String) -> String {
    switch container {
    case "": "Contents/MacOS/Frameshift"
    case BundleSparkle.root: BundleSparkle.root + "/Versions/B/Sparkle"
    default:
      container + "/Contents/MacOS/"
        + URL(fileURLWithPath: container).deletingPathExtension().lastPathComponent
    }
  }
  static func seals(forContainer container: String) -> (
    files: Set<String>, directories: Set<String>
  ) {
    let directory =
      container == BundleSparkle.root
      ? container + "/Versions/B/_CodeSignature"
      : (container.isEmpty ? "" : container + "/") + "Contents/_CodeSignature"
    return ([directory + "/CodeResources"], [directory])
  }
  static func seals(forNative native: String) -> (files: Set<String>, directories: Set<String>) {
    for container in [""] + BundleSparkle.containers where main(forContainer: container) == native {
      return seals(forContainer: container)
    }
    return ([], [])
  }
  static func check(
    _ before: BundleSnapshot, _ after: BundleSnapshot,
    mutableFiles: Set<String>, sealDirectories: Set<String>
  ) throws {
    guard before.links == after.links else { throw ReleaseToolError.inputChanged }
    let oldFiles = Dictionary(uniqueKeysWithValues: before.files.map { ($0.value.path, $0) })
    let newFiles = Dictionary(uniqueKeysWithValues: after.files.map { ($0.value.path, $0) })
    for path in Set(oldFiles.keys).union(newFiles.keys) {
      if mutableFiles.contains(path) {
        if let old = oldFiles[path], let new = newFiles[path] {
          guard old.value.mode == new.value.mode, old.identity.user == new.identity.user,
            old.identity.group == new.identity.group, old.native == new.native
          else { throw ReleaseToolError.inputChanged }
        } else {
          guard
            sealDirectories.contains(path.split(separator: "/").dropLast().joined(separator: "/"))
          else { throw ReleaseToolError.inputChanged }
        }
      } else if oldFiles[path] != newFiles[path] {
        throw ReleaseToolError.inputChanged
      }
    }
    let oldDirs = Dictionary(uniqueKeysWithValues: before.directories.map { ($0.value.path, $0) })
    let newDirs = Dictionary(uniqueKeysWithValues: after.directories.map { ($0.value.path, $0) })
    for path in Set(oldDirs.keys).union(newDirs.keys) {
      guard let old = oldDirs[path], let new = newDirs[path] else {
        guard sealDirectories.contains(path) else { throw ReleaseToolError.inputChanged }
        continue
      }
      guard old.value == new.value, old.identity.device == new.identity.device,
        old.identity.inode == new.identity.inode, old.identity.user == new.identity.user,
        old.identity.group == new.identity.group
      else { throw ReleaseToolError.inputChanged }
      let ancestor = mutableFiles.contains { path.isEmpty || $0.hasPrefix(path + "/") }
      guard ancestor || old.identity == new.identity else { throw ReleaseToolError.inputChanged }
    }
  }
  static func checkNative(
    _ before: [NativeBundleObservation.Native], _ after: [NativeBundleObservation.Native],
    removing library: String?
  ) throws {
    guard before.count == after.count else { throw ReleaseToolError.inputChanged }
    for (old, new) in zip(before, after) {
      guard old.path == new.path, old.mode == new.mode, old.slices.count == new.slices.count else {
        throw ReleaseToolError.inputChanged
      }
      for (left, right) in zip(old.slices, new.slices) {
        let rpaths = left.rpaths.filter { !(library.map($0.hasPrefix) ?? false) }
        guard left.arch == right.arch, left.filetype == right.filetype,
          left.minimum == right.minimum, left.dependencies == right.dependencies,
          rpaths == right.rpaths
        else { throw ReleaseToolError.inputChanged }
      }
    }
  }
}
