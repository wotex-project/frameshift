import CryptoKit
import Foundation
import FrameshiftShell
import Testing

@Suite("Bounded local visual similarity")
@MainActor
struct VisualSimilarityTests {
  @Test(
    "Observed pages retain nearest ranking with a 100-result ceiling and explicit partial scan",
    arguments: [18, 512, 513])
  func boundedScan(total: Int) async throws {
    let fixture = try ScanFixture(total: total)
    let source = try simSource()
    let result = try await VisualSimilarity.scan(
      source: source,
      load: { try await fixture.page(after: $0) },
      compare: { await fixture.distances($0) }, verifySource: { source })
    try result.validate(itemID: source.itemID)
    #expect(result.scannedCount == min(total, 512))
    #expect(result.matches.count == min(total, 100))
    #expect(result.isPartial == (total > 512))
    #expect(
      result.matches.prefix(2).map(\.item.id) == [
        simID(min(total, 512) - 1), simID(min(total, 512)),
      ])
    #expect(await fixture.readCount() == min(32, (total + 15) / 16))
    #expect(await fixture.maximumCompared() <= 16)
  }

  @Test(
    "Duplicate/corrupt pages, nonfinite distances and replaced source refuse; precancel reads no pages"
  )
  func refusal() async throws {
    let source = try simSource()
    let print = source.featurePrint
    let candidate = SimilarityCandidate(item: simItem(1), featurePrint: print)
    let duplicate = SimilarityCandidatesPage(
      itemID: source.itemID, cohort: source.cohort, featureDigest: print.digest,
      items: [candidate, candidate])
    #expect(throws: CoreClientError.protocolFailure) {
      try duplicate.validate(source: source, afterID: nil)
    }
    let corrupt = SimilarityCandidate(
      item: simItem(1),
      featurePrint: NativeFeaturePrint(
        cohort: print.cohort, archive: print.archive, digest: simID(99)))
    #expect(throws: CoreClientError.protocolFailure) {
      try SimilarityCandidatesPage(
        itemID: source.itemID, cohort: source.cohort, featureDigest: print.digest, items: [corrupt]
      ).validate(source: source, afterID: nil)
    }
    let fixture = try ScanFixture(total: 1)
    await #expect(throws: CoreClientError.protocolFailure) {
      try await VisualSimilarity.scan(
        source: source, load: { try await fixture.page(after: $0) },
        compare: { $0.keys.map { VisualDistance(masterDigest: $0, distance: .nan) } },
        verifySource: { source })
    }
    let replaced = try simSource(bytes: Data("replacement".utf8))
    await #expect(throws: CoreClientError.analysisChanged) {
      try await VisualSimilarity.scan(
        source: source, load: { try await fixture.page(after: $0) },
        compare: { await fixture.distances($0) }, verifySource: { replaced })
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await VisualSimilarity.scan(
        source: source, load: { _ in throw CoreClientError.protocolFailure }, compare: { _ in [] },
        verifySource: { source })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test(
    "Visible timeout and stop retain a non-cooperative owner and discard its late result",
    arguments: [false, true])
  func timeoutOwner(stop: Bool) async throws {
    let client = SimilarityClient(hold: true)
    let model = VisualSimilarityModel(
      client: client, deadline: stop ? .seconds(30) : .milliseconds(15))
    model.start(itemID: simID(0), filters: LibraryFilters())
    await client.waitForStart()
    if stop { model.stop() } else { try await Task.sleep(for: .milliseconds(40)) }
    #expect(model.isBusy)
    #expect(model.result == nil)
    #expect(model.message?.contains(stop ? "Stopping" : "timed out") == true)
    model.start(itemID: simID(1), filters: LibraryFilters())
    #expect(await client.calls().count == 1)
    await client.release()
    await waitForIdle(model)
    #expect(model.result == nil)
    #expect(model.message?.contains(stop ? "stopped" : "timed out") == true)
    #expect(model.message?.contains("Waiting") == false)
  }

  @Test(
    "New selection, facets and literal text invalidate late results without losing drafts",
    arguments: ["selection", "facets", "text"])
  func scopeChanges(change: String) async throws {
    let client = SimilarityClient(hold: true)
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(simID(0))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Unsaved title")
    model.draftInstruction = "Unsaved instruction"
    model.findSimilarArtwork()
    await client.waitForStart()
    switch change {
    case "selection": model.selectItem(simID(1))
    case "facets": model.setPinnedFilter(true)
    default: model.setSearchQuery("forest")
    }
    await client.release()
    await waitForIdle(model.similarity)
    #expect(model.similarity.result == nil)
    #expect(model.draftInstruction == "Unsaved instruction")
    model.selectItem(simID(0))
    await model.loadSelectedMetadata()
    #expect(model.metadataDraft?.title == "Unsaved title")
    model.findSimilarArtwork()
    await waitForIdle(model.similarity)
    #expect(model.similarity.result?.matches.first?.item.id == simID(1000))
    #expect(await client.calls().last?.1.pinnedOnly == (change == "facets"))
    model.selectItem(simID(1000))
    #expect(model.selectedItem?.id == simID(1000))
    #expect(model.similarity.result == nil)
    #expect(model.draftInstruction == "Unsaved instruction")
  }

  private func waitForIdle(_ model: VisualSimilarityModel) async {
    for _ in 0..<1000 {
      if !model.isBusy { return }
      await Task.yield()
    }
    #expect(!model.isBusy)
  }
}

