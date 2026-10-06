import AppKit
import Foundation
import Testing

@testable import FrameshiftShell

@Suite("Updater shares confirmed core exit")
@MainActor
struct CoreTerminationCoordinatorTests {
  @Test("duplicate pending relaunch refuses without replacing the first callback")
  func duplicateAndConfirmedReuse() async throws {
    let gate = ExitObservationGate()
    var quiesceCount = 0
    let coordinator = coordinator(gate) { quiesceCount += 1 }
    let first = Task { await outcome(coordinator) }
    await gate.waitForObservation()
    var duplicate: CoreShutdownResult?
    #expect(coordinator.prepareForUpdaterRelaunch { duplicate = $0 } == nil)
    #expect(duplicate == .uncertain)
    #expect(await gate.calls == 1)
    await gate.finish(.stopped)
    #expect(await first.value == .stopped)
    #expect(quiesceCount == 1)
    #expect(await outcome(coordinator) == .stopped)
    #expect(await gate.calls == 1)
    #expect(quiesceCount == 1)
  }

  @Test("uncertainty consumes the callback and permits only an explicit later observation")
  func uncertainAndExplicitRetry() async {
    let gate = ExitObservationGate()
    var quiesceCount = 0
    let coordinator = coordinator(gate) { quiesceCount += 1 }
    let first = Task { await outcome(coordinator) }
    await gate.waitForObservation()
    await gate.finish(.uncertain)
    #expect(await first.value == .uncertain)
    #expect(await gate.calls == 1)
    let second = Task { await outcome(coordinator) }
    await gate.waitForObservation()
    #expect(await gate.calls == 2)
    await gate.finish(.stopped)
    #expect(await second.value == .stopped)
    #expect(quiesceCount == 1)
  }

  @Test("matching cancellation suppresses an old handler while the shared stop continues")
  func canceledHandlerAndStaleIdentity() async throws {
    let gate = ExitObservationGate()
    var oldCalls = 0
    let coordinator = coordinator(gate) {}
    let oldID = try #require(coordinator.prepareForUpdaterRelaunch { _ in oldCalls += 1 })
    await gate.waitForObservation()
    coordinator.cancelUpdaterRelaunch(UUID())
    var duplicate: CoreShutdownResult?
    #expect(coordinator.prepareForUpdaterRelaunch { duplicate = $0 } == nil)
    #expect(duplicate == .uncertain)
    coordinator.cancelUpdaterRelaunch(oldID)
    let latest = Task {
      await withCheckedContinuation { continuation in
        let newID = coordinator.prepareForUpdaterRelaunch { continuation.resume(returning: $0) }
        #expect(newID != nil && newID != oldID)
        coordinator.cancelUpdaterRelaunch(oldID)
      }
    }
    // The new request attaches to the still-owned observation, without starting another.
    await Task.yield()
    #expect(await gate.calls == 1)
    await gate.finish(.stopped)
    #expect(await latest.value == .stopped)
    #expect(oldCalls == 0)
    #expect(await gate.calls == 1)
  }

  @Test("a canceled already-confirmed callback cannot consume its replacement")
  func canceledQueuedConfirmation() async throws {
    let gate = ExitObservationGate()
    let deliveries = DeferredExitDeliveries()
    let coordinator = CoreTerminationCoordinator(
      quiesce: {}, shutdown: { await gate.observe() },
      deliver: { operation in Task { @MainActor in deliveries.append(operation) } })
    var first: CoreShutdownResult?
    _ = coordinator.prepareForUpdaterRelaunch { first = $0 }
    await gate.waitForObservation()
    await gate.finish(.stopped)
    await deliveries.waitForCount(1)
    deliveries.runFirst()
    #expect(first == .stopped)
    var oldCalls = 0
    let oldID = try #require(coordinator.prepareForUpdaterRelaunch { _ in oldCalls += 1 })
    coordinator.cancelUpdaterRelaunch(oldID)
    var latest: CoreShutdownResult?
    let latestID = try #require(coordinator.prepareForUpdaterRelaunch { latest = $0 })
    coordinator.cancelUpdaterRelaunch(oldID)
    await deliveries.waitForCount(2)
    deliveries.runFirst()
    #expect(oldCalls == 0 && latest == nil)
    deliveries.runFirst()
    #expect(latest == .stopped)
    #expect(oldCalls == 0)
    #expect(latestID != oldID)
    #expect(await gate.calls == 1)
  }

  @Test("immediate normal quit resumes a queued confirmed continuation exactly once")
  func confirmedNormalQuitResumesPendingUpdater() async throws {
    let gate = ExitObservationGate()
    let deliveries = DeferredExitDeliveries()
    let coordinator = CoreTerminationCoordinator(
      quiesce: {}, shutdown: { await gate.observe() },
      deliver: { operation in Task { @MainActor in deliveries.append(operation) } })
    var first: CoreShutdownResult?
    _ = coordinator.prepareForUpdaterRelaunch { first = $0 }
    await gate.waitForObservation()
    await gate.finish(.stopped)
    await deliveries.waitForCount(1)
    deliveries.runFirst()
    #expect(first == .stopped)
    var continuations = 0
    let id = try #require(
      coordinator.prepareForUpdaterRelaunch { result in
        #expect(result == .stopped)
        continuations += 1
      })
    #expect(continuations == 0)
    #expect(coordinator.requestTermination(NSApplication.shared) == .terminateNow)
    #expect(continuations == 1)
    await deliveries.waitForCount(1)
    deliveries.runFirst()
    coordinator.cancelUpdaterRelaunch(id)
    #expect(continuations == 1)
    #expect(await gate.calls == 1)
  }

  private func coordinator(
    _ gate: ExitObservationGate, quiesce: @escaping @MainActor () -> Void
  ) -> CoreTerminationCoordinator {
    CoreTerminationCoordinator(
      quiesce: quiesce, shutdown: { await gate.observe() },
      deliver: { operation in Task { @MainActor in operation() } })
  }

  private func outcome(_ coordinator: CoreTerminationCoordinator) async -> CoreShutdownResult {
    await withCheckedContinuation { continuation in
      coordinator.prepareForUpdaterRelaunch { continuation.resume(returning: $0) }
    }
  }
}

private actor ExitObservationGate {
  private var pending: CheckedContinuation<CoreShutdownResult, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var calls = 0
  func observe() async -> CoreShutdownResult {
    calls += 1
    return await withCheckedContinuation { continuation in
      pending = continuation
      started?.resume()
      started = nil
    }
  }
  func waitForObservation() async {
    if pending != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish(_ result: CoreShutdownResult) {
    let completion = pending
    pending = nil
    completion?.resume(returning: result)
  }
}

@MainActor
private final class DeferredExitDeliveries {
  private var operations: [@MainActor () -> Void] = []
  func append(_ operation: @escaping @MainActor () -> Void) { operations.append(operation) }
  func waitForCount(_ count: Int) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while operations.count < count && ContinuousClock.now < deadline { await Task.yield() }
    #expect(operations.count == count)
  }
  func runFirst() { operations.removeFirst()() }
}
