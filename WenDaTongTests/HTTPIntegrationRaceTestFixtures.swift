import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

final class SessionReauthenticationUploadGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let phase: String
    private let lateFailure: Bool
    private let voice: Bool
    private let size: Int
    private let loginResult: HTTPTransportResult
    private var oldContinuation: CheckedContinuation<Void, Never>?
    private var replacementContinuation: CheckedContinuation<Void, Never>?
    private var oldReleased = false
    private var replacementReleased = false
    private var oldWaiting = false
    private var replacementWaiting = false
    private var expectsReplacementConfig = false
    private var oldRequestCounts: [String: Int] = [:]

    init(phase: String, lateFailure: Bool, voice: Bool, size: Int, loginResult: HTTPTransportResult) {
        self.phase = phase
        self.lateFailure = lateFailure
        self.voice = voice
        self.size = size
        self.loginResult = loginResult
    }

    var oldIsWaiting: Bool { lock.withLock { oldWaiting } }
    var replacementIsWaiting: Bool { lock.withLock { replacementWaiting } }
    var oldCounts: [String: Int] { lock.withLock { oldRequestCounts } }

    func expectReplacementConfig() {
        lock.withLock { expectsReplacementConfig = true }
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        if path == "/api/platform/apps/current-policy" {
            return try result(["app_id": "jianhuitong-ios", "status": "active", "enterprise_code_first": false])
        }
        if path == "/api/platform/captcha/slide/config" {
            return try result(["enabled": false, "available": false, "required": false, "provider": "self_hosted_slide", "surface": "ios", "scene": "im_user_login"])
        }
        if path == "/api/platform/auth/im-login" { return loginResult.resolvingResponseURL(request.url) }
        let requestPhase: String
        if path == "/api/tenant/files/config" { requestPhase = "config" }
        else if path == "/api/tenant/files/presign-upload" { requestPhase = "presign" }
        else if path == "/api/tenant/files/file-race/uploaded" { requestPhase = "finalize" }
        else if path == "/api/im/messages", request.httpMethod == "POST" { requestPhase = "send" }
        else {
            throw FakeHTTPTransportError.responseQueueExhausted(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "")
        }
        // File configuration uses the anonymous media contract. The old
        // attempt is already paused, so the next config belongs to the
        // replacement armed by the fixture, regardless of bearer headers.
        let replacement = requestPhase == "config" && lock.withLock {
            let armed = expectsReplacementConfig
            expectsReplacementConfig = false
            return armed
        }
        if !replacement { lock.withLock { oldRequestCounts[requestPhase, default: 0] += 1 } }
        if replacement && requestPhase == "config" { await wait(replacement: true) }
        if !replacement && requestPhase == phase {
            await wait(replacement: false)
            if lateFailure { return failure() }
        }
        switch requestPhase {
        case "config":
            return try result(["max_bytes": 10_485_760])
        case "presign":
            return try result([
                "file": file(status: "pending"),
                "upload": ["url": "https://upload.example.test/\(replacement ? "new" : "old")", "method": "PUT", "headers": ["Content-Type": voice ? "audio/mp4" : "image/png"]]
            ])
        case "finalize":
            return try result(["file": file(status: "uploaded")])
        default:
            var payload = file(status: "uploaded")
            payload["duration_ms"] = 1_500
            payload["waveform"] = [10, 20, 30]
            return try result(["message": [
                "message_id": "late-old-authoritative-message", "channel_id": "uid-1:uid-2",
                "channel_type": "direct", "channel_seq": 7, "from_uid": "uid-1",
                "content_type": voice ? "voice" : "image", "payload": payload,
                "status": "sent", "created_at": "2026-09-05T00:00:00Z"
            ]])
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        try await uploadResponse(request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        _ = try Data(contentsOf: fileURL)
        return try await uploadResponse(request)
    }

    private func uploadResponse(_ request: URLRequest) async throws -> HTTPTransportResult {
        let replacement = request.url?.path == "/new"
        if !replacement { lock.withLock { oldRequestCounts["put", default: 0] += 1 } }
        if !replacement && phase == "put" {
            await wait(replacement: false)
            if lateFailure { return failure() }
        }
        return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204, responseURL: request.url)
    }

    private func wait(replacement: Bool) async {
        await withCheckedContinuation { continuation in
            let released = lock.withLock {
                if replacement {
                    replacementWaiting = true
                    if replacementReleased { return true }
                    replacementContinuation = continuation
                } else {
                    oldWaiting = true
                    if oldReleased { return true }
                    oldContinuation = continuation
                }
                return false
            }
            if released { continuation.resume() }
        }
    }

    func releaseOld() { release(replacement: false) }
    func releaseReplacement() { release(replacement: true) }

    private func release(replacement: Bool) {
        let continuation = lock.withLock {
            if replacement {
                replacementReleased = true
                defer { replacementContinuation = nil }
                return replacementContinuation
            }
            oldReleased = true
            defer { oldContinuation = nil }
            return oldContinuation
        }
        continuation?.resume()
    }

    private func file(status: String) -> [String: Any] {
        ["file_id": "file-race", "file_name": voice ? "voice.m4a" : "fixture.png",
         "mime_type": voice ? "audio/mp4" : "image/png", "size_bytes": size,
         "status": status, "upload_status": status, "attachment_status": status,
         "media_category": voice ? "voice" : "image", "extension": voice ? "m4a" : "png",
         "preview_kind": voice ? "voice" : "image", "duration_seconds": 1.5]
    }

    private func result(_ data: [String: Any]) throws -> HTTPTransportResult {
        HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]), isHTTPResponse: true, statusCode: 200)
    }

    private func failure() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"synthetic_upload_failure","message":"synthetic failure"}}"#.utf8),
            isHTTPResponse: true, statusCode: 503
        )
    }
}

final class SessionReauthenticationRouteGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: HTTPTransportResult]
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var entryReleased = false
    private var entryRequests = 0
    private var entryURL: URL?

    init(responses: [String: HTTPTransportResult]) {
        self.responses = responses
    }

    var entryRequestCount: Int { lock.withLock { entryRequests } }
    var entryRequestURL: URL? { lock.withLock { entryURL } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        guard let response = responses[path] else {
            throw FakeHTTPTransportError.responseQueueExhausted(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "")
        }
        if path == "/api/tenant/auth/platform-entry" {
            lock.withLock {
                entryRequests += 1
                entryURL = request.url
            }
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if entryReleased { return true }
                    entryContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        return response.resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw FakeHTTPTransportError.responseQueueExhausted(method: request.httpMethod ?? "PUT", url: request.url?.absoluteString ?? "")
    }

    func releaseEntry() {
        let continuation = lock.withLock {
            entryReleased = true
            let continuation = entryContinuation
            entryContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

final class RememberedLoginGateHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waitingLoginContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var loginRequests = 0
    private var completedLoginResponses = 0
    private let loginResult: HTTPTransportResult?

    init(loginResult: HTTPTransportResult? = nil) {
        self.loginResult = loginResult
    }

    var loginRequestCount: Int { lock.withLock { loginRequests } }
    var loginResponseCount: Int { lock.withLock { completedLoginResponses } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        switch path {
        case "/api/platform/apps/current-policy":
            return response(
                request,
                body: #"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#
            )
        case "/api/platform/captcha/slide/config":
            return response(
                request,
                body: #"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#
            )
        case "/api/platform/auth/im-login":
            lock.withLock { loginRequests += 1 }
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if released { return true }
                    waitingLoginContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            lock.withLock { completedLoginResponses += 1 }
            if let loginResult { return loginResult }
            return response(
                request,
                body: #"{"ok":true,"data":{"account":{"id":"account-1","username":"remember-user","status":"normal"},"platform_token":"platform-token-redacted","auth_session":{"session_id":"platform-session","refresh_token":"platform-refresh","expires_at":1785200000,"app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"platform"},"requires_workspace_selection":true,"can_direct_enter":false,"entry_status":"none","pending_entry_tenant_id":"","workspaces":[]}}"#
            )
        default:
            throw FakeHTTPTransportError.responseQueueExhausted(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "<missing-url>"
            )
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        throw FakeHTTPTransportError.responseQueueExhausted(
            method: request.httpMethod ?? "PUT",
            url: request.url?.absoluteString ?? "<missing-url>"
        )
    }

    func releaseLoginResponse() {
        let continuation = lock.withLock {
            released = true
            let continuation = waitingLoginContinuation
            waitingLoginContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func response(_ request: URLRequest, body: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: 200,
            responseURL: request.url
        )
    }
}

final class StrictAttachmentHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias CapturedUpload = (request: URLRequest, body: Data)

    private let lock = NSLock()
    private var queuedResults: [HTTPTransportResult]
    private var queuedUploadResults: [HTTPTransportResult]
    private var capturedRequests: [URLRequest] = []
    private var capturedUploads: [CapturedUpload] = []
    private let suspendedPath: String?
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var suspendedReleased = false
    private var suspendedReturned = false

    init(results: [HTTPTransportResult], uploadResults: [HTTPTransportResult], suspendedPath: String? = nil) {
        queuedResults = results
        queuedUploadResults = uploadResults
        self.suspendedPath = suspendedPath
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let result = try lock.withLock {
            capturedRequests.append(request)
            guard !queuedResults.isEmpty else {
                throw FakeHTTPTransportError.responseQueueExhausted(
                    method: request.httpMethod ?? "GET",
                    url: request.url?.absoluteString ?? "<missing-url>"
                )
            }
            return queuedResults.removeFirst().resolvingResponseURL(request.url)
        }
        if request.url?.path == suspendedPath, suspendedPath != nil {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if suspendedReleased { return true }
                    suspendedContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            lock.withLock { suspendedReturned = true }
        }
        return result
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try lock.withLock {
            capturedUploads.append((request: request, body: data))
            guard !queuedUploadResults.isEmpty else {
                throw FakeHTTPTransportError.responseQueueExhausted(
                    method: request.httpMethod ?? "PUT",
                    url: request.url?.absoluteString ?? "<missing-url>"
                )
            }
            return queuedUploadResults.removeFirst().resolvingResponseURL(request.url)
        }
    }

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await upload(for: request, from: Data(contentsOf: fileURL), delegate: delegate)
    }

    func requests() -> [URLRequest] {
        lock.withLock { capturedRequests }
    }

    func uploads() -> [CapturedUpload] {
        lock.withLock { capturedUploads }
    }

    var isExhausted: Bool {
        lock.withLock { queuedResults.isEmpty && queuedUploadResults.isEmpty }
    }

    func didReturnSuspendedResponse() -> Bool { lock.withLock { suspendedReturned } }

    func releaseSuspendedResponse() {
        let pending = lock.withLock {
            suspendedReleased = true
            let pending = suspendedContinuation
            suspendedContinuation = nil
            return pending
        }
        pending?.resume()
    }
}

final class InviteCodeRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstResult: HTTPTransportResult
    private let laterResult: HTTPTransportResult
    private var inviteRequests = 0
    private var firstInviteContinuation: CheckedContinuation<Void, Never>?
    private var firstInviteReleased = false

    init(first: HTTPTransportResult, later: HTTPTransportResult) {
        firstResult = first
        laterResult = later
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path.hasSuffix("/api/tenant/me/invite-code") == true else {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200,
                responseURL: request.url
            )
        }
        let ordinal = lock.withLock {
            inviteRequests += 1
            return inviteRequests
        }
        if ordinal == 1 {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if firstInviteReleased {
                        return true
                    }
                    firstInviteContinuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
        return (ordinal == 1 ? firstResult : laterResult).resolvingResponseURL(request.url)
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204, responseURL: request.url)
    }

    func inviteRequestCount() -> Int {
        lock.withLock { inviteRequests }
    }

    func releaseFirstInviteResponse() {
        let continuation = lock.withLock {
            firstInviteReleased = true
            let continuation = firstInviteContinuation
            firstInviteContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

final class FailingHTTPTransport: HTTPTransport, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        throw error
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        throw error
    }
}

final class HangingRegistrationHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let policyResult: HTTPTransportResult
    private var capturedRegistrationRequest: URLRequest?
    private var registrationCount = 0
    private var registrationContinuation: CheckedContinuation<Void, Never>?
    private var registrationReleased = false

    init(policyResult: HTTPTransportResult) {
        self.policyResult = policyResult
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/platform/auth/register" else {
            return policyResult
        }
        lock.withLock {
            capturedRegistrationRequest = request
            registrationCount += 1
        }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if registrationReleased {
                    return true
                }
                registrationContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
        return HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"temporarily unavailable"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 503
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func registrationRequestCount() -> Int {
        lock.withLock { registrationCount }
    }

    func registrationRequest() -> URLRequest? {
        lock.withLock { capturedRegistrationRequest }
    }

    func releaseRegistration() {
        let continuation = lock.withLock {
            registrationReleased = true
            let continuation = registrationContinuation
            registrationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

final class GroupAnnouncementRefreshRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let suspendInitialRefresh: Bool
    private let suspendPostPublicationRefresh: Bool
    private let currentNull: Bool
    private let suspendFirstSummary: Bool
    private let summaryIncludesCurrent: Bool
    private let summaryHasLegacyNotice: Bool
    private var firstSummaryReleased = false
    private var summaryContinuation: CheckedContinuation<Void, Never>?
    private var summaryCount = 0
    private var publicationCount = 0
    private var failAnnouncementReads = false
    private var failCurrentRead = true
    private var failedReadCount = 0
    private var emptyList = false
    private var published = false
    private var initialRefreshReleased = false
    private var postPublicationRefreshReleased = false
    private var initialRequestPaths = Set<String>()
    private var postPublicationRequestPaths = Set<String>()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var postPublicationContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        suspendInitialRefresh: Bool,
        suspendPostPublicationRefresh: Bool = false,
        currentNull: Bool = false,
        suspendFirstSummary: Bool = false,
        summaryIncludesCurrent: Bool = false,
        summaryHasLegacyNotice: Bool = false
    ) {
        self.suspendInitialRefresh = suspendInitialRefresh
        self.suspendPostPublicationRefresh = suspendPostPublicationRefresh
        self.currentNull = currentNull
        self.suspendFirstSummary = suspendFirstSummary
        self.summaryIncludesCurrent = summaryIncludesCurrent
        self.summaryHasLegacyNotice = summaryHasLegacyNotice
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let holdSummary = lock.withLock {
            if method == "POST", path.hasSuffix("/announcements") { publicationCount += 1 }
            guard method == "GET", path.hasSuffix("/summary") else { return false }
            summaryCount += 1
            return suspendFirstSummary && summaryCount == 1
        }
        if holdSummary {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if firstSummaryReleased { return true }
                    summaryContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        let failRead = lock.withLock {
            guard failAnnouncementReads, method == "GET",
                  path.hasSuffix("/announcements") || (failCurrentRead && path.hasSuffix("/announcements/current")) else { return false }
            failedReadCount += 1
            return true
        }
        if failRead {
            return HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"test read unavailable"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503
            ).resolvingResponseURL(request.url)
        }
        let snapshot = lock.withLock { () -> (suspend: Bool, suspendPostPublication: Bool, published: Bool, emptyList: Bool) in
            if method == "POST", path.hasSuffix("/announcements") {
                published = true
            }
            let isAnnouncementRefresh = method == "GET"
                && (path.hasSuffix("/announcements") || path.hasSuffix("/announcements/current"))
            let shouldSuspend = suspendInitialRefresh && !published && isAnnouncementRefresh
            let suspendPostPublication = suspendPostPublicationRefresh && published && isAnnouncementRefresh
            if shouldSuspend { initialRequestPaths.insert(path) }
            if suspendPostPublication { postPublicationRequestPaths.insert(path) }
            return (shouldSuspend, suspendPostPublication, published, emptyList)
        }
        if snapshot.suspend {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if initialRefreshReleased { return true }
                    continuations.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        if snapshot.suspendPostPublication {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if postPublicationRefreshReleased { return true }
                    postPublicationContinuations.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        let old = #"{"id":"old-announcement","group_id":"group-announcement","title":"旧公告","content":"旧正文","updated_at":"2026-09-04T10:00:00Z","unread":true}"#
        let new = #"{"id":"new-announcement","group_id":"group-announcement","title":"新公告","content":"新正文","updated_at":"2026-09-05T10:00:00Z","unread":\#(snapshot.published && method == "GET" ? "true" : "false")}"#
        let data: String
        switch (method, path) {
        case ("GET", _) where path.hasSuffix("/summary"):
            let legacyNotice = summaryHasLegacyNotice ? #", "notice":"旧正文""# : ""
            let current = summaryIncludesCurrent ? ",\"current_announcement\":\(old)" : ""
            data = #"{"group":{"group_id":"group-announcement","name":"公告测试群"\#(legacyNotice)},"my_role":"owner","member_preview":[]\#(current)}"#
        case ("POST", _) where path.hasSuffix("/announcements"):
            data = new
        case ("GET", _) where path.hasSuffix("/announcements/current"):
            data = currentNull ? "null" : (snapshot.published ? new : old)
        case ("GET", _) where path.hasSuffix("/announcements"):
            let items = snapshot.emptyList ? "" : (snapshot.suspend ? old : "\(new),\(old)")
            data = "{\"items\":[\(items)]}"
        case ("GET", _) where path.hasSuffix("/announcements/old-announcement"):
            data = old
        default:
            data = #"{"items":[]}"#
        }
        return HTTPTransportResult(
            data: Data("{\"ok\":true,\"data\":\(data)}".utf8),
            isHTTPResponse: true,
            statusCode: method == "POST" ? 201 : 200
        ).resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func suspendedRequestCount() -> Int {
        lock.withLock { initialRequestPaths.count }
    }

    func summaryRequestCount() -> Int { lock.withLock { summaryCount } }
    func publicationRequestCount() -> Int { lock.withLock { publicationCount } }
    func failedAnnouncementReadCount() -> Int { lock.withLock { failedReadCount } }

    func setAnnouncementReadsFail(_ fail: Bool, includingCurrent: Bool = true) {
        lock.withLock {
            failAnnouncementReads = fail
            failCurrentRead = includingCurrent
        }
    }

    func releaseFirstSummary() {
        let pending = lock.withLock {
            firstSummaryReleased = true
            let pending = summaryContinuation
            summaryContinuation = nil
            return pending
        }
        pending?.resume()
    }

    func postPublicationRequestCount() -> Int {
        lock.withLock { postPublicationRequestPaths.count }
    }

    func setAnnouncementListEmpty(_ empty: Bool) {
        lock.withLock { emptyList = empty }
    }

    func releasePostPublicationRefresh() {
        let pending = lock.withLock {
            postPublicationRefreshReleased = true
            let pending = postPublicationContinuations
            postPublicationContinuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }

    func releaseInitialRefresh() {
        let pending = lock.withLock {
            initialRefreshReleased = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}

// WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
final class OrganizationDepartmentMutationGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<HTTPTransportResult, Error>] = []
    private var closed = false

    var pendingCount: Int { lock.withLock { pending.count } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.httpMethod == "POST", request.url?.path == "/api/tenant/org/departments" else {
            throw URLError(.unsupportedURL)
        }
        let result: HTTPTransportResult = try await withCheckedThrowingContinuation { continuation in
            let reject = lock.withLock {
                guard !closed else { return true }
                pending.append(continuation)
                return false
            }
            if reject { continuation.resume(throwing: URLError(.cancelled)) }
        }
        return result.resolvingResponseURL(request.url)
    }

    func releaseFirst() {
        let continuation = lock.withLock { pending.removeFirst() }
        continuation.resume(returning: HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"department_id":"department-created","name":"测试部门"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        ))
    }

    func close() {
        let waiting = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return pending
        }
        waiting.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END
