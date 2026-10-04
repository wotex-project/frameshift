import CryptoKit
import Foundation
import Vision

public enum ArtworkAnalysisError: Error, Equatable, Sendable {
  case busy
  case cancelled
  case timeout
  case unavailable
  case invalidInput
  case invalidResult
  case incompatibleFeaturePrint
}

/// An opaque Apple observation; its cohort is part of its comparison identity.
public struct NativeFeaturePrint: Codable, Equatable, Sendable {
  public let cohort: String
  public let archive: Data
  public let digest: String

  public init(cohort: String, archive: Data, digest: String) {
    self.cohort = cohort
    self.archive = archive
    self.digest = digest
  }
}

/// Local observations of the bounded source-preview input, never artwork authority.
public struct NativeArtworkAnalysis: Sendable {
  public let masterDigest: String
  public let inputDigest: String
  public let rendererBuildDigest: String
  public let cohort: String
  public let labels: [ArtworkLabel]
  public let featurePrint: NativeFeaturePrint
}

public struct VisualDistance: Equatable, Sendable {
  public let masterDigest: String
  public let distance: Float

  public init(masterDigest: String, distance: Float) {
    self.masterDigest = masterDigest
    self.distance = distance
  }
}

/// Owns one bounded Vision worker. Caller cancellation never releases a still-running worker.
public actor AppleArtworkAnalyzer {
  public static let shared = AppleArtworkAnalyzer()
  public static let maximumArchiveBytes = 16 * 1024
  public static let cohort: String = {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "unsupported"
    #endif
    return
      "apple-vision-v1:c2:f2:macos\(os.majorVersion).\(os.minorVersion).\(os.patchVersion):\(architecture):source256-fit"
  }()
  private var workerID: UUID?

  package init() {}

  public func analyze(_ preview: ArtworkPreview) async throws -> NativeArtworkAnalysis {
    do { try preview.validate(masterID: preview.masterDigest, target: nil) } catch {
      throw ArtworkAnalysisError.invalidInput
    }
    return try await run { control in
      guard VNClassifyImageRequest.supportedRevisions.contains(2),
        VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(2),
        let image = preview.image()
      else { throw ArtworkAnalysisError.unavailable }
      let classifier = VNClassifyImageRequest()
      classifier.revision = 2
      let features = VNGenerateImageFeaturePrintRequest()
      features.revision = 2
      features.imageCropAndScaleOption = .scaleFit
      try control.install([classifier, features])
      do {
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([classifier, features])
      } catch {
        if control.isCancelled { throw ArtworkAnalysisError.cancelled }
        throw ArtworkAnalysisError.unavailable
      }
      try control.checkCancellation()
      guard let observations = classifier.results, observations.count <= 10_000,
        let print = features.results?.first, features.results?.count == 1,
        print.requestRevision == 2
      else { throw ArtworkAnalysisError.invalidResult }
      try validateObservation(print)
      let archive: Data
      do {
        archive = try NSKeyedArchiver.archivedData(
          withRootObject: print, requiringSecureCoding: true)
      } catch { throw ArtworkAnalysisError.invalidResult }
      guard (1...Self.maximumArchiveBytes).contains(archive.count) else {
        throw ArtworkAnalysisError.invalidResult
      }
      let featurePrint = NativeFeaturePrint(
        cohort: Self.cohort, archive: archive, digest: sha256(archive))
      // Exercise the actual secure decoder before handing opaque bytes to a consumer.
      _ = try decode(featurePrint)
      return NativeArtworkAnalysis(
        masterDigest: preview.masterDigest, inputDigest: preview.digest,
        rendererBuildDigest: preview.rendererBuildDigest, cohort: Self.cohort,
        labels: try labels(observations), featurePrint: featurePrint)
    }
  }

  /// Verifies a source even when the Library has no other comparable candidates.
  public func validateFeaturePrint(_ print: NativeFeaturePrint) async throws {
    try await run { control in
      try control.checkCancellation()
      _ = try decode(print)
    }
  }

  public func compare(
    _ source: NativeFeaturePrint, candidates: [String: NativeFeaturePrint]
  ) async throws -> [VisualDistance] {
    guard (1...16).contains(candidates.count), candidates.keys.allSatisfy(validLibraryDigest) else {
      throw ArtworkAnalysisError.invalidInput
    }
    return try await run { control in
      let sourceObservation = try decode(source)
      var distances: [VisualDistance] = []
      for (id, candidate) in candidates.sorted(by: { $0.key < $1.key }) {
        try control.checkCancellation()
        let observation = try decode(candidate)
        var distance: Float = 0
        do { try sourceObservation.computeDistance(&distance, to: observation) } catch {
          throw ArtworkAnalysisError.incompatibleFeaturePrint
        }
        guard distance.isFinite, distance >= 0 else { throw ArtworkAnalysisError.invalidResult }
        distances.append(VisualDistance(masterDigest: id, distance: distance))
      }
      return distances.sorted {
        $0.distance == $1.distance ? $0.masterDigest < $1.masterDigest : $0.distance < $1.distance
      }
    }
  }

  package func run<Result: Sendable>(
    deadline: Duration = .seconds(10),
    operation: @escaping @Sendable (VisionCancellation) throws -> Result
  ) async throws -> Result {
    guard workerID == nil else { throw ArtworkAnalysisError.busy }
    guard !Task.isCancelled else { throw ArtworkAnalysisError.cancelled }
    let id = UUID()
    workerID = id
    let control = VisionCancellation()
    let completion = VisionCompletion<Result>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        completion.install(continuation)
        let timer = Task.detached {
          do { try await Task.sleep(for: deadline) } catch { return }
          control.cancel()
          completion.finish(.failure(ArtworkAnalysisError.timeout))
        }
        Task.detached {
          let result = Swift.Result { try operation(control) }
          await self.finished(id)
          timer.cancel()
          completion.finish(result)
        }
      }
    } onCancel: {
      control.cancel()
      completion.finish(.failure(ArtworkAnalysisError.cancelled))
    }
  }

  private func finished(_ id: UUID) {
    if workerID == id { workerID = nil }
  }
}

