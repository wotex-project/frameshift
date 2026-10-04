import CryptoKit
import Foundation

public struct LibraryAnalysis: Decodable, Sendable {
  public let itemID: String
  public let cohort: String
  public let inputDigest: String
  public let rendererBuildDigest: String
  public let observedAtMs: Int
  public let featurePrint: NativeFeaturePrint

  public func validate(itemID expected: String) throws {
    let hash =
      "sha256:"
      + SHA256.hash(data: featurePrint.archive).map { String(format: "%02x", $0) }.joined()
    guard itemID == expected, validLibraryDigest(itemID), validLibraryDigest(inputDigest),
      validLibraryDigest(rendererBuildDigest), observedAtMs >= 0,
      validVisionCohort(cohort), featurePrint.cohort == cohort,
      (1...AppleArtworkAnalyzer.maximumArchiveBytes).contains(featurePrint.archive.count),
      featurePrint.digest == hash
    else { throw CoreClientError.protocolFailure }
  }
}

public struct PendingLibraryAnalysis: Decodable, Sendable {
  public let itemIDs: [String]
  public let hasMore: Bool

  public init(itemIDs: [String], hasMore: Bool) {
    self.itemIDs = itemIDs
    self.hasMore = hasMore
  }

  public func validate() throws {
    guard itemIDs.count <= 16, Set(itemIDs).count == itemIDs.count,
      itemIDs.allSatisfy(validLibraryDigest), itemIDs == itemIDs.sorted(),
      !hasMore || itemIDs.count == 16
    else { throw CoreClientError.protocolFailure }
  }
}

package func validVisionCohort(_ cohort: String) -> Bool {
  cohort.utf8.count <= 128
    && cohort.range(
      of:
        #"\Aapple-vision-v1:c2:f2:macos[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}:(arm64|x86_64):source256-fit\z"#,
      options: .regularExpression) != nil
}

package func featureArchiveChunks(_ data: Data) throws -> [String] {
  guard (1...AppleArtworkAnalyzer.maximumArchiveBytes).contains(data.count) else {
    throw CoreClientError.invalidAnalysis
  }
  return stride(from: 0, to: data.count, by: 6144).map { offset in
    data.subdata(in: offset..<min(offset + 6144, data.count)).base64EncodedString()
  }
}
