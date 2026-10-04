import Foundation
import OSLog
import Observation

@MainActor
@Observable
public final class ShellModel {
  private static let logger = Logger(subsystem: "io.frameshift.app", category: "shell")
  public private(set) var snapshot: CoreSnapshot
  public let storageSettings: StorageSettingsModel
  public let similarity: VisualSimilarityModel
  public private(set) var isBusy = false
  public private(set) var errorMessage: String?
  public var draftInstruction: String
  public private(set) var searchQuery = ""
  public private(set) var libraryFilters = LibraryFilters()
  public private(set) var searchError: String?
  public private(set) var searchItems: [LibraryItem]?
  public private(set) var guideHandoff: GuideHandoff?
  public private(set) var selectedItem: LibraryItem?
  public private(set) var selectedPreview: ArtworkPreview?
  public private(set) var previewMessage: String?
  public private(set) var isPreviewLoading = false
  public private(set) var selectedMetadata: LibraryMetadata?
  public private(set) var metadataMessage: String?
  public private(set) var isMetadataLoading = false
  public private(set) var removedItems: [RemovedArtwork] = []
  public private(set) var recoveryCursor: String?
  public private(set) var recoveryMessage: String?
  public private(set) var isRecoveryLoading = false
  public var isRecoveryPresented = false
  public private(set) var isAnalysisBusy = false
  public private(set) var analysisMessage: String?

  private let client: any CoreClient
  private var searchRevision = 0
  private var playlistDrafts: [String: PlaylistDraft] = [:]
  private var previewRevision = 0
  private var previewWorkerActive = false
  private var metadataDrafts: [String: MetadataDraft] = [:]
  private var metadataRevision = 0
  private var metadataLoad: (itemID: String, revision: Int, task: Task<Void, Never>)?
  private var recoveryRevision = 0
  private var analysisTask: Task<Void, Never>?
  private var analysisQueue: [(itemID: String, force: Bool)] = []
  private var analysisAttempted: Set<String> = []
  private var analysisRemaining = 16
  private var automaticAnalysisStopped = false
  private var analysisOverflow = false

  public init(
    client: any CoreClient,
    initialSnapshot: CoreSnapshot = .disconnected
  ) {
    self.client = client
    storageSettings = StorageSettingsModel(client: client)
    similarity = VisualSimilarityModel(client: client)
    snapshot = initialSnapshot
    draftInstruction = initialSnapshot.instruction
  }

  public func refresh() async {
    if await perform({ try await client.snapshot() }) {
      similarity.invalidate()
      automaticAnalysisStopped = false
      startAnalysis(discoverPending: true)
    }
  }

  public func analyzeSelectedArtwork() {
    guard !similarity.isBusy, let itemID = selectedItem?.id else { return }
    automaticAnalysisStopped = false
    enqueueAnalysis(itemID, force: true)
  }

  public func stopAnalysis() {
    automaticAnalysisStopped = true
    analysisQueue.removeAll()
    analysisTask?.cancel()
    analysisMessage = "Stopping local labeling. An accepted save may still finish."
  }

  private func enqueueAnalysis(_ itemID: String, force: Bool) {
    guard !similarity.isBusy else {
      analysisMessage = "Artwork saved. Refresh after local comparison to resume labeling."
      return
    }
    guard validLibraryDigest(itemID), !automaticAnalysisStopped else { return }
    if analysisTask == nil {
      analysisRemaining = 16
      analysisAttempted.removeAll()
    }
    guard !analysisAttempted.contains(itemID) else { return }
    if let index = analysisQueue.firstIndex(where: { $0.itemID == itemID }) {
      analysisQueue[index].force = analysisQueue[index].force || force
    } else if analysisQueue.count < analysisRemaining {
      analysisQueue.append((itemID, force))
    } else {
      analysisOverflow = true
    }
    startAnalysis(discoverPending: false)
  }

  private func startAnalysis(discoverPending: Bool) {
    guard analysisTask == nil, !automaticAnalysisStopped, !similarity.isBusy else { return }
    analysisRemaining = 16
    analysisAttempted.removeAll()
    analysisOverflow = false
    isAnalysisBusy = true
    analysisMessage = "Labeling artwork locally…"
    analysisTask = Task { await runAnalysisBatch(discoverPending: discoverPending) }
  }

