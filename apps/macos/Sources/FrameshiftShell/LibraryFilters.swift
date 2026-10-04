import Foundation

public enum ArtworkSource: String, Codable, CaseIterable, Sendable {
  case imported = "import"
  case generated

  public var label: String {
    switch self {
    case .imported: "Imported"
    case .generated: "Generated"
    }
  }
}

public struct LibraryFilters: Codable, Equatable, Sendable {
  public var pinnedOnly: Bool
  public var sourceKind: ArtworkSource?
  public var frameID: String?

  public init(pinnedOnly: Bool = false, sourceKind: ArtworkSource? = nil, frameID: String? = nil) {
    self.pinnedOnly = pinnedOnly
    self.sourceKind = sourceKind
    self.frameID = frameID
  }

  public var isActive: Bool { pinnedOnly || sourceKind != nil || frameID != nil }

  public func validate() throws {
    if let frameID, frameID.isEmpty || frameID.utf8.count > 128 {
      throw CoreClientError.invalidCommand
    }
  }
}
