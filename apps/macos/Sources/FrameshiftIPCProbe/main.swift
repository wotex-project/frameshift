import CoreGraphics
import Foundation
import FrameshiftShell
import ImageIO
import UniformTypeIdentifiers

private struct ProbeFailure: Error {}

@main
private struct FrameshiftIPCProbe {
  static func main() async throws {
    let client = LocalCoreClient()
    let initial = try await client.snapshot()
    guard initial.targets.isEmpty else { throw ProbeFailure() }

    let outbox = try await client.outboxStatus()
    guard !outbox.available, outbox.port == nil else { throw ProbeFailure() }

    let marker = "release-smoke-\(UUID().uuidString.lowercased())\nsecond line"
    let updated = try await client.send(
      CoreCommand(kind: .updateInstruction, instruction: marker)
    )
    guard updated.instruction == marker else { throw ProbeFailure() }

    let refreshed = try await client.snapshot()
    guard refreshed.instruction == marker else { throw ProbeFailure() }

    let diagnosticHealth = try DiagnosticsClient.query("health")
    guard let health = try JSONSerialization.jsonObject(with: diagnosticHealth) as? [String: Any],
      health["ok"] as? Bool == true
    else { throw ProbeFailure() }

    let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "frameshift-ipc-probe-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: fixtureDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let fixtureURL = fixtureDirectory.appendingPathComponent("installed-flow.png")
    try writeFixture(to: fixtureURL)

    let imported = try await client.send(
      CoreCommand(kind: .importFile, importPath: fixtureURL.path)
    )
    guard
      imported.items.contains(where: {
        $0.title == "installed-flow" && $0.digest.hasPrefix("sha256:")
      })
    else {
      throw ProbeFailure()
    }

    let matched = try await client.snapshot(query: "installed")
    guard matched.items.count == 1, matched.items[0].title == "installed-flow" else {
      throw ProbeFailure()
    }
    let absent = try await client.snapshot(query: "absent")
    guard absent.items.isEmpty else { throw ProbeFailure() }

    let item = matched.items[0]
    let preview = try await client.preview(masterID: item.id, target: nil)
    try preview.validate(masterID: item.id, target: nil)
    guard preview.width == 2, preview.height == 1,
      preview.rgb == Data([255, 0, 0, 0, 255, 0]), preview.image() != nil
    else { throw ProbeFailure() }
    _ = try await client.send(CoreCommand(kind: .setPinned, itemID: item.id, isPinned: true))
    let pinPreview = try await client.snapshot(query: "absent")
    guard pinPreview.items.isEmpty, pinPreview.pinnedItems?.map(\.id) == [item.id],
      pinPreview.pinnedSetTooLarge == false
    else { throw ProbeFailure() }
    let pinnedImports = try await client.snapshot(
      query: "installed", filters: LibraryFilters(pinnedOnly: true, sourceKind: .imported))
    guard pinnedImports.items.map(\.id) == [item.id] else { throw ProbeFailure() }
    let generatedOnly = try await client.snapshot(
      query: "", filters: LibraryFilters(sourceKind: .generated))
    guard generatedOnly.items.isEmpty, generatedOnly.pinnedItems?.map(\.id) == [item.id] else {
      throw ProbeFailure()
    }
    do {
      _ = try await client.send(
        CoreCommand(
          kind: .loopArtwork, targetID: "missing-frame", dwellMs: 1501, itemIDs: [item.id]))
      throw ProbeFailure()
    } catch CoreClientError.targetNotFound {}
    do {
      _ = try await client.send(
        CoreCommand(kind: .resumePlaylist, targetID: "missing-frame", playlistRevision: item.digest)
      )
      throw ProbeFailure()
    } catch CoreClientError.targetNotFound {}

    let metadata = try await client.metadata(itemID: item.id)
    let metadataResult = try await client.send(
      CoreCommand(
        kind: .updateMetadata, itemID: item.id,
        metadataRevision: metadata.revision, title: "Verified study", userLabels: ["probe-label"],
        dismissedLabels: []))
    guard let committed = metadataResult.updatedMetadata, committed.itemID == item.id,
      committed.revision != metadata.revision, committed.title == "Verified study"
    else { throw ProbeFailure() }
    try committed.validate(itemID: item.id)
    let labelSearch = try await client.snapshot(query: "probe-label")
    guard labelSearch.items.map(\.id) == [item.id] else { throw ProbeFailure() }
    do {
      _ = try await client.send(
        CoreCommand(
          kind: .updateMetadata, itemID: item.id,
          metadataRevision: metadata.revision, title: "Stale", userLabels: [], dismissedLabels: []))
      throw ProbeFailure()
    } catch CoreClientError.metadataRevisionConflict {}
    _ = try await client.send(CoreCommand(kind: .remove, itemID: item.id))
    let removed = try await client.recovery(afterID: nil)
    guard removed.items.map(\.id) == [item.id], removed.items[0].retentionReasons == ["pinned"]
    else { throw ProbeFailure() }
    let restored = try await client.send(CoreCommand(kind: .restore, itemID: item.id))
    guard restored.items.first?.id == item.id, restored.items.first?.isPinned == true,
      restored.items.first?.title == "Verified study"
    else { throw ProbeFailure() }
    let retained = try await client.metadata(itemID: item.id)
    guard retained.revision == committed.revision else { throw ProbeFailure() }

    let storage = try await client.storage()
    guard storage.totalBytes > 0, storage.objectCount == 1 else { throw ProbeFailure() }
    let budgetResult = try await client.send(
      CoreCommand(
        kind: .updateStorage, storageRevision: storage.revision,
        objectByteLimit: LibraryStorage.mebibyte))
    guard let budget = budgetResult.updatedStorage,
      budget.objectByteLimit == LibraryStorage.mebibyte,
      budget.totalBytes == storage.totalBytes
    else { throw ProbeFailure() }
    try budget.validate()
    guard try await client.storage() == budget else { throw ProbeFailure() }
    do {
      _ = try await client.send(
        CoreCommand(
          kind: .updateStorage, storageRevision: storage.revision,
          objectByteLimit: 2 * LibraryStorage.mebibyte))
      throw ProbeFailure()
    } catch CoreClientError.storageRevisionConflict {}

    print("Frameshift Swift-to-Elixir IPC probe passed")
  }

  private static func writeFixture(to url: URL) throws {
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
    let info = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue
    )
    guard let provider = CGDataProvider(data: pixels as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: 2,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw ProbeFailure()
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ProbeFailure() }
  }
}
