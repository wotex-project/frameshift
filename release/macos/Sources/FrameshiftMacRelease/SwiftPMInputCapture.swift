import Darwin
import Foundation

/// Existing ordered SDK regular-file facts, with the complete producer entry charge.
///
/// Empty packages contribute no SDK inputs. A qualified Sparkle target returns
/// 85 framework files and the private original ZIP; all directories and aliases
/// also count against the producer's shared inventory ceiling. These native
/// observations have no publication authority and are not source receipts.
public struct SwiftPMInputObservation: Sendable {
  public let files: [NativeBundleObservation.File]
  public var inventoryEntries: Int { files.isEmpty ? 0 : 152 }

  /// Retained bare JSON file array, without LF, below the 64 KiB CLI bound.
  public func observationBytes() throws -> Data {
    var output = NativeObservationWriter()
    try output.raw("[")
    for (index, file) in files.enumerated() {
      if index > 0 { try output.raw(",") }
      try output.raw(#"{"path":"#)
      try output.string(file.path)
      try output.raw(",\"mode\":\(file.mode),\"bytes\":\(file.bytes),\"sha256\":")
      try output.string(file.sha256)
      try output.raw("}")
    }
    try output.raw("]")
    guard output.bytes.count < 64 * 1024 else { throw ReleaseToolError.inputLimit }
    return output.bytes
  }
}

/// Admits the recorded root-package SDK actually selected by the native compiler.
///
/// SwiftPM evaluates the protected manifest in separate private scratch, never
/// in the evidence workspace. Strict bounded workspace versions six/seven must
/// bind the parsed binary target to the fixed root package, URL, checksum and
/// artifact path. Parent descriptors, manifest/state bytes and complete original
/// archive/cache custody bracket admission. No fetch, resolve, build, thinning,
/// signing or cache repair occurs here. Retained source/receipt joins and checks
/// around the compiler remain the producer's responsibility.
///
/// Success returns the existing ordered file facts and removes only completed
/// scratch. Failure retains scratch and any owned child monitor. Cancellation
/// and software deadlines refuse late success; blocked syscalls and descendant
/// termination are not claimed. Upstream authenticity, licenses, native runtime
/// compatibility and installed/production qualification remain separate gates.
public enum SwiftPMInputCapture {
  static let archivePath = "apps/macos/.build/sparkle/Sparkle-for-Swift-Package-Manager.zip"
  static let frameworkPath =
    "apps/macos/.build/artifacts/macos/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/"

  public static func capture(repository: String) async throws -> SwiftPMInputObservation {
    try await capture(repository: repository, work: nil, child: OwnedCommand())
  }

