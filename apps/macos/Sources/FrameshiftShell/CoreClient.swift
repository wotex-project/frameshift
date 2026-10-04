import Foundation

public protocol CoreClient: Sendable {
  func snapshot() async throws -> CoreSnapshot
  func snapshot(query: String) async throws -> CoreSnapshot
  func snapshot(query: String, filters: LibraryFilters) async throws -> CoreSnapshot
  func send(_ command: CoreCommand) async throws -> CoreSnapshot
  func preview(masterID: String, target: FrameTarget?) async throws -> ArtworkPreview
  func metadata(itemID: String) async throws -> LibraryMetadata
  func recovery(afterID: String?) async throws -> LibraryRecoveryPage
  func storage() async throws -> LibraryStorage
  func analysis(itemID: String) async throws -> LibraryAnalysis
  func analysisPending() async throws -> PendingLibraryAnalysis
  func analyzeArtwork(itemID: String, force: Bool) async throws -> CoreSnapshot
  func similarityCandidates(source: LibraryAnalysis, afterID: String?, filters: LibraryFilters)
    async throws -> SimilarityCandidatesPage
  func similarArtwork(itemID: String, filters: LibraryFilters) async throws
    -> VisualSimilarityResult
}

extension CoreClient {
  public func similarityCandidates(
    source _: LibraryAnalysis, afterID _: String?, filters _: LibraryFilters
  ) async throws -> SimilarityCandidatesPage {
    throw CoreClientError.analysisUnavailable
  }

  public func similarArtwork(itemID: String, filters: LibraryFilters) async throws
    -> VisualSimilarityResult
  {
    try filters.validate()
    let source = try await analysis(itemID: itemID)
    guard source.cohort == AppleArtworkAnalyzer.cohort else {
      throw CoreClientError.analysisUnavailable
    }
    try await AppleArtworkAnalyzer.shared.validateFeaturePrint(source.featurePrint)
    return try await VisualSimilarity.scan(
      source: source,
      load: { try await self.similarityCandidates(source: source, afterID: $0, filters: filters) },
      compare: {
        try await AppleArtworkAnalyzer.shared.compare(source.featurePrint, candidates: $0)
      },
      verifySource: { try await self.analysis(itemID: itemID) })
  }

  public func analysis(itemID _: String) async throws -> LibraryAnalysis {
    throw CoreClientError.analysisUnavailable
  }

  public func analysisPending() async throws -> PendingLibraryAnalysis {
    throw CoreClientError.analysisUnavailable
  }

  public func analyzeArtwork(itemID _: String, force _: Bool) async throws -> CoreSnapshot {
    throw CoreClientError.analysisUnavailable
  }

  public func storage() async throws -> LibraryStorage {
    throw CoreClientError.storageUnavailable
  }

  public func snapshot(query: String, filters: LibraryFilters) async throws -> CoreSnapshot {
    guard !filters.isActive else { throw CoreClientError.filtersUnavailable }
    return try await snapshot(query: query)
  }

  public func metadata(itemID _: String) async throws -> LibraryMetadata {
    throw CoreClientError.metadataUnavailable
  }

  public func recovery(afterID _: String?) async throws -> LibraryRecoveryPage {
    throw CoreClientError.metadataUnavailable
  }

  public func preview(masterID _: String, target _: FrameTarget?) async throws -> ArtworkPreview {
    throw CoreClientError.previewUnavailable
  }
}

public enum CoreClientError: Error, Equatable, Sendable {
  case commandIDConflict
  case analysisUnavailable
  case analysisChanged
  case invalidAnalysis
  case libraryStorageFull
  case storageUnavailable
  case storageRevisionConflict
  case commandOutcomeUnknown
  case coreUnavailable
  case credentialBrokerUnavailable
  case deliveryOutcomeUnknown
  case deliveryPending
  case importTooLarge
  case importUnreadable
  case invalidCommand
  case loopAlreadyActive
  case loopPending
  case noPinnedArtwork
  case intervalRequired
  case loopUnavailable
  case loopStorageFull
  case loopRevisionConflict
  case loopProfileChanged
  case duplicateLoopArtwork
  case previewUnavailable
  case previewBusy
  case previewProfileChanged
  case itemNotFound
  case metadataUnavailable
  case metadataRevisionConflict
  case invalidMetadata
  case restoreFailed
  case filtersUnavailable
  case protocolFailure
  case pairingIncomplete
  case pairingOutcomeUnknown
  case pairingPreflightFailed
  case pairingRejected
  case targetNotFound
  case unsupportedMedia
}

public struct PairedFrameResult: Decodable, Sendable {
  public let frameID: String

  private enum CodingKeys: String, CodingKey {
    case frameID = "frameId"
  }
}
