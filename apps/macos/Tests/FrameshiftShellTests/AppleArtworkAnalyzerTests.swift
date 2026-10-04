import CryptoKit
import Foundation
import FrameshiftShell
import Testing
import Vision

@Suite("Bounded Apple Vision adapter", .serialized)
struct AppleArtworkAnalyzerTests {
  @Test("Actual Vision revisions produce bounded observations and securely comparable prints")
  func actualVision() async throws {
    let analyzer = AppleArtworkAnalyzer()
    let input = try fixture()
    let first = try await analyzer.analyze(input)
    let second = try await analyzer.analyze(input)
    #expect(first.masterDigest == input.masterDigest)
    #expect(first.inputDigest == input.digest)
    #expect(first.rendererBuildDigest == input.rendererBuildDigest)
    #expect(first.cohort == AppleArtworkAnalyzer.cohort)
    #expect(first.cohort.utf8.count <= 128)
    #expect(first.labels.count <= 32)
    #expect(
      first.labels.allSatisfy {
        $0.provenance == "vision" && $0.revision == first.cohort
          && ($0.confidence.map { (0.5...1).contains($0) } ?? false)
      })
    #expect((1...16_384).contains(first.featurePrint.archive.count))
    let distances = try await analyzer.compare(
      first.featurePrint,
      candidates: [digest(2): second.featurePrint, digest(1): first.featurePrint])
    #expect(distances.map(\.masterDigest) == [digest(1), digest(2)])
    #expect(distances.allSatisfy { $0.distance == 0 })
    // This synthetic raster establishes API/secure comparison behavior, not classifier accuracy.
  }

  @Test("Target, malformed pixel, cohort, archive and candidate-budget inputs refuse")
  func refusesInputs() async throws {
    let analyzer = AppleArtworkAnalyzer()
    let target = try fixture(changes: ["kind": "target", "targetID": "frame"])
    await #expect(throws: ArtworkAnalysisError.invalidInput) { try await analyzer.analyze(target) }
    let wrong = try fixture(changes: ["digest": digest(10)])
    await #expect(throws: ArtworkAnalysisError.invalidInput) { try await analyzer.analyze(wrong) }
    let actual = try await analyzer.analyze(fixture())
    let archive = actual.featurePrint.archive
    let mismatch = NativeFeaturePrint(cohort: "other", archive: archive, digest: hash(archive))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): mismatch])
    }
    let invalid = Data("invalid secure archive".utf8)
    let corrupt = NativeFeaturePrint(cohort: actual.cohort, archive: invalid, digest: hash(invalid))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): corrupt])
    }
    let changed = NativeFeaturePrint(cohort: actual.cohort, archive: archive, digest: digest(12))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): changed])
    }
    let oversized = Data(repeating: 0, count: 16_385)
    let large = NativeFeaturePrint(
      cohort: actual.cohort, archive: oversized, digest: hash(oversized))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): large])
    }
    let wrongClassBytes = try NSKeyedArchiver.archivedData(
      withRootObject: "fixture" as NSString, requiringSecureCoding: true)
    let wrongClass = NativeFeaturePrint(
      cohort: actual.cohort, archive: wrongClassBytes, digest: hash(wrongClassBytes))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): wrongClass])
    }
    let legacyRequest = VNGenerateImageFeaturePrintRequest()
    legacyRequest.revision = 1
    try VNImageRequestHandler(cgImage: fixture().image()!, orientation: .up).perform([legacyRequest]
    )
    let legacyArchive = try NSKeyedArchiver.archivedData(
      withRootObject: legacyRequest.results!.first!, requiringSecureCoding: true)
    let legacy = NativeFeaturePrint(
      cohort: actual.cohort, archive: legacyArchive, digest: hash(legacyArchive))
    await #expect(throws: ArtworkAnalysisError.incompatibleFeaturePrint) {
      try await analyzer.compare(actual.featurePrint, candidates: [digest(1): legacy])
    }
    let many = Dictionary(uniqueKeysWithValues: (1...17).map { (digest($0), actual.featurePrint) })
    await #expect(throws: ArtworkAnalysisError.invalidInput) {
      try await analyzer.compare(actual.featurePrint, candidates: many)
    }
  }

  @Test(
    "Timeout/cancellation resolves once but retains a non-cooperative worker's slot",
    arguments: [false, true])
  func workerCustody(cancel: Bool) async throws {
    let analyzer = AppleArtworkAnalyzer()
    let work = BlockingWork()
    defer { work.release.signal() }
    let task = Task {
      try await analyzer.run(deadline: cancel ? .seconds(10) : .milliseconds(30)) { _ in
        work.perform()
      }
    }
    await work.waitForStart()
    if cancel { task.cancel() }
    await #expect(throws: cancel ? ArtworkAnalysisError.cancelled : .timeout) {
      try await task.value
    }
    await #expect(throws: ArtworkAnalysisError.busy) { try await analyzer.run { _ in 1 } }
    work.release.signal()
    var next: Int?
    for _ in 0..<100 {
      do {
        next = try await analyzer.run { _ in 7 }
        break
      } catch ArtworkAnalysisError.busy { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(next == 7)
    // The late first result cannot resume the timed-out/cancelled continuation again.
  }
}

private final class BlockingWork: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var started = false
  func perform() -> Int {
    lock.withLock { started = true }
    release.wait()
    return 42
  }
  func waitForStart() async {
    while !lock.withLock({ started }) { await Task.yield() }
  }
}

private func digest(_ value: Int) -> String { "sha256:" + String(format: "%064x", value) }
private func hash(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func fixture(changes: [String: Any] = [:]) throws -> ArtworkPreview {
  var pixels = Data()
  for y in 0..<32 {
    for x in 0..<32 { pixels.append(contentsOf: [UInt8(x * 8), UInt8(y * 8), UInt8((x + y) * 4)]) }
  }
  var fields: [String: Any] = [
    "kind": "source", "masterDigest": digest(20), "approximation": true, "format": "rgb24",
    "width": 32, "height": 32, "aspectWidth": 32, "aspectHeight": 32,
    "rgb": pixels.base64EncodedString(), "digest": hash(pixels), "rendererBuildDigest": digest(21),
  ]
  fields.merge(changes) { _, replacement in replacement }
  return try JSONDecoder().decode(
    ArtworkPreview.self, from: JSONSerialization.data(withJSONObject: fields))
}
