import Foundation
import FrameshiftShell
import FrameshiftUpdater

/// Executes only in a disposable, uniquely identified stopped-controller app.
/// The owning fixture seals and checks the complete pinned SDK before launch.
@main
struct UpdaterProbe {
  @MainActor
  static func main() {
    guard CommandLine.arguments == [CommandLine.arguments[0], "--stopped-preferences"],
      let identifier = Bundle.main.bundleIdentifier,
      identifier.hasPrefix("io.frameshift.fixture.updater."),
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      let channel = SignedUpdateChannel.admit(
        info: Bundle.main.infoDictionary ?? [:], feedURL: feed, publicKey: key)
    else { exit(64) }

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
}
