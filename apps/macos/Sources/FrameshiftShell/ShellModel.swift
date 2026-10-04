import Foundation
import OSLog
import Observation

@MainActor
@Observable
public final class ShellModel {
  private static let logger = Logger(subsystem: "io.frameshift.app", category: "shell")
  public private(set) var snapshot: CoreSnapshot
  public private(set) var isBusy = false
  public private(set) var errorMessage: String?
  public var draftInstruction: String
  public private(set) var searchQuery = ""
  public private(set) var searchError: String?
  public private(set) var searchItems: [LibraryItem]?
  public private(set) var guideHandoff: GuideHandoff?
  public private(set) var selectedItem: LibraryItem?

  private let client: any CoreClient
  private var searchRevision = 0
  private var playlistDrafts: [String: PlaylistDraft] = [:]

  public init(
    client: any CoreClient,
    initialSnapshot: CoreSnapshot = .disconnected
  ) {
    self.client = client
    snapshot = initialSnapshot
    draftInstruction = initialSnapshot.instruction
  }

  public func refresh() async {
    await perform { try await client.snapshot() }
  }

  public var visibleItems: [LibraryItem] {
    searchItems ?? snapshot.items
  }

  public func selectItem(_ itemID: String?) {
    guard let itemID else {
      selectedItem = nil
      return
    }
    guard
      let item = visibleItems.first(where: { $0.id == itemID })
        ?? snapshot.items.first(where: { $0.id == itemID })
    else { return }
    selectedItem = item
  }

  public var hasUnsavedInstruction: Bool {
    draftInstruction != snapshot.instruction
  }

