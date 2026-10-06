import AppKit
import Foundation
import FrameshiftShell

@MainActor
func runOwnedQuitProbe(_ result: URL, updaterRelaunch: Bool = false) throws {
  try Data().write(to: result, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
  let application = NSApplication.shared
  application.setActivationPolicy(.prohibited)
  let delegate = OwnedQuitProbeDelegate(result: result)
  application.delegate = delegate
  let startup = Task { @MainActor in
    do {
      guard await delegate.model.refresh() else { throw CoreClientError.coreUnavailable }
      guard let socket = ProcessInfo.processInfo.environment["FRAMESHIFT_SOCKET_PATH"] else {
        throw CocoaError(.fileReadUnknown)
      }
      let pidFile = URL(fileURLWithPath: socket).deletingLastPathComponent()
        .appendingPathComponent("core.pid")
      let pidBytes = try Data(contentsOf: pidFile)
      guard pidBytes.count <= 20, let raw = String(data: pidBytes, encoding: .utf8),
        let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
      else { throw CocoaError(.fileReadCorruptFile) }
      delegate.record("core:\(pid)")
      delegate.record("ready")
      if updaterRelaunch { try delegate.prepareUpdaterRelaunch() }
      // Also exercise quit nested inside an active main-actor dispatch job.
      application.terminate(nil)
    } catch {
      delegate.record("refused")
      application.stop(nil)
    }
  }
  withExtendedLifetime(delegate) { application.run() }
  startup.cancel()
}

@MainActor
private final class OwnedQuitProbeDelegate: NSObject, NSApplicationDelegate {
  private let result: URL
  let model = ShellModel(client: LocalCoreClient())
  private lazy var termination = CoreTerminationCoordinator { [weak self] in self?.model.quiesce() }
  private var deferred = false

  init(result: URL) { self.result = result }

  func record(_ phase: String) {
    guard let handle = try? FileHandle(forWritingTo: result) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((phase + "\n").utf8))
  }

  func prepareUpdaterRelaunch() throws {
    guard
      termination.prepareForUpdaterRelaunch({ [weak self] result in
        self?.record(result == .stopped ? "updater-confirmed" : "refused")
      }) != nil
    else { throw CocoaError(.fileReadUnknown) }
    guard model.isQuiescing else { throw CocoaError(.fileReadUnknown) }
    record("updater-deferred")
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reply = termination.requestTermination(sender)
    guard model.isQuiescing, model.storageSettings.isQuiescing, model.similarity.isQuiescing else {
      record("refused")
      return .terminateCancel
    }
    if reply == .terminateLater {
      deferred = true
      record("deferred")
    }
    return reply
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = notification
    record(deferred ? "confirmed" : "refused")
  }
}
