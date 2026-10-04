import CryptoKit
import Foundation
import FrameshiftShell
import Testing

@Suite("Persistent native observations and bounded background labeling")
@MainActor
struct LibraryAnalysisTests {
  @Test("Maximum archive keeps existing command limits and read identities refuse tampering")
  func wireBounds() throws {
    let bytes = Data(repeating: 255, count: 16_384)
    let chunks = try featureArchiveChunks(bytes)
    #expect(chunks.map(\.utf8.count) == [8192, 8192, 5464])
    #expect(chunks.reduce(Data()) { $0 + Data(base64Encoded: $1)! } == bytes)
    let cohort = AppleArtworkAnalyzer.cohort
    let labels = (0..<32).map {
      ArtworkLabel(
        label: String(repeating: "x", count: 120) + "\($0)", provenance: "vision", confidence: 1,
        revision: cohort)
    }
    let command = CoreCommand(
      kind: .recordVision, itemID: analysisID(1), metadataRevision: analysisID(10),
      cohort: cohort, inputDigest: analysisID(11), rendererBuildDigest: analysisID(12),
      visionLabels: labels, featureArchiveChunks: chunks, featureDigest: analysisHash(bytes))
    let encoded = try JSONEncoder().encode(command)
    #expect(encoded.count < 64 * 1024)
    #expect(throws: CoreClientError.invalidAnalysis) { try featureArchiveChunks(Data()) }
    #expect(throws: CoreClientError.invalidAnalysis) {
      try featureArchiveChunks(Data(repeating: 0, count: 16_385))
    }
    let valid = try observation(bytes: bytes)
    try valid.validate(itemID: analysisID(1))
    #expect(throws: CoreClientError.protocolFailure) { try valid.validate(itemID: analysisID(2)) }
    #expect(throws: CoreClientError.protocolFailure) {
      try observation(bytes: bytes, changes: ["cohort": "mutable"]).validate(itemID: analysisID(1))
    }
    #expect(throws: CoreClientError.protocolFailure) {
      try observation(
        bytes: bytes,
        changes: [
          "featurePrint": [
            "cohort": cohort, "archive": bytes.base64EncodedString(), "digest": analysisID(9),
          ]
        ]
      ).validate(itemID: analysisID(1))
    }
    #expect(throws: CoreClientError.protocolFailure) {
      try PendingLibraryAnalysis(itemIDs: [analysisID(1), analysisID(1)], hasMore: false).validate()
    }
    #expect(throws: CoreClientError.protocolFailure) {
      try PendingLibraryAnalysis(itemIDs: [analysisID(1)], hasMore: true).validate()
    }
  }

  @Test(
    "Import returns before labeling and stale background snapshots cannot erase new state or drafts"
  )
  func asynchronousImport() async throws {
    let client = AnalysisClient(hold: true)
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    model.selectItem(analysisID(1))
    await model.loadSelectedMetadata()
    model.setMetadataTitle("Unsaved draft")
    model.draftInstruction = "New instruction"
    await model.importFile(URL(fileURLWithPath: "/fixture.png"))
    #expect(!model.isBusy)
    await client.waitForStart()
    #expect(model.isAnalysisBusy)
    await model.saveInstruction()
    await model.togglePin(analysisID(1))
    await client.release()
    await waitForBatch(model)
    #expect(model.snapshot.instruction == "New instruction")
    #expect(model.snapshot.items.first?.isPinned == true)
    #expect(model.selectedItem?.id == analysisID(1))
    #expect(model.metadataDraft?.title == "Unsaved draft")
    #expect(model.metadataIsStale)
    #expect(model.selectedMetadata?.labels.first?.provenance == "vision")
    #expect(await client.attempts() == [analysisID(1)])
  }

  @Test("Stop discards pending work, retains its slot until completion and pauses later imports")
  func stopBackground() async throws {
    let client = AnalysisClient(hold: true, pending: [analysisID(1), analysisID(2)])
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    await model.refresh()
    await client.waitForStart()
    model.stopAnalysis()
    #expect(model.isAnalysisBusy)
    await model.importFile(URL(fileURLWithPath: "/fixture.png"))
    await client.release()
    await waitForBatch(model)
    #expect(await client.attempts() == [analysisID(1)])
    #expect(await client.savedCount() == 0)
    #expect(model.analysisMessage == "Local labeling stopped.")
    await model.importFile(URL(fileURLWithPath: "/fixture.png"))
    #expect(!model.isAnalysisBusy)
    model.selectItem(analysisID(1))
    model.analyzeSelectedArtwork()
    await waitForBatch(model)
    #expect(await client.savedCount() == 1)
  }

  @Test("A batch attempts sixteen IDs once; failures and unknown writes never replay automatically")
  func finiteBatch() async throws {
    let client = AnalysisClient(
      pending: (1...16).map(analysisID), hasMore: true, failures: [analysisID(1)])
    let model = ShellModel(client: client, initialSnapshot: await client.snapshot())
    await model.refresh()
    await waitForBatch(model)
    #expect(await client.attempts().count == 16)
    #expect(await client.savedCount() == 15)
    #expect(model.analysisMessage?.contains("could not be labeled") == true)
    let uncertain = AnalysisClient(pending: [analysisID(1), analysisID(2)], unknown: true)
    let review = ShellModel(client: uncertain, initialSnapshot: await uncertain.snapshot())
    await review.refresh()
    await waitForBatch(review)
    #expect(await uncertain.attempts() == [analysisID(1)])
    #expect(review.analysisMessage?.contains("Review current metadata") == true)
  }

  private func waitForBatch(_ model: ShellModel) async {
    for _ in 0..<1000 {
      if !model.isAnalysisBusy { return }
      await Task.yield()
    }
    #expect(!model.isAnalysisBusy)
  }
}

