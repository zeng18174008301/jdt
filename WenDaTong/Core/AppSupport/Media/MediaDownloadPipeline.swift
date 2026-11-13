import CryptoKit
import Foundation
import IM4Data

enum MediaDownloadPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case background = 0
    case normal = 10
    case visible = 20
    case userInitiated = 30

    static func < (lhs: MediaDownloadPriority, rhs: MediaDownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MediaDownloadSource: Codable, Hashable, Sendable {
    case endpoint(path: String)
    case provider(key: String)

    var debugDescription: String {
        switch self {
        case .endpoint:
            return "endpoint:<redacted>"
        case .provider(let key):
            return "provider:\(key)"
        }
    }
}

struct MediaDownloadRequest: Codable, Hashable, Sendable {
    var identity: MediaResourceIdentity
    var source: MediaDownloadSource
    var priority: MediaDownloadPriority
    var requestedAt: Date
    var signatureExpiresAt: Date?
    var preferredExtension: String

    init(
        identity: MediaResourceIdentity,
        source: MediaDownloadSource,
        priority: MediaDownloadPriority = .normal,
        requestedAt: Date = Date(),
        signatureExpiresAt: Date? = nil,
        preferredExtension: String = ""
    ) {
        self.identity = identity
        self.source = source
        self.priority = priority
        self.requestedAt = requestedAt
        self.signatureExpiresAt = signatureExpiresAt
        self.preferredExtension = preferredExtension
    }

    var taskID: String {
        identity.stableCacheKey
    }

    func cacheFileURL(in rootDirectory: URL) -> URL {
        identity.cacheFileURL(in: rootDirectory, preferredExtension: preferredExtension)
    }
}

enum MediaDownloadFailureReason: String, Codable, Hashable, Sendable {
    case network
    case notFound
    case forbidden
    case unauthorized
    case cancelled
    case signatureExpired
    case unknown

    static func normalized(httpStatus: Int?, backendCode: String? = nil) -> MediaDownloadFailureReason {
        let code = backendCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if code.contains("signature_expired") || code.contains("url_expired") || code.contains("signed_url_expired") {
            return .signatureExpired
        }
        if httpStatus == 401 {
            return .unauthorized
        }
        if httpStatus == 403 {
            return .forbidden
        }
        if httpStatus == 404 || code == "not_found" || code.contains("file_not_found") {
            return .notFound
        }
        if code.contains("cancel") {
            return .cancelled
        }
        if let httpStatus, (500...599).contains(httpStatus) {
            return .network
        }
        return code.isEmpty ? .unknown : .forbidden
    }
}

protocol MediaHTTPStatusProvidingError: Error {
    var statusCode: Int { get }
    var requestURL: URL? { get }
}

enum MediaSignedURLRefreshPolicy {
    static func shouldRefresh(
        statusCode: Int,
        requestURL: URL?,
        backendCode: String = ""
    ) -> Bool {
        let code = backendCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.contains("signature_expired")
            || code.contains("url_expired")
            || code.contains("signed_url_expired") {
            return !isAuthenticatedTenantAPIURL(requestURL)
        }
        guard statusCode == 401 || statusCode == 403 else { return false }
        return !isAuthenticatedTenantAPIURL(requestURL) && isSignedObjectStorageURL(requestURL)
    }

    static func isAuthenticatedTenantAPIURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path == "/api/tenant" || path.hasPrefix("/api/tenant/")
    }

    static func isSignedObjectStorageURL(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let names = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        if names.contains("auth_key") || names.contains("x-oss-signature") {
            return true
        }
        return names.contains("ossaccesskeyid") && names.contains("signature")
    }
}

enum MediaSignedURLRecovery {
    @MainActor
    static func perform<Output>(
        initialURL: URL,
        refreshURL: () async throws -> URL,
        operation: (URL) async throws -> Output
    ) async throws -> Output {
        do {
            return try await operation(initialURL)
        } catch {
            guard let statusError = error as? any MediaHTTPStatusProvidingError,
                  MediaSignedURLRefreshPolicy.shouldRefresh(
                      statusCode: statusError.statusCode,
                      requestURL: statusError.requestURL ?? initialURL
                  ) else {
                throw error
            }
            let refreshedURL = try await refreshURL()
            return try await operation(refreshedURL)
        }
    }
}

