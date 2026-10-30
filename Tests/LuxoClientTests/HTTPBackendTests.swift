import Foundation
import XCTest
@testable import LuxoClient

final class HTTPBackendTests: XCTestCase {
    private actor Backend: HTTPBackend {
        var tokens: [String?] = []
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            tokens.append(headers["Authorization"])
            let text =
                tokens.count == 1
                ? "{\"error\":\"Unauthorized\",\"code\":401,\"message\":\"expired\"}"
                : "{\"data\":42}"
            return HTTPBackendResponse(status: tokens.count == 1 ? 401 : 200, body: Data(text.utf8))
        }
    }

    func testSharedBackendRefreshesExactlyOnce() async throws {
        let backend = Backend()
        let transport = HTTPTransport(backend: backend, token: "old")
        transport.onTokenExpired = { "new" }
        let response = try await transport.call("viewer")
        XCTAssertEqual(response.mode, .json)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "42")
        let tokens = await backend.tokens
        XCTAssertEqual(tokens, ["Bearer old", "Bearer new"])
    }
}
