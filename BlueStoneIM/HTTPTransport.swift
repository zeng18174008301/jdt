import Foundation

struct HTTPTransportResult: Sendable {
    let data: Data
    let isHTTPResponse: Bool
    let statusCode: Int?
	let responseURL: URL?
    private let headersByLowercasedName: [String: String]

    init(
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

    init(data: Data, response: URLResponse) {
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

    func value(forHTTPHeaderField name: String) -> String? {
        headersByLowercasedName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

	func resolvingResponseURL(_ fallback: URL?) -> HTTPTransportResult {
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

protocol HTTPTransport: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResult
	func data(
		for request: URLRequest,
		rejectingCrossOriginRedirectsFrom expectedOrigin: URL
	) async throws -> HTTPTransportResult
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult
    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult
}

extension HTTPTransport {
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

typealias HTTPTransporting = HTTPTransport

struct HTTPInFlightTaskClaim<Value: Sendable> {
    let task: Task<Value, Error>
    fileprivate let registeredKey: String?
}

@MainActor
final class HTTPInFlightRequestStore<Value: Sendable> {
    private var tasksByKey: [String: Task<Value, Error>] = [:]

    var registeredTaskCount: Int {
        tasksByKey.count
    }

    func task(for key: String?, create: () -> Task<Value, Error>) -> HTTPInFlightTaskClaim<Value> {
        guard let key, !key.isEmpty else {
            return HTTPInFlightTaskClaim(task: create(), registeredKey: nil)
        }
        if let existing = tasksByKey[key] {
            return HTTPInFlightTaskClaim(task: existing, registeredKey: nil)
        }
        let task = create()
        tasksByKey[key] = task
        return HTTPInFlightTaskClaim(task: task, registeredKey: key)
    }

    func finish(_ claim: HTTPInFlightTaskClaim<Value>) {
        guard let registeredKey = claim.registeredKey else { return }
        tasksByKey[registeredKey] = nil
    }

    func reset() {
        tasksByKey.removeAll()
    }
}

private final class HTTPOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	private let expectedScheme: String
	private let expectedHost: String
	private let expectedPort: Int

	init(expectedOrigin: URL) {
		expectedScheme = expectedOrigin.scheme?.lowercased() ?? ""
		expectedHost = expectedOrigin.host?.lowercased() ?? ""
		expectedPort = expectedOrigin.port ?? (expectedScheme == "https" ? 443 : 80)
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		guard let url = request.url,
		      url.scheme?.lowercased() == expectedScheme,
		      url.host?.lowercased() == expectedHost,
		      (url.port ?? (expectedScheme == "https" ? 443 : 80)) == expectedPort else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}
}

final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let (data, response) = try await session.data(for: request)
        return HTTPTransportResult(data: data, response: response)
    }

	func data(
		for request: URLRequest,
		rejectingCrossOriginRedirectsFrom expectedOrigin: URL
	) async throws -> HTTPTransportResult {
		let delegate = HTTPOriginRedirectDelegate(expectedOrigin: expectedOrigin)
		let (data, response) = try await session.data(for: request, delegate: delegate)
		return HTTPTransportResult(data: data, response: response)
	}

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let (data, response) = try await session.upload(for: request, from: data, delegate: delegate)
        return HTTPTransportResult(data: data, response: response)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        return HTTPTransportResult(data: data, response: response)
    }
}
