import Foundation
import FrameshiftShell
import Testing

@Suite("Native Library search facets")
@MainActor
struct LibraryFilterTests {
  @Test("Empty text uses active facets; refresh and commands retain them without hiding selection")
  func preservesFacets() async throws {
    let client = FilterClient()
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem("generated")
    model.draftInstruction = "Unsaved instruction"
    model.setLibraryFilters(
      LibraryFilters(pinnedOnly: true, sourceKind: .imported, frameID: "frame-a"))
    await model.submitSearch()
    #expect(model.visibleItems.map(\.id) == ["imported"])
    #expect(model.selectedItem?.id == "generated")
    #expect(model.snapshot.selectedTargetID == "frame-b")
    await model.refresh()
    #expect(model.visibleItems.map(\.id) == ["imported"])
    await model.togglePin("imported")
    #expect(model.visibleItems.isEmpty)
    #expect(
      model.libraryFilters
        == LibraryFilters(pinnedOnly: true, sourceKind: .imported, frameID: "frame-a"))
    #expect(model.draftInstruction == "Unsaved instruction")
    model.resetLibraryFilters()
    #expect(model.visibleItems.count == 2)
    #expect(model.selectedItem?.id == "generated")
  }

  @Test("An older facet response cannot replace the current filtered set")
  func refusesLateFacets() async {
    let client = FilterClient(holdImported: true)
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.setSourceFilter(.imported)
    let old = Task { await model.submitSearch() }
    await client.waitForRead()
    model.setSourceFilter(.generated)
    await model.submitSearch()
    #expect(model.visibleItems.map(\.id) == ["generated"])
    await client.completeRead()
    await old.value
    #expect(model.visibleItems.map(\.id) == ["generated"])
    #expect(model.libraryFilters.sourceKind == .generated)
  }

  @Test("A client without facet support refuses rather than returning an unfiltered library")
  func refusesUnsupportedClient() async {
    let client = UnfilteredClient()
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.setPinnedFilter(true)
    await model.submitSearch()
    #expect(model.visibleItems.isEmpty)
    #expect(model.searchError?.contains("reset the filters") == true)
    model.resetLibraryFilters()
    #expect(model.visibleItems.count == 1)
  }

  @Test("Facet encoding uses exact source identities and frame bounds")
  func validatesWireFields() throws {
    let encoded = try JSONEncoder().encode(
      LibraryFilters(pinnedOnly: true, sourceKind: .imported, frameID: "frame-a"))
    let value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(value.keys) == Set(["pinnedOnly", "sourceKind", "frameID"]))
    #expect(value["sourceKind"] as? String == "import")
    #expect(throws: CoreClientError.invalidCommand) { try LibraryFilters(frameID: "").validate() }
    #expect(throws: CoreClientError.invalidCommand) {
      try LibraryFilters(frameID: String(repeating: "é", count: 65)).validate()
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        LibraryFilters.self, from: Data(#"{"pinnedOnly":true,"sourceKind":"provider"}"#.utf8))
    }
  }
}

private actor FilterClient: CoreClient {
  private var current = CoreSnapshot(
    targets: [
      FrameTarget(
        id: "frame-a", name: "A", medium: .photo, profileID: "rgb", state: .waitingForContact),
      FrameTarget(
        id: "frame-b", name: "B", medium: .photo, profileID: "rgb", state: .waitingForContact),
    ],
    selectedTargetID: "frame-b",
    items: [
      LibraryItem(id: "imported", title: "Imported", digest: "imported", isPinned: true),
      LibraryItem(id: "generated", title: "Generated", digest: "generated"),
    ], statusMessage: "Ready")
  private var holdImported: Bool
  private var continuation: CheckedContinuation<Void, Never>?

  init(holdImported: Bool = false) { self.holdImported = holdImported }
  func snapshot() -> CoreSnapshot { current }
  func snapshot(query _: String) -> CoreSnapshot { current }
  func snapshot(query: String, filters: LibraryFilters) async -> CoreSnapshot {
    var result = current
    if holdImported, filters.sourceKind == .imported {
      holdImported = false
      await withCheckedContinuation { continuation = $0 }
    }
    result.items = result.items.filter { item in
      (query.isEmpty || item.title.localizedCaseInsensitiveContains(query))
        && (!filters.pinnedOnly || item.isPinned)
        && (filters.sourceKind == nil
          || (filters.sourceKind == .imported ? item.id == "imported" : item.id == "generated"))
        && (filters.frameID == nil || item.id == "imported")
    }
    return result
  }
  func send(_ command: CoreCommand) -> CoreSnapshot {
    if command.kind == .setPinned,
      let index = current.items.firstIndex(where: { $0.id == command.itemID })
    {
      current.items[index].isPinned = command.isPinned!
    }
    return current
  }
  func waitForRead() async { while continuation == nil { await Task.yield() } }
  func completeRead() {
    continuation?.resume()
    continuation = nil
  }
}

private struct UnfilteredClient: CoreClient {
  func snapshot() -> CoreSnapshot {
    CoreSnapshot(
      targets: [], selectedTargetID: nil,
      items: [LibraryItem(id: "one", title: "One", digest: "one")], statusMessage: "Ready")
  }
  func snapshot(query _: String) -> CoreSnapshot { snapshot() }
  func send(_: CoreCommand) -> CoreSnapshot { snapshot() }
}
