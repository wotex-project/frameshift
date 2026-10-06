import Darwin
import Foundation
import XCTest

@testable import FrameshiftMacRelease

@MainActor
final class OwnedCommandTests: XCTestCase {
  func testBothPipesDrainBeyondKernelCapacityAndStdinIsClosed() async throws {
    let command = try shell(
      """
      if read input; then exit 9; fi
      i=0
      while [ "$i" -lt 8192 ]; do
        printf 0123456789abcdef
        printf fedcba9876543210 >&2
        i=$((i + 1))
      done
      """)
    let owner = OwnedCommand()
    let output = try await owner.run(
      command, limits: ChildLimits(outputBytes: 256 * 1024, seconds: 5))
    XCTAssertEqual(
      output.standardOutput, Data(String(repeating: "0123456789abcdef", count: 8192).utf8))
    XCTAssertEqual(
      output.standardError, Data(String(repeating: "fedcba9876543210", count: 8192).utf8))
    let status = await owner.status()
    XCTAssertEqual(status, .stopped(.exited(0)))
    try await refuses(.childAlreadyStarted) { try await owner.run(command) }
  }

  func testOutputFloodRefusesEachPipeAndReapsTheOwnedChild() async throws {
    for sink in ["", " >&2"] {
      let owner = OwnedCommand()
      let command = try shell("while :; do printf 0123456789abcdef\(sink); done")
      try await refuses(.childOutputLimit) {
        try await owner.run(command, limits: ChildLimits(outputBytes: 1024, seconds: 3))
      }
      let stopped = try await owner.observeExit(seconds: 1)
      XCTAssertEqual(stopped, .stopped(.signalled(SIGTERM)))
    }
  }

  func testDeadlineRequestsTerminationAndConfirmsActualExit() async throws {
    let owner = OwnedCommand()
    let command = try AppleCommand(executable: "/bin/sleep", arguments: ["5"])
    try await refuses(.childDeadline) {
      try await owner.run(command, limits: ChildLimits(seconds: 0.05))
    }
    let stopped = try await owner.observeExit(seconds: 1)
    XCTAssertEqual(stopped, .stopped(.signalled(SIGTERM)))
  }

