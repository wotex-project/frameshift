import AppKit
import FrameshiftShell
@_spi(Validation) import FrameshiftUpdater
import Sparkle

/// Executes only in a disposable, uniquely identified fixture app.
/// The owning fixture seals and checks the complete pinned SDK before launch.
@main
struct UpdaterProbe {
  @MainActor
  static func main() {
    guard let identifier = Bundle.main.bundleIdentifier,
      identifier.hasPrefix("io.frameshift.fixture.updater."),
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      let channel = SignedUpdateChannel.admit(
        info: Bundle.main.infoDictionary ?? [:], feedURL: feed, publicKey: key)
    else { exit(64) }

    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--stopped-preferences"] {
      stopped(identifier: identifier, channel: channel)
      return
    }
    guard arguments.count >= 2, arguments.last == key else { exit(64) }
    _ = NSApplication.shared
    Task { @MainActor in
      do {
        switch arguments.first {
        case "--running-preferences" where arguments.count == 3:
          try require(channel.feedURL == arguments[1], "independent feed pin")
          try await running(identifier: identifier, channel: channel)
        case "--signed-feed" where arguments.count == 3:
          try await signedFeed(identifier: identifier, feed: arguments[1])
        default: exit(64)
        }
        exit(0)
      } catch {
        fputs("updater probe refused: \(error)\n", stderr)
        exit(1)
      }
    }
    NSApplication.shared.run()
  }

  @MainActor
  static func stopped(identifier: String, channel: SignedUpdateChannel) {

    let defaults = UserDefaults.standard
    guard defaults.persistentDomain(forName: identifier) == nil else { exit(1) }
    let choices: [String: Any] = [
      "SUEnableAutomaticChecks": true,
      "SUAutomaticallyUpdate": true,
      "SUSendProfileInfo": true,
      "SUFeedURL": "https://stored.example.invalid/override.xml",
      "SUScheduledCheckInterval": 7200,
    ]
    defaults.setPersistentDomain(choices, forName: identifier)
    defer { defaults.removePersistentDomain(forName: identifier) }

    let updater = NativeUpdater(channel: channel, termination: CoreTerminationCoordinator())
    let before = defaults.persistentDomain(forName: identifier) ?? [:]
    updater.checkForUpdates()
    updater.setAutomaticallyChecksForUpdates(false)
    updater.quiesce()
    let after = defaults.persistentDomain(forName: identifier) ?? [:]
    guard updater.state == .paused, !updater.canCheckForUpdates,
      updater.automaticallyChecksForUpdates,
      NSDictionary(dictionary: before).isEqual(to: choices),
      NSDictionary(dictionary: after).isEqual(to: choices)
    else { exit(1) }
    print("stopped updater preserves stored choices")
  }

  @MainActor
  static func running(identifier: String, channel: SignedUpdateChannel) async throws {
    let defaults = UserDefaults.standard
    try require(defaults.persistentDomain(forName: identifier) == nil, "existing defaults")
    let choices: [String: Any] = [
      "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": true,
      "SUSendProfileInfo": true, "SUScheduledCheckInterval": 7200,
      "SUFeedURL": "https://stored.example.invalid/override.xml",
    ]
    defaults.setPersistentDomain(choices, forName: identifier)
    var succeeded = false
    defer { if succeeded { defaults.removePersistentDomain(forName: identifier) } }
    let updater = NativeUpdater(channel: channel, termination: CoreTerminationCoordinator())
    try require(updater.startForQualifiedDistribution(), "startup")
    guard let sdk = updater.validationSDK else { throw ProbeFailure.failed("missing SDK") }
    try require(sdk.feedURL?.absoluteString == channel.feedURL, "feed override")
    try require(!sdk.automaticallyDownloadsUpdates && sdk.sendsSystemProfile, "stored policies")
    try require(updater.canCheckForUpdates && !updater.automaticallyChecksForUpdates, "readiness")
    updater.setAutomaticallyChecksForUpdates(true)
    try require(updater.automaticallyChecksForUpdates, "explicit enable")
    updater.setAutomaticallyChecksForUpdates(false)
    updater.quiesce()
    let previousCheck = sdk.lastUpdateCheckDate
    sdk.checkForUpdateInformation()
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while sdk.lastUpdateCheckDate == previousCheck || sdk.sessionInProgress {
      try require(ContinuousClock.now < deadline, "paused cycle deadline")
      try await Task.sleep(for: .milliseconds(10))
    }
    // Deliver queued KVO and the SDK's delayed preference/scheduler callbacks.
    try await Task.sleep(for: .seconds(1))
    try require(updater.state == .paused && !updater.canCheckForUpdates, "paused KVO")
    try require(sdk.canCheckForUpdates && !sdk.sessionInProgress, "SDK cycle completion")
    let after = defaults.persistentDomain(forName: identifier) ?? [:]
    for (name, choice) in choices {
      try require(
        NSDictionary(dictionary: [name: after[name] as Any]).isEqual(to: [name: choice]),
        "stored \(name)")
    }
    succeeded = true
    print("running updater preserves choices and denies paused checks")
  }

  @MainActor
  static func signedFeed(identifier: String, feed: String) async throws {
    guard let url = URL(string: feed), url.scheme == "http", url.host == "127.0.0.1",
      url.port != nil, url.path == "/appcast.xml", url.query == nil, url.fragment == nil,
      url.user == nil, url.password == nil
    else { throw ProbeFailure.failed("loopback route") }
    let defaults = UserDefaults.standard
    try require(defaults.persistentDomain(forName: identifier) == nil, "existing defaults")
    var succeeded = false
    defer { if succeeded { defaults.removePersistentDomain(forName: identifier) } }
    let delegate = FeedProbeDelegate(feed: feed)
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    let sdk = controller.updater
    try sdk.start()
    for valid in [true, false, false, true] {
      try require(sdk.canCheckForUpdates && !sdk.sessionInProgress, "cycle readiness")
      let result = await delegate.probe(sdk)
      try require(result.selected == valid && (result.error == nil) == valid, "signature result")
      try require(sdk.canCheckForUpdates && !sdk.sessionInProgress, "finished readiness")
      if let error = result.error {
        // Sparkle 2.10.0 SUErrors.h: SUAppcastParseError is 1000.
        try require(
          error.domain == SUSparkleErrorDomain && error.code == 1000, "feed validation error")
        print("signed feed refused: \(error.domain) \(error.code)")
      }
    }
    try require(delegate.finished == 4 && delegate.selected == 2, "cycle count")
    succeeded = true
    print("signed feed accepts valid, refuses tampered/unsigned, recovers valid")
  }

  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure.failed(message) }
  }
}

private enum ProbeFailure: Error { case failed(String) }

/// Uses only public probing delegates; no update archive or installation path.
@MainActor
private final class FeedProbeDelegate: NSObject, SPUUpdaterDelegate {
  struct Result {
    let selected: Bool
    let error: NSError?
  }
  let feed: String
  var finished = 0
  var selected = 0
  private var found = false
  private var continuation: CheckedContinuation<Result, Never>?

  init(feed: String) { self.feed = feed }

  func feedURLString(for updater: SPUUpdater) -> String? { feed }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard updateCheck == .updateInformation, continuation != nil else {
      throw ProbeFailure.failed("non-probing check")
    }
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    guard continuation != nil, item.versionString == "2.0.0", !found else { exit(1) }
    found = true
    selected += 1
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    guard updateCheck == .updateInformation, let completion = continuation else { exit(1) }
    continuation = nil
    finished += 1
    completion.resume(returning: Result(selected: found, error: error.map { $0 as NSError }))
  }

  func probe(_ updater: SPUUpdater) async -> Result {
    precondition(continuation == nil)
    found = false
    return await withCheckedContinuation { completion in
      continuation = completion
      updater.checkForUpdateInformation()
    }
  }
}