  private func runAnalysisBatch(discoverPending: Bool) async {
    defer {
      if Task.isCancelled, analysisMessage?.hasPrefix("Stopping local labeling") == true {
        analysisMessage = "Local labeling stopped."
      }
      analysisTask = nil
      analysisQueue.removeAll()
      isAnalysisBusy = false
    }
    var hasMore = false
    var saved = 0
    var failed = 0
    if discoverPending {
      do {
        let pending = try await client.analysisPending()
        try pending.validate()
        guard !Task.isCancelled else { return }
        hasMore = pending.hasMore
        for itemID in pending.itemIDs where !analysisQueue.contains(where: { $0.itemID == itemID })
        {
          if analysisQueue.count < analysisRemaining {
            analysisQueue.append((itemID, false))
          } else {
            hasMore = true
          }
        }
      } catch {
        analysisMessage = "Local labeling is unavailable. Refresh or analyze an artwork to retry."
        return
      }
    }
    while !Task.isCancelled, analysisRemaining > 0, !analysisQueue.isEmpty {
      let job = analysisQueue.removeFirst()
      analysisRemaining -= 1
      analysisAttempted.insert(job.itemID)
      do {
        // A background snapshot can predate newer ordinary commands. Read only
        // current metadata/search after the commit; never apply that snapshot.
        _ = try await client.analyzeArtwork(itemID: job.itemID, force: job.force)
        saved += 1
        if selectedItem?.id == job.itemID {
          metadataRevision += 1
          metadataLoad = nil
          await loadSelectedMetadata()
        }
        await refreshSearch()
      } catch CoreClientError.commandOutcomeUnknown {
        analysisQueue.removeAll()
        if selectedItem?.id == job.itemID {
          metadataRevision += 1
          metadataLoad = nil
          await loadSelectedMetadata()
        }
        analysisMessage =
          "The labeling save was not confirmed. Review current metadata before retrying."
        return
      } catch {
        if !Task.isCancelled { failed += 1 }
      }
    }
    if Task.isCancelled {
      analysisMessage =
        saved > 0 ? "Local analysis saved; background labeling stopped." : "Local labeling stopped."
    } else if failed > 0 {
      analysisMessage = "Some artwork could not be labeled. Refresh or analyze it to retry."
    } else if hasMore || analysisOverflow {
      analysisMessage = "Local labeling batch finished. Refresh to label more artwork."
    } else {
      analysisMessage =
        saved > 0 ? "Local artwork analysis saved." : "Local artwork analysis is up to date."
    }
  }

  public var visibleItems: [LibraryItem] {
    searchItems ?? snapshot.items
  }

  public func selectItem(_ itemID: String?) {
    let previous = previewScope
    guard let itemID else {
      selectedItem = nil
      similarity.invalidate()
      invalidatePreview()
      invalidateMetadata()
      return
    }
    guard
      let item = visibleItems.first(where: { $0.id == itemID })
        ?? snapshot.items.first(where: { $0.id == itemID })
        ?? similarity.result?.matches.first(where: { $0.item.id == itemID })?.item
    else { return }
    selectedItem = item
    if previous?.masterID != itemID { similarity.invalidate() }
    if previewScope != previous { invalidatePreview() }
    if previous?.masterID != itemID { invalidateMetadata() }
  }

  private func invalidateMetadata() {
    metadataRevision += 1
    metadataLoad = nil
    selectedMetadata = nil
    metadataMessage = nil
    isMetadataLoading = selectedItem != nil
    Task { await loadSelectedMetadata() }
  }

  public var metadataDraft: MetadataDraft? {
    guard let itemID = selectedItem?.id else { return nil }
    return metadataDrafts[itemID]
  }

  public var metadataIsStale: Bool {
    guard let draft = metadataDraft, let selectedMetadata else { return false }
    return draft.base.revision != selectedMetadata.revision
  }

