import CryptoKit
import Darwin
import Foundation
import OSLog

public actor LocalCoreClient: CoreClient {
  private static let maximumRequestBytes = 64 * 1024
  private static let maximumResponseBytes = 1024 * 1024
  private let socketPath: String
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  public init(socketPath: String = LocalCoreClient.defaultSocketPath()) {
    self.socketPath = socketPath
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  public func snapshot() async throws -> CoreSnapshot {
    try await exchange(operation: "snapshot")
  }

  public func snapshot(query: String) async throws -> CoreSnapshot {
    guard query.utf8.count <= 256 else { throw CoreClientError.invalidCommand }
    return try await exchange(operation: "snapshot", query: query)
  }

  public func snapshot(query: String, filters: LibraryFilters) async throws -> CoreSnapshot {
    guard query.utf8.count <= 256 else { throw CoreClientError.invalidCommand }
    try filters.validate()
    return try await exchange(operation: "snapshot", query: query, filters: filters)
  }

  public func send(_ command: CoreCommand) async throws -> CoreSnapshot {
    let prepared = try prepare(command)
    defer { prepared.decodedImport?.removeWorkDirectory() }
    return try await exchange(operation: "command", command: prepared.command)
  }

  public func metadata(itemID: String) async throws -> LibraryMetadata {
    guard validLibraryDigest(itemID) else { throw CoreClientError.invalidCommand }
    let response = try await libraryRead(operation: "libraryMetadata", itemID: itemID)
    guard let metadata = response.metadata else { throw CoreClientError.protocolFailure }
    try metadata.validate(itemID: itemID)
    return metadata
  }

  public func recovery(afterID: String?) async throws -> LibraryRecoveryPage {
    guard afterID == nil || validLibraryDigest(afterID!) else {
      throw CoreClientError.invalidCommand
    }
    let response = try await libraryRead(operation: "libraryRecovery", afterID: afterID)
    guard let page = response.recovery else { throw CoreClientError.protocolFailure }
    try page.validate(afterID: afterID)
    return page
  }

  public func storage() async throws -> LibraryStorage {
    let response = try await libraryRead(operation: "libraryStorage")
    guard let storage = response.storage else { throw CoreClientError.protocolFailure }
    try storage.validate()
    return storage
  }

  public func analysis(itemID: String) async throws -> LibraryAnalysis {
    guard validLibraryDigest(itemID) else { throw CoreClientError.invalidCommand }
    let response = try await libraryRead(operation: "libraryAnalysis", itemID: itemID)
    guard let analysis = response.analysis else { throw CoreClientError.protocolFailure }
    try analysis.validate(itemID: itemID)
    return analysis
  }

  public func analysisPending() async throws -> PendingLibraryAnalysis {
    let response = try await libraryRead(
      operation: "libraryAnalysisPending", cohort: AppleArtworkAnalyzer.cohort)
    guard let pending = response.analysisPending else { throw CoreClientError.protocolFailure }
    try pending.validate()
    return pending
  }

  public func similarityCandidates(
    source: LibraryAnalysis, afterID: String?, filters: LibraryFilters
  ) async throws -> SimilarityCandidatesPage {
    try source.validate(itemID: source.itemID)
    try filters.validate()
    guard afterID == nil || validLibraryDigest(afterID!) else {
      throw CoreClientError.invalidCommand
    }
    let response = try await libraryRead(
      operation: "librarySimilarityCandidates", itemID: source.itemID,
      afterID: afterID, cohort: source.cohort, featureDigest: source.featurePrint.digest,
      filters: filters)
    guard let page = response.similarityCandidates else { throw CoreClientError.protocolFailure }
    try page.validate(source: source, afterID: afterID)
    return page
  }

  public func analyzeArtwork(itemID: String, force: Bool) async throws -> CoreSnapshot {
    guard validLibraryDigest(itemID) else { throw CoreClientError.invalidCommand }
    if !force {
      do {
        if try await analysis(itemID: itemID).cohort == AppleArtworkAnalyzer.cohort {
          return try await snapshot()
        }
      } catch CoreClientError.analysisUnavailable {
        // Missing derived metadata permits one fresh local observation, without provider fallback.
      }
    }
    let metadata = try await metadata(itemID: itemID)
    guard metadata.removedAtMs == nil else { throw CoreClientError.itemNotFound }
    let preview = try await preview(masterID: itemID, target: nil)
    let observed = try await AppleArtworkAnalyzer.shared.analyze(preview)
    guard !Task.isCancelled else { throw ArtworkAnalysisError.cancelled }
    return try await send(
      CoreCommand(
        kind: .recordVision, itemID: itemID, metadataRevision: metadata.revision,
        cohort: observed.cohort, inputDigest: observed.inputDigest,
        rendererBuildDigest: observed.rendererBuildDigest, visionLabels: observed.labels,
        featureArchiveChunks: featureArchiveChunks(observed.featurePrint.archive),
        featureDigest: observed.featurePrint.digest))
  }

  private func libraryRead(
    operation: String, itemID: String? = nil, afterID: String? = nil,
    cohort: String? = nil, featureDigest: String? = nil, filters: LibraryFilters? = nil
  )
    async throws -> WireResponse
  {
    try await BundledCore.shared.ensureRunning(socketPath: socketPath)
    let auth = try await BundledCore.shared.sessionToken(socketPath: socketPath)
    let request = LibraryWireRequest(
      operation: operation, auth: auth, itemID: itemID, afterID: afterID, cohort: cohort,
      featureDigest: featureDigest, filters: filters)
    let responseData = try await send(encoder.encode(request))
    guard let response = try? decoder.decode(WireResponse.self, from: responseData),
      response.version == 1, response.requestID == request.requestID
    else { throw CoreClientError.protocolFailure }
    guard response.ok else { throw Self.clientError(for: response.error?.code) }
    return response
  }

  public func preview(masterID: String, target: FrameTarget?) async throws -> ArtworkPreview {
    try await BundledCore.shared.ensureRunning(socketPath: socketPath)
    let auth = try await BundledCore.shared.sessionToken(socketPath: socketPath)
    let request = PreviewWireRequest(
      auth: auth, itemID: masterID, targetID: target?.id, profileID: target?.profileID,
      capabilityDigest: target?.capabilityDigest)
    let payload = try encoder.encode(request)
    guard payload.count <= Self.maximumRequestBytes else { throw CoreClientError.invalidCommand }
    let responseData = try await send(payload)
    guard let response = try? decoder.decode(WireResponse.self, from: responseData),
      response.version == 1, response.requestID == request.requestID
    else { throw CoreClientError.protocolFailure }
    guard response.ok, let preview = response.preview else {
      if ["timeout", "unsupported_profile", "preview_unavailable"].contains(
        response.error?.code ?? "")
      {
        throw CoreClientError.previewUnavailable
      }
      throw Self.clientError(for: response.error?.code)
    }
    try preview.validate(masterID: masterID, target: target)
    return preview
  }

  public func outboxStatus() async throws -> OutboxServiceStatus {
    try await BundledCore.shared.ensureRunning(socketPath: socketPath)
    let auth = try await BundledCore.shared.sessionToken(socketPath: socketPath)
    let request = WireRequest(auth: auth, operation: "outboxStatus", command: nil, query: nil)
    let payload = try encoder.encode(request)
    let responseData = try await send(payload)
    guard let response = try? decoder.decode(WireResponse.self, from: responseData),
      response.version == 1, response.requestID == request.requestID,
      response.ok, let status = response.outbox,
      (!status.available && status.port == nil)
        || (status.available && status.port.map({ (1...65_535).contains($0) }) == true)
    else { throw CoreClientError.protocolFailure }
    return status
  }

  /// Sends a physical bootstrap only through the transient IPC operation.
  /// A lost response is not retried because the one-time secret may have been consumed.
  public func pair(
    bootstrap: String, discoveredID: String, origin: String, credentialReference: String
  ) async throws -> PairedFrameResult {
    try await pairingOperation(
      "pair", bootstrap: bootstrap, discoveredID: discoveredID, origin: origin,
      credentialReference: credentialReference)
  }

  /// Reads the authenticated introduction after an uncertain pair; no pair POST is replayed.
  public func recoverPair(
    bootstrap: String, discoveredID: String, origin: String, credentialReference: String
  ) async throws -> PairedFrameResult {
    try await pairingOperation(
      "recoverPair", bootstrap: bootstrap, discoveredID: discoveredID, origin: origin,
      credentialReference: credentialReference)
  }

  private func pairingOperation(
    _ operation: String, bootstrap: String, discoveredID: String, origin: String,
    credentialReference: String
  ) async throws -> PairedFrameResult {
    guard bootstrap.utf8.count <= 2_048,
      discoveredID.utf8.count <= 128,
      origin.utf8.count <= 1_024,
      credentialReference.utf8.count <= 1_024
    else { throw CoreClientError.pairingPreflightFailed }

    try await BundledCore.shared.ensureRunning(socketPath: socketPath)
    let auth = try await BundledCore.shared.sessionToken(socketPath: socketPath)
    let request = PairingWireRequest(
      operation: operation, auth: auth, bootstrap: bootstrap, discoveredID: discoveredID,
      origin: origin, credentialReference: credentialReference
    )
    let payload = try encoder.encode(request)
    guard payload.count <= Self.maximumRequestBytes else {
      throw CoreClientError.pairingPreflightFailed
    }

    let responseData: Data
    do {
      responseData = try await send(payload)
    } catch {
      throw CoreClientError.pairingOutcomeUnknown
    }

    guard let response = try? decoder.decode(WireResponse.self, from: responseData),
      response.version == 1, response.requestID == request.requestID
    else { throw CoreClientError.pairingOutcomeUnknown }

    if response.ok, let frame = response.frame { return frame }
    switch response.error?.code {
    case "pairing_preflight_failed": throw CoreClientError.pairingPreflightFailed
    case "pairing_rejected": throw CoreClientError.pairingRejected
    case "pairing_incomplete": throw CoreClientError.pairingIncomplete
    default: throw CoreClientError.pairingOutcomeUnknown
    }
  }

  public static func defaultSocketPath() -> String {
    if let configured = ProcessInfo.processInfo.environment["FRAMESHIFT_SOCKET_PATH"],
      !configured.isEmpty
    {
      return URL(fileURLWithPath: configured).standardizedFileURL.path
    }

    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]

    return
      applicationSupport
      .appendingPathComponent("Frameshift", isDirectory: true)
      .appendingPathComponent("core.sock", isDirectory: false)
      .path
  }

  public static func shutdownBundledCore() async {
    await BundledCore.shared.shutdown()
  }

  private func prepare(_ command: CoreCommand) throws -> PreparedCommand {
    guard command.kind == .importFile else {
      return PreparedCommand(command: command, decodedImport: nil)
    }
    guard let path = command.importPath else { throw CoreClientError.invalidCommand }
    let decoded = try AppleImageDecoder.decode(URL(fileURLWithPath: path))
    return PreparedCommand(command: command.withDecodedImport(decoded), decodedImport: decoded)
  }

  private func exchange(
    operation: String, command: CoreCommand? = nil, query: String? = nil,
    filters: LibraryFilters? = nil
  ) async throws -> CoreSnapshot {
    try await BundledCore.shared.ensureRunning(socketPath: socketPath)

    do {
      return try await exchangeOnce(
        operation: operation, command: command, query: query, filters: filters)
    } catch CoreClientError.coreUnavailable {
      try await BundledCore.shared.ensureRunning(socketPath: socketPath, force: true)
      return try await exchangeOnce(
        operation: operation, command: command, query: query, filters: filters)
    }
  }

  private func exchangeOnce(
    operation: String, command: CoreCommand?, query: String?, filters: LibraryFilters?
  ) async throws -> CoreSnapshot {
    let auth = try await BundledCore.shared.sessionToken(socketPath: socketPath)
    let request = WireRequest(
      auth: auth, operation: operation, command: command, query: query, filters: filters)
    let payload = try encoder.encode(request)
    guard payload.count <= Self.maximumRequestBytes else {
      throw CoreClientError.invalidCommand
    }

    let responseData = try await send(payload)

    let response: WireResponse
    do {
      response = try decoder.decode(WireResponse.self, from: responseData)
    } catch {
      throw CoreClientError.protocolFailure
    }

    guard response.version == 1, response.requestID == request.requestID else {
      throw CoreClientError.protocolFailure
    }

    if response.ok, let snapshot = response.snapshot {
      return snapshot
    }

    throw Self.clientError(for: response.error?.code)
  }

  private func send(_ payload: Data) async throws -> Data {
    let path = socketPath
    return try await Task.detached(priority: .userInitiated) {
      try UnixSocket.exchange(
        path: path,
        payload: payload,
        maximumResponseBytes: Self.maximumResponseBytes
      )
    }.value
  }

  private static func clientError(for code: String?) -> CoreClientError {
    switch code {
    case "analysis_unavailable": .analysisUnavailable
    case "analysis_changed": .analysisChanged
    case "invalid_analysis": .invalidAnalysis
    case "library_storage_full": .libraryStorageFull
    case "storage_revision_conflict": .storageRevisionConflict
    case "storage_configuration_invalid", "storage_unavailable", "invalid_storage_setting":
      .storageUnavailable
    case "command_id_conflict": .commandIDConflict
    case "command_outcome_unknown": .commandOutcomeUnknown
    case "credential_broker_unavailable": .credentialBrokerUnavailable
    case "delivery_outcome_unknown": .deliveryOutcomeUnknown
    case "direct_delivery_pending": .deliveryPending
    case "import_too_large": .importTooLarge
    case "already_active": .loopAlreadyActive
    case "playlist_pending": .loopPending
    case "playlist_revision_conflict": .loopRevisionConflict
    case "playlist_profile_changed": .loopProfileChanged
    case "duplicate_artifact": .duplicateLoopArtwork
    case "busy": .previewBusy
    case "preview_profile_changed": .previewProfileChanged
    case "preview_unavailable": .previewUnavailable
    case "no_pinned_artwork": .noPinnedArtwork
    case "interval_required", "invalid_interval": .intervalRequired
    case "pull_not_supported", "frame_not_paired", "compatible_binding_unavailable":
      .loopUnavailable
    case "playlist_too_long", "storage_full": .loopStorageFull
    case "import_unreadable", "import_not_regular", "import_changed",
      "invalid_canonical_image", "canonical_digest_mismatch":
      .importUnreadable
    case "unsupported_media_type", "media_type_mismatch": .unsupportedMedia
    case "item_not_found": .itemNotFound
    case "metadata_unavailable": .metadataUnavailable
    case "metadata_revision_conflict": .metadataRevisionConflict
    case "invalid_metadata": .invalidMetadata
    case "restore_failed": .restoreFailed
    case "target_not_found": .targetNotFound
    case "invalid_command", "invalid_dimensions", "invalid_orientation", "invalid_color_profile":
      .invalidCommand
    default: .protocolFailure
    }
  }
}