  static func capture(
    repository: String, work: String?, child: OwnedCommand, seconds: Double = 180,
    limits: ChildLimits? = nil,
    observe: (@Sendable (SwiftPMCapturePhase) throws -> Void)? = nil
  ) async throws -> SwiftPMInputObservation {
    guard !repository.isEmpty, !repository.utf8.contains(0) else {
      throw ReleaseToolError.unsafeInput
    }
    let budget = try CaptureBudget(seconds: seconds)
    try budget.check()
    guard let resolved = realpath(repository, nil) else { throw ReleaseToolError.readFailed }
    let root = String(cString: resolved)
    free(resolved)
    let parents = try CaptureParents(root: root)
    let packageRoot = root + "/apps/macos"
    let packagePath = packageRoot + "/Package.swift"
    var state = stat()
    if lstat(packagePath, &state) != 0 {
      guard errno == ENOENT else { throw ReleaseToolError.readFailed }
      try parents.check()
      try budget.check()
      return SwiftPMInputObservation(files: [])
    }
    try parents.hold(packagePath)
    let manifest = try CaptureLeaf(packagePath, maximum: 64 * 1024, budget: budget)
    let statePath = packageRoot + "/.build/workspace-state.json"
    let recordedState = try CaptureParents.optionalNamed(statePath)
    let recordedArchive = try CaptureParents.optionalNamed(root + "/" + archivePath)
    let scratch = work ?? "/tmp/frameshift-swiftpm-admission-\(UUID().uuidString)"
    guard scratch.hasPrefix("/"), !scratch.utf8.contains(0), mkdir(scratch, 0o700) == 0 else {
      throw ReleaseToolError.unsafeInput
    }
    let descriptor = open(scratch, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    defer { Darwin.close(descriptor) }
    let initial = try CaptureParents.named(scratch)
    func scratchIdentity() throws -> FileIdentity {
      var opened = stat()
      let named = try CaptureParents.named(scratch)
      guard fstat(descriptor, &opened) == 0, named == FileIdentity(opened),
        named.device == initial.device, named.inode == initial.inode,
        named.user == getuid(), named.mode & 0o7777 == 0o700,
        named.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else { throw ReleaseToolError.inputChanged }
      return named
    }
    _ = try scratchIdentity()
    let bounds =
      try limits
      ?? ChildLimits(
        outputBytes: 512 * 1024, seconds: budget.remaining(maximum: 60))
    guard bounds.duration <= .seconds(60), bounds.outputBytes <= 512 * 1024 else {
      throw ReleaseToolError.invalidBounds
    }
    let parsed = try await child.run(
      AppleCommand(
        .swift,
        arguments: [
          "package", "--package-path", packageRoot, "--scratch-path", scratch, "dump-package",
        ]), limits: bounds)
    try budget.check()
    let completedScratch = try scratchIdentity()
    try observe?(.manifestEvaluated)
    let binary = try binaryTarget(parsed.standardOutput, check: budget.check)
    var files: [NativeBundleObservation.File] = []
    var stateWitness: CaptureLeaf?
    var archiveWitness: FileIdentity?
    if binary {
      let archive = root + "/" + archivePath
      let framework = root + "/" + String(frameworkPath.dropLast())
      for path in [archive, framework, statePath] { try parents.hold(path) }
      let workspace = try CaptureLeaf(statePath, maximum: 128 * 1024, budget: budget)
      guard workspace.identity == recordedState else { throw ReleaseToolError.inputChanged }
      stateWitness = workspace
      try validateWorkspace(workspace.bytes, packageRoot: packageRoot, check: budget.check)
      let original = try CaptureParents.named(archive)
      guard original == recordedArchive else { throw ReleaseToolError.inputChanged }
      guard original.mode & 0o7777 == 0o600 else { throw ReleaseToolError.unsafeInput }
      archiveWitness = original
      let cached = try PinnedSparkleFramework.custody(
        framework: framework, seconds: budget.remaining(maximum: 120))
      try observe?(.workspaceChecked)
      let material = try await PinnedSparkleFramework.verify(
        archive: archive, framework: framework, work: nil, child: OwnedCommand(),
        seconds: budget.remaining(maximum: 120))
      try observe?(.materialChecked)
      guard
        try PinnedSparkleFramework.custody(
          framework: framework, seconds: budget.remaining(maximum: 120)) == cached
      else { throw ReleaseToolError.inputChanged }
      try observe?(.cacheRechecked)
      files = material.files.map {
        .init(path: frameworkPath + $0.path, mode: $0.mode, bytes: $0.bytes, sha256: $0.sha256)
      }
      files.append(
        .init(
          path: archivePath, mode: 0o600, bytes: PinnedSparkleArchive.bytes,
          sha256: PinnedSparkleArchive.sha256))
    }
    try manifest.check(budget: budget)
    try stateWitness?.check(budget: budget)
    if let archiveWitness {
      guard try CaptureParents.named(root + "/" + archivePath) == archiveWitness else {
        throw ReleaseToolError.inputChanged
      }
    }
    try parents.check()
    guard try scratchIdentity() == completedScratch else { throw ReleaseToolError.inputChanged }
    try budget.check()
    let result = SwiftPMInputObservation(files: files)
    _ = try result.observationBytes()
    try budget.check()
    try FileManager.default.removeItem(atPath: scratch)
    return result
  }

  static func binaryTarget(_ bytes: Data, check: @escaping () throws -> Void) throws -> Bool {
    let manifest = try SwiftPMJSON.read(bytes, maximum: 512 * 1024, check: check).object()
    guard let targets = manifest["targets"] else { throw ReleaseToolError.invalidSwiftPMInputs }
    let binary = try targets.array().filter {
      let target = try $0.object()
      guard case .string(let type) = target["type"] else {
        throw ReleaseToolError.invalidSwiftPMInputs
      }
      return type == "binary"
    }
    guard !binary.isEmpty else { return false }
    guard binary.count == 1 else { throw ReleaseToolError.invalidSwiftPMInputs }
    let target = try binary[0].object()
    guard target["name"] == .string("Sparkle"), target["url"] == .string(PinnedSparkleArchive.url),
      target["checksum"] == .string(PinnedSparkleArchive.sha256)
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    return true
  }

  static func validateWorkspace(
    _ bytes: Data, packageRoot: String, check: @escaping () throws -> Void
  )
    throws
  {
    let state = try SwiftPMJSON.read(bytes, maximum: 128 * 1024, check: check).object(keys: [
      "version", "object",
    ])
    guard let version = state["version"], [.number("6"), .number("7")].contains(version),
      let container = state["object"]
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    let seven = version == .number("7")
    let object = try container.object(
      keys: seven ? ["artifacts", "dependencies", "prebuilts"] : ["artifacts", "dependencies"])
    guard object["dependencies"] == .array([]), !seven || object["prebuilts"] == .array([]),
      let artifacts = object["artifacts"]
    else { throw ReleaseToolError.invalidSwiftPMInputs }
    let members = try artifacts.array()
    guard members.count == 1 else { throw ReleaseToolError.invalidSwiftPMInputs }
    let artifact = try members[0].object(keys: [
      "kind", "packageRef", "path", "source", "targetName",
    ])
    guard artifact["targetName"] == .string("Sparkle"),
      artifact["kind"] == (seven ? .object(["xcframework": .object([:])]) : .string("xcframework")),
      artifact["packageRef"]
        == .object([
          "identity": .string("macos"), "kind": .string("root"), "location": .string(packageRoot),
          "name": .string("macos"),
        ]),
      artifact["source"]
        == .object([
          "checksum": .string(PinnedSparkleArchive.sha256), "type": .string("remote"),
          "url": .string(PinnedSparkleArchive.url),
        ]),
      artifact["path"]
        == .string(packageRoot + "/.build/artifacts/macos/Sparkle/Sparkle.xcframework")
    else { throw ReleaseToolError.invalidSwiftPMInputs }
  }
}

enum SwiftPMCapturePhase: Sendable {
  case manifestEvaluated, workspaceChecked, materialChecked, cacheRechecked
}

private struct CaptureBudget {
  let deadline: ContinuousClock.Instant
  init(seconds: Double) throws {
    guard seconds.isFinite, seconds > 0, seconds <= 180 else {
      throw ReleaseToolError.invalidBounds
    }
    deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(seconds * 1_000_000_000)))
  }
  func check() throws {
    guard !Task.isCancelled else { throw ReleaseToolError.admissionCancelled }
    guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
  }
  func remaining(maximum: Double) throws -> Double {
    try check()
    let duration = ContinuousClock.now.duration(to: deadline).components
    return min(maximum, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
  }
}

private struct CaptureLeaf {
  let path: String
  let maximum: Int64
  let bytes: Data
  let identity: FileIdentity
  init(_ path: String, maximum: Int64, budget: CaptureBudget) throws {
    self.path = path
    self.maximum = maximum
    identity = try CaptureParents.named(path)
    bytes = try AdmittedFile.read(
      path,
      policy: FileReadPolicy(
        maximum: maximum, protection: .protected, singleLink: true,
        seconds: budget.remaining(maximum: 60)))
    guard try CaptureParents.named(path) == identity else { throw ReleaseToolError.inputChanged }
  }
  func check(budget: CaptureBudget) throws {
    guard try CaptureParents.named(path) == identity,
      try AdmittedFile.read(
        path,
        policy: FileReadPolicy(
          maximum: maximum, protection: .protected, singleLink: true,
          seconds: budget.remaining(maximum: 60))) == bytes,
      try CaptureParents.named(path) == identity
    else { throw ReleaseToolError.inputChanged }
  }
}

/// Retained named/open parent identity; write times intentionally are not stable fields.
private final class CaptureParents {
  let root: String
  var directories: [String: (Int32, FileIdentity)] = [:]
  init(root: String) throws {
    self.root = root
    try admit(root)
  }
  deinit { for (descriptor, _) in directories.values { Darwin.close(descriptor) } }
  static func named(_ path: String) throws -> FileIdentity {
    var state = stat()
    guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
    return FileIdentity(state)
  }
  static func optionalNamed(_ path: String) throws -> FileIdentity? {
    var state = stat()
    if lstat(path, &state) == 0 { return FileIdentity(state) }
    guard errno == ENOENT else { throw ReleaseToolError.readFailed }
    return nil
  }
  func hold(_ path: String) throws {
    guard path.hasPrefix(root + "/") else { throw ReleaseToolError.unsafeInput }
    let parts = String(path.dropFirst(root.count + 1)).split(
      separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 24, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw ReleaseToolError.unsafeInput
    }
    var directory = root
    for part in parts.dropLast() {
      directory += "/" + part
      if directories[directory] == nil { try admit(directory) }
    }
    try check()
  }
  private func admit(_ path: String) throws {
    let named = try Self.named(path)
    guard named.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), named.user == getuid(),
      named.mode & 0o7022 == 0
    else { throw ReleaseToolError.unsafeInput }
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    var owned = true
    defer { if owned { Darwin.close(descriptor) } }
    var state = stat()
    guard fstat(descriptor, &state) == 0, FileIdentity(state) == named,
      try Self.named(path) == named
    else { throw ReleaseToolError.inputChanged }
    directories[path] = (descriptor, named)
    owned = false
  }
  func check() throws {
    for (path, (descriptor, before)) in directories {
      let named = try Self.named(path)
      var state = stat()
      guard fstat(descriptor, &state) == 0, named == FileIdentity(state),
        named.device == before.device, named.inode == before.inode, named.mode == before.mode,
        named.user == before.user, named.group == before.group
      else { throw ReleaseToolError.inputChanged }
    }
  }
}
