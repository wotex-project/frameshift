import Foundation

/// Presentation state for one frame; accepted playlists remain owned by the core.
public struct PlaylistDraft: Equatable, Sendable {
  public var items: [PlaylistItem]
  public var intervalInput: String
  public var intervalUnit: LoopIntervalInput.Unit
  public var useProfileSuggestion: Bool

  public init(target: FrameTarget) {
    items = target.playlist?.items ?? []
    let milliseconds = max(
      target.minimumDwellMs ?? 1,
      target.loopInterval?.requestedDwellMs ?? target.loopInterval?.appliedDwellMs
        ?? target.playlist?.dwellMs ?? target.recommendedDwellMs ?? 60_000)
    intervalUnit = LoopIntervalInput.exactUnit(for: milliseconds)
    intervalInput = String(milliseconds / intervalUnit.multiplier)
    useProfileSuggestion =
      target.loopInterval?.source == "profile"
      || (target.loopInterval == nil && target.playlist == nil && target.recommendedDwellMs != nil)
  }

  public func effectiveDwell(for target: FrameTarget) -> Int? {
    if useProfileSuggestion {
      guard let dwell = target.recommendedDwellMs,
        dwell >= max(1, target.minimumDwellMs ?? 1),
        dwell <= LoopIntervalInput.maximumMilliseconds
      else { return nil }
      return dwell
    }
    return LoopIntervalInput.dwellMilliseconds(
      intervalInput, unit: intervalUnit, minimumDwellMs: target.minimumDwellMs)
  }
}
