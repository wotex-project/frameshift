import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

package struct DecodedImport {
  package let metadata: ImportMetadata
  package let canonicalURL: URL
  package let canonicalDigest: String
  package let workDirectory: URL

  package func removeWorkDirectory() {
    try? FileManager.default.removeItem(at: workDirectory)
  }
}

package enum AppleImageDecoder {
  private static let maximumSourceBytes = 128 * 1024 * 1024
  private static let maximumDimension = 32_768
  package static let maximumPixels = 16_777_011
  private static let supportedMediaTypes: Set<String> = [
    "image/gif",
    "image/heic",
    "image/heif",
    "image/jpeg",
    "image/png",
    "image/tiff",
    "image/webp",
  ]

  package static func decode(_ url: URL) throws -> DecodedImport {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    } catch {
      throw CoreClientError.importUnreadable
    }

    guard values.isRegularFile == true, let size = values.fileSize else {
      throw CoreClientError.importUnreadable
    }
    guard size > 0, size <= maximumSourceBytes else {
      throw CoreClientError.importTooLarge
    }

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
      CGImageSourceGetCount(source) == 1,
      let typeIdentifier = CGImageSourceGetType(source),
      let mediaType = UTType(typeIdentifier as String)?.preferredMIMEType,
      supportedMediaTypes.contains(mediaType),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
        as? [CFString: Any],
      let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      throw CoreClientError.unsupportedMedia
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else { throw CoreClientError.importUnreadable }

    let rotatesAxes = (5...8).contains(orientation)
    let width = rotatesAxes ? sourceHeight : sourceWidth
    let height = rotatesAxes ? sourceWidth : sourceHeight
    try validateDimensions(width: width, height: height)

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
      image.width == width,
      image.height == height
    else {
      throw CoreClientError.importUnreadable
    }

    let rgba = try canonicalRGBA(image: image, width: width, height: height)
    let workDirectory = try makeWorkDirectory()

    do {
      let canonicalURL = workDirectory.appendingPathComponent("canonical.rgba", isDirectory: false)
      try rgba.write(to: canonicalURL, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: canonicalURL.path
      )

      let digest = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
      let profileName = properties[kCGImagePropertyProfileName] as? String
      let boundedProfile = profileName.flatMap {
        $0.lengthOfBytes(using: .utf8) <= 256 ? $0 : nil
      }

      return DecodedImport(
        metadata: ImportMetadata(
          width: width,
          height: height,
          mediaType: mediaType,
          orientation: orientation,
          colorProfile: boundedProfile
        ),
        canonicalURL: canonicalURL,
        canonicalDigest: "sha256:\(digest)",
        workDirectory: workDirectory
      )
    } catch {
      try? FileManager.default.removeItem(at: workDirectory)
      if let clientError = error as? CoreClientError { throw clientError }
      throw CoreClientError.importUnreadable
    }
  }

  package static func validateDimensions(width: Int, height: Int) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
      !overflow, pixels <= maximumPixels
    else {
      throw CoreClientError.importTooLarge
    }
  }

  private static func canonicalRGBA(image: CGImage, width: Int, height: Int) throws -> Data {
    let bytesPerRow = width * 4
    var rgba = Data(count: bytesPerRow * height)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw CoreClientError.importUnreadable
    }
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    )

    let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
      guard let baseAddress = storage.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo.rawValue
        )
      else {
        return false
      }

      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

      let bytes = storage.bindMemory(to: UInt8.self)
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        let alpha = Int(bytes[offset + 3])
        if alpha == 0 {
          bytes[offset] = 0
          bytes[offset + 1] = 0
          bytes[offset + 2] = 0
        } else if alpha < 255 {
          for channel in 0..<3 {
            let value = (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha
            bytes[offset + channel] = UInt8(clamping: value)
          }
        }
      }
      return true
    }

    guard rendered else { throw CoreClientError.importUnreadable }
    return rgba
  }

  private static func makeWorkDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "frameshift-import-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )

    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return directory
    } catch {
      throw CoreClientError.importUnreadable
    }
  }
}