  public func loadSelectedMetadata(discardDraft: Bool = false) async {
    guard let itemID = selectedItem?.id else { return }
    let load: (itemID: String, revision: Int, task: Task<Void, Never>)
    if let active = metadataLoad, active.itemID == itemID {
      load = active
    } else {
      metadataRevision += 1
      let revision = metadataRevision
      isMetadataLoading = true
      let task = Task { await fetchMetadata(itemID: itemID, revision: revision) }
      load = (itemID, revision, task)
      metadataLoad = load
    }
    await load.task.value
    if discardDraft, load.revision == metadataRevision, selectedItem?.id == itemID,
      let metadata = selectedMetadata
    {
      metadataDrafts[itemID] = MetadataDraft(metadata: metadata)
    }
  }

  private func fetchMetadata(itemID: String, revision: Int) async {
    defer {
      if revision == metadataRevision {
        isMetadataLoading = false
        metadataLoad = nil
      }
    }
    do {
      let metadata = try await client.metadata(itemID: itemID)
      guard revision == metadataRevision, selectedItem?.id == itemID else { return }
      try metadata.validate(itemID: itemID)
      selectedMetadata = metadata
      if metadataDrafts[itemID]?.hasChanges != true {
        metadataDrafts[itemID] = MetadataDraft(metadata: metadata)
      }
      metadataMessage = nil
    } catch {
      guard revision == metadataRevision else { return }
      metadataMessage = "Metadata is unavailable. Refresh or retry this artwork."
    }
  }

  public func setMetadataTitle(_ title: String) {
    guard let itemID = selectedItem?.id else { return }
    metadataDrafts[itemID]?.title = title
  }

  public func addUserLabel(_ label: String) {
    guard let itemID = selectedItem?.id, var draft = metadataDrafts[itemID],
      draft.userLabels.count < 32
    else { return }
    let normalized = label.precomposedStringWithCanonicalMapping.trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !draft.userLabels.contains(normalized) else { return }
    draft.userLabels.append(normalized)
    metadataDrafts[itemID] = draft
  }

  public func removeUserLabel(at index: Int) {
    guard let itemID = selectedItem?.id, var draft = metadataDrafts[itemID],
      draft.userLabels.indices.contains(index)
    else { return }
    draft.userLabels.remove(at: index)
    metadataDrafts[itemID] = draft
  }

  public func toggleLabelDismissal(_ label: ArtworkLabel) {
    guard label.provenance != "user", let itemID = selectedItem?.id,
      var draft = metadataDrafts[itemID], draft.machineLabels.contains(label)
    else { return }
    let dismissal = LabelDismissal(label: label.label, provenance: label.provenance)
    if draft.dismissedLabels.contains(dismissal) {
      draft.dismissedLabels.removeAll { $0 == dismissal }
    } else {
      draft.dismissedLabels.append(dismissal)
    }
    metadataDrafts[itemID] = draft
  }

  public func saveMetadata() async {
    guard !metadataIsStale, let itemID = selectedItem?.id, let submitted = metadataDraft,
      submitted.hasChanges, submitted.isValid, !isMetadataLoading
    else { return }
    let saved = await send(
      CoreCommand(
        kind: .updateMetadata, itemID: itemID,
        metadataRevision: submitted.base.revision, title: submitted.title,
        userLabels: submitted.userLabels, dismissedLabels: submitted.dismissedLabels))
    guard saved else { return }
    guard let committed = snapshot.updatedMetadata, committed.itemID == itemID,
      (try? committed.validate(itemID: itemID)) != nil
    else {
      metadataMessage = "The edit was applied. Reload current metadata before editing again."
      return
    }
    if metadataDrafts[itemID] == submitted {
      metadataDrafts[itemID] = MetadataDraft(metadata: committed)
    } else if var newer = metadataDrafts[itemID] {
      newer.base = committed
      newer.dismissedLabels.removeAll { dismissal in
        !committed.labels.contains {
          $0.label == dismissal.label && $0.provenance == dismissal.provenance
        }
      }
      metadataDrafts[itemID] = newer
    }
    if selectedItem?.id == itemID {
      selectedMetadata = committed
      metadataMessage = nil
    }
  }

