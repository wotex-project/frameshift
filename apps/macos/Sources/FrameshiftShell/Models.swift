import Foundation

public enum FrameMedium: String, Codable, CaseIterable, Sendable {
  case paper
  case photo
  case pixel

  public var label: String {
    switch self {
    case .paper: "Paper"
    case .photo: "Photo"
    case .pixel: "Pixel"
    }
  }
}

public enum FrameConnectionState: String, Codable, Sendable {
  case waitingForContact
  case displayed
  case failed
}

public struct DirectDelivery: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case pending
    case displayed
  }

  public let status: Status
  public let revision: Int
  public let desiredDigest: String
}

public struct FramePlaylist: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case pending
    case active
    case suspended
  }

  public let status: Status
  public let revision: String
  public let entryCount: Int
  public let dwellMs: Int
  public let replacingActive: Bool?
  public let items: [PlaylistItem]?
  public let requiresRevalidation: Bool?
}

public struct PlaylistItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let digest: String
  public let title: String

  public init(id: String, digest: String, title: String) {
    self.id = id
    self.digest = digest
    self.title = title
  }
}

public struct LoopIntervalPreference: Codable, Equatable, Sendable {
  public let source: String
  public let requestedDwellMs: Int?
  public let appliedDwellMs: Int
  public let recommendationRevision: String?
  public let capabilityDigest: String
  public let requiresReview: Bool
}

public struct FrameTarget: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let medium: FrameMedium
  public let profileID: String
  public var state: FrameConnectionState
  public var directDelivery: DirectDelivery?
  public let minimumDwellMs: Int?
  public let recommendedDwellMs: Int?
  public let recommendationBasis: String?
  public let recommendationRevision: String?
  public let playlist: FramePlaylist?
  public let loopInterval: LoopIntervalPreference?
  public let maximumPlaylistLength: Int?
  public let hasQueuedDelivery: Bool?
  public let capabilityDigest: String?

  public init(
    id: String,
    name: String,
    medium: FrameMedium,
    profileID: String,
    state: FrameConnectionState,
    directDelivery: DirectDelivery? = nil,
    minimumDwellMs: Int? = nil,
    recommendedDwellMs: Int? = nil,
    recommendationBasis: String? = nil,
    recommendationRevision: String? = nil,
    playlist: FramePlaylist? = nil,
    loopInterval: LoopIntervalPreference? = nil,
    maximumPlaylistLength: Int? = nil,
    hasQueuedDelivery: Bool? = nil,
    capabilityDigest: String? = nil
  ) {
    self.id = id
    self.name = name
    self.medium = medium
    self.profileID = profileID
    self.state = state
    self.directDelivery = directDelivery
    self.minimumDwellMs = minimumDwellMs
    self.recommendedDwellMs = recommendedDwellMs
    self.recommendationBasis = recommendationBasis
    self.recommendationRevision = recommendationRevision
    self.playlist = playlist
    self.loopInterval = loopInterval
    self.maximumPlaylistLength = maximumPlaylistLength
    self.hasQueuedDelivery = hasQueuedDelivery
    self.capabilityDigest = capabilityDigest
  }
}

public struct LibraryItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let digest: String
  public var isPinned: Bool
  public var queuedTargetID: String?
  public var loopStatus: FramePlaylist.Status?

  public init(
    id: String,
    title: String,
    digest: String,
    isPinned: Bool = false,
    queuedTargetID: String? = nil,
    loopStatus: FramePlaylist.Status? = nil
  ) {
    self.id = id
    self.title = title
    self.digest = digest
    self.isPinned = isPinned
    self.queuedTargetID = queuedTargetID
    self.loopStatus = loopStatus
  }
}

public enum GenerationAvailability: String, Codable, Sendable {
  case notConfigured
  case available
}

public struct CoreSnapshot: Codable, Equatable, Sendable {
  public var targets: [FrameTarget]
  public var selectedTargetID: String?
  public var instruction: String
  public var items: [LibraryItem]
  public var generationAvailability: GenerationAvailability
  public var statusMessage: String
  public var pinnedItems: [PlaylistItem]?
  public var pinnedSetTooLarge: Bool?
  public var updatedMetadata: LibraryMetadata?