private func analysisID(_ number: Int) -> String { "sha256:" + String(format: "%064x", number) }
private func analysisHash(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func observation(bytes: Data, changes: [String: Any] = [:]) throws -> LibraryAnalysis {
  var value: [String: Any] = [
    "itemID": analysisID(1), "cohort": AppleArtworkAnalyzer.cohort,
    "inputDigest": analysisID(11), "rendererBuildDigest": analysisID(12), "observedAtMs": 1,
    "featurePrint": [
      "cohort": AppleArtworkAnalyzer.cohort, "archive": bytes.base64EncodedString(),
      "digest": analysisHash(bytes),
    ],
  ]
  value.merge(changes) { _, new in new }
  return try JSONDecoder().decode(
    LibraryAnalysis.self, from: JSONSerialization.data(withJSONObject: value))
}

private actor AnalysisClient: CoreClient {
  private var current = CoreSnapshot(
    targets: [], selectedTargetID: nil, instruction: "Old instruction",
    items: [LibraryItem(id: analysisID(1), title: "Artwork", digest: analysisID(1))],
    statusMessage: "Ready")
  private var observed = LibraryMetadata(
    itemID: analysisID(1), revision: analysisID(10), title: "Artwork", sourceKind: "import",
    width: 2, height: 1)
  private var hold: Bool
  private let pending: [String]
  private let hasMore: Bool
  private let failures: Set<String>
  private let unknown: Bool
  private var attempted: [String] = []
  private var saved = 0
  private var continuation: CheckedContinuation<Void, Never>?

  init(
    hold: Bool = false, pending: [String] = [], hasMore: Bool = false, failures: Set<String> = [],
    unknown: Bool = false
  ) {
    self.hold = hold
    self.pending = pending
    self.hasMore = hasMore
    self.failures = failures
    self.unknown = unknown
  }
  func snapshot() -> CoreSnapshot { current }
  func snapshot(query: String) -> CoreSnapshot { current }
  func metadata(itemID: String) -> LibraryMetadata { observed }
  func analysisPending() -> PendingLibraryAnalysis {
    PendingLibraryAnalysis(itemIDs: pending, hasMore: hasMore)
  }
  func attempts() -> [String] { attempted }
  func savedCount() -> Int { saved }
  func waitForStart() async { while continuation == nil { await Task.yield() } }
  func release() {
    hold = false
    continuation?.resume()
    continuation = nil
  }
  func analyzeArtwork(itemID: String, force: Bool) async throws -> CoreSnapshot {
    let old = current
    attempted.append(itemID)
    if hold { await withCheckedContinuation { continuation = $0 } }
    try Task.checkCancellation()
    if unknown { throw CoreClientError.commandOutcomeUnknown }
    if failures.contains(itemID) { throw CoreClientError.analysisUnavailable }
    saved += 1
    observed = LibraryMetadata(
      itemID: analysisID(1), revision: analysisID(20), title: "Artwork", sourceKind: "import",
      width: 2, height: 1,
      labels: [
        ArtworkLabel(
          label: "forest", provenance: "vision", confidence: 0.8,
          revision: AppleArtworkAnalyzer.cohort)
      ])
    return old
  }
  func send(_ command: CoreCommand) -> CoreSnapshot {
    if command.kind == .importFile { current.importedItemID = analysisID(1) }
    if command.kind == .updateInstruction { current.instruction = command.instruction ?? "" }
    if command.kind == .setPinned {
      current.items = [
        LibraryItem(
          id: analysisID(1), title: "Artwork", digest: analysisID(1),
          isPinned: command.isPinned ?? false)
      ]
    }
    return current
  }
}