  public func loadRecovery(reset: Bool = false) async {
    if reset { recoveryRevision += 1 }
    guard reset || (!isRecoveryLoading && recoveryCursor != nil) else { return }
    let revision = recoveryRevision
    let cursor = reset ? nil : recoveryCursor
    isRecoveryLoading = true
    defer { if revision == recoveryRevision { isRecoveryLoading = false } }
    do {
      let page = try await client.recovery(afterID: cursor)
      guard revision == recoveryRevision else { return }
      try page.validate(afterID: cursor)
      if reset { removedItems = page.items } else { removedItems.append(contentsOf: page.items) }
      recoveryCursor = page.nextCursor
      recoveryMessage = nil
    } catch {
      guard revision == recoveryRevision else { return }
      recoveryMessage = "Recently Removed is unavailable. Refresh to retry."
    }
  }

  public func restoreArtwork(_ itemID: String) async {
    guard removedItems.contains(where: { $0.id == itemID }) else { return }
    if await send(CoreCommand(kind: .restore, itemID: itemID)) {
      removedItems.removeAll { $0.id == itemID }
      metadataDrafts.removeValue(forKey: itemID)
      recoveryRevision += 1
      isRecoveryLoading = false
    }
  }

  private var previewScope: PreviewScope? {
    guard let selectedItem else { return nil }
    let target = snapshot.selectedTarget
    return PreviewScope(
      masterID: selectedItem.id, targetID: target?.id, profileID: target?.profileID,
      capabilityDigest: target?.capabilityDigest)
  }

  private func invalidatePreview() {
    previewRevision += 1
    selectedPreview = nil
    previewMessage = nil
    isPreviewLoading = selectedItem != nil
    Task { await loadSelectedPreview() }
  }

  public func retryPreview() async {
    invalidatePreview()
    await loadSelectedPreview()
  }

  public func loadSelectedPreview() async {
    guard !previewWorkerActive, selectedPreview == nil else { return }
    previewWorkerActive = true
    defer {
      previewWorkerActive = false
      isPreviewLoading = false
    }
    while let scope = previewScope {
      let revision = previewRevision
      let target = snapshot.selectedTarget
      isPreviewLoading = true
      do {
        let preview = try await client.preview(masterID: scope.masterID, target: target)
        guard revision == previewRevision else { continue }
        try preview.validate(masterID: scope.masterID, target: target)
        selectedPreview = preview
        previewMessage = nil
      } catch {
        guard revision == previewRevision else { continue }
        switch error {
        case CoreClientError.previewBusy:
          previewMessage = "The renderer is busy. Retry after the current artwork finishes."
        case CoreClientError.previewProfileChanged:
          previewMessage = "Frame capabilities changed. Refresh the target and retry."
        case CoreClientError.itemNotFound:
          previewMessage = "This master is no longer available. Refresh the library."
        case CoreClientError.protocolFailure:
          previewMessage = "Preview identity or bytes could not be verified. Retry the preview."
        default:
          previewMessage = "Preview is unavailable for this source or profile. Refresh and retry."
        }
      }
      return
    }
  }

  public var hasUnsavedInstruction: Bool {
    draftInstruction != snapshot.instruction
  }