actor MediaVisibleRecoveryGate {
    static let shared = MediaVisibleRecoveryGate()

    private let cooldown: TimeInterval
    private var lastAttemptsByKey: [String: Date] = [:]

    init(cooldown: TimeInterval = 15) {
        self.cooldown = max(1, cooldown)
    }

    func shouldRetry(key: String, now: Date = Date()) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        if let lastAttempt = lastAttemptsByKey[normalizedKey],
           now.timeIntervalSince(lastAttempt) < cooldown {
            return false
        }
        lastAttemptsByKey[normalizedKey] = now
        if lastAttemptsByKey.count > 512 {
            let cutoff = now.addingTimeInterval(-cooldown * 4)
            lastAttemptsByKey = lastAttemptsByKey.filter { $0.value >= cutoff }
        }
        return true
    }
}

enum MediaDownloadTaskPhase: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case signatureExpired
}

struct MediaDownloadTaskState: Codable, Hashable, Sendable {
    var request: MediaDownloadRequest
    var phase: MediaDownloadTaskPhase
    var progress: Double?
    var localURL: URL?
    var failureReason: MediaDownloadFailureReason?
    var updatedAt: Date

    init(
        request: MediaDownloadRequest,
        phase: MediaDownloadTaskPhase = .queued,
        progress: Double? = nil,
        localURL: URL? = nil,
        failureReason: MediaDownloadFailureReason? = nil,
        updatedAt: Date = Date()
    ) {
        self.request = request
        self.phase = phase
        self.progress = progress.map { min(max($0, 0), 1) }
        self.localURL = localURL
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }

    var transferState: MediaTransferState {
        switch phase {
        case .queued:
            return .readyRemote
        case .running:
            return .downloading(progress: progress)
        case .completed:
            if let localURL {
                return .downloaded(localURL: localURL)
            }
            return .failed(message: "本地文件不存在")
        case .failed:
            return .failed(message: failureReason?.rawValue)
        case .cancelled:
            return .failed(message: MediaDownloadFailureReason.cancelled.rawValue)
        case .signatureExpired:
            return .signatureExpired
        }
    }
}

