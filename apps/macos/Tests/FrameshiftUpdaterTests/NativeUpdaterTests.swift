import Foundation
import FrameshiftShell
import Sparkle
import Testing

@testable import FrameshiftUpdater

@Suite("Native updater boundary", .serialized)
@MainActor
struct NativeUpdaterTests {
  @Test("Actual SDK delegate selectors retain the pinned feed and finish/cancel the pending lease")
  func actualDelegate() throws {
    let owner = ExitGuard()
    let updater = make(try channel(), owner)
    let sdk = try #require(updater.sdk)
    let delegate = try #require(updater.sdkDelegate)
    for selector in [
      "feedURLStringForUpdater:", "updater:mayPerformUpdateCheck:error:",
      "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
      "updater:didFinishUpdateCycleForUpdateCheck:error:",
    ] {
      #expect(delegate.responds(to: NSSelectorFromString(selector)))
    }
    #expect(delegate.feedURLString(for: sdk) == updater.admittedFeed)
    do {
      try delegate.updater(sdk, mayPerform: .updates)
      Issue.record("Stopped SDK delegate permitted a check")
    } catch {}
    var resumed = 0
    updater.postponeRelaunch { resumed += 1 }
    delegate.updater(sdk, didFinishUpdateCycleFor: .updates, error: nil)
    #expect(owner.canceled == [owner.requests[0].id])
    owner.requests[0].completion(.stopped)
    #expect(resumed == 0)
    #expect(!updater.isWaitingForCoreExit)
  }

  @Test("Missing channel constructs no SDK and cannot check, set preferences or start")
  func unavailable() {
    let guardOwner = ExitGuard()
    let updater = make(nil, guardOwner)
    #expect(updater.state == .unavailable)
    #expect(updater.sdk == nil)
    updater.checkForUpdates()
    updater.setAutomaticallyChecksForUpdates(true)
    #expect(!updater.startForQualifiedDistribution())
    updater.quiesce()
    #expect(updater.state == .unavailable)
    #expect(!updater.canCheckForUpdates)
    #expect(guardOwner.requests.isEmpty)
  }

  @Test("Actual pinned SDK stays stopped and actual main-bundle mismatch refuses startup")
  func stopped() throws {
    let updater = make(try channel(), ExitGuard())
    let sdk = try #require(updater.sdk)
    let choice = sdk.automaticallyChecksForUpdates
    #expect(updater.state == .stopped)
    #expect(!sdk.canCheckForUpdates)
    #expect(!sdk.sessionInProgress)
    #expect(updater.admittedFeed == "https://updates.example.invalid/appcast.xml")
    updater.setAutomaticallyChecksForUpdates(!choice)
    updater.checkForUpdates()
    #expect(sdk.automaticallyChecksForUpdates == choice)
    #expect(!updater.startForQualifiedDistribution())
    #expect(updater.state == .stopped)
    #expect(!sdk.canCheckForUpdates)
    #expect(!sdk.sessionInProgress)
    updater.quiesce()
    updater.refresh()
    #expect(updater.state == .paused)
    #expect(!updater.canCheckForUpdates)
  }

  @Test("Duplicate relaunch preserves the first handler; uncertainty requires explicit retry")
  func uncertaintyAndRetry() {
    let owner = ExitGuard()
    let updater = make(nil, owner)
    var first = 0
    var duplicate = 0
    updater.postponeRelaunch { first += 1 }
    updater.postponeRelaunch { duplicate += 1 }
    #expect(owner.requests.count == 1)
    #expect(updater.isWaitingForCoreExit)
    owner.requests[0].completion(.uncertain)
    #expect(updater.canRetryCoreExit)
    #expect(first == 0 && duplicate == 0)
    updater.quiesce()
    updater.retryCoreExit()
    #expect(owner.requests.count == 2)
    #expect(!updater.canRetryCoreExit)
    owner.requests[0].completion(.uncertain)
    owner.requests[0].completion(.stopped)
    #expect(!updater.canRetryCoreExit)
    #expect(first == 0)
    owner.requests[1].completion(.stopped)
    owner.requests[1].completion(.stopped)
    #expect(first == 1 && duplicate == 0)
    #expect(!updater.isWaitingForCoreExit && !updater.canRetryCoreExit)
  }

  @Test("Cycle completion cancels only its callback and ignores late delivery for a newer handler")
  func cancellationAndStaleness() {
    let owner = ExitGuard()
    let updater = make(nil, owner)
    var old = 0
    var current = 0
    updater.postponeRelaunch { old += 1 }
    updater.finishCycle()
    #expect(owner.canceled == [owner.requests[0].id])
    updater.postponeRelaunch { current += 1 }
    owner.requests[0].completion(.stopped)
    #expect(old == 0 && current == 0)
    #expect(updater.isWaitingForCoreExit)
    owner.requests[1].completion(.stopped)
    #expect(old == 0 && current == 1)
    updater.finishCycle()
    #expect(owner.canceled.count == 1)
  }

  @Test("Synchronous guard refusal retains its handler for retry without inventing confirmation")
  func synchronousRefusal() {
    let owner = ExitGuard()
    owner.refuse = true
    let updater = make(nil, owner)
    var installations = 0
    updater.postponeRelaunch { installations += 1 }
    #expect(updater.canRetryCoreExit && updater.isWaitingForCoreExit)
    #expect(installations == 0)
    updater.finishCycle()
    #expect(owner.canceled.isEmpty)
    #expect(!updater.canRetryCoreExit && !updater.isWaitingForCoreExit)
  }

  private func make(_ channel: SignedUpdateChannel?, _ owner: ExitGuard) -> NativeUpdater {
    NativeUpdater(
      channel: channel, prepare: { owner.prepare($0) }, cancel: { owner.canceled.append($0) })
  }

  private func channel() throws -> SignedUpdateChannel {
    let feed = "https://updates.example.invalid/appcast.xml"
    let key = Data(repeating: 0x7a, count: 32).base64EncodedString()
    return try #require(
      SignedUpdateChannel.admit(
        info: [
          "SUFeedURL": feed, "SUPublicEDKey": key, "SURequireSignedFeed": true,
          "SUVerifyUpdateBeforeExtraction": true, "SUSignedFeedFailureExpirationInterval": 0,
          "SUEnableAutomaticChecks": false, "SUAllowsAutomaticUpdates": false,
          "SUAutomaticallyUpdate": false, "SUSendProfileInfo": false,
        ], feedURL: feed, publicKey: key))
  }
}

@MainActor
private final class ExitGuard {
  var requests: [(id: UUID, completion: @MainActor (CoreShutdownResult) -> Void)] = []
  var canceled: [UUID] = []
  var refuse = false

  func prepare(_ completion: @escaping @MainActor (CoreShutdownResult) -> Void) -> UUID? {
    if refuse {
      completion(.uncertain)
      return nil
    }
    let id = UUID()
    requests.append((id, completion))
    return id
  }
}
