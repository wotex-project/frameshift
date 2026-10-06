import Darwin
import Foundation
import FrameshiftMacRelease

let arguments = Array(CommandLine.arguments.dropFirst())
let captureCommand = arguments.first == "capture-swiftpm-inputs"
let frameworkCommand = arguments.first == "verify-sparkle-framework"
let resourceCommand = arguments.first == "verify-generation-resources"
let signatureCommand = arguments.first == "verify-development-bundle"
let bundleCommand = arguments.first == "check-bundle" || signatureCommand
guard
  (frameworkCommand && arguments.count == 3)
    || (bundleCommand && arguments.count == 3
      && NativeBundleArchitecture(rawValue: arguments[2]) != nil)
    || (arguments.count == 2
      && [
        "verify-sparkle-archive", "verify-sparkle-plist", "inspect-macho",
        "verify-generation-resources",
        "capture-swiftpm-inputs",
      ]
      .contains(arguments[0]))
else {
  FileHandle.standardError.write(
    Data(
      "usage: frameshift-mac-release [verify-sparkle-archive|verify-sparkle-plist|inspect-macho|verify-generation-resources] INPUT\n       frameshift-mac-release [check-bundle|verify-development-bundle] APP arm64|x86_64|universal\n       frameshift-mac-release verify-sparkle-framework ARCHIVE FRAMEWORK\n       frameshift-mac-release capture-swiftpm-inputs REPOSITORY\n"
        .utf8)
  )
  exit(64)
}
let manifestChild = OwnedCommand()
let materialChild = OwnedCommand()
do {
  if captureCommand {
    var bytes = try await SwiftPMInputCapture.capture(
      repository: arguments[1], manifestChild: manifestChild, materialChild: materialChild
    ).observationBytes()
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if frameworkCommand {
    var bytes = try await PinnedSparkleFramework.verify(
      archive: arguments[1], framework: arguments[2], child: materialChild
    ).observationBytes()
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if resourceCommand {
    var bytes = try PinnedGenerationResources.verify(arguments[1])
    guard bytes.count < 64 * 1024 else { throw ReleaseToolError.inputLimit }
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if arguments[0] == "verify-sparkle-archive" {
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
  if captureCommand {
    FileHandle.standardError.write(
      Data("recorded updater compiler inputs unavailable, unsafe or changed\n".utf8))
    _ = await manifestChild.retainUntilExitAfterRefusal()
    _ = await materialChild.retainUntilExitAfterRefusal()
    exit(1)
  }
  if frameworkCommand {
    FileHandle.standardError.write(
      Data("pinned updater material unavailable, unsafe or changed\n".utf8))
    _ = await materialChild.retainUntilExitAfterRefusal()
    exit(1)
  }
  if resourceCommand {
    FileHandle.standardError.write(
      Data("generation SDK resources: unavailable, unsafe or changed custody\n".utf8))
    exit(1)
  }
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