private struct PreparedCommand {
  let command: CoreCommand
  let decodedImport: DecodedImport?
}

private actor BundledCore {
  static let shared = BundledCore()
  private static let logger = Logger(subsystem: "io.frameshift.app", category: "shell")

  private var process: Process?
  private var token: String?
  private var credentialBroker: KeychainCredentialBroker?
  private var logBridge: CoreLogBridge?

  func ensureRunning(socketPath: String, force: Bool = false) async throws {
    if !force, UnixSocket.isAccepting(path: socketPath) {
      if process?.isRunning == true { return }
      if process == nil, try loadExternalTokenIfAvailable() { return }
    }

    if process?.isRunning != true {
      logBridge?.stop()
      logBridge = nil
      credentialBroker?.stop()
      credentialBroker = nil
      let launched = try launch(socketPath: socketPath)
      process = launched.process
      token = launched.token
      credentialBroker = launched.broker
      logBridge = launched.bridge
    }

    for _ in 0..<100 {
      if UnixSocket.isAccepting(path: socketPath) { return }
      if process?.isRunning == false { throw CoreClientError.coreUnavailable }
      try await Task.sleep(for: .milliseconds(50))
    }

    throw CoreClientError.coreUnavailable
  }

  func sessionToken(socketPath: String) async throws -> String {
    try await ensureRunning(socketPath: socketPath)
    guard let token else { throw CoreClientError.coreUnavailable }
    return token
  }

  func shutdown() {
    if let process, process.isRunning {
      process.terminate()
    }
    self.process = nil
    token = nil
    credentialBroker?.stop()
    credentialBroker = nil
    logBridge?.stop()
    logBridge = nil
    Self.logger.info("bundled core stopped")
  }

  private func launch(socketPath: String) throws -> (
    process: Process, token: String, broker: KeychainCredentialBroker, bridge: CoreLogBridge
  ) {
    guard let resources = Bundle.main.resourceURL else {
      throw CoreClientError.coreUnavailable
    }

    let coreExecutable = resources.appendingPathComponent(
      "core/bin/frameshift_core",
      isDirectory: false
    )
    let renderer = resources.appendingPathComponent(
      "bin/frameshift-raster",
      isDirectory: false
    )
    let launcher = resources.appendingPathComponent(
      "bin/launch-bundled-core",
      isDirectory: false
    )
    guard FileManager.default.isExecutableFile(atPath: coreExecutable.path),
      FileManager.default.isExecutableFile(atPath: renderer.path),
      FileManager.default.isExecutableFile(atPath: launcher.path)
    else {
      throw CoreClientError.coreUnavailable
    }

    let socketURL = URL(fileURLWithPath: socketPath)
    let dataDirectory = socketURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: dataDirectory,
        withIntermediateDirectories: true
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: dataDirectory.path
      )
    } catch {
      throw CoreClientError.coreUnavailable
    }

    let configuredToken = ProcessInfo.processInfo.environment["FRAMESHIFT_IPC_TOKEN"]
    let token = configuredToken.flatMap { Self.validToken($0) ? $0 : nil } ?? Self.makeToken()
    let socketNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let credentialSocket = dataDirectory.appendingPathComponent("c-\(socketNonce).sock")
    let broker = try KeychainCredentialBroker.start(
      socketPath: credentialSocket.path,
      token: token
    )
    let tokenURL = dataDirectory.appendingPathComponent(
      "ipc-bootstrap-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    do {
      try Data(token.utf8).write(to: tokenURL, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: tokenURL.path
      )
    } catch {
      try? FileManager.default.removeItem(at: tokenURL)
      broker.stop()
      throw CoreClientError.coreUnavailable
    }

    var environment = ProcessInfo.processInfo.environment
    environment["FRAMESHIFT_DATA_DIR"] =
      environment["FRAMESHIFT_DATA_DIR"] ?? dataDirectory.path
    environment["FRAMESHIFT_SOCKET_PATH"] = socketPath
    environment["FRAMESHIFT_RENDERER_PATH"] = renderer.path
    environment["ERL_CRASH_DUMP"] = dataDirectory.appendingPathComponent("erl_crash.dump").path
    environment["ERL_CRASH_DUMP_SECONDS"] = "0"
    environment["FRAMESHIFT_CORE_PID_FILE"] =
      dataDirectory.appendingPathComponent("core.pid").path
    environment["FRAMESHIFT_IPC_TOKEN_FILE"] = tokenURL.path
    environment["FRAMESHIFT_CREDENTIAL_SOCKET"] = credentialSocket.path
    environment["RELEASE_DISTRIBUTION"] = "none"

    let child = Process()
    child.executableURL = launcher
    child.arguments = [String(getpid()), coreExecutable.path]
    child.environment = environment
    let output = Pipe()
    let error = Pipe()
    child.standardOutput = output
    child.standardError = error
    let bridge = CoreLogBridge(output: output, error: error)

    do {
      try child.run()
      Self.logger.info("bundled core launched")
      return (child, token, broker, bridge)
    } catch {
      bridge.stop()
      try? FileManager.default.removeItem(at: tokenURL)
      broker.stop()
      throw CoreClientError.coreUnavailable
    }
  }

  private func loadExternalTokenIfAvailable() throws -> Bool {
    guard let configured = ProcessInfo.processInfo.environment["FRAMESHIFT_IPC_TOKEN"] else {
      return false
    }
    guard Self.validToken(configured) else { throw CoreClientError.coreUnavailable }
    token = configured
    return true
  }

  private static func makeToken() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
      bytes.map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func validToken(_ candidate: String) -> Bool {
    candidate.utf8.count == 64
      && candidate.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

private struct WireRequest: Encodable, Sendable {
  let version: Int
  let requestID: String
  let auth: String
  let operation: String
  let command: CoreCommand?
  let query: String?
  let filters: LibraryFilters?

  private enum CodingKeys: String, CodingKey {
    case version
    case requestID = "requestId"
    case auth
    case operation
    case command
    case query
    case filters
  }

  init(
    auth: String, operation: String, command: CoreCommand? = nil, query: String? = nil,
    filters: LibraryFilters? = nil
  ) {
    version = 1
    requestID = UUID().uuidString.lowercased()
    self.auth = auth
    self.operation = operation
    self.command = command
    self.query = query
    self.filters = filters
  }
}

private struct PreviewWireRequest: Encodable, Sendable {
  let version = 1
  let requestID = UUID().uuidString.lowercased()
  let operation = "preview"
  let auth: String
  let itemID: String
  let targetID: String?
  let profileID: String?
  let capabilityDigest: String?

  private enum CodingKeys: String, CodingKey {
    case version, operation, auth, itemID, targetID, profileID, capabilityDigest
    case requestID = "requestId"
  }
}

private struct LibraryWireRequest: Encodable, Sendable {
  let version = 1
  let requestID = UUID().uuidString.lowercased()
  let operation: String
  let auth: String
  let itemID: String?
  let afterID: String?
  let cohort: String?
  let featureDigest: String?
  let filters: LibraryFilters?

  private enum CodingKeys: String, CodingKey {
    case version, operation, auth, itemID, afterID, cohort, featureDigest, filters
    case requestID = "requestId"
  }
}

private struct PairingWireRequest: Encodable, Sendable {
  let version = 1
  let requestID = UUID().uuidString.lowercased()
  let operation: String
  let auth: String
  let bootstrap: String
  let discoveredID: String
  let origin: String
  let credentialReference: String

  private enum CodingKeys: String, CodingKey {
    case version
    case requestID = "requestId"
    case operation
    case auth
    case bootstrap
    case discoveredID = "discoveredId"
    case origin
    case credentialReference = "credentialRef"
  }
}

private struct WireResponse: Decodable, Sendable {
  let version: Int
  let requestID: String?
  let ok: Bool
  let snapshot: CoreSnapshot?
  let frame: PairedFrameResult?
  let outbox: OutboxServiceStatus?
  let preview: ArtworkPreview?
  let metadata: LibraryMetadata?
  let recovery: LibraryRecoveryPage?
  let storage: LibraryStorage?
  let analysis: LibraryAnalysis?
  let analysisPending: PendingLibraryAnalysis?
  let similarityCandidates: SimilarityCandidatesPage?
  let error: WireError?

  private enum CodingKeys: String, CodingKey {
    case version
    case requestID = "requestId"
    case ok
    case snapshot
    case frame
    case outbox
    case preview
    case metadata
    case recovery
    case storage
    case analysis
    case analysisPending
    case similarityCandidates
    case error
  }
}

public struct OutboxServiceStatus: Decodable, Sendable {
  public let available: Bool
  public let port: Int?
}

private struct WireError: Decodable, Sendable {
  let code: String
}

enum UnixSocket {
  // Rendering and a bounded direct frame exchange may outlast the handshake timeout.
  private static let timeoutSeconds = 30

  static func isAccepting(path: String) -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return (try? connect(descriptor, path: path)) != nil
  }

  static func exchange(path: String, payload: Data, maximumResponseBytes: Int) throws -> Data {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreClientError.coreUnavailable }
    defer { Darwin.close(descriptor) }

    try configure(descriptor)
    try connect(descriptor, path: path)

    var size = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &size, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    try writeAll(descriptor, data: frame)

    let prefix = try readExactly(descriptor, count: 4)
    let responseLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
    guard responseLength > 0, responseLength <= maximumResponseBytes else {
      throw CoreClientError.protocolFailure
    }

    return try readExactly(descriptor, count: responseLength)
  }

  private static func configure(_ descriptor: Int32) throws {
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
      throw CoreClientError.coreUnavailable
    }

    var noSignal: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal))
      ) == 0
    else {
      throw CoreClientError.coreUnavailable
    }

    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
    else {
      throw CoreClientError.coreUnavailable
    }
  }

  private static func connect(_ descriptor: Int32, path: String) throws {
    let pathBytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw CoreClientError.coreUnavailable
    }

    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
    }

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.connect(
          descriptor,
          socketAddress,
          socklen_t(MemoryLayout<sockaddr_un>.size)
        )
      }
    }

    guard result == 0 else { throw CoreClientError.coreUnavailable }
  }

  private static func writeAll(_ descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { throw CoreClientError.protocolFailure }
      var written = 0

      while written < data.count {
        let count = Darwin.write(
          descriptor, baseAddress.advanced(by: written), data.count - written)
        if count > 0 {
          written += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          throw CoreClientError.coreUnavailable
        }
      }
    }
  }

  private static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var received = 0

    try data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { throw CoreClientError.protocolFailure }

      while received < count {
        let result = Darwin.read(descriptor, baseAddress.advanced(by: received), count - received)
        if result > 0 {
          received += result
        } else if result < 0, errno == EINTR {
          continue
        } else {
          throw CoreClientError.coreUnavailable
        }
      }
    }

    return data
  }
}
