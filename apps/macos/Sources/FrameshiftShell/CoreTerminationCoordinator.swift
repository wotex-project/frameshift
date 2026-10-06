import AppKit

/// Coordinates normal AppKit termination with the shell's owned core.
///
/// The application delegate passes `applicationShouldTerminate(_:)` here after
/// stopping its advertisements. This coordinator returns `.terminateLater`,
/// keeps the main actor responsive, and replies only after observing the owned
/// launcher's exit. An uncertain stop cancels quit and offers an explicit retry
/// while `LocalCoreClient` retains custody and refuses new work.
///
/// Concurrent requests share the current wait. This handshake does not prevent
/// forced OS termination or establish installed updater behavior.
/// The supplied callback quiesces the shared model and advertisements once,
/// before waiting; it must preserve admitted command and process custody.
@MainActor
public final class CoreTerminationCoordinator {
  private var quitTask: Task<Void, Never>?
  private var terminationConfirmed = false
  private let quiesce: @MainActor () -> Void
  private var quiesced = false

  public init(quiesce: @escaping @MainActor () -> Void = {}) { self.quiesce = quiesce }

  public func requestTermination(_ application: NSApplication) -> NSApplication.TerminateReply {
    if !quiesced {
      quiesced = true
      quiesce()
    }
    if terminationConfirmed { return .terminateNow }
    if quitTask != nil { return .terminateLater }
    quitTask = Task.detached { [weak self] in
      let result = await LocalCoreClient.shutdownBundledCore()
      // A terminateLater modal loop may be nested inside a main dispatch job.
      // Deliver through the run loop so its reply does not wait for that job.
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { self?.complete(result, application: application) }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    return .terminateLater
  }

  private func complete(_ result: CoreShutdownResult, application: NSApplication) {
    quitTask = nil
    if result == .stopped {
      terminationConfirmed = true
      application.reply(toApplicationShouldTerminate: true)
    } else {
      application.reply(toApplicationShouldTerminate: false)
      let alert = NSAlert()
      alert.messageText = "Frameshift could not finish quitting"
      alert.informativeText =
        "Frameshift could not confirm that the core stopped. New work is paused. Retry quitting, or keep Frameshift open while it finishes."
      alert.addButton(withTitle: "Retry Quit")
      alert.addButton(withTitle: "Keep Open")
      if alert.runModal() == .alertFirstButtonReturn { application.terminate(nil) }
    }
  }
}
