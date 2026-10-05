import Darwin
import Foundation
import Testing

@testable import FrameshiftShell

@Suite("Owned core process exit", .serialized)
struct CoreProcessExitTests {
  private func process(_ executable: String, arguments: [String] = [], output: Pipe? = nil) throws
    -> Process
  {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    if let output {
      child.standardOutput = output
    } else {
      child.standardOutput = FileHandle.nullDevice
    }
    child.standardError = FileHandle.nullDevice
    try child.run()
    return child
  }

  @Test("an exited process and cooperative TERM have an observed stopped outcome")
  func observedExit() async throws {
    let exited = try process("/usr/bin/true")
    exited.waitUntilExit()
    #expect(await CoreProcessExit.observe(exited, within: .zero) == .stopped)

    let child = try process("/bin/sleep", arguments: ["60"])
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    child.terminate()
    #expect(await CoreProcessExit.observe(child, within: .seconds(2)) == .stopped)
    #expect(!child.isRunning)
  }

  @Test(
    "ignored TERM retains a live process at the deadline and read-only retry later confirms exit")
  func stoppedProcess() async throws {
    let output = Pipe()
    let child = try process(
      "/bin/sh", arguments: ["-c", "trap '' TERM; printf READY; exec /bin/sleep 60"], output: output
    )
    defer {
      if child.isRunning {
        _ = kill(child.processIdentifier, SIGKILL)
      }
      child.waitUntilExit()
    }
    #expect(try output.fileHandleForReading.read(upToCount: 5) == Data("READY".utf8))
    child.terminate()
    let clock = ContinuousClock()
    let started = clock.now
    #expect(await CoreProcessExit.observe(child, within: .milliseconds(100)) == .uncertain)
    #expect(started.duration(to: clock.now) < .seconds(2))
    #expect(child.isRunning)
    // The fixture releases only its own signal-ignoring child. Product code
    // never does this; recovery only observes the retained process.
    #expect(kill(child.processIdentifier, SIGKILL) == 0)
    #expect(await CoreProcessExit.observe(child, within: .seconds(2)) == .stopped)
  }

  @Test("cancelled observation refuses success and never signals the retained process")
  func cancelledObservation() async throws {
    let child = try process("/bin/sleep", arguments: ["60"])
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let observation = Task { await CoreProcessExit.observe(child, within: .seconds(10)) }
    observation.cancel()
    #expect(await observation.value == .uncertain)
    #expect(child.isRunning)
  }
}
