import CoreGraphics
import CryptoKit
import Foundation
import FrameshiftShell
import ImageIO
import UniformTypeIdentifiers

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

@main
private struct FrameshiftShellChecks {
  static func main() async throws {
    try await checkItemLifecycle()
    try checkDisconnectedState()
    try await checkInvalidIdentities()
    try await checkShellModel()
    try await checkRedactedErrors()
    try checkAppleImageDecode()
    print("Frameshift shell checks passed")
  }

  private static func checkItemLifecycle() async throws {
    let client = InMemoryCoreClient(snapshot: .checkFixture)
    let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "frameshift-shell-checks-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: fixtureDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    let firstURL = fixtureDirectory.appendingPathComponent("quiet-study.png")
    let duplicateURL = fixtureDirectory.appendingPathComponent("duplicate.png")
    let fixture = Data([1, 2, 3, 4, 5, 6])
    try fixture.write(to: firstURL, options: .atomic)
    try fixture.write(to: duplicateURL, options: .atomic)

    var snapshot = try await client.send(
      CoreCommand(kind: .importFile, importPath: firstURL.path)
    )
    let item = try require(snapshot.items.first, "manual import did not create an item")
    try expect(item.title == "quiet-study", "manual import title changed")
    try expect(item.digest.hasPrefix("sha256:"), "manual import digest is not content addressed")

    snapshot = try await client.send(
      CoreCommand(kind: .importFile, importPath: duplicateURL.path)
    )
    try expect(snapshot.items.count == 1, "identical import bytes were duplicated")

    snapshot = try await client.send(
      CoreCommand(kind: .setPinned, itemID: item.id, isPinned: true)
    )
    try expect(snapshot.items.first?.isPinned == true, "pin command did not update the snapshot")

    snapshot = try await client.send(
      CoreCommand(
        kind: .queue,
        targetID: snapshot.selectedTargetID,
        itemID: item.id
      )
    )
    try expect(
      snapshot.items.first?.queuedTargetID == "frame-paper",
      "queue command targeted the wrong frame"
    )

    snapshot = try await client.send(CoreCommand(kind: .remove, itemID: item.id))
    try expect(snapshot.items.isEmpty, "remove command left the item active")
  }

  private static func checkDisconnectedState() throws {
    let snapshot = CoreSnapshot.disconnected
    try expect(snapshot.targets.isEmpty, "disconnected state invented paired frames")
    try expect(snapshot.selectedTargetID == nil, "disconnected state selected a target")
    try expect(
      snapshot.generationAvailability == .notConfigured,
      "generation must not appear available without a provider"
    )
  }

  private static func checkAppleImageDecode() throws {
    try expect(
      AppleImageDecoder.maximumPixels == 16_777_011,
      "decoder pixel bound diverged from the largest renderer request envelope"
    )

    do {
      try AppleImageDecoder.validateDimensions(width: 4_096, height: 4_096)
      throw CheckFailure(description: "decoder admitted pixels that cannot fit a render request")
    } catch CoreClientError.importTooLarge {
      // Expected: the complete request must still fit with a 256-entry palette.
    }

    let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "frameshift-decode-check-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: fixtureDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

    let sourceURL = fixtureDirectory.appendingPathComponent("oriented.png")
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
    let image = try makeImage(width: 2, height: 1, rgba: pixels)
    try writeImage(image, to: sourceURL, type: .png, orientation: 6)

    let decoded = try AppleImageDecoder.decode(sourceURL)
    defer { decoded.removeWorkDirectory() }
    let rgba = try Data(contentsOf: decoded.canonicalURL)

    try expect(decoded.metadata.width == 1, "orientation did not rotate decoded width")
    try expect(decoded.metadata.height == 2, "orientation did not rotate decoded height")
    try expect(decoded.metadata.orientation == 6, "source orientation was not retained")
    try expect(decoded.metadata.mediaType == "image/png", "decoded media type changed")
    try expect(
      rgba == pixels,
      "canonical pixels are not top-left RGBA8: \(Array(rgba))"
    )

    let digest = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
    try expect(
      decoded.canonicalDigest == "sha256:\(digest)",
      "canonical handoff digest does not identify its bytes"
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: decoded.canonicalURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    try expect(permissions == 0o600, "canonical handoff is not user-only")
  }

  private static func makeImage(width: Int, height: Int, rgba: Data) throws -> CGImage {
    let info = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue
    )
    guard let provider = CGDataProvider(data: rgba as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      throw CheckFailure(description: "could not create decode fixture")
    }
    return image
  }

  private static func writeImage(
    _ image: CGImage,
    to url: URL,
    type: UTType,
    orientation: Int
  ) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
      )
    else {
      throw CheckFailure(description: "could not create image destination")
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImagePropertyOrientation: orientation] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw CheckFailure(description: "could not write decode fixture")
    }
  }

  private static func checkInvalidIdentities() async throws {
    let client = InMemoryCoreClient(snapshot: .checkFixture)

    do {
      _ = try await client.send(CoreCommand(kind: .selectTarget, targetID: "missing"))
      throw CheckFailure(description: "missing target was accepted")
    } catch CoreClientError.targetNotFound {
      // Expected.
    }

    do {
      _ = try await client.send(
        CoreCommand(kind: .setPinned, itemID: "missing", isPinned: true)
      )
      throw CheckFailure(description: "missing item was accepted")
    } catch CoreClientError.itemNotFound {
      // Expected.
    }
  }

  @MainActor
  private static func checkShellModel() async throws {
    let recorder = RecordingClient()
    let model = ShellModel(client: recorder)
    model.draftInstruction = "A quiet geometric still"
    await model.saveInstruction()

    try expect(
      model.snapshot.instruction == "A quiet geometric still",
      "shell did not apply the returned core snapshot"
    )
    let commandKinds = await recorder.commandKinds()
    try expect(commandKinds == [.updateInstruction], "shell bypassed the command client")

    let reconcilingModel = ShellModel(client: UnknownOutcomeClient())
    await reconcilingModel.saveInstruction()
    try expect(
      reconcilingModel.snapshot.instruction == "Reconciled state",
      "shell did not refresh authoritative state after an unknown command outcome"
    )
    try expect(
      reconcilingModel.errorMessage?.contains("review it before trying again") == true,
      "shell did not explain the unknown-outcome recovery"
    )
  }

  @MainActor
  private static func checkRedactedErrors() async throws {
    let model = ShellModel(client: FailingClient())
    await model.selectTarget("private-target-name")
    try expect(
      model.errorMessage == "The core command could not be completed.",
      "shell error copy changed"
    )
    try expect(
      model.errorMessage?.contains("private-target-name") == false,
      "shell error exposed command data"
    )
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
  }

  private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw CheckFailure(description: message) }
    return value
  }
}