  public func setSearchQuery(_ query: String) {
    searchQuery = query
    searchRevision += 1
    let revision = searchRevision

    guard !query.isEmpty else {
      searchItems = nil
      searchError = nil
      return
    }

    guard query.utf8.count <= 256 else {
      searchItems = []
      searchError = "Search is limited to 256 bytes."
      return
    }

    Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard revision == searchRevision else { return }
      await loadSearch(query, revision: revision)
    }
  }

  public func submitSearch() async {
    await refreshSearch()
  }

  private func refreshSearch() async {
    guard !searchQuery.isEmpty, searchQuery.utf8.count <= 256 else { return }
    searchRevision += 1
    await loadSearch(searchQuery, revision: searchRevision)
  }

  private func loadSearch(_ query: String, revision: Int) async {
    do {
      let result = try await client.snapshot(query: query)
      guard revision == searchRevision else { return }
      searchItems = result.items
      updateSelection(from: result.items)
      searchError = nil
    } catch {
      guard revision == searchRevision else { return }
      searchItems = []
      searchError = "Library search is unavailable."
    }
  }

  public func selectTarget(_ targetID: String) async {
    await send(CoreCommand(kind: .selectTarget, targetID: targetID))
  }

  public func receiveGuideURL(_ url: URL) {
    guard let handoff = GuideHandoff.parse(url) else { return }
    guideHandoff = handoff
  }

  public func dismissGuideHandoff() {
    guideHandoff = nil
  }

  public var guideMatchingTargets: [FrameTarget] {
    guard let handoff = guideHandoff else { return [] }
    return snapshot.targets.filter { target in
      target.medium == handoff.medium
        && (handoff.profileID == nil || target.profileID == handoff.profileID)
    }
  }

  public func saveInstruction() async {
    await send(CoreCommand(kind: .updateInstruction, instruction: draftInstruction))
  }

  public func importFile(_ url: URL) async {
    await send(CoreCommand(kind: .importFile, importPath: url.path))
  }

  public func togglePin(_ itemID: String) async {
    guard
      let item = visibleItems.first(where: { $0.id == itemID })
        ?? snapshot.items.first(where: { $0.id == itemID })
        ?? (selectedItem?.id == itemID ? selectedItem : nil)
    else { return }
    await send(CoreCommand(kind: .setPinned, itemID: itemID, isPinned: !item.isPinned))
  }

  public func remove(_ itemID: String) async {
    let removed = await send(CoreCommand(kind: .remove, itemID: itemID))
    if removed, selectedItem?.id == itemID { selectedItem = nil }
  }

  public func queue(_ itemID: String) async {
    guard let selectedTargetID = snapshot.selectedTargetID else { return }
    await send(
      CoreCommand(
        kind: .queue,
        targetID: selectedTargetID,
        itemID: itemID
      )
    )
  }

  public func loopPinned(dwellMs: Int?) async {
    guard let selectedTargetID = snapshot.selectedTargetID else { return }
    await send(CoreCommand(kind: .loopPinned, targetID: selectedTargetID, dwellMs: dwellMs))
  }

  public var playlistDraft: PlaylistDraft? {
    guard let target = snapshot.selectedTarget else { return nil }
    return playlistDrafts[target.id] ?? PlaylistDraft(target: target)
  }

  public func beginPlaylistEdit() {
    editPlaylist { _ in }
  }

  public func reloadSavedPlaylist() {
    guard let target = snapshot.selectedTarget else { return }
    playlistDrafts[target.id] = PlaylistDraft(target: target)
  }

  private func editPlaylist(_ change: (inout PlaylistDraft) -> Void) {
    guard let target = snapshot.selectedTarget else { return }
    var draft = playlistDrafts[target.id] ?? PlaylistDraft(target: target)
    change(&draft)
    playlistDrafts[target.id] = draft
  }

  public func usePinnedArtwork() {
    guard snapshot.pinnedSetTooLarge != true, let pins = snapshot.pinnedItems else {
      errorMessage =
        "The full pin set is unavailable or exceeds 64 stills. Review the library pins."
      return
    }
    editPlaylist { $0.items = pins }
  }

  public func addSelectedToPlaylist() {
    guard let selectedItem else { return }
    editPlaylist { draft in
      guard !draft.items.contains(where: { $0.id == selectedItem.id }), draft.items.count < 64
      else {
        return
      }
      draft.items.append(
        PlaylistItem(id: selectedItem.id, digest: selectedItem.digest, title: selectedItem.title))
    }
  }

  public func removePlaylistItem(_ itemID: String) {
    editPlaylist { $0.items.removeAll { $0.id == itemID } }
  }

  public func movePlaylistItem(_ itemID: String, offset: Int) {
    guard offset == -1 || offset == 1 else { return }
    editPlaylist { draft in
      guard let index = draft.items.firstIndex(where: { $0.id == itemID }),
        draft.items.indices.contains(index + offset)
      else { return }
      draft.items.swapAt(index, index + offset)
    }
  }

  public func setPlaylistInterval(_ input: String) {
    editPlaylist { $0.intervalInput = input }
  }

  public func setPlaylistIntervalUnit(_ unit: LoopIntervalInput.Unit) {
    editPlaylist { $0.intervalUnit = unit }
  }

  public func setPlaylistProfileSuggestion(_ enabled: Bool) {
    editPlaylist { $0.useProfileSuggestion = enabled }
  }

  public var canQueuePlaylist: Bool {
    guard let target = snapshot.selectedTarget, let draft = playlistDraft else { return false }
    return !draft.items.isEmpty
      && draft.items.count <= min(64, target.maximumPlaylistLength ?? 64)
      && draft.effectiveDwell(for: target) != nil
  }

  public func queuePlaylist() async {
    guard canQueuePlaylist, let target = snapshot.selectedTarget, let draft = playlistDraft else {
      return
    }
    await send(
      CoreCommand(
        kind: .loopArtwork, targetID: target.id,
        dwellMs: draft.useProfileSuggestion ? nil : draft.effectiveDwell(for: target),
        itemIDs: draft.items.map(\.id)))
  }

  public func resumePlaylist() async {
    guard let target = snapshot.selectedTarget, let playlist = target.playlist,
      playlist.status == .suspended, playlist.requiresRevalidation != true,
      target.hasQueuedDelivery != true, target.directDelivery?.status != .pending
    else { return }
    await send(
      CoreCommand(kind: .resumePlaylist, targetID: target.id, playlistRevision: playlist.revision))
  }

  public func reconcileDelivery() async {
    guard let selectedTargetID = snapshot.selectedTargetID else { return }
    await send(CoreCommand(kind: .reconcileDelivery, targetID: selectedTargetID))
  }

  public func dismissError() {
    errorMessage = nil
  }

  @discardableResult
  private func send(_ command: CoreCommand) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    defer { isBusy = false }
    var succeeded = false

    do {
      apply(try await client.send(command))
      errorMessage = nil
      succeeded = true
    } catch CoreClientError.commandOutcomeUnknown {
      do {
        apply(try await client.snapshot())
        errorMessage =
          "The core restarted before it could confirm the command. Current state was refreshed; review it before trying again."
      } catch {
        errorMessage =
          "The core restarted before it could confirm the command. Reconnect and review current state before trying again."
      }
    } catch CoreClientError.commandIDConflict {
      errorMessage = "The command identity was rejected. Refresh and try the operation again."
    } catch CoreClientError.deliveryOutcomeUnknown {
      do {
        apply(try await client.snapshot())
        errorMessage =
          "The frame did not confirm display. Its pending delivery is saved; check the frame before sending again."
      } catch {
        errorMessage =
          "The frame did not confirm display. Reconnect and check its delivery state before sending again."
      }
    } catch CoreClientError.credentialBrokerUnavailable {
      errorMessage =
        "Secure frame credentials are not available on this Mac. Direct send was not started."
    } catch CoreClientError.deliveryPending {
      errorMessage =
        "This frame already has a pending direct delivery. Confirm its display before sending another image."
    } catch CoreClientError.noPinnedArtwork {
      errorMessage = "Pin artwork in the library before starting a loop."
    } catch CoreClientError.intervalRequired {
      errorMessage = "Choose a loop interval for this frame."
    } catch CoreClientError.loopUnavailable {
      errorMessage = "Frame cannot cycle artwork offline. Check its pairing and transfer mode."
    } catch CoreClientError.loopStorageFull {
      errorMessage = "This frame cannot hold the set. Reduce its size or free frame storage."
    } catch CoreClientError.loopRevisionConflict {
      errorMessage = "The saved loop changed. Refresh and review the frame before resuming."
    } catch CoreClientError.loopProfileChanged {
      errorMessage = "Frame capabilities changed. Review and queue a newly prepared set."
    } catch CoreClientError.duplicateLoopArtwork {
      errorMessage = "Two stills render to identical frame bytes. Keep one of them in the set."
    } catch CoreClientError.loopPending {
      errorMessage = "This loop is already queued. Wait for the frame to confirm it."
    } catch CoreClientError.loopAlreadyActive {
      errorMessage = "Loop is already on this frame. Change pins or interval to queue another."
    } catch let error as CoreClientError {
      Self.logger.error("core command failed: \(String(describing: error), privacy: .public)")
      errorMessage = "The core command could not be completed."
    } catch {
      errorMessage = "The core command could not be completed."
    }
    await refreshSearch()
    return succeeded
  }

  private func perform(_ operation: () async throws -> CoreSnapshot) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      apply(try await operation())
      errorMessage = nil
    } catch let error as CoreClientError {
      Self.logger.error("core refresh failed: \(String(describing: error), privacy: .public)")
      errorMessage = "The core command could not be completed."
    } catch {
      errorMessage = "The core command could not be completed."
    }
    await refreshSearch()
  }

  private func apply(_ next: CoreSnapshot) {
    let preserveDraft = hasUnsavedInstruction
    snapshot = next
    if !preserveDraft { draftInstruction = next.instruction }
    updateSelection(from: next.items)
  }

  private func updateSelection(from items: [LibraryItem]) {
    guard let selectedItem,
      let current = items.first(where: { $0.id == selectedItem.id })
    else { return }
    self.selectedItem = current
  }
}
