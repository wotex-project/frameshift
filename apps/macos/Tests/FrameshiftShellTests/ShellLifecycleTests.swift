import CryptoKit
import Foundation
import FrameshiftShell
import Testing

@Suite("Shared shell lifetime and quiescence")
@MainActor
struct ShellLifecycleTests {
  @Test("Startup is single-flight, failure is visible and retry is explicit")
  func startupFailureAndRetry() async throws {
    let client = LifecycleClient(failFirstSnapshot: true)
    let model = ShellModel(client: client)
    model.start()
    model.start()
    try await until { !model.isStarting }
    #expect(await client.snapshotCount() == 1)
    #expect(model.startupFailed)
    #expect(model.errorMessage == "The local core could not start. Retry the connection.")
    #expect(model.snapshot.statusMessage == CoreSnapshot.disconnected.statusMessage)
    model.start()
    try await until { !model.isStarting }
    #expect(await client.snapshotCount() == 2)
    #expect(!model.startupFailed)
    #expect(model.errorMessage == nil)
    #expect(model.snapshot.statusMessage == "Connected")
  }

  @Test("Quiescence cancels retained startup and ignores a late successful read")
  func startupQuiescence() async throws {
    let client = LifecycleClient(holdSnapshot: true)
    let original = CoreSnapshot(targets: [], selectedTargetID: nil, statusMessage: "Original")
    let model = ShellModel(client: client, initialSnapshot: original)
    model.start()
    try await until { await client.snapshotCount() == 1 }
    model.quiesce()
    model.quiesce()
    model.start()
    _ = await model.refresh()
    await client.completeSnapshot()
    try await until { !model.isStarting && !model.isBusy }
    #expect(model.isQuiescing)
    #expect(model.storageSettings.isQuiescing)
    #expect(model.similarity.isQuiescing)
    #expect(model.actionsUnavailable)
    #expect(model.snapshot.statusMessage == "Original")
    #expect(model.errorMessage == nil)
    #expect(!model.startupFailed)
    #expect(await client.snapshotCount() == 1)
    #expect(await client.pendingCount() == 0)
  }

  @Test("Cancelled presentation refresh neither publishes nor opens an error")
  func cancelledRefresh() async throws {
    let client = LifecycleClient(holdSnapshot: true)
    let model = ShellModel(client: client)
    let read = Task { await model.refresh() }
    try await until { await client.snapshotCount() == 1 }
    read.cancel()
    await client.completeSnapshot()
    #expect(await read.value == false)
    #expect(model.snapshot.statusMessage == CoreSnapshot.disconnected.statusMessage)
    #expect(model.errorMessage == nil)
    #expect(!model.isBusy)
  }

