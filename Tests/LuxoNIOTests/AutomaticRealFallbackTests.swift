#if canImport(Security)
    import Foundation
    import Security
    import XCTest
    @testable import LuxoClient
    @testable import LuxoNIO

    // Test-owned trust anchors; system trust configuration is never modified.
    private final class FixtureTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
        let certificate: SecCertificate
        init(path: String) throws {
            let pem = try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            guard let der = Data(base64Encoded: pem, options: .ignoreUnknownCharacters),
                let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else { throw URLError(.serverCertificateUntrusted) }
            self.certificate = certificate
        }

        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let trust = challenge.protectionSpace.serverTrust,
                SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                SecTrustEvaluateWithError(trust, nil)
            else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    @MainActor
    final class AutomaticRealFallbackTests: XCTestCase {
        func testVerifiedH1FallbackCarriesRealJSONAndBinaryRequests() async throws {
            let config = try IntegrationTests.Configuration()
            let endpoint = "https://localhost:\(config.http1Port)/api-h1"
            let session = URLSession(
                configuration: .ephemeral, delegate: try FixtureTrust(path: config.certificate), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let backend = try await AutomaticHTTPBackend.select(
                maximumRequest: 1024, maximumConcurrent: 2,
                connectHTTP2: {
                    try await NIOHTTPBackend.connectForSelection(endpoint: endpoint, trustRootsFile: config.certificate)
                },
                makeFallback: {
                    try URLSessionHTTPBackend(endpoint: endpoint, timeout: 2, maximum: 1024, session: session)
                })
            do {
                XCTAssertEqual(backend.selectedBackend, .urlSession)
                let json = try await backend.send(body: Data("{}".utf8), mode: .json, headers: [:])
                XCTAssertEqual(json.status, 200)
                XCTAssertEqual(json.body, Data("{\"data\":42}".utf8))
                let binary = try await backend.send(body: Data([0]), mode: .binary, headers: [:])
                XCTAssertEqual(binary.status, 200)
                XCTAssertEqual(binary.body, Data([84]))
                let unauthorized = try await backend.send(
                    body: Data([0]), mode: .binary, headers: ["Authorization": "Bearer old"])
                XCTAssertEqual(unauthorized.status, 401)
                try await backend.close()
            } catch { try? await backend.close(); throw error }
        }
    }
#endif
