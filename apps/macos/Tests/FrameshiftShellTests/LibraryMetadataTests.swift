import Foundation
import FrameshiftShell
import Testing

@Suite("Editable native Library metadata and recovery")
@MainActor
struct LibraryMetadataTests {
  @Test("Per-master drafts survive selection and refresh; explicit reload discards edits")
  func preservesDrafts() async throws {
    let client = MetadataClient()
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(identity(1))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Unsaved title")
    model.addUserLabel("quiet")
    await model.refresh()
    model.selectItem(identity(2))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Second draft")
    model.selectItem(identity(1))
    await model.loadSelectedMetadata()
    #expect(model.metadataDraft?.title == "Unsaved title")
    #expect(model.metadataDraft?.userLabels == ["quiet"])
    await model.loadSelectedMetadata(discardDraft: true)
    #expect(model.metadataDraft?.title == "First")
    #expect(model.metadataDraft?.hasChanges == false)
  }

  @Test(
    "Save captures the observed revision; newer title and label edits survive its acknowledgement")
  func preservesPendingEdits() async throws {
    let client = MetadataClient(holdSends: true)
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(identity(1))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Submitted")
    let observation = try #require(model.metadataDraft?.machineLabels.first)
    model.toggleLabelDismissal(observation)
    let task = Task { await model.saveMetadata() }
    await client.waitForCommand()
    model.setMetadataTitle("Newer draft")
    model.addUserLabel("newer")
    await client.completeSend()
    await task.value
    let command = try #require(await client.commands().first)
    #expect(command.metadataRevision == identity(101))
    #expect(command.title == "Submitted")
    #expect(command.dismissedLabels == [LabelDismissal(label: "forest", provenance: "vision")])
    #expect(model.metadataDraft?.title == "Newer draft")
    #expect(model.metadataDraft?.userLabels == ["newer"])
    #expect(model.metadataDraft?.base.revision == identity(201))
    #expect(model.metadataDraft?.hasChanges == true)
  }

  @Test("External observations preserve the draft and block a stale overwrite")
  func refusesStaleDraft() async throws {
    let client = MetadataClient()
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(identity(1))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Local draft")
    await client.changeMetadata()
    await model.loadSelectedMetadata()
    #expect(model.metadataIsStale)
    await model.saveMetadata()
    #expect(await client.commands().isEmpty)
    #expect(model.metadataDraft?.title == "Local draft")
    await model.loadSelectedMetadata(discardDraft: true)
    #expect(!model.metadataIsStale)
    #expect(model.metadataDraft?.title == "External title")
  }

  @Test("Late reads for an old selection cannot replace current metadata")
  func refusesLateRead() async throws {
    let client = MetadataClient(holdMetadata: true)
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(identity(1))
    await client.waitForMetadata()
    model.selectItem(identity(2))
    await model.loadSelectedMetadata()
    await client.completeMetadata()
    for _ in 0..<20 { await Task.yield() }
    #expect(model.selectedMetadata?.itemID == identity(2))
    #expect(model.metadataDraft?.title == "Second")
  }

  @Test("Recovery appends bounded pages and restores only explicitly selected removed IDs")
  func paginatesAndRestores() async throws {
    let client = MetadataClient()
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    await model.loadRecovery(reset: true)
    #expect(model.removedItems.count == 50)
    #expect(model.recoveryCursor == identity(1049))
    await model.loadRecovery()
    #expect(model.removedItems.count == 51)
    #expect(model.recoveryCursor == nil)
    await model.restoreArtwork(identity(9999))
    #expect(await client.commands().isEmpty)
    await model.restoreArtwork(identity(1000))
    #expect(model.removedItems.count == 50)
    #expect(model.snapshot.items.contains { $0.id == identity(1000) })
    #expect(await client.commands().first?.kind == .restore)
  }