  @Test("Superseded debounce makes one current request and paused debounce makes none")
  func debounceLifetime() async throws {
    let client = LifecycleClient()
    let model = ShellModel(client: client)
    model.setSearchQuery("older")
    model.setSearchQuery("current")
    try await until { await client.queries() == ["current"] }
    model.setSearchQuery("must-not-start")
    model.quiesce()
    await model.submitSearch()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await client.queries() == ["current"])
    #expect(model.searchError == nil)
  }

  @Test("Late selected preview cannot publish or schedule follow-up work after quit")
  func latePreviewQuiescence() async throws {
    let client = LifecycleClient(holdPreview: true)
    let original = CoreSnapshot(
      targets: [], selectedTargetID: nil,
      items: [LibraryItem(id: lifecycleMaster, title: "Selected", digest: lifecycleMaster)],
      statusMessage: "Original")
    let model = ShellModel(client: client, initialSnapshot: original)
    model.selectItem(lifecycleMaster)
    try await until { await client.previewCount() == 1 }
    model.quiesce()
    try await client.completePreview()
    await model.loadSelectedPreview()
    await model.loadSelectedMetadata()
    await model.loadRecovery(reset: true)
    await model.storageSettings.refresh()
    model.analyzeSelectedArtwork()
    model.findSimilarArtwork()
    model.similarity.start(itemID: lifecycleMaster, filters: LibraryFilters())
    // The ignored-cancellation fixture returns real valid preview bytes.
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.selectedPreview == nil)
    #expect(model.previewMessage == nil)
    #expect(model.selectedItem?.id == lifecycleMaster)
    #expect(!model.isPreviewLoading)
    #expect(await client.previewCount() == 1)
    #expect(await client.recoveryCount() == 0)
    #expect(await client.storageCount() == 0)
    #expect(await client.pendingCount() == 0)
    #expect(await client.similarityCount() == 0)
  }

  @Test("An admitted cancelled mutation retains its completed identity and newer draft")
  func admittedMutationCompletes() async throws {
    let client = LifecycleClient(holdCommand: true)
    let model = ShellModel(client: client)
    model.draftInstruction = "Submitted"
    let save = Task { await model.saveInstruction() }
    try await until { await client.commands().count == 1 }
    let command = try #require(await client.commands().first)
    #expect(model.commandOutcome == .inFlight(command.id))
    model.quiesce()
    save.cancel()
    model.draftInstruction = "Newer unsaved draft"
    await client.completeCommand(unknown: false)
    await save.value
    #expect(model.commandOutcome == .completed(command.id))
    #expect(model.snapshot.instruction == "Submitted")
    #expect(model.draftInstruction == "Newer unsaved draft")
    #expect(model.errorMessage == nil)
    await model.saveInstruction()
    #expect(await client.commands().count == 1)
    #expect(await client.snapshotCount() == 0)
  }

  @Test("An admitted unknown outcome retains identity without reconciliation or replay during quit")
  func admittedMutationUnknown() async throws {
    let client = LifecycleClient(holdCommand: true)
    let model = ShellModel(client: client)
    model.draftInstruction = "Submitted"
    let save = Task { await model.saveInstruction() }
    try await until { await client.commands().count == 1 }
    let command = try #require(await client.commands().first)
    model.quiesce()
    await client.completeCommand(unknown: true)
    await save.value
    #expect(model.commandOutcome == .unconfirmed(command.id))
    #expect(model.errorMessage?.contains("did not confirm") == true)
    #expect(model.errorMessage?.contains("New work is paused") == true)
    #expect(model.snapshot.instruction == CoreSnapshot.disconnected.instruction)
    await model.saveInstruction()
    #expect(model.commandOutcome == .unconfirmed(command.id))
    #expect(await client.commands().map(\.id) == [command.id])
    #expect(await client.snapshotCount() == 0)
  }

  private func until(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else { throw CoreClientError.coreUnavailable }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private let lifecycleMaster = "sha256:" + String(repeating: "a", count: 64)

private actor LifecycleClient: CoreClient {
  private let holdSnapshot: Bool
  private let failFirstSnapshot: Bool
  private let holdCommand: Bool
  private let holdPreview: Bool
  private var reads = 0
  private var searched: [String] = []
  private var sent: [CoreCommand] = []
  private var previews = 0
  private var pending = 0
  private var recoveries = 0
  private var storageReads = 0
  private var similarities = 0
  private var readResponse: CheckedContinuation<CoreSnapshot, Never>?
  private var commandResponse: CheckedContinuation<CoreSnapshot, any Error>?
  private var previewResponse: CheckedContinuation<ArtworkPreview, any Error>?

  init(
    holdSnapshot: Bool = false, failFirstSnapshot: Bool = false, holdCommand: Bool = false,
    holdPreview: Bool = false
  ) {
    self.holdSnapshot = holdSnapshot
    self.failFirstSnapshot = failFirstSnapshot
    self.holdCommand = holdCommand
    self.holdPreview = holdPreview
  }

  func snapshot() async throws -> CoreSnapshot {
    reads += 1
    if failFirstSnapshot && reads == 1 { throw CoreClientError.coreUnavailable }
    if holdSnapshot { return await withCheckedContinuation { readResponse = $0 } }
    return connected()
  }

  func snapshot(query: String) async throws -> CoreSnapshot {
    try Task.checkCancellation()
    searched.append(query)
    return connected()
  }

  func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    sent.append(command)
    if holdCommand { return try await withCheckedThrowingContinuation { commandResponse = $0 } }
    return connected()
  }

  func preview(masterID: String, target _: FrameTarget?) async throws -> ArtworkPreview {
    previews += 1
    if holdPreview { return try await withCheckedThrowingContinuation { previewResponse = $0 } }
    return try previewBytes(masterID)
  }

  func metadata(itemID _: String) throws -> LibraryMetadata {
    try Task.checkCancellation()
    throw CoreClientError.metadataUnavailable
  }

  func analysisPending() throws -> PendingLibraryAnalysis {
    try Task.checkCancellation()
    pending += 1
    return PendingLibraryAnalysis(itemIDs: [], hasMore: false)
  }

  func recovery(afterID _: String?) throws -> LibraryRecoveryPage {
    recoveries += 1
    throw CoreClientError.metadataUnavailable
  }

  func storage() throws -> LibraryStorage {
    storageReads += 1
    throw CoreClientError.storageUnavailable
  }

  func similarArtwork(itemID _: String, filters _: LibraryFilters) throws -> VisualSimilarityResult
  {
    similarities += 1
    throw CoreClientError.analysisUnavailable
  }

  func snapshotCount() -> Int { reads }
  func queries() -> [String] { searched }
  func commands() -> [CoreCommand] { sent }
  func previewCount() -> Int { previews }
  func pendingCount() -> Int { pending }
  func recoveryCount() -> Int { recoveries }
  func storageCount() -> Int { storageReads }
  func similarityCount() -> Int { similarities }
  func completeSnapshot() {
    readResponse?.resume(returning: connected())
    readResponse = nil
  }
  func completeCommand(unknown: Bool) {
    if unknown {
      commandResponse?.resume(throwing: CoreClientError.commandOutcomeUnknown)
    } else {
      commandResponse?.resume(
        returning: CoreSnapshot(
          targets: [], selectedTargetID: nil, instruction: sent.last?.instruction ?? "",
          statusMessage: "Saved"))
    }
    commandResponse = nil
  }
  func completePreview() throws {
    previewResponse?.resume(returning: try previewBytes(lifecycleMaster))
    previewResponse = nil
  }
  private func connected() -> CoreSnapshot {
    CoreSnapshot(targets: [], selectedTargetID: nil, statusMessage: "Connected")
  }
  private func previewBytes(_ master: String) throws -> ArtworkPreview {
    let data = Data([1, 2, 3])
    let values: [String: Any] = [
      "kind": "source", "masterDigest": master, "approximation": true, "format": "rgb24",
      "width": 1, "height": 1, "aspectWidth": 1, "aspectHeight": 1,
      "rgb": data.base64EncodedString(),
      "digest": "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      "rendererBuildDigest": "sha256:" + String(repeating: "c", count: 64),
    ]
    return try JSONDecoder().decode(
      ArtworkPreview.self, from: JSONSerialization.data(withJSONObject: values))
  }
}
