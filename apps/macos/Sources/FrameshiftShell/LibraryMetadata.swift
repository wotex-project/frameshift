import Foundation

public struct ArtworkLabel: Codable, Equatable, Identifiable, Sendable {
  public let label: String
  public let provenance: String
  public let confidence: Double?
  public let revision: String?
  public var id: String { "\(provenance):\(label)" }

  public init(label: String, provenance: String, confidence: Double? = nil, revision: String? = nil)
  {
    self.label = label
    self.provenance = provenance
    self.confidence = confidence
    self.revision = revision
  }
}

public struct LabelDismissal: Codable, Equatable, Sendable {
  public let label: String
  public let provenance: String

  public init(label: String, provenance: String) {
    self.label = label
    self.provenance = provenance
  }
}

public struct LibraryMetadata: Codable, Equatable, Sendable {
  public let itemID: String
  public let revision: String
  public let title: String
  public let sourceKind: String
  public let width: Int
  public let height: Int
  public let removedAtMs: Int?
  public let labels: [ArtworkLabel]

  public init(
    itemID: String, revision: String, title: String, sourceKind: String,
    width: Int, height: Int, removedAtMs: Int? = nil, labels: [ArtworkLabel] = []
  ) {
    self.itemID = itemID
    self.revision = revision
    self.title = title
    self.sourceKind = sourceKind
    self.width = width
    self.height = height
    self.removedAtMs = removedAtMs
    self.labels = labels
  }

  public func validate(itemID expected: String) throws {
    guard itemID == expected, validLibraryDigest(itemID), validLibraryDigest(revision),
      !title.isEmpty, title.utf8.count <= 1024, ["import", "generated"].contains(sourceKind),
      (1...32768).contains(width), (1...32768).contains(height),
      removedAtMs == nil || removedAtMs! >= 0, labels.count <= 64,
      Set(labels.map(\.id)).count == labels.count,
      labels.allSatisfy({ label in
        validMetadataText(label.label, maximum: 128)
          && ["user", "vision", "filename", "metadata"].contains(label.provenance)
          && (label.confidence == nil || (0...1).contains(label.confidence!))
          && (label.revision?.utf8.count ?? 0) <= 128
      })
    else { throw CoreClientError.protocolFailure }
  }
}

public struct MetadataDraft: Equatable, Sendable {
  public var base: LibraryMetadata
  public var title: String
  public var userLabels: [String]
  public var dismissedLabels: [LabelDismissal] = []

  public init(metadata: LibraryMetadata) {
    base = metadata
    title = metadata.title
    userLabels = metadata.labels.filter { $0.provenance == "user" }.map(\.label)
  }

  public var hasChanges: Bool {
    title != base.title
      || userLabels != base.labels.filter { $0.provenance == "user" }.map(\.label)
      || !dismissedLabels.isEmpty
  }

  public var isValid: Bool {
    let machines = base.labels.filter { label in
      label.provenance != "user"
        && !dismissedLabels.contains(
          LabelDismissal(label: label.label, provenance: label.provenance))
    }
    return validMetadataText(title, maximum: 256)
      && userLabels.count <= 32 && userLabels.allSatisfy { validMetadataText($0, maximum: 128) }
      && userLabels.count + machines.count <= 64
  }

  public var machineLabels: [ArtworkLabel] { base.labels.filter { $0.provenance != "user" } }
}

public struct RemovedArtwork: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let removedAtMs: Int
  public let storageState: String
  public let retentionReasons: [String]

  public init(
    id: String, title: String, removedAtMs: Int, storageState: String,
    retentionReasons: [String] = []
  ) {
    self.id = id
    self.title = title
    self.removedAtMs = removedAtMs
    self.storageState = storageState
    self.retentionReasons = retentionReasons
  }
}

public struct LibraryRecoveryPage: Codable, Equatable, Sendable {
  public let items: [RemovedArtwork]
  public let nextCursor: String?

  public init(items: [RemovedArtwork], nextCursor: String? = nil) {
    self.items = items
    self.nextCursor = nextCursor
  }

  public func validate(afterID: String?) throws {
    let ids = items.map(\.id)
    guard items.count <= 50, ids == ids.sorted(), Set(ids).count == ids.count,
      items.allSatisfy({ item in
        validLibraryDigest(item.id) && item.id > (afterID ?? "")
          && !item.title.isEmpty && item.title.utf8.count <= 1024 && item.removedAtMs >= 0
          && ["active", "trash"].contains(item.storageState)
          && Set(item.retentionReasons).count == item.retentionReasons.count
          && item.retentionReasons.allSatisfy {
            ["pinned", "frame", "artifact", "recipe"].contains($0)
          }
      }), nextCursor == nil || (items.count == 50 && nextCursor == ids.last)
    else { throw CoreClientError.protocolFailure }
  }
}

func validLibraryDigest(_ value: String) -> Bool {
  value.utf8.count == 71 && value.hasPrefix("sha256:")
    && value.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func validMetadataText(_ value: String, maximum: Int) -> Bool {
  let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(
    in: .whitespacesAndNewlines)
  return !normalized.isEmpty && normalized.utf8.count <= maximum
    && !normalized.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
