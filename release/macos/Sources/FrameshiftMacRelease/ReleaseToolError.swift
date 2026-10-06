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

  public var description: String {
    switch self {
    case .invalidBounds: "invalid release input bounds"
    case .unsafeInput: "unsafe release input"
    case .inputLimit: "release input exceeds its size profile"
    case .inputChanged: "release input changed during admission"
    case .deadline: "release input admission deadline"
    case .readFailed: "release input unavailable"
    case .digestMismatch: "pinned release digest mismatch"
    }
  }
}
