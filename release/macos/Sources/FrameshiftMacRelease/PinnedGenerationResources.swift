import Darwin
import Foundation

/// Admits the two exact private JSON descriptors of the pinned generation SDK.
///
/// The root must be a current nonroot user's real 0700 directory, with only
/// single-link 0600 configs/models files. A bounded no-follow directory stream
/// brackets protected leaf hashes and repeated name/file/directory custody.
/// Success returns the unchanged schema-one native facts as JSON without LF;
/// no private path or caller metadata appears in the observation.
///
/// This performs no JSON normalization, SDK initialization, model IO, network,
/// copy or repair. Matching bytes do not qualify weight identity, source trust,
/// rights, generation or native worker lifecycle. The sixty-second software
/// budget cannot preempt a filesystem call already blocked in the kernel.
public enum PinnedGenerationResources {
  private static let facts: [(name: String, bytes: Int64, sha256: String)] = [
    ("configs.json", 47_709, "37180f6a7b21bf718e30e1f72efcc1241691daa5d3dc4ef32fc5d9fe7ec50f86"),
    ("models.json", 125_897, "b50e05acf0410422bb1513b61dc81542e94bea5e5d7c3ed9a94ca47ca89c0134"),
  ]

  public static func verify(_ input: String) throws -> Data {
    try verify(input, observe: nil)
  }

  static func verify(
    _ input: String, observe: ((GenerationResourcePhase) throws -> Void)?
  ) throws -> Data {
    guard getuid() != 0, !input.isEmpty, !input.utf8.contains(0) else {
      throw ReleaseToolError.unsafeInput
    }
    let root = URL(fileURLWithPath: input).standardizedFileURL.path
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    func budget() throws {
      guard ContinuousClock.now < deadline else { throw ReleaseToolError.deadline }
    }
    func named(_ path: String) throws -> FileIdentity {
      var state = stat()
      guard lstat(path, &state) == 0 else { throw ReleaseToolError.readFailed }
      return FileIdentity(state)
    }
    let before = try named(root)
    guard before.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), before.user == getuid(),
      before.mode & 0o7777 == 0o700
    else { throw ReleaseToolError.unsafeInput }
    let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReleaseToolError.readFailed }
    var owned = true
    defer { if owned { Darwin.close(descriptor) } }
    var state = stat()
    guard fstat(descriptor, &state) == 0, FileIdentity(state) == before else {
      throw ReleaseToolError.inputChanged
    }
    guard let directory = fdopendir(descriptor) else { throw ReleaseToolError.readFailed }
    owned = false
    defer { closedir(directory) }
    func names() throws -> [String] {
      var names: [String] = []
      while true {
        try budget()
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw ReleaseToolError.readFailed }
          return names.sorted()
        }
        let length = Int(entry.pointee.d_namlen)
        guard length > 0, length < 1024 else { throw ReleaseToolError.unsafeInput }
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
          String(bytes: $0.prefix(length), encoding: .utf8)
        }
        guard let name else { throw ReleaseToolError.unsafeInput }
        if name == "." || name == ".." { continue }
        guard names.count < 2, facts.contains(where: { $0.name == name }), !names.contains(name)
        else { throw ReleaseToolError.unsafeInput }
        names.append(name)
      }
    }
    guard try names() == facts.map(\.name) else { throw ReleaseToolError.unsafeInput }
    let files = try facts.map { fact in
      let file = try named(root + "/" + fact.name)
      guard file.isRegular, file.user == getuid(), file.links == 1,
        file.mode & 0o7777 == 0o600, file.size == fact.bytes
      else { throw ReleaseToolError.unsafeInput }
      return file
    }
    try observe?(.admitted)
    for (index, fact) in facts.enumerated() {
      try budget()
      let remaining = ContinuousClock.now.duration(to: deadline).components
      let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
      let policy = try FileReadPolicy(
        maximum: 256 * 1024, protection: .privateFile, singleLink: true, seconds: seconds)
      let digest = try AdmittedFile.sha256(root + "/" + fact.name, policy: policy)
      guard digest.bytes == fact.bytes, digest.sha256 == fact.sha256 else {
        throw ReleaseToolError.digestMismatch
      }
      guard try named(root + "/" + fact.name) == files[index] else {
        throw ReleaseToolError.inputChanged
      }
      try observe?(.read(index))
    }
    for (index, fact) in facts.enumerated() {
      guard try named(root + "/" + fact.name) == files[index] else {
        throw ReleaseToolError.inputChanged
      }
    }
    rewinddir(directory)
    guard try names() == facts.map(\.name), fstat(descriptor, &state) == 0,
      FileIdentity(state) == before, try named(root) == before
    else { throw ReleaseToolError.inputChanged }
    try budget()
    return Data(
      "{\"schemaVersion\":1,\"kind\":\"pinned-generation-sdk-resource-custody\",\"wrapperRevision\":\"8868a9685d9c299816f43ef53efd455ffca437f0\",\"implementationRevision\":\"d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66\",\"publicationAuthority\":\"none\",\"resources\":[{\"path\":\"configs.json\",\"bytes\":47709,\"sha256\":\"37180f6a7b21bf718e30e1f72efcc1241691daa5d3dc4ef32fc5d9fe7ec50f86\"},{\"path\":\"models.json\",\"bytes\":125897,\"sha256\":\"b50e05acf0410422bb1513b61dc81542e94bea5e5d7c3ed9a94ca47ca89c0134\"}]}"
        .utf8)
  }
}

enum GenerationResourcePhase: Equatable {
  case admitted
  case read(Int)
}
