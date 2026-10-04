import CoreGraphics
import CryptoKit
import Foundation

/// A transient host-rendered approximation, never a delivery or display receipt.
public struct ArtworkPreview: Decodable, Equatable, Sendable {
  public let kind: String
  public let masterDigest: String
  public let targetID: String?
  public let profileID: String?
  public let capabilityDigest: String?
  public let approximation: Bool
  public let format: String
  public let width: Int
  public let height: Int
  public let aspectWidth: Int
  public let aspectHeight: Int
  public let rgb: Data
  public let digest: String
  public let rendererBuildDigest: String

  public func validate(masterID: String, target: FrameTarget?) throws {
    let pixelDigest = "sha256:" + SHA256.hash(data: rgb).map { String(format: "%02x", $0) }.joined()
    guard masterDigest == masterID, validDigest(masterDigest), targetID == target?.id,
      profileID == target?.profileID,
      capabilityDigest == target?.capabilityDigest,
      kind == (target == nil ? "source" : "target"), approximation, format == "rgb24",
      (1...256).contains(width), (1...256).contains(height),
      (1...32_768).contains(aspectWidth), (1...32_768).contains(aspectHeight),
      rgb.count == width * height * 3, validDigest(rendererBuildDigest),
      digest == pixelDigest
    else { throw CoreClientError.protocolFailure }
  }

  private func validDigest(_ value: String) -> Bool {
    value.hasPrefix("sha256:") && value.count == 71
      && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
  }

  /// Call only after validating the response against its requested identity.
  public func image() -> CGImage? {
    guard (1...256).contains(width), (1...256).contains(height), rgb.count == width * height * 3,
      let provider = CGDataProvider(data: rgb as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
      bytesPerRow: width * 3, space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
