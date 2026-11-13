import Foundation
import CryptoKit
import XCTest
@testable import WenDaTong

extension AccessDiscoveryTests {
    func makeStore() throws -> AccessDiscoveryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccessDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return AccessDiscoveryStore(
            baseDirectory: directory.appendingPathComponent("last-good", isDirectory: true),
            watermarkDirectory: directory.appendingPathComponent("watermark", isDirectory: true)
        )
    }

    func accessDiscoveryTrustWatermarkKey(
        _ context: IMAPIContext,
        trust: AccessDiscoveryTrustConfiguration
    ) -> String {
        [
            "v2",
            trust.environment,
            trust.appID,
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    func makeContext(
        accountID: String = "account-1",
        tenantID: String = "tenant-1",
        appID: String = "ios-main"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: accountID,
            tenantID: tenantID,
            imUID: "uid-1",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: appID,
            deviceID: "device-1"
        )
    }

    func isolatedRuntimeRouteStore() -> IMRuntimeRouteStore {
        IMRuntimeRouteStore(
            defaults: UserDefaults(suiteName: "AccessDiscoveryTests.routes.\(UUID().uuidString)")!
        )
    }

    func makeResponse(
        configVersion: String,
        endpoints: [RemoteAccessDiscoveryEndpoint]? = nil,
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint] = []
    ) -> RemoteAccessDiscoveryResponse {
        RemoteAccessDiscoveryResponse(
            contractVersion: 1,
            configVersion: configVersion,
            serverTime: 1_782_710_000,
            ttlSeconds: 60,
            refreshJitterSeconds: 10,
            source: "platform",
            stale: false,
            degraded: false,
            endpoints: endpoints ?? [
                makeEndpoint(id: "ga", host: "ga.example.test", priority: 10, network: "accelerated"),
                makeEndpoint(id: "direct", host: "direct.example.test", priority: 20, network: "direct")
            ],
            discoveryFallbacks: discoveryFallbacks,
            signatureAlg: "ignored",
            signature: "ignored-by-client"
        )
    }

    private func copyResponse(
        _ response: RemoteAccessDiscoveryResponse,
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    ) -> RemoteAccessDiscoveryResponse {
        RemoteAccessDiscoveryResponse(
            contractVersion: response.contractVersion,
            configVersion: response.configVersion,
            serverTime: response.serverTime,
            ttlSeconds: response.ttlSeconds,
            refreshJitterSeconds: response.refreshJitterSeconds,
            source: response.source,
            stale: response.stale,
            degraded: response.degraded,
            endpoints: response.endpoints,
            discoveryFallbacks: discoveryFallbacks,
            signatureAlg: response.signatureAlg,
            signature: response.signature,
            trust: response.trust
        )
    }

    func makeDiscoveryFallback(
        id: String,
        priority: Int,
        host: String? = nil
    ) -> RemoteAccessDiscoveryEndpoint {
        let hostname = host ?? "\(id).example.test"
        return RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: "access_discovery",
            protocolValue: "https",
            url: "https://\(hostname)/api/tenant/access/v1/endpoints",
            host: hostname,
            port: 443,
            priority: priority,
            weight: 100,
            network: "fallback",
            tls: true,
            auth: "none",
            status: "ready"
        )
    }

    func makeEndpoint(
        id: String,
        host: String,
        priority: Int,
        network: String,
        protocolValue: String = "wss",
        url: String? = nil,
        port: Int = 443,
        path: String = "/im/ws",
        resolvedIPs: [String] = ["203.0.113.10"],
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        dialMode: String? = "domain_or_ip_hint",
        includeTLSServerName: Bool = true,
        includeHTTPHost: Bool = true
    ) -> RemoteAccessDiscoveryEndpoint {
        RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: "im_realtime",
            protocolValue: protocolValue,
            url: url ?? "wss://\(host)/im/ws",
            host: host,
            port: port,
            path: path,
            resolvedIPs: resolvedIPs,
            tlsServerName: includeTLSServerName ? (tlsServerName ?? host) : nil,
            httpHost: includeHTTPHost ? (httpHost ?? host) : nil,
            dialMode: dialMode,
            priority: priority,
            weight: 100,
            network: network,
            auth: "im_token",
            connectTimeoutMs: 3_000,
            heartbeatSeconds: 25,
            minStableSeconds: 300,
            failbackAfterSeconds: 300,
            cooldownSeconds: 300,
            maxParallelRace: 2,
            status: "ready"
        )
    }

    func makeProductionDomainOnlyEndpoint(
        id: String = "cloudfront-wss",
        usage: String = "im_realtime",
        protocolValue: String = "wss",
        host: String = "d111111abcdef8.cloudfront.net",
        url: String? = nil,
        path: String = "/im/ws",
        resolvedIPs: [String] = [],
        dialMode: String = "domain_only",
        network: String = "fallback",
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        provider: String = "aws_cloudfront",
        resourceType: String = "controlled_load_balancer",
        resourceID: String = "E1234567890ABC",
        priority: Int = 10,
        auth: String = "im_token"
    ) -> RemoteAccessDiscoveryEndpoint {
        RemoteAccessDiscoveryEndpoint(
            id: id,
            usage: usage,
            protocolValue: protocolValue,
            url: url ?? "\(protocolValue)://\(host)\(path)",
            host: host,
            port: 443,
            path: path,
            resolvedIPs: resolvedIPs,
            tlsServerName: tlsServerName ?? host,
            httpHost: httpHost ?? host,
            dialMode: dialMode,
            priority: priority,
            weight: 100,
            provider: provider,
            network: network,
            tls: true,
            auth: auth,
            minStableSeconds: 300,
            failbackAfterSeconds: 300,
            cooldownSeconds: 300,
            status: "ready",
            protectedResourceID: resourceID,
            protectedResourceType: resourceType,
            protectionEvidenceHash: String(repeating: "a", count: 64),
            protectionExpiresAt: "2026-08-03T00:00:00Z"
        )
    }

    func accessDiscoveryCacheKey(_ context: IMAPIContext) -> String {
        [
            "v3",
            AccessDiscoveryTrustConfiguration.load().environment,
            IMAPIContext.normalizedIOSAppID(context.appID),
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }
}

