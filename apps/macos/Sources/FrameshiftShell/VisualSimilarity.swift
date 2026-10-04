import CryptoKit
import Foundation
import Observation

public struct SimilarityCandidate: Decodable, Sendable {
  public let item: LibraryItem
  public let featurePrint: NativeFeaturePrint

  public init(item: LibraryItem, featurePrint: NativeFeaturePrint) {
    self.item = item
    self.featurePrint = featurePrint
  }
}

public struct SimilarityCandidatesPage: Decodable, Sendable {
  public let itemID: String
  public let cohort: String
  public let featureDigest: String
  public let items: [SimilarityCandidate]
  public let nextCursor: String?

  public init(
    itemID: String, cohort: String, featureDigest: String,
    items: [SimilarityCandidate], nextCursor: String? = nil
  ) {
    self.itemID = itemID
    self.cohort = cohort
    self.featureDigest = featureDigest
    self.items = items
    self.nextCursor = nextCursor
  }

  public func validate(source: LibraryAnalysis, afterID: String?) throws {
    let ids = items.map(\.item.id)
    guard itemID == source.itemID, cohort == source.cohort,
      featureDigest == source.featurePrint.digest, items.count <= 16,
      ids == ids.sorted(), Set(ids).count == ids.count,
      !ids.contains(itemID), ids.allSatisfy({ afterID == nil || $0 > afterID! }),
      nextCursor == nil || (items.count == 16 && nextCursor == ids.last)
    else { throw CoreClientError.protocolFailure }
    for candidate in items {
      let print = candidate.featurePrint
      let hash =
        "sha256:" + SHA256.hash(data: print.archive).map { String(format: "%02x", $0) }.joined()
      guard validLibraryDigest(candidate.item.id), candidate.item.digest == candidate.item.id,
        (1...256).contains(candidate.item.title.utf8.count),
        print.cohort == cohort, print.digest == hash,
        (1...AppleArtworkAnalyzer.maximumArchiveBytes).contains(print.archive.count)
      else { throw CoreClientError.protocolFailure }
    }
  }
}

public struct VisualMatch: Sendable {
  public let item: LibraryItem
  public let distance: Float

  public init(item: LibraryItem, distance: Float) {
    self.item = item
    self.distance = distance
  }
}

public struct VisualSimilarityResult: Sendable {
  public let itemID: String
  public let scannedCount: Int
  public let isPartial: Bool
  public let matches: [VisualMatch]

  public init(itemID: String, scannedCount: Int, isPartial: Bool, matches: [VisualMatch]) {
    self.itemID = itemID
    self.scannedCount = scannedCount
    self.isPartial = isPartial
    self.matches = matches
  }

  public func validate(itemID expected: String) throws {
    let ids = matches.map(\.item.id)
    guard itemID == expected, validLibraryDigest(itemID), (0...512).contains(scannedCount),
      matches.count <= min(100, scannedCount), Set(ids).count == ids.count,
      !ids.contains(itemID), !isPartial || scannedCount == 512,
      matches.allSatisfy({
        validLibraryDigest($0.item.id) && $0.item.digest == $0.item.id && $0.distance.isFinite
          && $0.distance >= 0
      }),
      zip(matches, matches.dropFirst()).allSatisfy({ ordered($0, $1) })
    else { throw CoreClientError.protocolFailure }
  }
}

