// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_BEGIN
import Foundation

public enum PreloginRedirectPolicy {
    public static func requestToFollow(
        originalURL: URL?,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        _ = originalURL
        _ = proposedRequest
        // Bootstrap objects are immutable, source-bound trust inputs. Following
        // even a same-origin redirect would make the fetched object differ from
        // the URL constrained and audited by the caller.
        return nil
    }
}

private final class PreloginNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            PreloginRedirectPolicy.requestToFollow(
                originalURL: task.originalRequest?.url,
                proposedRequest: request
            )
        )
    }
}

public final class PreloginHTTPSClient: @unchecked Sendable {
    private let delegate: PreloginNoRedirectDelegate
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        delegate = PreloginNoRedirectDelegate()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func get(_ url: URL, constrainedTo baseURL: URL, maximumResponseBytes: Int) async throws -> Data {
        guard Self.isWithinSourceForBootstrap(url, baseURL: baseURL) else {
            throw PreloginIOError.unavailable
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == url,
              http.url?.scheme == "https",
              http.expectedContentLength <= Int64(maximumResponseBytes)
                || http.expectedContentLength == NSURLSessionTransferSizeUnknown else {
            throw PreloginIOError.unavailable
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw PreloginIOError.unavailable
            }
            data.append(byte)
        }
        return data
    }

    public static func isWithinSourceForBootstrap(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme == "https",
              url.host?.lowercased() == baseURL.host?.lowercased(),
              (url.port ?? 443) == (baseURL.port ?? 443),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let basePath = normalizedBasePath(baseURL.path)
        return url.path.hasPrefix(basePath)
    }

    private static func normalizedBasePath(_ path: String) -> String {
        let base = path.isEmpty ? "/" : path
        return base.hasSuffix("/") ? base : "\(base)/"
    }
}

// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_END
