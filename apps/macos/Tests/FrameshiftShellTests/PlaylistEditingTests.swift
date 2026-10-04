import Foundation
import FrameshiftShell
import Testing

@Suite("Ordered native playlists")
@MainActor
struct PlaylistEditingTests {
  @Test("Draft order and precise interval survive refresh and target switching")
  func preservesPerFrameDrafts() async {
    let initial = snapshot()
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    model.beginPlaylistEdit()
    model.usePinnedArtwork()
    model.movePlaylistItem("second", offset: -1)
    model.setPlaylistIntervalUnit(.milliseconds)
    model.setPlaylistInterval("1501")
    await model.refresh()
    #expect(model.playlistDraft?.items.map(\.id) == ["second", "first"])
    await model.selectTarget("frame-b")
    model.beginPlaylistEdit()
    model.usePinnedArtwork()
    model.removePlaylistItem("second")
    await model.selectTarget("frame-a")
    #expect(model.playlistDraft?.items.map(\.id) == ["second", "first"])
    #expect(model.playlistDraft?.intervalInput == "1501")
    #expect(model.playlistDraft?.intervalUnit == .milliseconds)
    await model.selectTarget("frame-b")
    #expect(model.playlistDraft?.items.map(\.id) == ["first"])
  }

  @Test("Adding a selected master is unique; movement stays within the set")
  func editsBoundedSet() {
    var initial = snapshot()
    initial.items = [LibraryItem(id: "first", title: "First", digest: "first")]
    let model = ShellModel(client: PlaylistClient(snapshot: initial), initialSnapshot: initial)
    model.selectItem("first")
    model.addSelectedToPlaylist()
    model.addSelectedToPlaylist()
    model.movePlaylistItem("first", offset: -1)
    model.movePlaylistItem("first", offset: Int.max)
    #expect(model.playlistDraft?.items.map(\.id) == ["first"])
    model.removePlaylistItem("first")
    #expect(model.playlistDraft?.items.isEmpty == true)
    #expect(!model.canQueuePlaylist)
  }

  @Test("The pin preview never falls back to a filtered or truncated result page")
  func refusesTruncatedPins() {
    var initial = snapshot()
    initial.pinnedSetTooLarge = true
    let model = ShellModel(client: PlaylistClient(snapshot: initial), initialSnapshot: initial)
    model.usePinnedArtwork()
    #expect(model.playlistDraft?.items.isEmpty == true)
    #expect(model.errorMessage?.contains("exceeds 64") == true)
  }

  @Test("Queue captures exact order and interval while newer draft edits remain local")
  func preservesEditsDuringQueue() async throws {
    let initial = snapshot()
    let client = PlaylistClient(snapshot: initial, holdSends: true)
    let model = ShellModel(client: client, initialSnapshot: initial)
    model.usePinnedArtwork()
    model.setPlaylistIntervalUnit(.milliseconds)
    model.setPlaylistInterval("1501")
    let queued = Task { await model.queuePlaylist() }
    await client.waitForCommand()
    model.movePlaylistItem("second", offset: -1)
    model.setPlaylistInterval("2000")
    await client.completeSend()
    await queued.value
    let command = try #require(await client.commands().first)
    #expect(command.kind == .loopArtwork)
    #expect(command.targetID == "frame-a")
    #expect(command.itemIDs == ["first", "second"])
    #expect(command.dwellMs == 1501)
    #expect(model.playlistDraft?.items.map(\.id) == ["second", "first"])
    #expect(model.playlistDraft?.intervalInput == "2000")
  }

  @Test("Invalid dwell or receiver capacity prevents a queue request")
  func refusesInvalidDraft() async {
    let initial = snapshot(maximum: 1)
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    model.usePinnedArtwork()
    #expect(!model.canQueuePlaylist)
    await model.queuePlaylist()
    model.removePlaylistItem("second")
    model.setPlaylistIntervalUnit(.milliseconds)
    model.setPlaylistInterval("999")
    #expect(!model.canQueuePlaylist)
    await model.queuePlaylist()
    #expect(await client.commands().isEmpty)
  }

  @Test("Saved defaults preserve millisecond precision and profile choice remains explicit")
  func savedIntervalDefault() async throws {
    let initial = try savedSnapshot()
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    #expect(model.playlistDraft?.items.map(\.id) == ["saved-second", "saved-first"])
    #expect(model.playlistDraft?.intervalInput == "1501")
    #expect(model.playlistDraft?.intervalUnit == .milliseconds)
    #expect(model.playlistDraft?.useProfileSuggestion == false)
    model.setPlaylistProfileSuggestion(true)
    await model.queuePlaylist()
    let command = try #require(await client.commands().first)
    #expect(command.kind == .loopArtwork)
    #expect(command.dwellMs == nil)
    #expect(command.itemIDs == ["saved-second", "saved-first"])
  }

