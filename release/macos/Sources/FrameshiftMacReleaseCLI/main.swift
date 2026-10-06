import Darwin
import Foundation
import FrameshiftMacRelease

let arguments = Array(CommandLine.arguments.dropFirst())
let compileCommand = arguments.first == "compile-updater-inputs"
let captureCommand = arguments.first == "capture-swiftpm-inputs" || compileCommand
let stagingCommand = arguments.first == "stage-sparkle-framework"
let mergeCommand = arguments.first == "merge-development-bundles"
let imageCommand = arguments.first == "create-development-image"
let frameworkCommand = arguments.first == "verify-sparkle-framework"
let resourceCommand = arguments.first == "verify-generation-resources"
let signatureCommand = arguments.first == "verify-development-bundle"
let swiftPreparationCommand = arguments.first == "prepare-swift-updater-bundle"
let swiftBuildPreparationCommand = arguments.first == "prepare-swiftbuild-updater-bundle"
let preparationCommand =
  arguments.first == "prepare-development-bundle" || swiftPreparationCommand
  || swiftBuildPreparationCommand
let bundleCommand = arguments.first == "check-bundle" || signatureCommand
guard
  (frameworkCommand && arguments.count == 3)
    || (mergeCommand && arguments.count == 4)
    || (imageCommand && arguments.count == 4
      && NativeBundleArchitecture(rawValue: arguments[2]) != nil)
    || (stagingCommand && arguments.count == 4
      && ["arm64", "x86_64"].contains(arguments[3]))
    || ((bundleCommand || preparationCommand) && arguments.count == 3
      && NativeBundleArchitecture(rawValue: arguments[2]) != nil)
    || (arguments.count == 2
      && [
        "verify-sparkle-archive", "verify-sparkle-plist", "inspect-macho",
        "verify-generation-resources",
        "capture-swiftpm-inputs",
        "compile-updater-inputs",
      ]
      .contains(arguments[0]))
else {
  FileHandle.standardError.write(
    Data(
      "usage: frameshift-mac-release [verify-sparkle-archive|verify-sparkle-plist|inspect-macho|verify-generation-resources] INPUT\n       frameshift-mac-release [check-bundle|verify-development-bundle|prepare-development-bundle|prepare-swift-updater-bundle|prepare-swiftbuild-updater-bundle] APP arm64|x86_64|universal\n       frameshift-mac-release verify-sparkle-framework ARCHIVE FRAMEWORK\n       frameshift-mac-release stage-sparkle-framework ARCHIVE PRIVATE_APP arm64|x86_64\n       frameshift-mac-release merge-development-bundles ARM_APP INTEL_APP EMPTY_PRIVATE_APP\n       frameshift-mac-release create-development-image APP arm64|x86_64|universal EMPTY_PRIVATE_WORKSPACE\n       frameshift-mac-release [capture-swiftpm-inputs|compile-updater-inputs] REPOSITORY\n"
        .utf8)
  )
  exit(64)
}
let manifestChild = OwnedCommand()
let materialChild = OwnedCommand()
let compilerChild = OwnedCommand()
let preparer = DevelopmentBundlePreparer()
let stager = SparkleFrameworkStager()
let merger = UniversalBundleMerger()
let imageProducer = DevelopmentDiskImageProducer()
do {
  if imageCommand {
    var bytes = try await imageProducer.create(
      app: arguments[1],
      architecture: NativeBundleArchitecture(rawValue: arguments[2])!, workspace: arguments[3]
    ).observationBytes()
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if mergeCommand {
    var bytes = try await merger.merge(arm: arguments[1], intel: arguments[2], stage: arguments[3])
      .observationBytes()
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if stagingCommand {
    var bytes = try await stager.stage(
      archive: arguments[1], app: arguments[2],
      architecture: NativeBundleArchitecture(rawValue: arguments[3])!
    ).observationBytes()
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  } else if preparationCommand {
    let architecture = NativeBundleArchitecture(rawValue: arguments[2])!
    let result: NativeBundleObservation
    if swiftBuildPreparationCommand {
      result = try await preparer.prepareSwiftBuildUpdater(arguments[1], architecture: architecture)
    } else if swiftPreparationCommand {
      result = try await preparer.prepareSwiftUpdater(arguments[1], architecture: architecture)
    } else {
      result = try await preparer.prepare(arguments[1], architecture: architecture)
    }
    FileHandle.standardOutput.write(
      Data(
        "development bundle: \(result.architecture.rawValue), minimum macOS \(result.declaredMinimum)\n"
          .utf8))
  } else if captureCommand {
    let result: SwiftPMInputObservation
    if compileCommand {
      result = try await SwiftPMInputCapture.compileUpdater(
        repository: arguments[1], manifestChild: manifestChild, materialChild: materialChild,
        compilerChild: compilerChild)
    } else {
      result = try await SwiftPMInputCapture.capture(
        repository: arguments[1], manifestChild: manifestChild, materialChild: materialChild)
    }
    var bytes = try result.observationBytes()
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
  if imageCommand {
    FileHandle.standardError.write(
      Data("development image refused; private work and effect custody retained\n".utf8))
    _ = await imageProducer.retainUntilExitAfterRefusal()
    _ = try? await imageProducer.detachAfterRefusal()
    _ = await imageProducer.retainUntilExitAfterRefusal()
    exit(1)
  }
  if mergeCommand {
    FileHandle.standardError.write(
      Data("universal development stage refused; private work retained\n".utf8))
    _ = await merger.retainUntilExitAfterRefusal()
    exit(1)
  }
  if stagingCommand {
    FileHandle.standardError.write(
      Data("pinned updater material unavailable, unsafe or changed\n".utf8))
    _ = await stager.retainUntilExitAfterRefusal()
    exit(1)
  }
  if preparationCommand {
    FileHandle.standardError.write(Data("development bundle preparation refused\n".utf8))
    _ = await preparer.retainUntilExitAfterRefusal()
    exit(1)
  }
  if captureCommand {
    FileHandle.standardError.write(
      Data("recorded updater compiler inputs unavailable, unsafe or changed\n".utf8))
    _ = await compilerChild.retainUntilExitAfterRefusal()
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
