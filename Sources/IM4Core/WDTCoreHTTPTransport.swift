import Foundation

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
public struct HTTPRouteTiming: Sendable {
    @TaskLocal public static var current: HTTPRouteTiming?
    public let started: @Sendable (UInt64) -> Void
    public let receivedHeaders: @Sendable (Int) -> Void
    public let mayStart: @Sendable () -> Bool
    public let failed: @Sendable (Error) -> Void

    public init(
        started: @escaping @Sendable (UInt64) -> Void,
        receivedHeaders: @escaping @Sendable (Int) -> Void,
        mayStart: @escaping @Sendable () -> Bool = { true },
        failed: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.started = started
        self.receivedHeaders = receivedHeaders
        self.mayStart = mayStart
        self.failed = failed
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_BEGIN

public struct HTTPTransportResult: Sendable {
    public let data: Data
    public let isHTTPResponse: Bool
    public let statusCode: Int?
	public let responseURL: URL?
    private let headersByLowercasedName: [String: String]

    public init(
		data: Data,
		isHTTPResponse: Bool,
		statusCode: Int?,
		headers: [String: String] = [:],
		responseURL: URL? = nil
	) {
        self.data = data
        self.isHTTPResponse = isHTTPResponse
        self.statusCode = statusCode
		self.responseURL = responseURL
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { continue }
            normalizedHeaders[normalizedKey] = value
        }
        self.headersByLowercasedName = normalizedHeaders
    }

    public init(data: Data, response: URLResponse) {
        guard let http = response as? HTTPURLResponse else {
            self.init(data: data, isHTTPResponse: false, statusCode: nil, responseURL: response.url)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        self.init(
			data: data,
			isHTTPResponse: true,
			statusCode: http.statusCode,
			headers: headers,
			responseURL: http.url
		)
    }

    public func value(forHTTPHeaderField name: String) -> String? {
        headersByLowercasedName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

	public func resolvingResponseURL(_ fallback: URL?) -> HTTPTransportResult {
		guard responseURL == nil, let fallback else { return self }
		return HTTPTransportResult(
			data: data,
			isHTTPResponse: isHTTPResponse,
			statusCode: statusCode,
			headers: headersByLowercasedName,
			responseURL: fallback
		)
	}
}

public protocol HTTPTransport: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResult
	func data(
		for request: URLRequest,
		rejectingCrossOriginRedirectsFrom expectedOrigin: URL
	) async throws -> HTTPTransportResult
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func data(for request: URLRequest, expectedOrigin: URL, routeTiming: HTTPRouteTiming) async throws -> HTTPTransportResult
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult
    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult
}

public extension HTTPTransport {
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func data(for request: URLRequest, expectedOrigin: URL, routeTiming: HTTPRouteTiming) async throws -> HTTPTransportResult {
        guard routeTiming.mayStart() else { throw CancellationError() }
        routeTiming.started(DispatchTime.now().uptimeNanoseconds)
        let response = try await data(for: request, rejectingCrossOriginRedirectsFrom: expectedOrigin)
        if response.isHTTPResponse, let status = response.statusCode { routeTiming.receivedHeaders(status) }
        return response
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
	func data(
		for request: URLRequest,
		rejectingCrossOriginRedirectsFrom expectedOrigin: URL
	) async throws -> HTTPTransportResult {
		_ = expectedOrigin
		return try await data(for: request)
	}

    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        _ = request
        _ = fileURL
        _ = delegate
        throw URLError(.unsupportedURL)
    }
}

public typealias HTTPTransporting = HTTPTransport
// WDT_IOS1_REFACTOR_CORE_FOUNDATION_MODULE_20261110_END