private actor RecordingClient: CoreClient {
  private var commands: [CoreCommand] = []
  private var current = CoreSnapshot.disconnected

  func snapshot() -> CoreSnapshot {
    current
  }

  func snapshot(query _: String) -> CoreSnapshot { current }

  func send(_ command: CoreCommand) -> CoreSnapshot {
    commands.append(command)
    if command.kind == .updateInstruction {
      current.instruction = command.instruction ?? ""
    }
    return current
  }

  func commandKinds() -> [CoreCommand.Kind] {
    commands.map(\.kind)
  }
}

private actor InMemoryCoreClient: CoreClient {
  private let maximumImportBytes = 128 * 1024 * 1024
  private var current: CoreSnapshot

  init(snapshot: CoreSnapshot) {
    current = snapshot
  }

  func snapshot() -> CoreSnapshot {
    current
  }

  func snapshot(query: String) -> CoreSnapshot {
    var result = current
    result.items = current.items.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
    }
    return result
  }

  func send(_ command: CoreCommand) throws -> CoreSnapshot {
    switch command.kind {
    case .selectTarget:
      guard let targetID = command.targetID,
        current.targets.contains(where: { $0.id == targetID })
      else {
        throw CoreClientError.targetNotFound
      }
      current.selectedTargetID = targetID
    case .updateInstruction:
      guard let instruction = command.instruction else { throw CoreClientError.invalidCommand }
      current.instruction = instruction
    case .importFile:
      try importFile(command.importPath)
    case .setPinned:
      guard let pinned = command.isPinned else { throw CoreClientError.invalidCommand }
      try updateItem(command.itemID) { $0.isPinned = pinned }
    case .remove:
      guard let itemID = command.itemID,
        current.items.contains(where: { $0.id == itemID })
      else {
        throw CoreClientError.itemNotFound
      }
      current.items.removeAll(where: { $0.id == itemID })
    case .queue:
      guard let targetID = command.targetID,
        current.targets.contains(where: { $0.id == targetID })
      else {
        throw CoreClientError.targetNotFound
      }
      try updateItem(command.itemID) { $0.queuedTargetID = targetID }
    case .loopPinned, .loopArtwork, .resumePlaylist:
      throw CoreClientError.loopUnavailable
    case .updateMetadata, .restore:
      throw CoreClientError.invalidCommand
    case .reconcileDelivery:
      guard let targetID = command.targetID,
        current.targets.contains(where: { $0.id == targetID })
      else {
        throw CoreClientError.targetNotFound
      }
    }
    return current
  }

  private func importFile(_ path: String?) throws {
    guard let path else { throw CoreClientError.invalidCommand }
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize else {
      throw CoreClientError.importUnreadable
    }
    guard size <= maximumImportBytes else { throw CoreClientError.importTooLarge }
    let bytes = try Data(contentsOf: url)
    let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let digest = "sha256:\(hex)"

    if !current.items.contains(where: { $0.digest == digest }) {
      current.items.insert(
        LibraryItem(
          id: digest,
          title: url.deletingPathExtension().lastPathComponent,
          digest: digest
        ),
        at: 0
      )
    }
  }

  private func updateItem(
    _ itemID: String?,
    update: (inout LibraryItem) -> Void
  ) throws {
    guard let itemID, let index = current.items.firstIndex(where: { $0.id == itemID }) else {
      throw CoreClientError.itemNotFound
    }
    update(&current.items[index])
  }
}

private struct FailingClient: CoreClient {
  func snapshot() async throws -> CoreSnapshot {
    throw CoreClientError.invalidCommand
  }

  func snapshot(query _: String) async throws -> CoreSnapshot { try await snapshot() }

  func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    _ = command
    throw CoreClientError.invalidCommand
  }
}

private struct UnknownOutcomeClient: CoreClient {
  func snapshot() async throws -> CoreSnapshot {
    var refreshed = CoreSnapshot.checkFixture
    refreshed.instruction = "Reconciled state"
    return refreshed
  }

  func snapshot(query _: String) async throws -> CoreSnapshot { try await snapshot() }

  func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    _ = command
    throw CoreClientError.commandOutcomeUnknown
  }
}

extension CoreSnapshot {
  fileprivate static let checkFixture = CoreSnapshot(
    targets: [
      FrameTarget(
        id: "frame-paper",
        name: "Paper Frame",
        medium: .paper,
        profileID: "urn:frameshift:test:paper",
        state: .waitingForContact
      )
    ],
    selectedTargetID: "frame-paper",
    generationAvailability: .notConfigured,
    statusMessage: "Test fixture"
  )
}
