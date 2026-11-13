import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

final class RTCDeviceCapabilityBootstrapHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let capabilityStatusCode: Int
    private var capturedRequests: [URLRequest] = []

    init(capabilityStatusCode: Int = 200) {
        self.capabilityStatusCode = capabilityStatusCode
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        switch request.url?.path ?? "" {
        case "/api/tenant/files/config":
            return HTTPTransportResult(
                data: Data(
                    """
                    {
                      "ok": true,
                      "data": {
                        "file_upload_max_bytes": 20971520,
                        "max_mb": 20,
                        "source": "test",
                        "message_recall_max_minutes": 120,
                        "voice_call_enabled": true,
                        "video_call_enabled": true,
                        "read_receipts_enabled": true,
                        "group_admin_delete_message_enabled": false
                      }
                    }
                    """.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200,
                responseURL: request.url
            )
        case "/api/rtc/provider":
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"call_types":["audio","video"],"voice_call_enabled":true,"video_call_enabled":true,"video_supported":true,"capabilities_version":"video-call-v1","media_plane_configured":true,"ice_servers_configured":true}}"#.utf8),
                isHTTPResponse: true, statusCode: 200, responseURL: request.url)
        case "/api/rtc/device-capabilities":
            if capabilityStatusCode == 200 {
                return HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200,
                    responseURL: request.url
                )
            }
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":false,"error":{"code":"rtc_capability_unavailable","message":"capability unavailable"}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: capabilityStatusCode,
                responseURL: request.url
            )
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }

    func requestCount(path: String) -> Int {
        lock.withLock {
            capturedRequests.filter { $0.url?.path == path }.count
        }
    }

    func lastJSONBody(path: String) -> [String: Any]? {
        lock.withLock {
            guard let body = capturedRequests.last(where: { $0.url?.path == path })?.httpBody else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }
}

final class SearchJumpTargetHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let syncItemsJSON: String
    private var capturedBodies: [[String: Any]] = []

    init(syncItemsJSON: String) {
        self.syncItemsJSON = syncItemsJSON
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/sync" else {
            throw URLError(.unsupportedURL)
        }
        if let bodyData = request.httpBody,
           let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            lock.withLock {
                capturedBodies.append(body)
            }
        }
        let json = #"{"ok":true,"data":{"items":\#(syncItemsJSON),"total":0}}"#
        return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestBodies() -> [[String: Any]] {
        lock.withLock { capturedBodies }
    }
}