  public init(
    targets: [FrameTarget],
    selectedTargetID: String?,
    instruction: String = "",
    items: [LibraryItem] = [],
    generationAvailability: GenerationAvailability = .notConfigured,
    statusMessage: String,
    pinnedItems: [PlaylistItem]? = nil,
    pinnedSetTooLarge: Bool? = nil,
    updatedMetadata: LibraryMetadata? = nil
  ) {
    self.targets = targets
    self.selectedTargetID = selectedTargetID
    self.instruction = instruction
    self.items = items
    self.generationAvailability = generationAvailability
    self.statusMessage = statusMessage
    self.pinnedItems = pinnedItems
    self.pinnedSetTooLarge = pinnedSetTooLarge
    self.updatedMetadata = updatedMetadata
  }

  public var selectedTarget: FrameTarget? {
    guard let selectedTargetID else { return nil }
    return targets.first(where: { $0.id == selectedTargetID })
  }
}

extension CoreSnapshot {
  public static let disconnected = CoreSnapshot(
    targets: [],
    selectedTargetID: nil,
    generationAvailability: .notConfigured,
    statusMessage: "Connecting to the Frameshift core…"
  )
}

public struct CoreCommand: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case selectTarget
    case updateInstruction
    case importFile
    case setPinned
    case remove
    case restore
    case updateMetadata
    case queue
    case loopPinned
    case loopArtwork
    case resumePlaylist
    case reconcileDelivery
  }

  public let id: UUID
  public let kind: Kind
  public let targetID: String?
  public let itemID: String?
  public let instruction: String?
  public let importPath: String?
  public let isPinned: Bool?
  public let importWidth: Int?
  public let importHeight: Int?
  public let importMediaType: String?
  public let importOrientation: Int?
  public let importColorProfile: String?
  public let importCanonicalPath: String?
  public let importCanonicalDigest: String?
  public let dwellMs: Int?
  public let itemIDs: [String]?
  public let playlistRevision: String?
  public let metadataRevision: String?
  public let title: String?
  public let userLabels: [String]?
  public let dismissedLabels: [LabelDismissal]?

  public init(
    id: UUID = UUID(),
    kind: Kind,
    targetID: String? = nil,
    itemID: String? = nil,
    instruction: String? = nil,
    importPath: String? = nil,
    isPinned: Bool? = nil,
    importWidth: Int? = nil,
    importHeight: Int? = nil,
    importMediaType: String? = nil,
    importOrientation: Int? = nil,
    importColorProfile: String? = nil,
    importCanonicalPath: String? = nil,
    importCanonicalDigest: String? = nil,
    dwellMs: Int? = nil,
    itemIDs: [String]? = nil,
    playlistRevision: String? = nil,
    metadataRevision: String? = nil,
    title: String? = nil,
    userLabels: [String]? = nil,
    dismissedLabels: [LabelDismissal]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.targetID = targetID
    self.itemID = itemID
    self.instruction = instruction
    self.importPath = importPath
    self.isPinned = isPinned
    self.importWidth = importWidth
    self.importHeight = importHeight
    self.importMediaType = importMediaType
    self.importOrientation = importOrientation
    self.importColorProfile = importColorProfile
    self.importCanonicalPath = importCanonicalPath
    self.importCanonicalDigest = importCanonicalDigest
    self.dwellMs = dwellMs
    self.itemIDs = itemIDs
    self.playlistRevision = playlistRevision
    self.metadataRevision = metadataRevision
    self.title = title
    self.userLabels = userLabels
    self.dismissedLabels = dismissedLabels
  }

  func withDecodedImport(_ decoded: DecodedImport) -> CoreCommand {
    let metadata = decoded.metadata
    return CoreCommand(
      id: id,
      kind: kind,
      targetID: targetID,
      itemID: itemID,
      instruction: instruction,
      importPath: importPath,
      isPinned: isPinned,
      importWidth: metadata.width,
      importHeight: metadata.height,
      importMediaType: metadata.mediaType,
      importOrientation: metadata.orientation,
      importColorProfile: metadata.colorProfile,
      importCanonicalPath: decoded.canonicalURL.path,
      importCanonicalDigest: decoded.canonicalDigest,
      dwellMs: dwellMs,
      itemIDs: itemIDs,
      playlistRevision: playlistRevision
    )
  }
}

package struct ImportMetadata: Sendable {
  package let width: Int
  package let height: Int
  package let mediaType: String
  package let orientation: Int
  package let colorProfile: String?
}