  func testIgnoredTERMRetainsPendingStageAndLateExitIsReadOnly() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let pending = root + "/stage.pending"
    let accepted = root + "/accepted"
    try Data("accepted".utf8).write(
      to: URL(fileURLWithPath: accepted), options: .withoutOverwriting)
    let original = try identity(accepted)
    let owner = OwnedCommand()
    let command = try shell(
      "trap '' TERM; printf started > \"$1\"; /bin/sleep 0.7; printf late >> \"$1\"",
      extra: [pending]
    )
    try await refuses(.childDeadline) {
      try await owner.run(command, limits: ChildLimits(seconds: 0.2))
    }
    guard case .running(let pid) = await owner.status() else {
      XCTFail("ignored-TERM child lost custody before late exit")
      return
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pending)), Data("started".utf8))
    let stillRunning = try await owner.observeExit(seconds: 0.01)
    XCTAssertEqual(stillRunning, .running(pid))
    try await refuses(.childAlreadyStarted) { try await owner.run(command) }
    let observation = Task { try await owner.observeExit(seconds: 2) }
    observation.cancel()
    do {
      _ = try await observation.value
      XCTFail("cancelled observation completed")
    } catch { XCTAssertTrue(error is CancellationError) }
    let afterCancellation = await owner.status()
    XCTAssertEqual(afterCancellation, .running(pid))
    let stopped = try await owner.observeExit(seconds: 2)
    XCTAssertEqual(stopped, .stopped(.exited(0)))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pending)), Data("startedlate".utf8))
    XCTAssertEqual(try identity(accepted), original)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: accepted)), Data("accepted".utf8))
  }

  func testCancellationOfRunningCommandRetainsExitCustody() async throws {
    let owner = OwnedCommand()
    let command = try AppleCommand(executable: "/bin/sleep", arguments: ["5"])
    let operation = Task { try await owner.run(command) }
    _ = try await running(owner)
    operation.cancel()
    try await refuses(.childCancelled) { try await operation.value }
    let stopped = try await owner.observeExit(seconds: 1)
    XCTAssertEqual(stopped, .stopped(.signalled(SIGTERM)))
  }

  func testRefusalRetentionSurvivesCallerCancellationUntilActualLateExitWithoutAnotherTERM()
    async throws
  {
    let root = try directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let signals = root + "/signals"
    let gate = root + "/exit-gate"
    let pending = root + "/stage.pending"
    let accepted = root + "/accepted"
    try Data("accepted".utf8).write(to: URL(fileURLWithPath: accepted))
    let original = try identity(accepted)
    let owner = OwnedCommand()
    let command = try shell(
      "trap 'printf t >> \"$2\"' TERM; printf pending > \"$1\"; while [ ! -f \"$3\" ]; do :; done; printf late >> \"$1\"",
      extra: [pending, signals, gate])
    try await refuses(.childDeadline) {
      try await owner.run(command, limits: ChildLimits(seconds: 0.1))
    }
    // Release only this controlled fixture on an assertion failure, never signal again.
    defer { try? Data().write(to: URL(fileURLWithPath: gate)) }
    guard case .running(let pid) = await owner.status() else {
      return XCTFail("Ignored TERM lost ownership before retention")
    }
    let retention = Task { await owner.retainUntilExitAfterRefusal() }
    retention.cancel()
    try await Task.sleep(for: .milliseconds(30))
    let active = await owner.status()
    XCTAssertEqual(active, .running(pid))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: signals)), Data("t".utf8))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pending)), Data("pending".utf8))
    try Data().write(to: URL(fileURLWithPath: gate), options: .withoutOverwriting)
    let stopped = await retention.value
    XCTAssertEqual(stopped, .stopped(.exited(0)))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: signals)), Data("t".utf8))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pending)), Data("pendinglate".utf8))
    XCTAssertEqual(try identity(accepted), original)
    let repeated = await owner.retainUntilExitAfterRefusal()
    XCTAssertEqual(repeated, stopped)
    try await refuses(.childAlreadyStarted) { try await owner.run(command) }
  }

  func testRefusalRetentionReturnsOnlyAlreadyKnownUnusedReapedOrFailedLaunchStatus() async throws {
    let unused = await OwnedCommand().retainUntilExitAfterRefusal()
    XCTAssertEqual(unused, .notStarted)
    let owner = OwnedCommand()
    try await refuses(.childFailed) { try await owner.run(shell("exit 42")) }
    let known = await owner.retainUntilExitAfterRefusal()
    XCTAssertEqual(known, .stopped(.exited(42)))
    let failed = OwnedCommand()
    try await refuses(.childLaunch) {
      try await failed.run(
        AppleCommand(executable: "/private/missing-frameshift-tool", arguments: []))
    }
    let absent = await failed.retainUntilExitAfterRefusal()
    XCTAssertEqual(absent, .notStarted)
  }

  func testReadOnlyObservationsNeverRepeatTERM() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let ready = root + "/ready"
    let signals = root + "/signals"
    let gate = root + "/exit-gate"
    let owner = OwnedCommand()
    let command = try shell(
      "trap 'printf t >> \"$2\"' TERM; printf ready > \"$1\"; while [ ! -f \"$3\" ]; do :; done",
      extra: [ready, signals, gate]
    )
    try await refuses(.childDeadline) {
      try await owner.run(command, limits: ChildLimits(seconds: 0.1))
    }
    guard case .running(let pid) = await owner.status() else {
      XCTFail("nonexiting TERM handler lost child custody")
      return
    }
    // Always release this own fixture, even if an observation assertion fails.
    defer { try? Data().write(to: URL(fileURLWithPath: gate)) }
    for _ in 0..<3 {
      let status = try await owner.observeExit(seconds: 0.02)
      XCTAssertEqual(status, .running(pid))
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: signals)), Data("t".utf8))
    try Data().write(to: URL(fileURLWithPath: gate), options: .withoutOverwriting)
    let status = try await owner.observeExit(seconds: 1)
    XCTAssertEqual(status, .stopped(.exited(0)))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: signals)), Data("t".utf8))
  }

  func testAlreadyCancelledTaskDoesNotLaunchAChild() async throws {
    let owner = OwnedCommand()
    let command = try AppleCommand(executable: "/bin/sleep", arguments: ["5"])
    let gate = AsyncStream<Void>.makeStream()
    let operation = Task {
      for await _ in gate.stream { break }
      return try await owner.run(command)
    }
    operation.cancel()
    gate.continuation.finish()
    try await refuses(.childCancelled) { try await operation.value }
    let status = await owner.status()
    XCTAssertEqual(status, .notStarted)
  }

  func testNonzeroExitReturnsFixedRefusalWithoutAcceptingOutput() async throws {
    let owner = OwnedCommand()
    try await refuses(.childFailed) { try await owner.run(shell("printf sensitive >&2; exit 42")) }
    let status = await owner.status()
    XCTAssertEqual(status, .stopped(.exited(42)))
    XCTAssertFalse(ReleaseToolError.childFailed.description.contains("sensitive"))
  }

  func testDirectChildExitDoesNotClaimInheritedPipeEOFOrDescendantExit() async throws {
    let owner = OwnedCommand()
    let command = try shell("(/bin/sleep 0.7) & printf direct-child-done; exit 0")
    let started = ContinuousClock.now
    try await refuses(.childOutputIncomplete) { try await owner.run(command) }
    let elapsed = started.duration(to: .now)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
    XCTAssertLessThan(elapsed, .seconds(2))
    let status = await owner.status()
    XCTAssertEqual(status, .stopped(.exited(0)))
    // The fixture descendant exits naturally; the runner never signals its PID.
    try await Task.sleep(for: .milliseconds(750))
  }

  func testLaunchFailureClosesBothPipesAndCannotReplayOwner() async throws {
    let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }
    let command = try AppleCommand(executable: "/private/absent-mac-release-tool", arguments: [])
    for _ in 0..<40 {
      let owner = OwnedCommand()
      try await refuses(.childLaunch) { try await owner.run(command) }
      let status = await owner.status()
      XCTAssertEqual(status, .notStarted)
      try await refuses(.childAlreadyStarted) { try await owner.run(command) }
    }
    XCTAssertEqual((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }, descriptors)
  }

  func testFixedAppleToolAndIsolatedWorkingDirectory() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let owner = OwnedCommand()
    let command = try AppleCommand(
      executable: "/bin/sh",
      arguments: ["-c", "pwd; test -z \"${DYLD_INSERT_LIBRARIES+x}${NODE_OPTIONS+x}\""],
      workingDirectory: root
    )
    let output = try await owner.run(command)
    let actual = String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(
      in: .newlines)
    XCTAssertEqual(
      URL(fileURLWithPath: actual).resolvingSymlinksInPath(),
      URL(fileURLWithPath: root).resolvingSymlinksInPath())
    let xcrun = OwnedCommand()
    let selected = try await xcrun.run(AppleCommand(.xcrun, arguments: ["--find", "swiftc"]))
    XCTAssertTrue(String(decoding: selected.standardOutput, as: UTF8.self).contains("/swiftc"))
    XCTAssertTrue(selected.standardError.isEmpty)
  }

  func testInvalidArgumentsAndLimitsRefuseBeforeLaunch() throws {
    for arguments in [
      ["a\0b"], [String(repeating: "x", count: 8193)], [String](repeating: "x", count: 257),
      [String](repeating: String(repeating: "x", count: 8192), count: 33),
    ] {
      XCTAssertThrowsError(try AppleCommand(.codesign, arguments: arguments)) {
        XCTAssertEqual($0 as? ReleaseToolError, .invalidCommand)
      }
    }
    XCTAssertThrowsError(try AppleCommand(.ditto, arguments: [], workingDirectory: "relative"))
    for seconds in [-1, 0, 901, .nan, .infinity] {
      XCTAssertThrowsError(try ChildLimits(seconds: seconds))
    }
    for maximum in [-1, 0, 16 * 1024 * 1024 + 1, Int.max] {
      XCTAssertThrowsError(try ChildLimits(outputBytes: maximum))
    }
  }

  private func shell(_ body: String, extra: [String] = []) throws -> AppleCommand {
    try AppleCommand(executable: "/bin/sh", arguments: ["-c", body, "fixture"] + extra)
  }

  private func refuses<T>(_ expected: ReleaseToolError, _ operation: () async throws -> T)
    async throws
  {
    do {
      _ = try await operation()
      XCTFail("command unexpectedly admitted")
    } catch { XCTAssertEqual(error as? ReleaseToolError, expected) }
  }

  private func running(_ owner: OwnedCommand) async throws -> pid_t {
    let until = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < until {
      if case .running(let pid) = await owner.status() { return pid }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw ReleaseToolError.childLaunch
  }

  private func directory() throws -> String {
    let root = NSTemporaryDirectory() + "frameshift-mac-command-test." + UUID().uuidString
    guard mkdir(root, 0o700) == 0 else { throw ReleaseToolError.childLaunch }
    return root
  }

  private func identity(_ path: String) throws -> [Int64] {
    var value = stat()
    guard lstat(path, &value) == 0 else { throw ReleaseToolError.readFailed }
    return [
      Int64(value.st_ino), value.st_size, Int64(value.st_mode), Int64(value.st_mtimespec.tv_sec),
      Int64(value.st_mtimespec.tv_nsec), Int64(value.st_ctimespec.tv_sec),
      Int64(value.st_ctimespec.tv_nsec),
    ]
  }
}
