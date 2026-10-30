import NIOHTTP1
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import LuxoNIO

@MainActor
final class IntegrationTests: XCTestCase {
    struct Configuration {
        let port: Int
        let http1Port: Int
        let certificate: String
        let wrongCertificate: String

        init() throws {
            let env = ProcessInfo.processInfo.environment
            guard let h2 = env["LUXO_NIO_TEST_H2"], let port = URL(string: h2)?.port,
                let h1 = env["LUXO_NIO_TEST_H1"], let http1Port = URL(string: h1)?.port,
                let certificate = env["LUXO_NIO_TEST_CERT"], let wrong = env["LUXO_NIO_TEST_WRONG_CERT"]
            else {
                throw XCTSkip("Run the isolated integration harness for real TLS tests")
            }
            self.port = port
            self.http1Port = http1Port
            self.certificate = certificate
            wrongCertificate = wrong
        }
    }

    private func withClient(_ body: (NIOHTTPClient, Configuration, MultiThreadedEventLoopGroup) async throws -> Void)
        async throws
    {
        let config = try Configuration()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let client = try await NIOHTTPClient.connect(
                group: group, host: "localhost", port: config.port, trustRootsFile: config.certificate,
                maximumResponseBytes: 1024)
            do { try await body(client, config, group) } catch { try? await client.close(); throw error }
            try await client.close()
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func post(_ client: NIOHTTPClient, _ path: String, body: Data = Data()) async throws -> NIOResponse {
        try await client.post(
            path: path, authority: "localhost", body: body,
            headers: HTTPHeaders([("content-type", "application/x-luxo")]))
    }

    func testTLSReuseAndBadBodyIsolation() async throws {
        try await withClient { client, _, _ in
            let identity = try await post(client, "/identity").body
            XCTAssertTrue(String(decoding: identity, as: UTF8.self).hasPrefix("HTTP/2.0 "))
            let payload = Data([0, 1, 127, 255])
            let echo = try await post(client, "/", body: payload)
            XCTAssertEqual(echo.status, 200)
            XCTAssertEqual(echo.body, payload)
            let overflowBefore = try await stats(client)["overflowCancelled", default: 0]
            for path in ["/large", "/truncated", "/chunked-overflow"] {
                do { _ = try await post(client, path); XCTFail("Bad body accepted: \(path)") } catch {}
                let current = try await post(client, "/identity").body
                XCTAssertEqual(current, identity)
            }
            try await waitFor(client, key: "overflowCancelled", above: overflowBefore)
        }
    }

    func testIPCertificateValidation() async throws {
        try await withClient { _, config, group in
            let client = try await NIOHTTPClient.connect(
                group: group, host: "127.0.0.1", port: config.port, trustRootsFile: config.certificate)
            do {
                let response = try await post(client, "/", body: Data([7]))
                XCTAssertEqual(response.body, Data([7]))
                let payload = Data((0..<(128 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
                let large = try await post(client, "/", body: payload)
                XCTAssertEqual(large.body, payload)
            } catch {
                try? await client.close()
                throw error
            }
            try await client.close()
        }
    }

    private func stats(_ client: NIOHTTPClient) async throws -> [String: Int] {
        let response = try await post(client, "/stats")
        return try JSONDecoder().decode([String: Int].self, from: response.body)
    }

    private func waitFor(_ client: NIOHTTPClient, key: String, above: Int) async throws {
        for _ in 0..<200 {
            if try await stats(client)[key, default: 0] > above { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Server did not observe \(key)")
        throw ConnectionFailure.deadline
    }

    func testCancellationAndDeadlinePreserveConnection() async throws {
        try await withClient { client, _, _ in
            let identity = try await post(client, "/identity").body
            let before = try await stats(client)
            let slow = Task { try await self.post(client, "/slow") }
            try await waitFor(client, key: "started", above: before["started", default: 0])
            let concurrent = try await post(client, "/", body: Data([4, 5]))
            XCTAssertEqual(concurrent.body, Data([4, 5]))
            slow.cancel()
            do { _ = try await slow.value; XCTFail("Cancelled request succeeded") } catch {
                XCTAssertTrue(error is CancellationError)
            }
            try await waitFor(client, key: "cancelled", above: before["cancelled", default: 0])
            do {
                _ = try await client.post(
                    path: "/slow", authority: "localhost", body: Data(), headers: HTTPHeaders(),
                    timeout: .milliseconds(20))
                XCTFail("Deadline ignored")
            } catch { XCTAssertTrue(error is ConnectionFailure) }
            let after = try await post(client, "/identity").body
            XCTAssertEqual(after, identity)
        }
    }

    func testAdmissionIsBounded() async throws {
        try await withClient { observer, config, group in
            let client = try await NIOHTTPClient.connect(
                group: group, host: "localhost", port: config.port, trustRootsFile: config.certificate,
                maximumConcurrent: 1)
            let before = try await stats(observer)
            let slow = Task { try await self.post(client, "/slow") }
            do {
                try await waitFor(observer, key: "started", above: before["started", default: 0])
                do { _ = try await post(client, "/"); XCTFail("Admission limit ignored") } catch {
                    XCTAssertTrue(error is ConnectionFailure)
                }
            } catch {
                slow.cancel()
                _ = await slow.result
                try? await client.close()
                throw error
            }
            slow.cancel()
            _ = await slow.result
            try await client.close()
        }
    }

    func testRejectsUntrustedCertificateAndHTTP1WithoutReplay() async throws {
        try await withClient { observer, config, group in
            let before = try await stats(observer)["http1"]
            for (port, certificate) in [(config.port, config.wrongCertificate), (config.http1Port, config.certificate)]
            {
                do {
                    let invalid = try await NIOHTTPClient.connect(
                        group: group, host: "localhost", port: port, trustRootsFile: certificate)
                    XCTFail("Invalid TLS connection accepted")
                    try? await invalid.close()
                } catch {}
            }
            let count = try await stats(observer)["http1"]
            XCTAssertEqual(count, before)
        }
    }
}
