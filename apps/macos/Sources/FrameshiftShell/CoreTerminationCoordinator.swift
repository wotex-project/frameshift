import AppKit

/// Shares confirmed owned-core exit between normal quit and updater relaunch.
///
/// `requestTermination(_:)` returns `.terminateLater` while one retained stop
/// observation runs. `prepareForUpdaterRelaunch(_:)` attaches a separate one-shot
/// callback to that same observation. Both paths quiesce the shared model and
/// advertisements once; only observed direct exit allows termination or the
/// caller's installation continuation. Uncertainty keeps process custody and
/// artwork work paused, allowing an explicit later read-only retry.
///
/// Delivery uses the main run loop's common modes, including a modal termination
/// loop nested inside a main dispatch job. Only one updater callback is pending;
/// duplicate requests refuse without replacing it. Cancel its returned UUID to
/// suppress that callback, without canceling the shared stop or resuming work.
/// A stale cancellation/job delivery cannot affect a newer request or job.
///
/// Sparkle may skip its postponement hook, so the normal AppKit guard remains
/// required. The callback's result is a core-exit fact, not an installation
/// receipt. The SDK adapter owns uncertainty/retry/cancellation presentation and
/// invokes its retained handler only for `.stopped`. This in-memory coordinator
/// cannot prevent forced OS termination or prove descendant/installed behavior.
@MainActor
public final class CoreTerminationCoordinator {
  private var exitJob: Task<Void, Never>?
  private var exitJobID: UUID?
  private var terminationConfirmed = false
  private var application: NSApplication?
  private var updater: (id: UUID, completion: @MainActor (CoreShutdownResult) -> Void)?
  private let quiesce: @MainActor () -> Void
  private let shutdown: @Sendable () async -> CoreShutdownResult
  private let deliver: @Sendable (@escaping @MainActor () -> Void) -> Void
  private var quiesced = false

  public init(quiesce: @escaping @MainActor () -> Void = {}) {
    self.quiesce = quiesce
    shutdown = { await LocalCoreClient.shutdownBundledCore() }
    deliver = Self.deliverOnRunLoop
  }

  init(
    quiesce: @escaping @MainActor () -> Void,
    shutdown: @escaping @Sendable () async -> CoreShutdownResult,
    deliver: @escaping @Sendable (@escaping @MainActor () -> Void) -> Void
  ) {
    self.quiesce = quiesce
    self.shutdown = shutdown
    self.deliver = deliver
  }

  public func requestTermination(_ application: NSApplication) -> NSApplication.TerminateReply {
    quiesceOnce()
    if terminationConfirmed {
      if let pending = updater { completeConfirmedUpdater(pending.id) }
      return .terminateNow
    }
    self.application = application
    beginObservation()
    return .terminateLater
  }

  /// Attaches one callback, returning its cancellation identity; duplicates refuse.
  ///
  /// A refused duplicate receives `.uncertain` and no UUID. Accepted completion
  /// never invoked inside an accepted preparation call. Confirmed exit is queued;
  /// normal quit consumes it before returning `.terminateNow`. The callback is
  /// consumed before invocation and must never treat `.uncertain` as exit.
  @discardableResult
  public func prepareForUpdaterRelaunch(
    _ completion: @escaping @MainActor (CoreShutdownResult) -> Void
  ) -> UUID? {
    quiesceOnce()
    guard updater == nil else {
      completion(.uncertain)
      return nil
    }
    let id = UUID()
    updater = (id, completion)
    if terminationConfirmed {
      deliver { [weak self] in self?.completeConfirmedUpdater(id) }
    } else {
      beginObservation()
    }
    return id
  }

  /// Suppresses only the matching callback; the owned exit observation continues.
  public func cancelUpdaterRelaunch(_ id: UUID) {
    if updater?.id == id { updater = nil }
  }

  private func quiesceOnce() {
    guard !quiesced else { return }
    quiesced = true
    quiesce()
  }

  private func beginObservation() {
    guard exitJob == nil else { return }
    let id = UUID()
    exitJobID = id
    let shutdown = shutdown
    let deliver = deliver
    exitJob = Task.detached { [weak self] in
      let result = await shutdown()
      deliver { self?.complete(result, job: id) }
    }
  }

  private func completeConfirmedUpdater(_ id: UUID) {
    guard terminationConfirmed, let pending = updater, pending.id == id else { return }
    updater = nil
    pending.completion(.stopped)
  }

  private func complete(_ result: CoreShutdownResult, job: UUID) {
    guard exitJobID == job else { return }
    exitJob = nil
    exitJobID = nil
    if result == .stopped { terminationConfirmed = true }
    let normalQuit = application
    let pending = updater
    application = nil
    updater = nil
    if result == .uncertain {
      // End the older AppKit request before a callback can explicitly retry.
      normalQuit?.reply(toApplicationShouldTerminate: false)
    }
    pending?.completion(result)
    if result == .stopped {
      // Resume the retained installer before confirming a simultaneous app quit.
      normalQuit?.reply(toApplicationShouldTerminate: true)
    } else if let normalQuit, exitJob == nil, !terminationConfirmed {
      let alert = NSAlert()
      alert.messageText = "Frameshift could not finish quitting"
      alert.informativeText =
        "Frameshift could not confirm that the core stopped. New work is paused. Retry quitting, or keep Frameshift open while it finishes."
      alert.addButton(withTitle: "Retry Quit")
      alert.addButton(withTitle: "Keep Open")
      if alert.runModal() == .alertFirstButtonReturn { normalQuit.terminate(nil) }
    }
  }

  private nonisolated static func deliverOnRunLoop(_ operation: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated { operation() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }
}
