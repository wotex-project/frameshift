import Darwin
import Foundation

/// Fixed native executables used by Mac release producers; never a shell interpreter.
public enum AppleTool: String, Sendable {
  case codesign = "/usr/bin/codesign"
  case ditto = "/usr/bin/ditto"
  case lipo = "/usr/bin/lipo"
  case hdiutil = "/usr/bin/hdiutil"
  case xcrun = "/usr/bin/xcrun"
  case swift = "/usr/bin/swift"
  case unzip = "/usr/bin/unzip"
  case installNameTool = "/usr/bin/install_name_tool"
  case plutil = "/usr/bin/plutil"
}

/// A bounded argument array for one selected Apple tool.
///
/// Consumers own argument semantics, source/stage admission and selected SDK
/// identity. No command string is interpreted. Child environment retains only
/// Apple/user temporary-directory context, never DYLD or language-runtime hooks.
public struct AppleCommand: Sendable {
  let executable: String
  let arguments: [String]
  let workingDirectory: String?

  public init(_ tool: AppleTool, arguments: [String], workingDirectory: String? = nil) throws {
    try self.init(
      executable: tool.rawValue, arguments: arguments, workingDirectory: workingDirectory)
  }

  init(executable: String, arguments: [String], workingDirectory: String? = nil) throws {
    guard executable.hasPrefix("/"), Self.valid(executable), arguments.count <= 256,
      arguments.allSatisfy(Self.valid), arguments.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024,
      workingDirectory.map({ $0.hasPrefix("/") && Self.valid($0) }) ?? true
    else { throw ReleaseToolError.invalidCommand }
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }

  private static func valid(_ value: String) -> Bool {
    value.utf8.count <= 8192 && !value.utf8.contains(0)
  }

  var environment: [String] {
    let inherited = ProcessInfo.processInfo.environment
    return ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"]
      + ["HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"].compactMap { key in
        guard let value = inherited[key], Self.valid(value) else { return nil }
        return "\(key)=\(value)"
      }
  }
}

/// Independent limits for each output pipe and a monotonic command deadline.
public struct ChildLimits: Sendable {
  let outputBytes: Int
  let duration: Duration

  public init(outputBytes: Int = 64 * 1024, seconds: Double = 30) throws {
    guard outputBytes > 0, outputBytes <= 16 * 1024 * 1024,
      seconds.isFinite, seconds > 0, seconds <= 900
    else { throw ReleaseToolError.invalidCommand }
    self.outputBytes = outputBytes
    duration = .nanoseconds(Int64(seconds * 1_000_000_000))
  }
}

/// A reaped child status, distinct from a request to terminate it.
public enum OwnedChildExit: Equatable, Sendable {
  case exited(Int32)
  case signalled(Int32)
}

/// Read-only child custody after launch, refusal or eventual exit.
public enum OwnedChildStatus: Equatable, Sendable {
  case notStarted
  case running(Int32)
  case stopped(OwnedChildExit)
  case unconfirmed
}

/// Complete bounded output from a child that actually exited successfully.
public struct OwnedCommandOutput: Equatable, Sendable {
  public let standardOutput: Data
  public let standardError: Data
}