  @Test("Resume names the saved revision without submitting current pins or draft interval")
  func resumesExactRevision() async throws {
    let initial = try savedSnapshot()
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    model.usePinnedArtwork()
    model.setPlaylistInterval("9999")
    await model.resumePlaylist()
    let command = try #require(await client.commands().first)
    #expect(command.kind == .resumePlaylist)
    #expect(command.playlistRevision == "sha256:saved")
    #expect(command.itemIDs == nil)
    #expect(command.dwellMs == nil)
  }

  @Test(
    "Resume respects authoritative capability and newer-delivery refusal", arguments: [true, false])
  func refusesUnsafeResume(capabilityChanged: Bool) async throws {
    let initial = try savedSnapshot(
      requiresRevalidation: capabilityChanged, hasQueuedDelivery: !capabilityChanged)
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    await model.resumePlaylist()
    #expect(await client.commands().isEmpty)
  }

  @Test("A stale resume tells the user to refresh without changing the local draft")
  func reportsStaleResume() async throws {
    let initial = try savedSnapshot()
    let model = ShellModel(
      client: PlaylistClient(snapshot: initial, failure: .loopRevisionConflict),
      initialSnapshot: initial)
    model.setPlaylistInterval("2000")
    await model.resumePlaylist()
    #expect(model.errorMessage?.contains("Refresh and review") == true)
    #expect(model.playlistDraft?.intervalInput == "2000")
  }

  @Test("An unresolved direct push prevents local resume")
  func refusesPendingPush() async throws {
    var initial = try savedSnapshot()
    initial.targets[0].directDelivery = try JSONDecoder().decode(
      DirectDelivery.self,
      from: Data(
        "{\"status\":\"pending\",\"revision\":1,\"desiredDigest\":\"sha256:fixture\"}".utf8))
    let client = PlaylistClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    await model.resumePlaylist()
    #expect(await client.commands().isEmpty)
  }

  private func snapshot(maximum: Int = 64) -> CoreSnapshot {
    let targets = ["frame-a", "frame-b"].map {
      FrameTarget(
        id: $0, name: $0, medium: .photo, profileID: "rgb24", state: .waitingForContact,
        minimumDwellMs: 1000, maximumPlaylistLength: maximum)
    }
    return CoreSnapshot(
      targets: targets, selectedTargetID: "frame-a", statusMessage: "Ready",
      pinnedItems: [
        PlaylistItem(id: "first", digest: "first", title: "First"),
        PlaylistItem(id: "second", digest: "second", title: "Second"),
      ], pinnedSetTooLarge: false)
  }

  private func savedSnapshot(
    requiresRevalidation: Bool = false, hasQueuedDelivery: Bool = false
  ) throws -> CoreSnapshot {
    let target = try JSONDecoder().decode(
      FrameTarget.self,
      from: Data(
        """
        {"id":"frame-a","name":"Frame A","medium":"photo","profileID":"rgb24","state":"displayed","minimumDwellMs":1000,"recommendedDwellMs":60000,"maximumPlaylistLength":64,"hasQueuedDelivery":\(hasQueuedDelivery),"playlist":{"status":"suspended","revision":"sha256:saved","entryCount":2,"dwellMs":1501,"requiresRevalidation":\(requiresRevalidation),"items":[{"id":"saved-second","digest":"saved-second","title":"Saved second"},{"id":"saved-first","digest":"saved-first","title":"Saved first"}]},"loopInterval":{"source":"override","requestedDwellMs":1501,"appliedDwellMs":1501,"capabilityDigest":"sha256:fixture","requiresReview":false}}
        """.utf8))
    var result = snapshot()
    result.targets = [target]
    return result
  }
}

private actor PlaylistClient: CoreClient {
  private var current: CoreSnapshot
  private let holdSends: Bool
  private let failure: CoreClientError?
  private var recorded: [CoreCommand] = []
  private var waiting: CheckedContinuation<Void, Never>?
  private var response: CheckedContinuation<Void, Never>?

  init(snapshot: CoreSnapshot, holdSends: Bool = false, failure: CoreClientError? = nil) {
    current = snapshot
    self.holdSends = holdSends
    self.failure = failure
  }

  func snapshot() -> CoreSnapshot { current }
  func snapshot(query _: String) -> CoreSnapshot { current }
  func commands() -> [CoreCommand] { recorded }

  func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    recorded.append(command)
    if command.kind == .selectTarget { current.selectedTargetID = command.targetID }
    if holdSends {
      waiting?.resume()
      waiting = nil
      await withCheckedContinuation { response = $0 }
    }
    if let failure { throw failure }
    return current
  }

  func waitForCommand() async {
    if response != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }

  func completeSend() {
    response?.resume()
    response = nil
  }
}