actor MediaDownloadManager {
    private let rootDirectory: URL
    private let policy: MediaCachePolicy
    private var statesByTaskID: [String: MediaDownloadTaskState] = [:]

    init(rootDirectory: URL, policy: MediaCachePolicy) {
        self.rootDirectory = rootDirectory
        self.policy = policy
    }

    var maxConcurrentDownloads: Int {
        policy.maxConcurrentDownloads
    }

    func enqueue(_ request: MediaDownloadRequest, now: Date = Date()) -> MediaDownloadTaskState {
        if var existing = statesByTaskID[request.taskID] {
            if request.priority > existing.request.priority {
                existing.request.priority = request.priority
                existing.updatedAt = now
                statesByTaskID[request.taskID] = existing
            }
            return existing
        }

        let phase: MediaDownloadTaskPhase = MediaPipelineCore.shouldRefreshSignature(
            expiresAt: request.signatureExpiresAt,
            now: now,
            policy: policy
        ) ? .signatureExpired : .queued
        let state = MediaDownloadTaskState(
            request: request,
            phase: phase,
            failureReason: phase == .signatureExpired ? .signatureExpired : nil,
            updatedAt: now
        )
        statesByTaskID[request.taskID] = state
        return state
    }

    func cancel(taskID: String, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        state.phase = .cancelled
        state.progress = nil
        state.failureReason = .cancelled
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func markRunning(taskID: String, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID], state.phase == .queued else { return nil }
        state.phase = .running
        state.progress = state.progress ?? 0
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func updateProgress(taskID: String, progress: Double, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID], state.phase == .running else { return nil }
        state.progress = min(max(progress, 0), 1)
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func complete(taskID: String, localURL: URL? = nil, now: Date = Date()) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        state.phase = .completed
        state.progress = 1
        state.localURL = localURL ?? state.request.cacheFileURL(in: rootDirectory)
        state.failureReason = nil
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func fail(
        taskID: String,
        httpStatus: Int? = nil,
        backendCode: String? = nil,
        now: Date = Date()
    ) -> MediaDownloadTaskState? {
        guard var state = statesByTaskID[taskID] else { return nil }
        let reason = MediaDownloadFailureReason.normalized(httpStatus: httpStatus, backendCode: backendCode)
        state.phase = reason == .signatureExpired ? .signatureExpired : .failed
        state.failureReason = reason
        state.progress = nil
        state.updatedAt = now
        statesByTaskID[taskID] = state
        return state
    }

    func stateSnapshot() -> [MediaDownloadTaskState] {
        statesByTaskID.values.sorted { lhs, rhs in
            if lhs.phase != rhs.phase {
                return lhs.phase.sortRank < rhs.phase.sortRank
            }
            if lhs.request.priority != rhs.request.priority {
                return lhs.request.priority > rhs.request.priority
            }
            return lhs.request.requestedAt < rhs.request.requestedAt
        }
    }

    func runnableTaskIDs() -> [String] {
        let runningCount = statesByTaskID.values.filter { $0.phase == .running }.count
        let capacity = max(policy.maxConcurrentDownloads - runningCount, 0)
        guard capacity > 0 else { return [] }
        return stateSnapshot()
            .filter { $0.phase == .queued }
            .prefix(capacity)
            .map(\.request.taskID)
    }

    func cachedURL(for request: MediaDownloadRequest) -> URL {
        request.cacheFileURL(in: rootDirectory)
    }
}

struct MediaSignedDownloadEndpoint: Sendable {
    var url: URL
    var headers: [String: String]
    var expiresAt: Date?

    init(url: URL, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

protocol MediaSignedURLProviding: Sendable {
    func signedEndpoint(for request: MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint
}

struct MediaSignedURLProvider: MediaSignedURLProviding {
    private let resolver: @Sendable (MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint

    init(resolver: @escaping @Sendable (MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint) {
        self.resolver = resolver
    }

    func signedEndpoint(for request: MediaDownloadRequest) async throws -> MediaSignedDownloadEndpoint {
        try await resolver(request)
    }
}

struct MediaDownloadResumeMetadata: Codable, Hashable, Sendable {
    var identity: MediaResourceIdentity
    var partialFileURL: URL
    var bytesWritten: Int64
    var expectedBytes: Int64?
    var entityTag: String?
    var updatedAt: Date

    init(
        identity: MediaResourceIdentity,
        partialFileURL: URL,
        bytesWritten: Int64,
        expectedBytes: Int64? = nil,
        entityTag: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.partialFileURL = partialFileURL
        self.bytesWritten = max(bytesWritten, 0)
        self.expectedBytes = expectedBytes
        self.entityTag = entityTag
        self.updatedAt = updatedAt
    }

    var rangeHeaderValue: String? {
        guard bytesWritten > 0 else { return nil }
        return "bytes=\(bytesWritten)-"
    }
}

enum MediaDownloadExecutorEvent: Sendable {
    case started(taskID: String)
    case progress(taskID: String, fraction: Double?)
    case completed(taskID: String, localURL: URL)
    case failed(taskID: String, reason: MediaDownloadFailureReason)
    case cancelled(taskID: String)
    case signatureExpired(taskID: String)
}

protocol MediaDownloadExecuting: Sendable {
    func events(
        for request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata?
    ) async -> AsyncStream<MediaDownloadExecutorEvent>

    func cancel(taskID: String) async
}

actor MediaURLSessionDownloadExecutor: MediaDownloadExecuting {
    private let session: URLSession
    private let policy: MediaCachePolicy
    private var tasksByID: [String: Task<Void, Never>] = [:]

    init(session: URLSession = .shared, policy: MediaCachePolicy) {
        self.session = session
        self.policy = policy
    }

    func events(
        for request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata? = nil
    ) async -> AsyncStream<MediaDownloadExecutorEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(
                    request: request,
                    provider: provider,
                    cacheRoot: cacheRoot,
                    resumeMetadata: resumeMetadata,
                    continuation: continuation
                )
            }
            register(task, for: request.taskID)
            continuation.onTermination = { @Sendable _ in
                Task { await self.cancel(taskID: request.taskID) }
            }
        }
    }

    func cancel(taskID: String) async {
        tasksByID[taskID]?.cancel()
        tasksByID[taskID] = nil
    }

    private func register(_ task: Task<Void, Never>, for taskID: String) {
        tasksByID[taskID]?.cancel()
        tasksByID[taskID] = task
    }

    private func unregister(taskID: String) {
        tasksByID[taskID] = nil
    }

    private func run(
        request: MediaDownloadRequest,
        provider: any MediaSignedURLProviding,
        cacheRoot: URL,
        resumeMetadata: MediaDownloadResumeMetadata?,
        continuation: AsyncStream<MediaDownloadExecutorEvent>.Continuation
    ) async {
        let taskID = request.taskID
        defer {
            continuation.finish()
            unregister(taskID: taskID)
        }

        do {
            continuation.yield(.started(taskID: taskID))
            var refreshAttempted = false
            while true {
                let endpoint = try await provider.signedEndpoint(for: request)
                if MediaPipelineCore.shouldRefreshSignature(expiresAt: endpoint.expiresAt, policy: policy) {
                    if !refreshAttempted {
                        refreshAttempted = true
                        continue
                    }
                    continuation.yield(.signatureExpired(taskID: taskID))
                    return
                }

                var urlRequest = URLRequest(url: endpoint.url)
                for (field, value) in endpoint.headers {
                    urlRequest.setValue(value, forHTTPHeaderField: field)
                }
                if let rangeHeader = resumeMetadata?.rangeHeaderValue {
                    urlRequest.setValue(rangeHeader, forHTTPHeaderField: "Range")
                }

                let (data, response) = try await MediaDownloadByteTransfer.fetch(urlRequest, using: session) // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111
                try Task.checkCancellation()
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.yield(.failed(taskID: taskID, reason: .unknown))
                    return
                }

                switch httpResponse.statusCode {
                case 200, 206:
                    continuation.yield(.progress(taskID: taskID, fraction: nil))
                    let localURL = try MediaDownloadByteTransfer.install(data, at: request.cacheFileURL(in: cacheRoot)) // WDT_IOS1_DATA17_MEDIA_DOWNLOAD_SPLASH_BYTES_20261111
                    continuation.yield(.completed(taskID: taskID, localURL: localURL))
                    return
                default:
                    if !refreshAttempted,
                       MediaSignedURLRefreshPolicy.shouldRefresh(
                           statusCode: httpResponse.statusCode,
                           requestURL: endpoint.url
                       ) {
                        refreshAttempted = true
                        continue
                    }
                    let reason = MediaSignedURLRefreshPolicy.shouldRefresh(
                        statusCode: httpResponse.statusCode,
                        requestURL: endpoint.url
                    )
                        ? MediaDownloadFailureReason.signatureExpired
                        : MediaDownloadFailureReason.normalized(httpStatus: httpResponse.statusCode)
                    if reason == .signatureExpired {
                        continuation.yield(.signatureExpired(taskID: taskID))
                    } else {
                        continuation.yield(.failed(taskID: taskID, reason: reason))
                    }
                    return
                }
            }
        } catch is CancellationError {
            continuation.yield(.cancelled(taskID: taskID))
        } catch {
            continuation.yield(.failed(taskID: taskID, reason: .network))
        }
    }

}

private extension MediaDownloadTaskPhase {
    var sortRank: Int {
        switch self {
        case .running:
            return 0
        case .queued:
            return 1
        case .signatureExpired:
            return 2
        case .failed:
            return 3
        case .cancelled:
            return 4
        case .completed:
            return 5
        }
    }
}
