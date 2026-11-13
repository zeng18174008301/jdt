import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

extension AccessDiscoveryTests {
    @MainActor
    func testIMAPIClientPostsDiscoveryContractBody() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"contract_version":1,"config_version":"cfg-api","server_time":1782710000,"ttl_seconds":60,"refresh_jitter_seconds":10,"source":"platform","stale":false,"degraded":false,"endpoints":[{"id":"ga","usage":"im_realtime","protocol":"wss","url":"wss://ga.example.test/im/ws","host":"ga.example.test","port":443,"priority":10,"weight":100,"network":"accelerated","status":"ready"}],"discovery_fallbacks":[]}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let response = try await client.accessDiscoveryEndpoints(context: makeContext())
        let request = try XCTUnwrap(transport.requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(response.configVersion, "cfg-api")
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/access/v1/endpoints")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(body["contract_version"] as? Int, 2)
        XCTAssertEqual(body["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["tenant_id"] as? String, "tenant-1")
        XCTAssertNil(body["device_id"])
    }

    @MainActor
    func testSignedDiscoveryWithoutTrustConfigurationReportsConfigurationBlocked() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"payload_b64":"e30=","key_id":"fixture","signature_alg":"Ed25519","signature":"fixture","key_state":{"payload_b64":"e30=","root_key_id":"fixture","signature_alg":"Ed25519","signature":"fixture"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        do {
            _ = try await client.accessDiscoveryEndpoints(context: makeContext())
            XCTFail("Signed configuration requires a configured trust policy")
        } catch let error as AccessDiscoveryTrustError {
            XCTAssertEqual(error, .configurationBlocked)
        }
    }

    @MainActor
    func testIMAPIClientPostsSameAuthenticatedBodyToExplicitTrustedFallback() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"contract_version":1,"config_version":"cfg-fallback","server_time":1782710000,"ttl_seconds":60,"refresh_jitter_seconds":10,"source":"platform","stale":false,"degraded":false,"endpoints":[{"id":"ga","usage":"im_realtime","protocol":"wss","url":"wss://ga.example.test/im/ws","host":"ga.example.test","port":443,"priority":10,"weight":100,"network":"accelerated","status":"ready"}],"discovery_fallbacks":[]}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )
        let fallbackURL = try XCTUnwrap(URL(string: "https://fallback.example.test/api/tenant/access/v1/endpoints"))

        _ = try await client.accessDiscoveryEndpoints(
            context: makeContext(),
            endpointURL: fallbackURL,
            timeoutInterval: 2.5
        )
        let request = try XCTUnwrap(transport.requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(request.url, fallbackURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(body["contract_version"] as? Int, 2)
        XCTAssertEqual(body["tenant_id"] as? String, "tenant-1")
    }

    @MainActor
    func testIMAPIClientRejectsMaliciousExplicitFallbackBeforeNetwork() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(),
            isHTTPResponse: true,
            statusCode: 500
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let invalidURLs = [
            "http://fallback.example.test/api/tenant/access/v1/endpoints",
            "https://user:pass@fallback.example.test/api/tenant/access/v1/endpoints",
            "https://fallback.example.test/api/tenant/access/v1/endpoints?token=attacker",
            "https://203.0.113.8/api/tenant/access/v1/endpoints",
        ]

        for rawValue in invalidURLs {
            do {
                _ = try await client.accessDiscoveryEndpoints(
                    context: makeContext(),
                    endpointURL: try XCTUnwrap(URL(string: rawValue)),
                    timeoutInterval: 2.5
                )
                XCTFail("Expected malicious fallback to fail closed")
            } catch AccessDiscoveryTrustError.endpointInvalid {
                // Expected.
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTrustedDiscoveryFallbacksAreHttpsSortedDedupedAndBounded() {
        let response = makeResponse(
            configVersion: "cfg-fallback-order",
            discoveryFallbacks: [
                makeDiscoveryFallback(id: "d", priority: 40),
                makeDiscoveryFallback(id: "b", priority: 20),
                makeDiscoveryFallback(id: "a", priority: 10),
                makeDiscoveryFallback(id: "a-duplicate", priority: 11, host: "a.example.test"),
                makeDiscoveryFallback(id: "c", priority: 30),
            ]
        )

        XCTAssertEqual(
            AccessDiscoveryManager.trustedDiscoveryFallbackURLs(from: response).map(\.absoluteString),
            [
                "https://a.example.test/api/tenant/access/v1/endpoints",
                "https://b.example.test/api/tenant/access/v1/endpoints",
                "https://c.example.test/api/tenant/access/v1/endpoints",
            ]
        )
    }

    @MainActor
    func testIMAPIClientPreservesTerminalDiscoveryErrorCode() async throws {
        let transport = AccessDiscoveryHTTPTransport(result: HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"access_discovery_disabled","message":"discovery disabled"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 503
        ))
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )

        do {
            _ = try await client.accessDiscoveryEndpoints(context: makeContext())
            XCTFail("Expected terminal discovery error")
        } catch IMAPIError.businessForbidden(let code, _, _) {
            XCTAssertEqual(code, "access_discovery_disabled")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