final class SystemInboxReadHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            paths.append(path)
        }
        switch path {
        case "/api/tenant/inbox/system/read":
            let json = #"{"ok":true,"data":{"items":[]}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        case "/api/tenant/inbox":
            let json = """
            {
              "ok": true,
              "data": {
                "items": [
                  {
                    "id": "system-2",
                    "kind": "system",
                    "title": "通知二",
                    "summary": "内容二",
                    "created_at": "2026-06-28T03:01:00Z"
                  },
                  {
                    "id": "system-1",
                    "kind": "system",
                    "title": "通知一",
                    "summary": "内容一",
                    "created_at": "2026-06-28T03:00:00Z"
                  }
                ]
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        case "/api/im/read-ack":
            let json = #"{"ok":false,"error":{"code":"read_ack_unavailable","message":"read ack unavailable"}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        case "/api/im/conversations/sync":
            let json = #"{"ok":false,"error":{"code":"snapshot_unavailable","message":"snapshot unavailable"}}"#
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestPaths() -> [String] {
        lock.withLock { paths }
    }
}

actor FirstReadAckSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func resumeFirst() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

final class ReadAckCoalescingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstRequestGate: FirstReadAckSuspensionGate
    private let failSecondRequest: Bool
    private var sequences: [Int64] = []

    init(firstRequestGate: FirstReadAckSuspensionGate, failSecondRequest: Bool = false) {
        self.firstRequestGate = firstRequestGate
        self.failSecondRequest = failSecondRequest
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/read-ack",
              let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let number = body["channel_seq"] as? NSNumber else {
            throw URLError(.unsupportedURL)
        }
        let sequence = number.int64Value
        let requestIndex = lock.withLock { () -> Int in
            sequences.append(sequence)
            return sequences.count
        }
        if requestIndex == 1 {
            await firstRequestGate.wait()
        }
        if requestIndex == 2, failSecondRequest {
            return HTTPTransportResult(
                data: Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\"}}".utf8),
                isHTTPResponse: true,
                statusCode: 500
            )
        }
        let json = """
        {"ok":true,"data":{"channel_id":"read-convergence-group","channel_type":"group","last_read_seq":\(sequence),"read_receipts":[]}}
        """
        return HTTPTransportResult(
            data: Data(json.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestedSequences() -> [Int64] {
        lock.withLock { sequences }
    }
}

final class LifecycleReadAckHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let suspendedRequestNumber: Int
    private let gate: FirstReadAckSuspensionGate
    private var sequences: [Int64] = []

    init(suspendedRequestNumber: Int, gate: FirstReadAckSuspensionGate) {
        self.suspendedRequestNumber = suspendedRequestNumber
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/read-ack",
              let bodyData = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let number = body["channel_seq"] as? NSNumber else {
            throw URLError(.unsupportedURL)
        }
        let requestNumber = lock.withLock { () -> Int in
            sequences.append(number.int64Value)
            return sequences.count
        }
        if requestNumber == suspendedRequestNumber {
            await gate.wait()
        }
        return HTTPTransportResult(
            data: Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\"}}".utf8),
            isHTTPResponse: true,
            statusCode: 500
        )
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestCount() -> Int {
        lock.withLock { sequences.count }
    }
}

final class EnterpriseProfileRefreshHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let tenantContextRole: String?
    private let workspaceItemsJSON: String
    private let tenantContextDevicePolicyJSON: String?

    init(
        tenantContextRole: String? = nil,
        workspaceItemsJSON: String? = nil,
        tenantContextDevicePolicyJSON: String? = nil
    ) {
        self.tenantContextRole = tenantContextRole
        self.tenantContextDevicePolicyJSON = tenantContextDevicePolicyJSON
        self.workspaceItemsJSON = workspaceItemsJSON ?? """
                  {
                    "id": "tenant-1",
                    "tenantCode": "WXT000001",
                    "tenantName": "后台改名企业",
                    "status": "enabled",
                    "join_status": "joined",
                    "member_status": "normal",
                    "member_role": "member",
                    "can_switch": true,
                    "enterable": true,
                    "current": true,
                    "logo_url": "/api/tenant/avatar/logo-v1.png",
                    "logo_status": "ready",
                    "logo_cache_key": "logo-v1"
                  }
        """
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            paths.append(path)
        }
        let json: String
        switch path {
        case "/api/platform/apps/current-policy":
            json = """
            {
              "ok": true,
              "data": {
                "app_id": "jht-ios-main",
                "platform": "ios",
                "status": "enabled",
                "allow_workspace_switch": true,
                "allow_default_tenant_join": true,
                "require_real_name": false,
                "require_phone_verification": false,
                "cache_ttl_seconds": 60
              }
            }
            """
        case "/api/tenant/workspaces":
            json = """
            {
              "ok": true,
              "data": {
                "items": [
                  \(workspaceItemsJSON)
                ]
              }
            }
            """
        case "/api/tenant/context":
            guard let tenantContextRole else {
                throw URLError(.unsupportedURL)
            }
            let devicePolicyField = tenantContextDevicePolicyJSON.map { ",\"device\":\($0)" } ?? ""
            json = """
            {
              "ok": true,
              "data": {
                "tenant_id": "tenant-1",
                "im_uid": "uid-1",
                "app_id": "\(IMAPIContext.canonicalIOSAppID)",
                "device_id": "unit-test-device",
                "tenant": {
                  "id": "tenant-1",
                  "tenantCode": "WXT000001",
                  "tenantName": "后台改名企业",
                  "status": "enabled",
                  "logo_url": "/api/tenant/avatar/logo-v2.png",
                  "logo_status": "ready",
                  "logo_version": "logo-v2",
                  "logo_cache_key": "logo-v2"
                },
                "user": {
                  "im_uid": "uid-1",
                  "user_id": "WXTNS000100",
                  "username": "admin22",
                  "nickname": "年明然",
                  "status": "normal",
                  "role": "\(tenantContextRole)"
                },
                "tenant_policy": {
                  "group": {
                    "allow_member_group_creation": false
                  }\(devicePolicyField)
                }
              }
            }
            """
        case "/api/tenant/profile":
            json = """
            {
              "ok": true,
              "data": {
                "id": "tenant-1",
                "tenantCode": "WXT000001",
                "tenantName": "旧企业",
                "status": "enabled",
                "logo_url": "/api/tenant/avatar/logo-v2.png",
                "logo_status": "ready",
                "logo_version": "logo-v2",
                "logo_updated_at": "2026-06-27T10:00:00Z",
                "logo_cache_key": "logo-v2"
              }
            }
            """
        default:
            throw URLError(.unsupportedURL)
        }
        return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestPaths() -> [String] {
        lock.withLock { paths }
    }
}

final class TenantDevicePolicyRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstTenantContextGate: FirstReadAckSuspensionGate
    private var tenantContextRequestCount = 0

    init(firstTenantContextGate: FirstReadAckSuspensionGate) {
        self.firstTenantContextGate = firstTenantContextGate
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        switch path {
        case "/api/tenant/workspaces":
            return result(#"{"ok":true,"data":{"items":[]}}"#)
        case "/api/tenant/profile":
            return result(#"{"ok":true,"data":{"id":"tenant-1","tenantCode":"WXT000001","tenantName":"Tenant","status":"enabled"}}"#)
        case "/api/tenant/context":
            let requestIndex = lock.withLock { () -> Int in
                tenantContextRequestCount += 1
                return tenantContextRequestCount
            }
            if requestIndex == 1 {
                await firstTenantContextGate.wait()
            }
            let enabled = requestIndex == 1 ? "false" : "true"
            return result("""
            {
              "ok": true,
              "data": {
                "tenant_id": "tenant-1",
                "im_uid": "uid-1",
                "app_id": "\(IMAPIContext.canonicalIOSAppID)",
                "device_id": "unit-test-device",
                "tenant": {"id":"tenant-1","tenantCode":"WXT000001","tenantName":"Tenant","status":"enabled"},
                "tenant_policy": {
                  "device": {
                    "multi_device_enabled": \(enabled),
                    "authoritative": true,
                    "contract_version": 1
                  }
                }
              }
            }
            """)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func tenantContextRequests() -> Int {
        lock.withLock { tenantContextRequestCount }
    }

    private func result(_ json: String) -> HTTPTransportResult {
        HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
    }
}

@MainActor
final class DeviceKickRealtimeTransport: RealtimeTransporting {
    struct Subscription {
        let channelID: String
        let tenantID: String
        let imUID: String
    }
    private(set) var subscriptions: [Subscription] = []
    func resetSubscriptions() { subscriptions.removeAll() }
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)?
    private(set) var disconnectCalls: [Bool] = []
    private(set) var isConnected = true

    func start(url: URL, token: String) {
        isConnected = true
    }

    func disconnect(shouldReconnect: Bool) {
        disconnectCalls.append(shouldReconnect)
        isConnected = false
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {
        subscriptions.append(Subscription(channelID: channelID, tenantID: tenantID, imUID: imUID))
    }
}

final class StickerPanelHydrationHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedPaths: [String] = []

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            capturedPaths.append(path)
        }
        if path == "/api/tenant/files/file-cached" {
            let json = """
            {
              "ok": true,
              "data": {
                "file": {
                  "id": "file-cached",
                  "file_name": "cached-sticker.gif",
                  "mime_type": "image/gif",
                  "size_bytes": 4096,
                  "status": "uploaded",
                  "cache_key": "cache-cached",
                  "version": "v1",
                  "checksum": "checksum-cached",
                  "thumbnail_url": "https://cdn.example.test/file-cached-thumb.gif?sig=unit",
                  "width": 128,
                  "height": 128,
                  "duration_ms": 600
                },
                "preview_available": true,
                "download_available": true,
                "preview_url": "https://cdn.example.test/file-cached-preview.gif?sig=unit",
                "download_url": "https://cdn.example.test/file-cached.gif?sig=unit"
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 200)
        }
        if path == "/api/tenant/user-stickers" {
            let json = """
            {
              "ok": false,
              "error": {
                "code": "temporarily_unavailable",
                "message": "temporarily unavailable"
              }
            }
            """
            return HTTPTransportResult(data: Data(json.utf8), isHTTPResponse: true, statusCode: 503)
        }
        throw URLError(.unsupportedURL)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func paths() -> [String] {
        lock.withLock { capturedPaths }
    }
}

