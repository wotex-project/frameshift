/// Independently verifies the pinned upstream archive, without extracting or resolving it.
///
/// Success establishes only exact archive bytes and descriptor custody. Compiler
/// cache comparison, framework admission, derivation and signatures are separate
/// gates. This command performs no network or compiler-workspace operation.
public enum PinnedSparkleArchive {
  public static let version = "2.10.0"
  public static let bytes: Int64 = 10_193_895
  public static let sha256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"

  public static func verify(_ path: String) throws {
    let policy = try FileReadPolicy(
      minimum: bytes, maximum: bytes, protection: .protected, singleLink: true
    )
    guard try AdmittedFile.sha256(path, policy: policy).sha256 == sha256
    else { throw ReleaseToolError.digestMismatch }
  }
}
