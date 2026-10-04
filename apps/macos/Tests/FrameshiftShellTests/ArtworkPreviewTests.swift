import CryptoKit
import Foundation
import FrameshiftShell
import Testing

private let previewMasterA = "sha256:" + String(repeating: "a", count: 64)
private let previewMasterB = "sha256:" + String(repeating: "b", count: 64)

@Suite("Verified local artwork previews")
struct ArtworkPreviewTests {
  @Test("A bounded source preview verifies exact bytes before native image creation")
  func validatesSourceImage() throws {
    let preview = try previewFixture(masterID: previewMasterA)
    try preview.validate(masterID: previewMasterA, target: nil)
    #expect(preview.image()?.width == 1)
    #expect(preview.image()?.height == 1)
    #expect(preview.rgb == Data([1, 2, 3]))
  }

  @Test(
    "Malformed dimensions, bytes, identity and non-preview claims refuse",
    arguments: [
      "width", "height", "rgb", "digest", "masterDigest", "kind", "approximation",
      "rendererBuildDigest", "aspectWidth",
    ])
  func refusesMalformedPreview(field: String) throws {
    let changes: [String: Any] = [
      "width": 257, "height": 0, "rgb": Data([1, 2]).base64EncodedString(),
      "digest": "sha256:" + String(repeating: "0", count: 64),
      "masterDigest": previewMasterB, "kind": "displayed", "approximation": false,
      "rendererBuildDigest": "mutable-renderer-label", "aspectWidth": 32_769,
    ]
    let preview = try previewFixture(masterID: previewMasterA, changes: [field: changes[field]!])
    #expect(throws: CoreClientError.protocolFailure) {
      try preview.validate(masterID: previewMasterA, target: nil)
    }
  }

  @Test("Target preview requires the exact frame, profile and capability snapshot")
  func validatesTargetScope() throws {
    let target = FrameTarget(
      id: "frame-a", name: "A", medium: .photo, profileID: "rgb24", state: .displayed,
      capabilityDigest: previewMasterB)
    let preview = try previewFixture(
      masterID: previewMasterA,
      changes: [
        "kind": "target", "targetID": "frame-a", "profileID": "rgb24",
        "capabilityDigest": previewMasterB,
      ])
    try preview.validate(masterID: previewMasterA, target: target)
    #expect(throws: CoreClientError.protocolFailure) {
      try preview.validate(masterID: previewMasterA, target: nil)
    }
    let changed = FrameTarget(
      id: "frame-a", name: "A", medium: .photo, profileID: "rgb24", state: .displayed,
      capabilityDigest: previewMasterA)
    #expect(throws: CoreClientError.protocolFailure) {
      try preview.validate(masterID: previewMasterA, target: changed)
    }
  }

  @Test("Late preview cannot replace a new selection; requests remain single flight")
  @MainActor
  func preservesSelectionDuringRender() async throws {
    let initial = CoreSnapshot(
      targets: [], selectedTargetID: nil,
      items: [
        LibraryItem(id: previewMasterA, title: "A", digest: previewMasterA),
        LibraryItem(id: previewMasterB, title: "B", digest: previewMasterB),
      ], statusMessage: "Ready")
    let client = DelayedPreviewClient(snapshot: initial)
    let model = ShellModel(client: client, initialSnapshot: initial)
    model.selectItem(previewMasterA)
    await client.waitForFirstPreview()
    model.selectItem(previewMasterB)
    #expect(model.selectedPreview == nil)
    #expect(model.isPreviewLoading)
    await client.completeFirstPreview()
    await client.waitForSecondPreview()
    // Wait for the model's active request without creating another renderer request.
    for _ in 0..<100 where model.isPreviewLoading { await Task.yield() }
    #expect(model.selectedItem?.id == previewMasterB)
    #expect(model.selectedPreview?.masterDigest == previewMasterB)
    #expect(await client.requests() == [previewMasterA, previewMasterB])
    #expect(!model.isPreviewLoading)
    await model.refresh()
    #expect(model.selectedPreview?.masterDigest == previewMasterB)
    #expect(await client.requests().count == 2)
  }
}

private func previewFixture(masterID: String, changes: [String: Any] = [:]) throws -> ArtworkPreview
{
  let rgb = Data([1, 2, 3])
  var fields: [String: Any] = [
    "kind": "source", "masterDigest": masterID, "approximation": true, "format": "rgb24",
    "width": 1, "height": 1, "aspectWidth": 1, "aspectHeight": 1,
    "rgb": rgb.base64EncodedString(),
    "digest": "sha256:" + SHA256.hash(data: rgb).map { String(format: "%02x", $0) }.joined(),
    "rendererBuildDigest": "sha256:" + String(repeating: "c", count: 64),
  ]
  fields.merge(changes) { _, new in new }
  return try JSONDecoder().decode(
    ArtworkPreview.self, from: JSONSerialization.data(withJSONObject: fields))
}

private actor DelayedPreviewClient: CoreClient {
  private let current: CoreSnapshot
  private var recorded: [String] = []
  private var firstStarted: CheckedContinuation<Void, Never>?
  private var firstResponse: CheckedContinuation<Void, Never>?
  private var secondStarted: CheckedContinuation<Void, Never>?

  init(snapshot: CoreSnapshot) { current = snapshot }
  func snapshot() -> CoreSnapshot { current }
  func snapshot(query _: String) -> CoreSnapshot { current }
  func send(_: CoreCommand) -> CoreSnapshot { current }
  func requests() -> [String] { recorded }

  func preview(masterID: String, target _: FrameTarget?) async throws -> ArtworkPreview {
    recorded.append(masterID)
    if recorded.count == 1 {
      firstStarted?.resume()
      firstStarted = nil
      await withCheckedContinuation { firstResponse = $0 }
    } else {
      secondStarted?.resume()
      secondStarted = nil
    }
    return try previewFixture(masterID: masterID)
  }

  func waitForFirstPreview() async {
    if firstResponse != nil { return }
    await withCheckedContinuation { firstStarted = $0 }
  }
  func completeFirstPreview() {
    firstResponse?.resume()
    firstResponse = nil
  }
  func waitForSecondPreview() async {
    if recorded.count >= 2 { return }
    await withCheckedContinuation { secondStarted = $0 }
  }
}
