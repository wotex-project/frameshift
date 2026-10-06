import Darwin
import Foundation
import FrameshiftMacRelease

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "verify-sparkle-archive" else {
  FileHandle.standardError.write(
    Data("usage: frameshift-mac-release verify-sparkle-archive ARCHIVE\n".utf8))
  exit(64)
}
do {
  try PinnedSparkleArchive.verify(arguments[1])
  FileHandle.standardOutput.write(
    Data("Sparkle \(PinnedSparkleArchive.version) archive verified\n".utf8))
} catch {
  let message = (error as? ReleaseToolError)?.description ?? "Mac release admission refused"
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(65)
}