  @Test("Malformed metadata and recovery identity, bounds and cursor refuse before presentation")
  func validatesReadBoundary() throws {
    let valid = LibraryMetadata(
      itemID: identity(1), revision: identity(101), title: "First",
      sourceKind: "import", width: 2, height: 1)
    try valid.validate(itemID: identity(1))
    #expect(throws: CoreClientError.protocolFailure) { try valid.validate(itemID: identity(2)) }
    let invalid = LibraryMetadata(
      itemID: identity(1), revision: "unverified", title: "First",
      sourceKind: "import", width: 2, height: 1)
    #expect(throws: CoreClientError.protocolFailure) { try invalid.validate(itemID: identity(1)) }
    let badLabel = LibraryMetadata(
      itemID: identity(1), revision: identity(101), title: "First",
      sourceKind: "import", width: 2, height: 1,
      labels: [ArtworkLabel(label: "forest", provenance: "vision", confidence: 1.1)])
    #expect(throws: CoreClientError.protocolFailure) { try badLabel.validate(itemID: identity(1)) }
    let item = removed(1000)
    #expect(throws: CoreClientError.protocolFailure) {
      try LibraryRecoveryPage(items: [item, item]).validate(afterID: nil)
    }
    #expect(throws: CoreClientError.protocolFailure) {
      try LibraryRecoveryPage(items: [item]).validate(afterID: item.id)
    }
    #expect(throws: CoreClientError.protocolFailure) {
      try LibraryRecoveryPage(items: [item], nextCursor: item.id).validate(afterID: nil)
    }
    var draft = MetadataDraft(metadata: valid)
    draft.title = String(repeating: "é", count: 129)
    #expect(!draft.isValid)
    draft.title = "Title"
    draft.userLabels = ["line\nbreak"]
    #expect(!draft.isValid)
  }
}

private func identity(_ value: Int) -> String { "sha256:" + String(format: "%064x", value) }
private func removed(_ value: Int) -> RemovedArtwork {
  RemovedArtwork(
    id: identity(value), title: "Removed \(value)", removedAtMs: 1,
    storageState: "active", retentionReasons: ["pinned"])
}

private actor MetadataClient: CoreClient {
  private var current = CoreSnapshot(
    targets: [], selectedTargetID: nil,
    items: [
      LibraryItem(id: identity(1), title: "First", digest: identity(1)),
      LibraryItem(id: identity(2), title: "Second", digest: identity(2)),
    ], statusMessage: "Ready")
  private var first = LibraryMetadata(
    itemID: identity(1), revision: identity(101), title: "First",
    sourceKind: "import", width: 2, height: 1,
    labels: [
      ArtworkLabel(label: "forest", provenance: "vision", confidence: 0.8, revision: "vision-1")
    ])
  private var sent: [CoreCommand] = []
  private let holdSends: Bool
  private var holdMetadata: Bool
  private var sendContinuation: CheckedContinuation<Void, Never>?
  private var metadataContinuation: CheckedContinuation<Void, Never>?

  init(holdSends: Bool = false, holdMetadata: Bool = false) {
    self.holdSends = holdSends
    self.holdMetadata = holdMetadata
  }

  func snapshot() -> CoreSnapshot { current }
  func snapshot(query _: String) -> CoreSnapshot { current }
  func commands() -> [CoreCommand] { sent }

  func metadata(itemID: String) async -> LibraryMetadata {
    if itemID == identity(1) {
      if holdMetadata {
        holdMetadata = false
        let old = first
        await withCheckedContinuation { metadataContinuation = $0 }
        return old
      }
      return first
    }
    return LibraryMetadata(
      itemID: identity(2), revision: identity(102), title: "Second",
      sourceKind: "import", width: 2, height: 1)
  }

  func changeMetadata() {
    first = LibraryMetadata(
      itemID: identity(1), revision: identity(301), title: "External title",
      sourceKind: "import", width: 2, height: 1)
  }

  func recovery(afterID: String?) -> LibraryRecoveryPage {
    if afterID == nil {
      return LibraryRecoveryPage(items: (1000...1049).map(removed), nextCursor: identity(1049))
    }
    return LibraryRecoveryPage(items: [removed(1050)])
  }

  func send(_ command: CoreCommand) async -> CoreSnapshot {
    sent.append(command)
    if holdSends { await withCheckedContinuation { sendContinuation = $0 } }
    if command.kind == .updateMetadata {
      first = LibraryMetadata(
        itemID: identity(1), revision: identity(201), title: command.title!,
        sourceKind: "import", width: 2, height: 1,
        labels: command.userLabels!.map { ArtworkLabel(label: $0, provenance: "user") })
      current.updatedMetadata = first
    } else if command.kind == .restore {
      current.items.append(
        LibraryItem(id: command.itemID!, title: "Restored", digest: command.itemID!))
    }
    return current
  }

  func waitForCommand() async { while sendContinuation == nil { await Task.yield() } }
  func completeSend() {
    sendContinuation?.resume()
    sendContinuation = nil
  }
  func waitForMetadata() async { while metadataContinuation == nil { await Task.yield() } }
  func completeMetadata() {
    metadataContinuation?.resume()
    metadataContinuation = nil
  }
}
