import Darwin
import Foundation
import FrameshiftMacRelease

let arguments = Array(CommandLine.arguments.dropFirst())
let signatureCommand = arguments.first == "verify-development-bundle"
let bundleCommand = arguments.first == "check-bundle" || signatureCommand
guard
  (bundleCommand && arguments.count == 3
    && NativeBundleArchitecture(rawValue: arguments[2]) != nil)
    || (arguments.count == 2
      && ["verify-sparkle-archive", "verify-sparkle-plist", "inspect-macho"].contains(arguments[0]))
else {
  FileHandle.standardError.write(
    Data(
      "usage: frameshift-mac-release [verify-sparkle-archive|verify-sparkle-plist|inspect-macho] INPUT\n       frameshift-mac-release [check-bundle|verify-development-bundle] APP arm64|x86_64|universal\n"
        .utf8)
  )
  exit(64)
}
do {
  if arguments[0] == "verify-sparkle-archive" {
    try PinnedSparkleArchive.verify(arguments[1])
    FileHandle.standardOutput.write(
      Data("Sparkle \(PinnedSparkleArchive.version) archive verified\n".utf8))
  } else if arguments[0] == "verify-sparkle-plist" {
    try PinnedSparkleArchive.verifyFrameworkInfo(arguments[1])
    FileHandle.standardOutput.write(
      Data("Sparkle \(PinnedSparkleArchive.version) plist identity verified\n".utf8))
  } else if bundleCommand {
    let architecture = NativeBundleArchitecture(rawValue: arguments[2])!
    let observation =
      signatureCommand
      ? try NativeSignatureVerifier.verifyDevelopmentBundle(
        arguments[1], architecture: architecture)
      : try NativeBundleInspector.inspect(arguments[1], architecture: architecture)
    var bytes = try observation.observationBytes()
    guard bytes.count < 16 * 1024 * 1024 else { throw ReleaseToolError.inputLimit }
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = try encoder.encode(MachOInspector.inspect(arguments[1]))
    guard bytes.count < 16 * 1024 * 1024 else { throw ReleaseToolError.inputLimit }
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  }
} catch {
  if bundleCommand {
    let message =
      signatureCommand ? "Mac development signatures refused" : "Mac bundle closure refused"
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
  }
  let message = (error as? ReleaseToolError)?.description ?? "Mac release admission refused"
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(65)
}
