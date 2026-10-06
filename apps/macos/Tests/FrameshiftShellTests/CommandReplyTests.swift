import Darwin
import Foundation
import Testing

@testable import FrameshiftShell

@Suite("Admitted command transport outcomes")
struct CommandReplyTests {
  @Test("Damaged or uncorrelated replies cannot establish a mutation refusal")
  func uncertainReplies() throws {
    let damaged = [
      "{", "{}", "{\"version\":2,\"requestId\":\"request\",\"ok\":true}",
      "{\"version\":1,\"requestId\":\"other\",\"ok\":false,\"error\":{\"code\":\"invalid_command\"}}",
      "{\"version\":1,\"requestId\":\"request\",\"ok\":true}",
      "{\"version\":1,\"requestId\":\"request\",\"ok\":false,\"error\":{\"code\":\"future_error\"}}",
    ]
    for wire in damaged {
      let bytes = Data(wire.utf8)
      #expect(throws: CoreClientError.commandOutcomeUnknown) {
        try LocalCoreClient.decodeSnapshot(bytes, requestID: "request", mutation: true)
      }
      #expect(throws: CoreClientError.protocolFailure) {
        try LocalCoreClient.decodeSnapshot(bytes, requestID: "request", mutation: false)
      }
    }
  }

  @Test("Correlated known refusal and authoritative completion retain their meanings")
  func terminalReplies() throws {
    let refused = Data(
      "{\"version\":1,\"requestId\":\"request\",\"ok\":false,\"error\":{\"code\":\"metadata_revision_conflict\"}}"
        .utf8)
    #expect(throws: CoreClientError.metadataRevisionConflict) {
      try LocalCoreClient.decodeSnapshot(refused, requestID: "request", mutation: true)
    }
    let snapshot = CoreSnapshot(targets: [], selectedTargetID: nil, statusMessage: "Completed")
    let fields: [String: Any] = [
      "version": 1, "requestId": "request", "ok": true,
      "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)),
    ]
    let bytes = try JSONSerialization.data(withJSONObject: fields)
    #expect(
      try LocalCoreClient.decodeSnapshot(bytes, requestID: "request", mutation: true)
        .statusMessage == "Completed")
  }

  @Test("A real socket receives the request once before lost or invalid framing becomes unknown")
  func interruptedTransport() async throws {
    // EOF, zero length, excessive length and a truncated body after complete request receipt.
    let replies: [Data] = [
      Data(), Data([0, 0, 0, 0]), Data([0, 16, 0, 1]), Data([0, 0, 0, 3, 123]),
    ]
    let payload = Data("{\"requestId\":\"request\",\"operation\":\"command\"}".utf8)
    for reply in replies {
      let server = try ReplyServer()
      defer { server.close() }
      let served = Task.detached { try server.serve(reply: reply) }
      await #expect(throws: CoreClientError.commandOutcomeUnknown) {
        try await Task.detached {
          try UnixSocket.exchange(
            path: server.path, payload: payload, maximumResponseBytes: 1_048_576,
            mutation: true)
        }.value
      }
      #expect(try await served.value == payload)
      #expect(!server.hasAnotherConnection())
    }
  }
}

/// One bounded local fixture connection; no real core, credentials or global core owner.
private final class ReplyServer: @unchecked Sendable {
  let path = "/tmp/fcr-\(UUID().uuidString).sock"
  private let listener: Int32

  init() throws {
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw CoreClientError.coreUnavailable }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: Array(path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(listener, 2) == 0,
      fcntl(listener, F_SETFL, O_NONBLOCK) == 0
    else {
      Darwin.close(listener)
      Darwin.unlink(path)
      throw CoreClientError.coreUnavailable
    }
  }

  func close() {
    Darwin.close(listener)
    Darwin.unlink(path)
  }

  func serve(reply: Data) throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var peer: Int32 = -1
    repeat {
      peer = Darwin.accept(listener, nil, nil)
      if peer < 0 { usleep(5_000) }
    } while peer < 0 && ContinuousClock.now < deadline
    guard peer >= 0 else { throw CoreClientError.coreUnavailable }
    defer { Darwin.close(peer) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var noSignal: Int32 = 1
    guard
      setsockopt(
        peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        == 0,
      setsockopt(
        peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        == 0
    else { throw CoreClientError.coreUnavailable }
    let prefix = try read(peer, count: 4)
    let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
    guard (1...65_536).contains(size) else { throw CoreClientError.protocolFailure }
    let request = try read(peer, count: size)
    try reply.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          peer, bytes.baseAddress!.advanced(by: written), bytes.count - written)
        guard count > 0 else { throw CoreClientError.coreUnavailable }
        written += count
      }
    }
    return request
  }

  func hasAnotherConnection() -> Bool {
    let peer = Darwin.accept(listener, nil, nil)
    guard peer >= 0 else { return false }
    Darwin.close(peer)
    return true
  }

  private func read(_ peer: Int32, count: Int) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { bytes in
      var received = 0
      while received < count {
        let size = Darwin.read(peer, bytes.baseAddress!.advanced(by: received), count - received)
        guard size > 0 else { throw CoreClientError.coreUnavailable }
        received += size
      }
    }
    return result
  }
}
