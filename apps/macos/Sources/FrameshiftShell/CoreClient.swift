import Foundation

public protocol CoreClient: Sendable {
  func snapshot() async throws -> CoreSnapshot
  func snapshot(query: String) async throws -> CoreSnapshot
  func send(_ command: CoreCommand) async throws -> CoreSnapshot
}

public enum CoreClientError: Error, Equatable, Sendable {
  case commandIDConflict
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
  case itemNotFound
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
