// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_BEGIN
import Foundation
import Dispatch
import IM4Core

private final class HTTPOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	private let expectedScheme: String
	private let expectedHost: String
	private let expectedPort: Int
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private let receivedHeaders: (@Sendable (Int) -> Void)?

	init(expectedOrigin: URL, receivedHeaders: (@Sendable (Int) -> Void)? = nil) {
		expectedScheme = expectedOrigin.scheme?.lowercased() ?? ""
		expectedHost = expectedOrigin.host?.lowercased() ?? ""
		expectedPort = expectedOrigin.port ?? (expectedScheme == "https" ? 443 : 80)
        self.receivedHeaders = receivedHeaders
	}
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        receivedHeaders?(response.statusCode)
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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

public final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> HTTPTransportResult {
        // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
        let delivery = SDKHTTPTrace.current?.delivery
        let started = delivery.map { _ in DispatchTime.now().uptimeNanoseconds }
        // WDT_IOS1_SDK_GET_V3_20261111_END
        let (data, response) = try await session.data(for: request)
        observeDelivery(delivery, started: started) // WDT_IOS1_SDK_GET_V3_20261111
        return HTTPTransportResult(data: data, response: response)
    }

	public func data(
		for request: URLRequest,
		rejectingCrossOriginRedirectsFrom expectedOrigin: URL
	) async throws -> HTTPTransportResult {
        // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
        let delivery = SDKHTTPTrace.current?.delivery
        let started = delivery.map { _ in DispatchTime.now().uptimeNanoseconds }
        // WDT_IOS1_SDK_GET_V3_20261111_END
		let delegate = HTTPOriginRedirectDelegate(expectedOrigin: expectedOrigin)
		let (data, response) = try await session.data(for: request, delegate: delegate)
        observeDelivery(delivery, started: started) // WDT_IOS1_SDK_GET_V3_20261111
		return HTTPTransportResult(data: data, response: response)
	}

    // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
    private func observeDelivery(_ observer: SDKHTTPTraceObserver?, started: UInt64?) {
        guard let observer, let started else { return }
        let uptime = DispatchTime.now().uptimeNanoseconds
        let actualMain = Thread.isMainThread
        observer(uptime, uptime &- started, actualMain)
    }
    // WDT_IOS1_SDK_GET_V3_20261111_END

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    public func data(for request: URLRequest, expectedOrigin: URL, routeTiming: HTTPRouteTiming) async throws -> HTTPTransportResult {
        let delivery = SDKHTTPTrace.current?.delivery
        let started = DispatchTime.now().uptimeNanoseconds
        let delegate = HTTPOriginRedirectDelegate(expectedOrigin: expectedOrigin, receivedHeaders: routeTiming.receivedHeaders)
        guard routeTiming.mayStart() else { throw CancellationError() }
        routeTiming.started(started)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        if let response = response as? HTTPURLResponse { routeTiming.receivedHeaders(response.statusCode) }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        observeDelivery(delivery, started: started)
        return HTTPTransportResult(data: data, response: response)
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    public func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let (data, response) = try await session.upload(for: request, from: data, delegate: delegate)
        return HTTPTransportResult(data: data, response: response)
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        return HTTPTransportResult(data: data, response: response)
    }
}
// WDT_IOS1_DATA_HTTP_MECHANISM_20261110_END
