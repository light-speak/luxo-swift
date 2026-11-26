import Darwin
import Foundation

private enum ProbeFailure: Error { case unexpectedResponse }

private final class ProbeBackend: HTTPBackend, @unchecked Sendable {
  private let lock = NSLock()
  private let expiredPeers: Int
  private let unauthorizedPeers: Int
  private let success: HTTPBackendResponse
  private let unauthorized: HTTPBackendResponse
  private var waiting: [CheckedContinuation<Bool, Never>] = []
  private var requests = 0
  private var refreshes = 0

  init(expiredPeers: Int, unauthorizedPeers: Int, mode: TransportMode) {
    self.expiredPeers = expiredPeers
    self.unauthorizedPeers = unauthorizedPeers
    if mode == .json {
      success = HTTPBackendResponse(status: 200, body: Data(#"{"data":42}"#.utf8))
      unauthorized = HTTPBackendResponse(
        status: 401, body: Data(#"{"error":"Unauthorized","code":401,"message":"expired"}"#.utf8))
    } else {
      var encoder = Encoder()
      encoder.writeVarint(1)
      encoder.writeSvarint(401)
      encoder.writeVarint(2)
      encoder.writeString("Unauthorized")
      encoder.writeVarint(3)
      encoder.writeString("expired")
      encoder.writeEnd()
      success = HTTPBackendResponse(status: 200, body: Data([84]))
      unauthorized = HTTPBackendResponse(status: 401, body: encoder.data)
    }
  }

  func send(body: Data, mode: TransportMode, headers: [String: String]) async throws
    -> HTTPBackendResponse
  {
    lock.withLock { requests += 1 }
    let authorization = headers["Authorization"]
    precondition(authorization == "Bearer old" || authorization == "Bearer renewed")
    guard expiredPeers > 0, authorization == "Bearer old" else { return success }
    let unauthorized = await withCheckedContinuation { continuation in
      let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
        waiting.append(continuation)
        guard waiting.count == expiredPeers else { return [] }
        let ready = waiting
        waiting = []
        return ready
      }
      for (index, continuation) in ready.enumerated() {
        continuation.resume(returning: index < unauthorizedPeers)
      }
    }
    return unauthorized ? self.unauthorized : success
  }

  func renew() async -> String? {
    lock.withLock { refreshes += 1 }
    await Task.yield()
    await Task.yield()
    return "renewed"
  }

  func takeCounts() -> (requests: Int, refreshes: Int) {
    lock.withLock {
      precondition(waiting.isEmpty)
      let counts = (requests, refreshes)
      requests = 0
      refreshes = 0
      return counts
    }
  }
}

@inline(never) private func phaseStart() -> UnsafeMutableRawPointer {
  let marker = malloc(23457)!
  memset(marker, 49, 23457)
  return marker
}

@inline(never) private func phaseEnd() -> UnsafeMutableRawPointer {
  let marker = malloc(34569)!
  memset(marker, 50, 34569)
  return marker
}

private func cpuMicros() -> Int64 {
  var usage = rusage()
  precondition(getrusage(RUSAGE_SELF, &usage) == 0)
  let seconds = Int64(usage.ru_utime.tv_sec) + Int64(usage.ru_stime.tv_sec)
  return seconds * 1_000_000 + Int64(usage.ru_utime.tv_usec) + Int64(usage.ru_stime.tv_usec)
}

@main
private struct Probe {
  static func main() async throws {
    precondition(CommandLine.arguments.count == 6)
    let scenario = CommandLine.arguments[1]
    let codec = CommandLine.arguments[2]
    let role = CommandLine.arguments[3]
    let iterations = Int(CommandLine.arguments[4])!
    let allocations = CommandLine.arguments[5] == "allocation"
    precondition(["normal-off", "normal", "single", "parallel-one", "expiry"].contains(scenario))
    precondition(["json", "binary"].contains(codec))
    precondition(["base", "next"].contains(role))
    let parallel = scenario == "parallel-one" || scenario == "expiry"
    let expiredPeers = parallel ? 3 : scenario == "single" ? 1 : 0
    let unauthorizedPeers = scenario == "parallel-one" ? 1 : expiredPeers
    let mode: TransportMode = codec == "json" ? .json : .binary
    let backend = ProbeBackend(
      expiredPeers: expiredPeers, unauthorizedPeers: unauthorizedPeers, mode: mode)
    let transport = HTTPTransport(backend: backend, token: "old")
    transport.setMode(mode)
    try transport.setSchema([
      "echo": APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])
    ])
    if scenario != "normal-off" { transport.onTokenExpired = { await backend.renew() } }

    let expected = mode == .json ? Data("42".utf8) : Data([84])
    let warmup = expiredPeers > 0 ? 80 : 1200
    _ = try await perform(
      transport, expiredPeers: expiredPeers, iterations: warmup, expected: expected)
    _ = backend.takeCounts()

    let first = allocations ? phaseStart() : nil
    let cpu = cpuMicros()
    let time = DispatchTime.now().uptimeNanoseconds
    let successes = try await perform(
      transport, expiredPeers: expiredPeers, iterations: iterations, expected: expected)
    let wall = DispatchTime.now().uptimeNanoseconds - time
    let elapsedCPU = cpuMicros() - cpu
    let final = allocations ? phaseEnd() : nil
    let counts = backend.takeCounts()
    let expectedSuccess = parallel ? iterations * 3 : iterations
    precondition(successes == expectedSuccess)
    let retries = scenario == "expiry" ? successes : iterations * unauthorizedPeers
    precondition(counts.requests == iterations * (parallel ? 3 : 1) + retries)
    precondition(counts.refreshes == (expiredPeers > 0 ? iterations : 0))
    let summary = [
      scenario, codec, role, String(iterations), String(successes), String(counts.requests),
      String(counts.refreshes), String(elapsedCPU), String(wall),
    ].joined(separator: ",")
    try FileHandle.standardOutput.write(contentsOf: Data((summary + "\n").utf8))
    if allocations {
      withExtendedLifetime((first, final)) { _ = readLine() }
      free(first)
      free(final)
    }
  }

  private static func perform(
    _ transport: HTTPTransport<ProbeBackend>, expiredPeers: Int, iterations: Int, expected: Data
  ) async throws -> Int {
    var successes = 0
    for _ in 0..<iterations {
      if expiredPeers > 0 { transport.setToken("old") }
      if expiredPeers == 3 {
        successes += try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
          for index in 1...3 {
            group.addTask { try await request(transport, index, expected: expected, expire: true) }
          }
          var successes = 0
          for try await result in group { successes += result }
          return successes
        }
      } else {
        successes += try await request(transport, 1, expected: expected, expire: expiredPeers > 0)
      }
    }
    return successes
  }

  private static func request(
    _ transport: HTTPTransport<ProbeBackend>, _ index: Int, expected: Data, expire: Bool
  ) async throws -> Int {
    do {
      let response = try await transport.call("echo", params: ["value": .int(Int64(index))])
      guard response.data == expected else { throw ProbeFailure.unexpectedResponse }
      return 1
    } catch let error as LuxoError where expire && error.code == 401 && error.message == "expired" {
      return 0
    }
  }
}
