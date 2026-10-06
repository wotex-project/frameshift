import AppKit
import Combine
import FrameshiftShell
import Observation
import Sparkle

/// Owns Sparkle's standard controller, published settings and guarded relaunch.
///
/// Construction leaves the controller stopped. A missing admitted channel does
/// not construct an SDK controller. `startForQualifiedDistribution()` is called
/// only by an independently qualified release integration; it rechecks the
/// running main bundle against the admitted pins but does not establish signing,
/// notarization, installation or distribution eligibility itself. Development
/// applications never call it. No sample feed or production key is supplied.
///
/// Initial preferences belong to the bundle. Construction/startup never sets
/// preferences, clears overrides or adds feed parameters. The only exposed
/// preference setter responds to an explicit automatic-check choice. Sparkle
/// owns permission flow and check/download/install UI. Current SDK state is read
/// on each delivered KVO notification, avoiding stale queued boolean snapshots.
///
/// The retained delegate returns the pinned feed and denies new checks after
/// quiescence. Relaunch retains one SDK handler until the shared core coordinator
/// confirms direct exit. Uncertainty keeps it pending for explicit retry; cycle
/// completion invalidates its callback without canceling core custody. Normal
/// AppKit termination must use that same coordinator because Sparkle can skip the
/// postponement hook. Stopped fixtures establish no installed-update behavior.
@MainActor
@Observable
public final class NativeUpdater {
  public enum State: Equatable, Sendable {
    case unavailable, stopped, running, failed, paused
  }

  public private(set) var state: State
  public private(set) var canCheckForUpdates = false
  public private(set) var automaticallyChecksForUpdates = false
  public private(set) var isWaitingForCoreExit = false
  public private(set) var canRetryCoreExit = false

  @ObservationIgnored private let channel: SignedUpdateChannel?
  @ObservationIgnored private let prepare:
    (@escaping @MainActor (CoreShutdownResult) -> Void) -> UUID?
  @ObservationIgnored private let cancel: (UUID) -> Void
  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var delegate: UpdaterDelegate?
  @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
  @ObservationIgnored private var pending: Relaunch?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var quiescing = false

  private struct Relaunch {
    let id: UUID
    let handler: () -> Void
    var guardID: UUID?
    var observationID: UUID?
  }

  public convenience init(channel: SignedUpdateChannel?, termination: CoreTerminationCoordinator) {
    self.init(
      channel: channel,
      prepare: { termination.prepareForUpdaterRelaunch($0) },
      cancel: { termination.cancelUpdaterRelaunch($0) }
    )
  }

  init(
    channel: SignedUpdateChannel?,
    prepare: @escaping (@escaping @MainActor (CoreShutdownResult) -> Void) -> UUID?,
    cancel: @escaping (UUID) -> Void
  ) {
    self.channel = channel
    self.prepare = prepare
    self.cancel = cancel
    state = channel == nil ? .unavailable : .stopped
    guard channel != nil else { return }
    let delegate = UpdaterDelegate(owner: self)
    self.delegate = delegate
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    self.controller = controller
    refresh()
    for publisher in [
      controller.updater.publisher(for: \.canCheckForUpdates).map { _ in () }.eraseToAnyPublisher(),
      controller.updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () }
        .eraseToAnyPublisher(),
    ] {
      publisher.sink { [weak self] _ in
        Self.deliver { self?.refresh() }
      }.store(in: &subscriptions)
    }
  }

  /// Starts once after the caller's independent release qualification and launch.
  ///
  /// Missing/mismatched actual main-bundle metadata refuses before SDK startup.
  /// Failure is explicit and is not retried automatically or shown as readiness.
  @discardableResult
  public func startForQualifiedDistribution() -> Bool {
    guard !started, !quiescing, state == .stopped, let channel, let controller,
      SignedUpdateChannel.admit(
        info: Bundle.main.infoDictionary ?? [:], feedURL: channel.feedURL,
        publicKey: channel.publicKey) == channel
    else { return false }
    do {
      try controller.updater.start()
      started = true
      state = .running
      refresh()
      return true
    } catch {
      state = .failed
      refresh()
      return false
    }
  }

  public func checkForUpdates() {
    refresh()
    guard canCheckForUpdates else { return }
    controller?.checkForUpdates(nil)
    refresh()
  }

  /// Applies only an explicit user choice while the running updater is usable.
  public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard started, !quiescing else { return }
    controller?.updater.automaticallyChecksForUpdates = enabled
    refresh()
  }

  /// Pauses new checks without invalidating an installation's exit continuation.
  public func quiesce() {
    quiescing = true
    if state != .unavailable { state = .paused }
    refresh()
  }

  public func retryCoreExit() {
    guard canRetryCoreExit, let pending else { return }
    observeExit(for: pending.id)
  }

  func postponeRelaunch(_ handler: @escaping () -> Void) {
    guard pending == nil else { return }
    quiesce()
    let id = UUID()
    pending = Relaunch(id: id, handler: handler)
    isWaitingForCoreExit = true
    observeExit(for: id)
  }

  private func observeExit(for id: UUID) {
    let observationID = UUID()
    pending?.observationID = observationID
    canRetryCoreExit = false
    let guardID = prepare { [weak self] result in
      guard let self, let pending = self.pending, pending.id == id,
        pending.observationID == observationID
      else { return }
      self.pending?.observationID = nil
      self.pending?.guardID = nil
      if result == .stopped {
        self.pending = nil
        self.isWaitingForCoreExit = false
        self.canRetryCoreExit = false
        pending.handler()
      } else {
        self.canRetryCoreExit = true
      }
    }
    // A refused duplicate can complete synchronously. Never resurrect a handler.
    if pending?.id == id, pending?.observationID == observationID { pending?.guardID = guardID }
  }

  func finishCycle() {
    if let guardID = pending?.guardID { cancel(guardID) }
    pending = nil
    isWaitingForCoreExit = false
    canRetryCoreExit = false
    refresh()
  }

  func refresh() {
    canCheckForUpdates = started && !quiescing && controller?.updater.canCheckForUpdates == true
    automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
  }

  var sdk: SPUUpdater? { controller?.updater }
  /// Fixture-only access to documented SDK probing/getters; no product UI action.
  @_spi(Validation) public var validationSDK: SPUUpdater? { controller?.updater }
  var sdkDelegate: UpdaterDelegate? { delegate }
  var admittedFeed: String? { channel?.feedURL }
  var permitsCheck: Bool { started && !quiescing }

  private nonisolated static func deliver(_ action: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated { action() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }
}

@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
  private weak var owner: NativeUpdater?

  init(owner: NativeUpdater) { self.owner = owner }

  func feedURLString(for updater: SPUUpdater) -> String? { owner?.admittedFeed }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard owner?.permitsCheck == true else {
      throw NSError(
        domain: "io.frameshift.updater", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Updates are unavailable or paused."])
    }
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    owner?.postponeRelaunch(installHandler)
    return true
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    owner?.finishCycle()
  }
}