@MainActor
final class FakeAccessDiscoveryFetcher: AccessDiscoveryFetching {
    private var results: [Result<RemoteAccessDiscoveryResponse, Error>]
    private let onRequest: (() -> Void)?
    private(set) var requestCount = 0
    private(set) var endpointURLs: [URL?] = []
    private(set) var timeoutIntervals: [TimeInterval] = []

    init(
        results: [Result<RemoteAccessDiscoveryResponse, Error>],
        onRequest: (() -> Void)? = nil
    ) {
        self.results = results
        self.onRequest = onRequest
    }

    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse {
        try await accessDiscoveryEndpoints(context: context, endpointURL: nil, timeoutInterval: 2.5)
    }

    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse {
        requestCount += 1
        endpointURLs.append(endpointURL)
        timeoutIntervals.append(timeoutInterval)
        onRequest?()
        guard !results.isEmpty else {
            throw IMAPIError.server("missing fake discovery result")
        }
        let result = results.count == 1 ? results[0] : results.removeFirst()
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

final class AccessDiscoveryHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let result: HTTPTransportResult
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(result: HTTPTransportResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            requests.append(request)
        }
        return result
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        result
    }
}

final class AppBootstrapTestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value: UInt64

	init(nowMS: UInt64) {
		value = nowMS
	}

	func now() -> UInt64 {
		lock.withLock { value }
	}

	func advance(by milliseconds: UInt64) {
		lock.withLock {
			value = value > UInt64.max - milliseconds ? UInt64.max : value + milliseconds
		}
	}
}

final class AppBootstrapFailoverTransport: HTTPTransport, @unchecked Sendable {
	enum Outcome {
		case failure(URLError.Code, advanceMS: UInt64)
		case response(HTTPTransportResult, advanceMS: UInt64)
	}

	struct Request: Equatable {
		let host: String?
		let path: String
		let atMS: UInt64
	}

	private let lock = NSLock()
	private let clock: AppBootstrapTestClock
	private var outcomes: [Outcome]
	private var capturedRequests: [Request] = []

	init(clock: AppBootstrapTestClock, outcomes: [Outcome]) {
		self.clock = clock
		self.outcomes = outcomes
	}

	var requests: [Request] {
		lock.withLock { capturedRequests }
	}

	func data(for request: URLRequest) async throws -> HTTPTransportResult {
		let outcome: Outcome = try lock.withLock {
			let pathAndQuery = request.url.map { url in
				url.path + (url.query.map { "?\($0)" } ?? "")
			} ?? ""
			capturedRequests.append(.init(
				host: request.url?.host,
				path: pathAndQuery,
				atMS: clock.now()
			))
			guard !outcomes.isEmpty else { throw URLError(.unknown) }
			return outcomes.removeFirst()
		}
		switch outcome {
		case .failure(let code, let advanceMS):
			clock.advance(by: advanceMS)
			throw URLError(code)
		case .response(let result, let advanceMS):
			clock.advance(by: advanceMS)
			return result.resolvingResponseURL(request.url)
		}
	}

	func upload(
		for request: URLRequest,
		from data: Data,
		delegate: URLSessionTaskDelegate?
	) async throws -> HTTPTransportResult {
		try await self.data(for: request)
	}
}