/// Owns exactly one directly spawned release child until it is reaped.
///
/// Both nonblocking pipes are drained fairly in finite turns, including after
/// refusal. Timeout, cancellation or output overflow sends at most one TERM to
/// this unreaped child and returns a fixed error. There is no escalation or group
/// signal. A retained monitor continues discarding excess output and observing
/// actual exit; status queries never signal or restart. A failed producer must
/// retain its private stage and must not promote any output from this operation.
/// Descendants are not claimed as stopped merely because the direct child exits.
public actor OwnedCommand {
  private var attempted = false
  private var pid: pid_t?
  private var stdout: Int32 = -1
  private var stderr: Int32 = -1
  private var output = Data()
  private var errors = Data()
  private var limits: ChildLimits?
  private var deadline: ContinuousClock.Instant?
  private var exit: OwnedChildExit?
  private var exitSeen: ContinuousClock.Instant?
  private var unconfirmed = false
  private var termRequested = false
  private var result: Result<OwnedCommandOutput, ReleaseToolError>?

  public init() {}

  public func run(_ command: AppleCommand, limits: ChildLimits? = nil) async throws
    -> OwnedCommandOutput
  {
    guard !attempted else { throw ReleaseToolError.childAlreadyStarted }
    guard !Task.isCancelled else { throw ReleaseToolError.childCancelled }
    attempted = true
    let bounds = try limits ?? ChildLimits()
    self.limits = bounds
    deadline = ContinuousClock.now.advanced(by: bounds.duration)
    let child = try spawn(command)
    pid = child.pid
    stdout = child.stdout
    stderr = child.stderr
    Task.detached { await self.monitor() }
    while true {
      if Task.isCancelled { refuse(.childCancelled) }
      if let result { return try result.get() }
      do { try await Task.sleep(for: .milliseconds(5)) } catch { refuse(.childCancelled) }
    }
  }

  public func status() -> OwnedChildStatus {
    if unconfirmed { return .unconfirmed }
    if let exit { return .stopped(exit) }
    if let pid { return .running(pid) }
    return .notStarted
  }

  /// Waits finitely for existing child exit, without signals, restart or effect replay.
  public func observeExit(seconds: Double) async throws -> OwnedChildStatus {
    guard seconds.isFinite, seconds >= 0, seconds <= 900 else {
      throw ReleaseToolError.invalidCommand
    }
    let until = ContinuousClock.now.advanced(by: .nanoseconds(Int64(seconds * 1_000_000_000)))
    while case .running = status(), ContinuousClock.now < until {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(5))
    }
    return status()
  }

  /// Keeps a one-shot caller alive after refusal until this direct child's exit is known.
  ///
  /// This read-only wait ignores the failed caller's task cancellation and has
  /// no deadline: admission already refused. Running or unconfirmed custody
  /// cannot permit caller exit merely because a TERM was requested. No signal,
  /// restart, output promotion or descendant-exit claim occurs. GUI callers
  /// should keep using finite cancellable `observeExit(seconds:)` observations.
  public nonisolated func retainUntilExitAfterRefusal() async -> OwnedChildStatus {
    await Task.detached { [self] in
      while true {
        let current = await status()
        switch current {
        case .notStarted, .stopped: return current
        case .running, .unconfirmed:
          try? await Task.sleep(for: .milliseconds(10))
        }
      }
    }.value
  }

  private func monitor() async {
    while true {
      drain(&stdout, into: &output)
      drain(&stderr, into: &errors)
      reap()
      if let deadline, ContinuousClock.now >= deadline { refuse(.childDeadline) }
      if unconfirmed {
        refuse(.childCustodyUnknown)
        closePipes()
        return
      }
      if let exit {
        if exit != .exited(0) { refuse(.childFailed) }
        if stdout == -1 && stderr == -1 {
          if result == nil {
            result = .success(OwnedCommandOutput(standardOutput: output, standardError: errors))
          }
          return
        }
        if let exitSeen, exitSeen.duration(to: .now) >= .milliseconds(200) {
          refuse(.childOutputIncomplete)
          closePipes()
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func refuse(_ error: ReleaseToolError) {
    guard result == nil else { return }
    result = .failure(error)
    reap()
    if let pid, exit == nil, !unconfirmed, !termRequested {
      termRequested = true
      _ = Darwin.kill(pid, SIGTERM)
    }
  }

  private func reap() {
    guard let pid, exit == nil, !unconfirmed else { return }
    var status: Int32 = 0
    let value = waitpid(pid, &status, WNOHANG)
    if value == pid {
      let signal = status & 0x7f
      // A traced child's stop notification is not an exit or a reaped PID.
      guard signal != 0x7f, status != 0xffff else { return }
      exit = signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
      exitSeen = .now
    } else if value == -1 && errno != EINTR {
      unconfirmed = true
    }
  }

  private func drain(_ descriptor: inout Int32, into bytes: inout Data) {
    guard descriptor >= 0, let limits else { return }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    for _ in 0..<4 {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress!, $0.count)
      }
      if count > 0 {
        if result == nil {
          if count > limits.outputBytes - bytes.count {
            refuse(.childOutputLimit)
          } else {
            bytes.append(contentsOf: buffer[..<count])
          }
        }
      } else if count == 0 {
        Darwin.close(descriptor)
        descriptor = -1
        return
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else if errno != EINTR {
        refuse(.childOutputIncomplete)
        Darwin.close(descriptor)
        descriptor = -1
        return
      }
    }
  }

  private func closePipes() {
    if stdout >= 0 {
      Darwin.close(stdout)
      stdout = -1
    }
    if stderr >= 0 {
      Darwin.close(stderr)
      stderr = -1
    }
  }
}

private struct SpawnedChild {
  let pid: pid_t
  let stdout: Int32
  let stderr: Int32
}

private func spawn(_ command: AppleCommand) throws -> SpawnedChild {
  func pipeEnds() throws -> [Int32] {
    var ends: [Int32] = [-1, -1]
    guard pipe(&ends) == 0 else { throw ReleaseToolError.childLaunch }
    for index in ends.indices {
      let original = ends[index]
      let retained = fcntl(original, F_DUPFD_CLOEXEC, 3)
      if retained < 0 {
        for descriptor in ends { Darwin.close(descriptor) }
        throw ReleaseToolError.childLaunch
      }
      Darwin.close(original)
      ends[index] = retained
    }
    guard fcntl(ends[0], F_SETFL, O_NONBLOCK) == 0 else {
      for descriptor in ends { Darwin.close(descriptor) }
      throw ReleaseToolError.childLaunch
    }
    return ends
  }
  func check(_ value: Int32) throws {
    guard value == 0 else { throw ReleaseToolError.childLaunch }
  }
  let out = try pipeEnds()
  defer { Darwin.close(out[1]) }
  var launched = false
  defer { if !launched { Darwin.close(out[0]) } }
  let err = try pipeEnds()
  defer {
    Darwin.close(err[1])
    if !launched { Darwin.close(err[0]) }
  }
  var actions: posix_spawn_file_actions_t?
  try check(posix_spawn_file_actions_init(&actions))
  defer { posix_spawn_file_actions_destroy(&actions) }
  try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
  try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
  try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
  for descriptor in out + err { try check(posix_spawn_file_actions_addclose(&actions, descriptor)) }
  if let directory = command.workingDirectory {
    if #available(macOS 26, *) {
      try check(posix_spawn_file_actions_addchdir(&actions, directory))
    } else {
      try check(posix_spawn_file_actions_addchdir_np(&actions, directory))
    }
  }
  var attributes: posix_spawnattr_t?
  try check(posix_spawnattr_init(&attributes))
  defer { posix_spawnattr_destroy(&attributes) }
  try check(
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    ))
  var mask = sigset_t()
  sigemptyset(&mask)
  try check(posix_spawnattr_setsigmask(&attributes, &mask))
  for signal in [SIGTERM, SIGINT, SIGPIPE, SIGQUIT] { sigaddset(&mask, signal) }
  try check(posix_spawnattr_setsigdefault(&attributes, &mask))
  let strings = ([command.executable] + command.arguments).map { strdup($0) }
  let environment = command.environment.map { strdup($0) }
  defer { for string in strings + environment { free(string) } }
  guard strings.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil })
  else { throw ReleaseToolError.childLaunch }
  var argv = strings + [nil]
  var envp = environment + [nil]
  var pid: pid_t = 0
  try check(posix_spawn(&pid, command.executable, &actions, &attributes, &argv, &envp))
  launched = true
  return SpawnedChild(pid: pid, stdout: out[0], stderr: err[0])
}