/// Scans bounded observed pages; distances never qualify artwork or physical display.
package enum VisualSimilarity {
  package static func scan(
    source: LibraryAnalysis,
    load: @Sendable (String?) async throws -> SimilarityCandidatesPage,
    compare: @Sendable ([String: NativeFeaturePrint]) async throws -> [VisualDistance],
    verifySource: @Sendable () async throws -> LibraryAnalysis
  ) async throws -> VisualSimilarityResult {
    try source.validate(itemID: source.itemID)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var cursor: String?
    var scanned = 0
    var matches: [VisualMatch] = []
    for _ in 0..<32 {
      try checkDeadline(deadline)
      let page = try await load(cursor)
      try checkDeadline(deadline)
      try page.validate(source: source, afterID: cursor)
      let prints = Dictionary(
        uniqueKeysWithValues: page.items.map { ($0.item.id, $0.featurePrint) })
      let distances = prints.isEmpty ? [] : try await compare(prints)
      try checkDeadline(deadline)
      guard distances.count == page.items.count,
        Set(distances.map(\.masterDigest)) == Set(prints.keys),
        distances.allSatisfy({ $0.distance.isFinite && $0.distance >= 0 })
      else { throw CoreClientError.protocolFailure }
      let items = Dictionary(uniqueKeysWithValues: page.items.map { ($0.item.id, $0.item) })
      matches.append(
        contentsOf: distances.map {
          VisualMatch(item: items[$0.masterDigest]!, distance: $0.distance)
        })
      matches = Array(matches.sorted(by: ordered).prefix(100))
      scanned += page.items.count
      cursor = page.nextCursor
      if cursor == nil { break }
    }
    let current = try await verifySource()
    try checkDeadline(deadline)
    try current.validate(itemID: source.itemID)
    guard current.cohort == source.cohort, current.featurePrint.digest == source.featurePrint.digest
    else {
      throw CoreClientError.analysisChanged
    }
    return VisualSimilarityResult(
      itemID: source.itemID, scannedCount: scanned, isPartial: cursor != nil, matches: matches)
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    if ContinuousClock.now >= deadline { throw ArtworkAnalysisError.timeout }
  }
}

private func ordered(_ left: VisualMatch, _ right: VisualMatch) -> Bool {
  left.distance < right.distance
    || (left.distance == right.distance && left.item.id < right.item.id)
}

/// Keeps scan ownership until the actual worker returns, including after UI timeout.
@MainActor
@Observable
public final class VisualSimilarityModel {
  public private(set) var result: VisualSimilarityResult?
  public private(set) var message: String?
  public private(set) var isBusy = false
  private let client: any CoreClient
  private var task: Task<Void, Never>?
  private var revision = 0
  private let deadline: Duration

  public init(client: any CoreClient) {
    self.client = client
    deadline = .seconds(30)
  }

  package init(client: any CoreClient, deadline: Duration) {
    self.client = client
    self.deadline = deadline
  }

  public func start(itemID: String, filters: LibraryFilters) {
    guard task == nil else { return }
    revision += 1
    let scope = revision
    isBusy = true
    result = nil
    message = "Comparing local artwork…"
    task = Task {
      let timer = Task {
        try? await Task.sleep(for: deadline)
        guard !Task.isCancelled, scope == revision else { return }
        message = "Local comparison timed out. Waiting for its worker to finish."
        task?.cancel()
      }
      defer {
        timer.cancel()
        if scope == revision, Task.isCancelled {
          if message?.hasPrefix("Stopping") == true {
            message = "Local comparison stopped."
          } else if message?.contains("Waiting for its worker") == true {
            message = "Local comparison timed out. Retry a narrower filter."
          }
        }
        task = nil
        isBusy = false
      }
      do {
        let found = try await client.similarArtwork(itemID: itemID, filters: filters)
        guard !Task.isCancelled, scope == revision else { return }
        try found.validate(itemID: itemID)
        result = found
        message =
          found.isPartial
          ? "Partial scan: compared 512 candidates; showing up to 100 nearest observed matches."
          : "Compared \(found.scannedCount) analyzed candidates; lower distance means more similar."
      } catch {
        guard scope == revision else { return }
        if Task.isCancelled {
          if message?.hasPrefix("Stopping") == true { message = "Local comparison stopped." }
          return
        }
        switch error {
        case CoreClientError.analysisUnavailable, CoreClientError.analysisChanged:
          message =
            "Current local observations are unavailable or changed. Analyze this artwork and retry."
        case ArtworkAnalysisError.busy:
          message = "Local analysis is busy. Wait for its worker and retry."
        case ArtworkAnalysisError.timeout:
          message = "Local comparison timed out. Retry a narrower filter."
        default:
          message = "Local comparison could not be verified. Refresh or reanalyze the artwork."
        }
      }
    }
  }

  public func stop() {
    result = nil
    message = "Stopping local comparison…"
    task?.cancel()
  }

  public func invalidate() {
    revision += 1
    result = nil
    message = nil
    task?.cancel()
  }
}