final class TestVoiceCallSystemIntegration: VoiceCallSystemIntegrating, @unchecked Sendable {
    private let continuation: AsyncStream<VoiceCallSystemEvent>.Continuation
    private var presentedCallIDs: Set<String>
    private(set) var started = false
    private(set) var endedCalls: [(callID: String, reason: String)] = []
    private(set) var reportedPayloads: [RTCVoIPPushPayload] = []
    let events: AsyncStream<VoiceCallSystemEvent>

    init(presentedCallIDs: Set<String> = []) {
        self.presentedCallIDs = presentedCallIDs
        var streamContinuation: AsyncStream<VoiceCallSystemEvent>.Continuation!
        events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func start() {
        started = true
    }

    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool {
        reportedPayloads.append(payload)
        presentedCallIDs.insert(payload.callID)
        return true
    }

    func endCall(callID: String, reason: String) {
        endedCalls.append((callID: callID, reason: reason))
        presentedCallIDs.remove(callID)
    }

    func setMuted(callID: String, isMuted: Bool) {}

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN
    private(set) var requestedAnswers: [String] = []
    var answerRequestError: Error?
    var onAnswerRequest: (@MainActor (String) -> Void)?
    func answerPresentedCall(callID: String) async throws {
        requestedAnswers.append(callID)
        if let answerRequestError { throw answerRequestError }
        if let onAnswerRequest { await onAnswerRequest(callID) }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END

    func hasPresentedCall(callID: String) -> Bool {
        presentedCallIDs.contains(callID)
    }

    func clearPresentedCall(callID: String) {
        presentedCallIDs.remove(callID)
    }

    func emit(_ event: VoiceCallSystemEvent) {
        continuation.yield(event)
    }
}