private func simID(_ number: Int) -> String { "sha256:" + String(format: "%064x", number) }
private func simItem(_ number: Int) -> LibraryItem {
  LibraryItem(id: simID(number), title: "Artwork \(number)", digest: simID(number))
}
private func simSource(bytes: Data = Data("opaque fixture".utf8)) throws -> LibraryAnalysis {
  let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let value: [String: Any] = [
    "itemID": simID(0), "cohort": AppleArtworkAnalyzer.cohort,
    "inputDigest": simID(100), "rendererBuildDigest": simID(200), "observedAtMs": 0,
    "featurePrint": [
      "cohort": AppleArtworkAnalyzer.cohort, "digest": hash, "archive": bytes.base64EncodedString(),
    ],
  ]
  return try JSONDecoder().decode(
    LibraryAnalysis.self, from: JSONSerialization.data(withJSONObject: value))
}

private actor ScanFixture {
  private let total: Int
  private let source: LibraryAnalysis
  private var reads = 0
  private var compared = 0
  init(total: Int) throws {
    self.total = total
    source = try simSource()
  }
  func page(after: String?) throws -> SimilarityCandidatesPage {
    reads += 1
    let offset = after.map { Int($0.suffix(8), radix: 16)! } ?? 0
    let last = min(offset + 16, total)
    let items = (offset..<last).map {
      SimilarityCandidate(item: simItem($0 + 1), featurePrint: source.featurePrint)
    }
    return SimilarityCandidatesPage(
      itemID: source.itemID, cohort: source.cohort, featureDigest: source.featurePrint.digest,
      items: items, nextCursor: last < total ? simID(last) : nil)
  }
  func distances(_ prints: [String: NativeFeaturePrint]) -> [VisualDistance] {
    compared = max(compared, prints.count)
    return prints.keys.map {
      VisualDistance(masterDigest: $0, distance: Float((600 - Int($0.suffix(8), radix: 16)!) / 2))
    }
  }
  func readCount() -> Int { reads }
  func maximumCompared() -> Int { compared }
}

private actor SimilarityClient: CoreClient {
  private var hold: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private var requests: [(String, LibraryFilters)] = []
  init(hold: Bool) { self.hold = hold }
  func snapshot() -> CoreSnapshot {
    CoreSnapshot(
      targets: [], selectedTargetID: nil, items: [simItem(0), simItem(1)], statusMessage: "Ready")
  }
  func snapshot(query: String) -> CoreSnapshot { snapshot() }
  func snapshot(query: String, filters: LibraryFilters) -> CoreSnapshot { snapshot() }
  func send(_ command: CoreCommand) -> CoreSnapshot { snapshot() }
  func metadata(itemID: String) -> LibraryMetadata {
    LibraryMetadata(
      itemID: itemID, revision: simID(999), title: "Artwork", sourceKind: "import", width: 2,
      height: 1)
  }
  func waitForStart() async { while continuation == nil { await Task.yield() } }
  func release() {
    hold = false
    continuation?.resume()
    continuation = nil
  }
  func calls() -> [(String, LibraryFilters)] { requests }
  func similarArtwork(itemID: String, filters: LibraryFilters) async -> VisualSimilarityResult {
    requests.append((itemID, filters))
    if hold { await withCheckedContinuation { continuation = $0 } }
    return VisualSimilarityResult(
      itemID: itemID, scannedCount: 1, isPartial: false,
      matches: [VisualMatch(item: simItem(1000), distance: 0)])
  }
}
