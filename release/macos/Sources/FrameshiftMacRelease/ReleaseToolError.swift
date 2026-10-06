/// Fixed refusal categories for local Mac release tools.
///
/// Descriptions contain no input paths, subprocess output, keys or record contents.
/// Callers retain their private incomplete output on failure; these errors do not
/// authorize deleting a stage, repairing compiler inputs or retrying an effect.
public enum ReleaseToolError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidBounds
  case unsafeInput
  case inputLimit
  case inputChanged
  case deadline
  case readFailed
  case digestMismatch
  case invalidCommand
  case childLaunch
  case childAlreadyStarted
  case childDeadline
  case childCancelled
  case childOutputLimit
  case childOutputIncomplete
  case childFailed
  case childCustodyUnknown
  case invalidPropertyList
  case invalidMachO
  case invalidBundle

  public var description: String {
    switch self {
    case .invalidBounds: "invalid release input bounds"
    case .unsafeInput: "unsafe release input"
    case .inputLimit: "release input exceeds its size profile"
    case .inputChanged: "release input changed during admission"
    case .deadline: "release input admission deadline"
    case .readFailed: "release input unavailable"
    case .digestMismatch: "pinned release digest mismatch"
    case .invalidCommand: "invalid Mac release command"
    case .childLaunch: "Mac release child could not start"
    case .childAlreadyStarted: "Mac release child owner already used"
    case .childDeadline: "Mac release child deadline; retain incomplete output"
    case .childCancelled: "Mac release child cancelled; retain incomplete output"
    case .childOutputLimit: "Mac release child output limit; retain incomplete output"
    case .childOutputIncomplete: "Mac release child output incomplete; retain incomplete output"
    case .childFailed: "Mac release child failed; retain incomplete output"
    case .childCustodyUnknown: "Mac release child exit unconfirmed; retain incomplete output"
    case .invalidPropertyList: "invalid native release property list"
    case .invalidMachO: "invalid native release loader metadata"
    case .invalidBundle: "Mac bundle closure refused"
    }
  }
}