/// Requests are installed and cancelled under a lock; Vision execution stays in its worker.
package final class VisionCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var requests: [VNRequest] = []

  package var isCancelled: Bool { lock.withLock { cancelled } }

  package func checkCancellation() throws {
    if isCancelled { throw ArtworkAnalysisError.cancelled }
  }

  package func install(_ requests: [VNRequest]) throws {
    try lock.withLock {
      guard !cancelled else { throw ArtworkAnalysisError.cancelled }
      self.requests = requests
    }
  }

  package func cancel() {
    lock.withLock {
      cancelled = true
      for request in requests { request.cancel() }
    }
  }
}

private final class VisionCompletion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  func install(_ continuation: CheckedContinuation<Value, any Error>) {
    lock.withLock {
      if let result { continuation.resume(with: result) } else { self.continuation = continuation }
    }
  }

  func finish(_ result: Result<Value, any Error>) {
    lock.withLock {
      guard self.result == nil else { return }
      self.result = result
      continuation?.resume(with: result)
      continuation = nil
    }
  }
}

private func sha256(_ bytes: Data) -> String {
  "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func decode(_ feature: NativeFeaturePrint) throws -> VNFeaturePrintObservation {
  guard feature.cohort == AppleArtworkAnalyzer.cohort,
    (1...AppleArtworkAnalyzer.maximumArchiveBytes).contains(feature.archive.count),
    feature.digest == sha256(feature.archive)
  else { throw ArtworkAnalysisError.incompatibleFeaturePrint }
  let observation: VNFeaturePrintObservation?
  do {
    observation = try NSKeyedUnarchiver.unarchivedObject(
      ofClass: VNFeaturePrintObservation.self, from: feature.archive)
  } catch { throw ArtworkAnalysisError.incompatibleFeaturePrint }
  guard let observation else { throw ArtworkAnalysisError.incompatibleFeaturePrint }
  try validateObservation(observation)
  return observation
}

private func validateObservation(_ observation: VNFeaturePrintObservation) throws {
  guard observation.requestRevision == 2, (1...4096).contains(observation.elementCount),
    observation.elementType == .float,
    observation.data.count == observation.elementCount * MemoryLayout<Float>.size
  else { throw ArtworkAnalysisError.incompatibleFeaturePrint }
  let finite = observation.data.withUnsafeBytes { bytes in
    (0..<observation.elementCount).allSatisfy {
      bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self).isFinite
    }
  }
  guard finite else { throw ArtworkAnalysisError.invalidResult }
}

private func labels(_ observations: [VNClassificationObservation]) throws -> [ArtworkLabel] {
  guard
    observations.allSatisfy({
      $0.requestRevision == 2 && $0.confidence.isFinite && (0...1).contains($0.confidence)
    })
  else { throw ArtworkAnalysisError.invalidResult }
  var seen: Set<String> = []
  var labels: [ArtworkLabel] = []
  for observation in observations.sorted(by: {
    $0.confidence == $1.confidence ? $0.identifier < $1.identifier : $0.confidence > $1.confidence
  }) where observation.confidence >= 0.5 {
    let label = observation.identifier.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...128).contains(label.utf8.count),
      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw ArtworkAnalysisError.invalidResult }
    let identity = label.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
    guard seen.insert(String(decoding: identity, as: UTF8.self)).inserted else { continue }
    labels.append(
      ArtworkLabel(
        label: label, provenance: "vision", confidence: Double(observation.confidence),
        revision: AppleArtworkAnalyzer.cohort))
    if labels.count == 32 { break }
  }
  return labels
}