  public func setSearchQuery(_ query: String) {
    similarity.invalidate()
    searchQuery = query
    searchRevision += 1
    let revision = searchRevision

    guard !query.isEmpty || libraryFilters.isActive else {
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

  public func setLibraryFilters(_ filters: LibraryFilters) {
    libraryFilters = filters
    searchItems = filters.isActive || !searchQuery.isEmpty ? [] : nil
    setSearchQuery(searchQuery)
  }

  public func setPinnedFilter(_ pinnedOnly: Bool) {
    var filters = libraryFilters
    filters.pinnedOnly = pinnedOnly
    setLibraryFilters(filters)
  }

  public func setSourceFilter(_ sourceKind: ArtworkSource?) {
    var filters = libraryFilters
    filters.sourceKind = sourceKind
    setLibraryFilters(filters)
  }

  public func setFrameFilter(_ frameID: String?) {
    var filters = libraryFilters
    filters.frameID = frameID
    setLibraryFilters(filters)
  }

  public func resetLibraryFilters() { setLibraryFilters(LibraryFilters()) }

  public func submitSearch() async {
    await refreshSearch()
  }

  private func refreshSearch() async {
    guard !searchQuery.isEmpty || libraryFilters.isActive else { return }
    guard searchQuery.utf8.count <= 256 else { return }
    searchRevision += 1
    await loadSearch(searchQuery, revision: searchRevision)
  }

  private func loadSearch(_ query: String, revision: Int) async {
    do {
      let result = try await client.snapshot(query: query, filters: libraryFilters)
      guard revision == searchRevision else { return }
      searchItems = result.items
      updateSelection(from: result.items)
      searchError = nil
    } catch {
      guard revision == searchRevision else { return }
      searchItems = []
      searchError =
        libraryFilters.isActive
        ? "Filtered Library search is unavailable. Refresh or reset the filters."
        : "Library search is unavailable."
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
    if await send(CoreCommand(kind: .importFile, importPath: url.path)),
      let itemID = snapshot.importedItemID
    {
      enqueueAnalysis(itemID, force: false)
    }
  }

  public func findSimilarArtwork() {
    guard !isAnalysisBusy, let itemID = selectedItem?.id else { return }
    similarity.start(itemID: itemID, filters: libraryFilters)
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
    if removed, selectedItem?.id == itemID {
      selectedItem = nil
      similarity.invalidate()
      invalidatePreview()
      invalidateMetadata()
    }
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
      if [.importFile, .setPinned, .remove, .restore, .updateMetadata, .recordVision].contains(
        command.kind)
      {
        similarity.invalidate()
      }
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
    } catch CoreClientError.libraryStorageFull {
      errorMessage = "The host Library reached its byte budget. Review Storage in Settings."
    } catch CoreClientError.storageUnavailable {
      errorMessage =
        "Storage settings are unavailable. Review them in Settings before adding artwork."
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
    } catch CoreClientError.metadataRevisionConflict {
      errorMessage = "Artwork metadata changed. Reload and review it before saving again."
      await loadSelectedMetadata()
    } catch CoreClientError.invalidMetadata {
      errorMessage = "Use a title up to 256 bytes and at most 32 labels of 128 bytes each."
    } catch CoreClientError.restoreFailed {
      errorMessage =
        "The retained artwork could not be verified or restored. It remains in Recently Removed."
    } catch let error as CoreClientError {
      Self.logger.error("core command failed: \(String(describing: error), privacy: .public)")
      errorMessage = "The core command could not be completed."
    } catch {
      errorMessage = "The core command could not be completed."
    }
    await refreshSearch()
    return succeeded
  }

  private func perform(_ operation: () async throws -> CoreSnapshot) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    defer { isBusy = false }

    var succeeded = false
    do {
      apply(try await operation())
      errorMessage = nil
      succeeded = true
    } catch let error as CoreClientError {
      Self.logger.error("core refresh failed: \(String(describing: error), privacy: .public)")
      errorMessage = "The core command could not be completed."
    } catch {
      errorMessage = "The core command could not be completed."
    }
    await refreshSearch()
    return succeeded
  }

  private func apply(_ next: CoreSnapshot) {
    let previousPreview = previewScope
    let preserveDraft = hasUnsavedInstruction
    snapshot = next
    if !preserveDraft { draftInstruction = next.instruction }
    updateSelection(from: next.items)
    if previewScope != previousPreview { invalidatePreview() }
    if let metadata = next.updatedMetadata, metadata.itemID == selectedItem?.id,
      (try? metadata.validate(itemID: metadata.itemID)) != nil
    {
      metadataRevision += 1
      metadataLoad = nil
      isMetadataLoading = false
      selectedMetadata = metadata
      if let item = selectedItem {
        selectedItem = LibraryItem(
          id: item.id, title: metadata.title, digest: item.digest,
          isPinned: item.isPinned, queuedTargetID: item.queuedTargetID, loopStatus: item.loopStatus)
      }
    } else if selectedItem != nil {
      Task { await loadSelectedMetadata() }
    }
  }

  private func updateSelection(from items: [LibraryItem]) {
    guard let selectedItem,
      let current = items.first(where: { $0.id == selectedItem.id })
    else { return }
    self.selectedItem = current
  }
}

private struct PreviewScope: Equatable {
  let masterID: String
  let targetID: String?
  let profileID: String?
  let capabilityDigest: String?
}
