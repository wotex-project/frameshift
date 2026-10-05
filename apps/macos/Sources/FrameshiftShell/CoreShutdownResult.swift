import Foundation

/// The observed outcome of stopping the core process owned by the shell.
///
/// `stopped` means the retained launcher has exited. `uncertain` preserves
/// custody and forbids restart or application replacement until another
/// observation confirms exit. This result does not resolve library receipts.
public enum CoreShutdownResult: Equatable, Sendable {
  case stopped
  case uncertain
}

/// Observes an already requested process stop without sending more signals.
///
/// The caller retains the process and related credentials on an uncertain
/// result. A monotonic deadline and cancellation bound this asynchronous wait;
/// an elapsed timer alone never establishes that a process exited.
enum CoreProcessExit {
  static func observe(_ process: Process, within duration: Duration) async -> CoreShutdownResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while process.isRunning {
      guard !Task.isCancelled, clock.now < deadline else { return .uncertain }
      do {
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(20))))
      } catch {
        return process.isRunning ? .uncertain : .stopped
      }
    }
    return .stopped
  }
}
