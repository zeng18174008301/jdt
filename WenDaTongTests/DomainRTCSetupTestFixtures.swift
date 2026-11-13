import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

final class BatchForwardLifecycleHTTPTransport: HTTPTransport, @unchecked Sendable {
    enum Behavior {
        case waitForCancellation
        case returnCommittedAfterCancellation
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var startedForwardRequest = false
    private var observedCancellation = false
    private var returnedForwardResponse = false

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var didStartForwardRequest: Bool {
        lock.withLock { startedForwardRequest }
    }

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    var didReturnForwardResponse: Bool {
        lock.withLock { returnedForwardResponse }
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/im/messages/forward-batch" else {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        }
        lock.withLock {
            startedForwardRequest = true
        }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            lock.withLock {
                observedCancellation = true
            }
            if case .waitForCancellation = behavior {
                throw CancellationError()
            }
        }
        let response = try committedResponse(for: request)
        lock.withLock {
            returnedForwardResponse = true
        }
        return response
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    private func committedResponse(for request: URLRequest) throws -> HTTPTransportResult {
        let bodyData = request.httpBody ?? Data()
        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        let clientBatchID = body["client_batch_id"] as? String ?? ""
        let sourceIDs = body["source_message_ids"] as? [String] ?? []
        let targets = body["targets"] as? [[String: Any]] ?? []
        let targetResults = targets.enumerated().map { targetOrdinal, target -> [String: Any] in
            [
                "target_ordinal": targetOrdinal,
                "channel_id": target["channel_id"] as? String ?? "",
                "channel_type": target["channel_type"] as? String ?? "",
                "messages": sourceIDs.enumerated().map { sourceOrdinal, sourceID in
                    [
                        "source_ordinal": sourceOrdinal,
                        "source_message_id": sourceID,
                        "message_id": "created-\(targetOrdinal)-\(sourceOrdinal)"
                    ] as [String: Any]
                }
            ]
        }
        let payload: [String: Any] = [
            "ok": true,
            "data": [
                "contract_version": 1,
                "batch_id": "late-batch",
                "client_batch_id": clientBatchID,
                "source_count": sourceIDs.count,
                "target_count": targets.count,
                "created_count": sourceIDs.count * targets.count,
                "state": "committed",
                "idempotent_replay": false,
                "authoritative_source_message_ids": sourceIDs,
                "targets": targetResults
            ]
        ]
        return HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: payload),
            isHTTPResponse: true,
            statusCode: 201
        )
    }
}

final class VideoCallStartHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let outgoingPolicyFixture: Bool
    private let fileConfigDelayNanoseconds: UInt64
    private let providerStatusCode: Int
    private let fileConfigStatusCode: Int
    private let providerErrorCode: String
    private let voiceEnabled: Bool
    private let fileConfigDecision: SuspendedBoolDecision?
    private let providerOmitsLicense: Bool
    private let providerNetworkFailure: Bool
    private let providerVideoEnabled: Bool
    private let incomingVideoJoinDecision: SuspendedBoolDecision?
    private var pathCounts: [String: Int] = [:]

    init(
        fileConfigDelayNanoseconds: UInt64,
        providerStatusCode: Int,
        incomingVideoJoinDecision: SuspendedBoolDecision? = nil,
        voiceEnabled: Bool = true,
        providerErrorCode: String = "rtc_provider_unavailable",
        fileConfigStatusCode: Int = 200,
        fileConfigDecision: SuspendedBoolDecision? = nil,
        providerOmitsLicense: Bool = false,
        providerNetworkFailure: Bool = false,
        providerVideoEnabled: Bool = true,
        outgoingPolicyFixture: Bool = false
    ) {
        self.outgoingPolicyFixture = outgoingPolicyFixture
        self.fileConfigDelayNanoseconds = fileConfigDelayNanoseconds
        self.providerStatusCode = providerStatusCode
        self.fileConfigStatusCode = fileConfigStatusCode
        self.providerErrorCode = providerErrorCode
        self.voiceEnabled = voiceEnabled
        self.fileConfigDecision = fileConfigDecision
        self.providerOmitsLicense = providerOmitsLicense
        self.providerNetworkFailure = providerNetworkFailure
        self.providerVideoEnabled = providerVideoEnabled
        self.incomingVideoJoinDecision = incomingVideoJoinDecision
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            pathCounts[path, default: 0] += 1
        }
        if outgoingPolicyFixture {
            if path == "/api/rtc/calls", request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let mode = body?["call_type"] as? String ?? "audio"
                return jsonResult(for: request, statusCode: 200, body: """
                {"ok":true,"data":{"call":{"id":"policy-call","room_id":"policy-room","status":"ringing","call_type":"\(mode)","caller_uid":"uid-1","callee_uid":"policy-peer","state_version":1},"rtc_token":"policy-test-token"}}
                """)
            }
            if path == "/api/rtc/rooms/policy-room/join" {
                return jsonResult(for: request, statusCode: 409, body: #"{"ok":false,"error":{"code":"rtc_transport_policy_pending","message":"pending"}}"#)
            }
            if path == "/api/rtc/device-capabilities" || path == "/api/rtc/calls/policy-call/cancel" {
                return jsonResult(for: request, statusCode: 200, body: #"{"ok":true,"data":{}}"#)
            }
        }
        switch path {
        case "/api/tenant/files/config":
            _ = await fileConfigDecision?.wait()
            if fileConfigDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: fileConfigDelayNanoseconds)
            }
            if fileConfigStatusCode != 200 {
                return jsonResult(for: request, statusCode: fileConfigStatusCode, body: #"{"ok":false,"error":{"code":"rtc_license_capabilities_unavailable","message":"redacted"}}"#)
            }
            return jsonResult(for: request, statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "file_upload_max_bytes": 20971520,
                    "max_mb": 20,
                    "source": "test",
                    "message_recall_max_minutes": 120,
                    "voice_call_enabled": \(voiceEnabled),
                    "video_call_enabled": true,
                    "read_receipts_enabled": true,
                    "group_admin_delete_message_enabled": false
                  }
                }
                """
            )
        case "/api/rtc/provider":
            if providerNetworkFailure { throw URLError(.notConnectedToInternet) }
            if providerStatusCode == 200 {
                let licenseFields = providerOmitsLicense ? "" : "\"voice_call_enabled\":\(voiceEnabled),\"video_call_enabled\":\(providerVideoEnabled),"
                let policyField = outgoingPolicyFixture ? "\"ice_transport_policy_version\":1," : ""
                return jsonResult(for: request, statusCode: 200,
                    body: """
                    {
                      "ok": true,
                      "data": {
                        "call_types": ["audio", "video"],
                        \(licenseFields)
                        "video_supported": true,
                        "capabilities_version": "video-call-v1",
                        \(policyField)
                        "media_plane_configured": true,
                        "ice_servers_configured": true
                      }
                    }
                    """
                )
            }
            return jsonResult(for: request, statusCode: providerStatusCode,
                body: """
                {
                  "ok": false,
                  "error": {
                    "code": "\(providerErrorCode)",
                    "message": "测试视频服务暂不可用"
                  }
                }
                """
            )
        case "/api/rtc/device-capabilities":
            return jsonResult(for: request, statusCode: 200, body: #"{"ok":true,"data":{}}"#)
        case "/api/rtc/calls/incoming-video-after-accept/accept":
            return jsonResult(for: request, statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "call": {
                      "id": "incoming-video-after-accept",
                      "room_id": "incoming-video-room",
                      "status": "accepted",
                      "call_type": "video",
                      "requested_media_mode": "video",
                      "media_mode": "audio",
                      "caller_uid": "incoming-video-peer",
                      "callee_uid": "uid-1"
                    },
                    "rtc_token": "incoming-video-token"
                  }
                }
                """
            )
        case "/api/rtc/rooms/incoming-video-room/join":
            _ = await incomingVideoJoinDecision?.wait()
            return jsonResult(for: request, statusCode: 200,
                body: """
                {
                  "ok": true,
                  "data": {
                    "room_id": "incoming-video-room",
                    "rtc_token": "incoming-video-token",
                    "media": {
                      "owt_base_url": "https://rtc.example.test",
                      "ice_servers": []
                    },
                    "participants": []
                  }
                }
                """
            )
        case "/api/rtc/calls/incoming-video-after-accept/hangup":
            return jsonResult(for: request, statusCode: 200,
                body: """
                {"ok":true,"data":{}}
                """
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
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func callsAcceptancePathCounts() -> [String: Int] {
        lock.withLock { pathCounts }
    }

    func requestCount(path: String) -> Int {
        lock.withLock { pathCounts[path, default: 0] }
    }

    private func jsonResult(for request: URLRequest, statusCode: Int, body: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: statusCode,
            responseURL: request.url
        )
    }
}

actor SuspendedBoolDecision {
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting() -> Bool {
        continuation != nil
    }

    func resume(returning value: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

actor FirstJoinSuspensionGate {
    private var joinCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func passOrSuspendFirst() async {
        joinCount += 1
        guard joinCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func isWaiting() -> Bool {
        firstContinuation != nil
    }

    func resumeFirst() {
        let pending = firstContinuation
        firstContinuation = nil
        pending?.resume()
    }
}

actor SequencedBoolDecision {
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next(default fallback: Bool = false) -> Bool {
        guard !values.isEmpty else { return fallback }
        return values.removeFirst()
    }
}

// WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: provider and file config keep the same independently selectable voice license.
// WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: faithful response origins/capabilities and deterministic async boundaries.
final class IncomingSameCallOwnershipHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let voiceEnabled: Bool
    private let callID: String
    private let callType: String
    private let peerUID: String
    private let acceptGate: FirstJoinSuspensionGate?
    private let firstJoinGate: FirstJoinSuspensionGate
    private let providerSuccessLimit: Int?
    private let gateStage: String
    private let acceptedMediaMode: String
    private let failJoin: Bool
    private let hangupFailures: Int
    private var mutationKeys: [String: [String]] = [:]
    private var pathCounts: [String: Int] = [:]
    private var authorizationHeaders: [String: [String]] = [:]

    init(
        callID: String,
        callType: String,
        peerUID: String,
        firstJoinGate: FirstJoinSuspensionGate,
        acceptGate: FirstJoinSuspensionGate? = nil,
        providerSuccessLimit: Int? = nil,
        gateStage: String = "join",
        acceptedMediaMode: String = "audio",
        failJoin: Bool = false,
        hangupFailures: Int = 0,
        voiceEnabled: Bool = true
    ) {
        self.voiceEnabled = voiceEnabled
        self.callID = callID
        self.callType = callType
        self.peerUID = peerUID
        self.acceptGate = acceptGate
        self.firstJoinGate = firstJoinGate
        self.providerSuccessLimit = providerSuccessLimit
        self.gateStage = gateStage
        self.acceptedMediaMode = acceptedMediaMode
        self.failJoin = failJoin
        self.hangupFailures = hangupFailures
    }

    func data(
        for request: URLRequest,
        rejectingCrossOriginRedirectsFrom expectedOrigin: URL
    ) async throws -> HTTPTransportResult {
        try await data(for: request).resolvingResponseURL(request.url)
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock {
            pathCounts[path, default: 0] += 1
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let key = json["idempotency_key"] as? String {
                mutationKeys[path, default: []].append(key)
            }
            if let authorization = request.value(forHTTPHeaderField: "Authorization") {
                authorizationHeaders[path, default: []].append(authorization)
            }
        }
        switch path {
        case "/api/tenant/files/config":
            if gateStage == "files" { await firstJoinGate.passOrSuspendFirst() }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "file_upload_max_bytes":20971520,
                  "max_mb":20,
                  "source":"test",
                  "message_recall_max_minutes":120,
                  "voice_call_enabled":\(voiceEnabled),
                  "video_call_enabled":true,
                  "read_receipts_enabled":true,
                  "group_admin_delete_message_enabled":false
                }}
                """
            )
        case "/api/rtc/provider":
            if gateStage == "provider" { await firstJoinGate.passOrSuspendFirst() }
            if let providerSuccessLimit,
               requestCount(path: path) > providerSuccessLimit {
                return jsonResult(
                    """
                    {"ok":false,"error":{
                      "code":"rtc_provider_unavailable",
                      "message":"replacement provider denied"
                    }}
                    """,
                    statusCode: 503
                )
            }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "call_types":["audio","video"],
                  "voice_call_enabled":\(voiceEnabled),
                  "video_call_enabled":true,
                  "capabilities_version":"video-call-v1",
                  "video_supported":true,
                  "media_plane_configured":true,
                  "ice_servers_configured":true
                }}
                """
            )
        case "/api/rtc/calls/\(callID)/accept":
            if let acceptGate { await acceptGate.passOrSuspendFirst() }
            let requestedMode = callType == "video" ? "video" : "audio"
            return jsonResult(
                """
                {"ok":true,"data":{
                  "call":{
                    "id":"\(callID)",
                    "room_id":"\(callID)-room",
                    "status":"accepted",
                    "call_type":"\(callType)",
                    "requested_media_mode":"\(requestedMode)",
                    "media_mode":"\(acceptedMediaMode)",
                    "caller_uid":"\(peerUID)",
                    "callee_uid":"uid-1",
                    "caller_device":{
                      "uid":"\(peerUID)",
                      "device_id":"peer-device",
                      "device_type":"web"
                    },
                    "callee_device":{
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios"
                    },
                    "accepted_device":{
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios"
                    }
                  },
                  "rtc_token":"\(callID)-token"
                }}
                """
            )
        case "/api/rtc/rooms/\(callID)-room/join":
            if gateStage == "join" { await firstJoinGate.passOrSuspendFirst() }
            if failJoin { throw URLError(.cannotConnectToHost) }
            if gateStage == "participants" {
                return jsonResult("""
                {"ok":true,"data":{
                  "room_id":"\(callID)-room","rtc_token":"\(callID)-token",
                  "media":{"owt_base_url":"https://rtc.example.test","ice_servers":[]},
                  "self_participant":{"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"},
                  "participants":[{"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"}]
                }}
                """)
            }
            return jsonResult(
                """
                {"ok":true,"data":{
                  "room_id":"\(callID)-room",
                  "rtc_token":"\(callID)-token",
                  "media":{
                    "owt_base_url":"https://rtc.example.test",
                    "ice_servers":[]
                  },
                  "self_participant":{
                    "uid":"uid-1",
                    "device_id":"unit-test-device",
                    "device_type":"ios",
                    "role":"self"
                  },
                  "peer_participant":{
                    "uid":"\(peerUID)",
                    "device_id":"peer-stale-device",
                    "device_type":"web",
                    "role":"peer"
                  },
                  "participants":[
                    {
                      "uid":"uid-1",
                      "device_id":"unit-test-device",
                      "device_type":"ios",
                      "role":"self"
                    },
                    {
                      "uid":"\(peerUID)",
                      "device_id":"peer-stale-device",
                      "device_type":"web",
                      "role":"peer"
                    },
                    {
                      "uid":"\(peerUID)",
                      "device_id":"peer-device",
                      "device_type":"web",
                      "role":"peer"
                    }
                  ]
                }}
                """
            )
        case "/api/rtc/rooms/\(callID)-room/participants":
            await firstJoinGate.passOrSuspendFirst()
            return jsonResult("""
            {"ok":true,"data":{"items":[
              {"uid":"uid-1","device_id":"unit-test-device","device_type":"ios","role":"self"},
              {"uid":"\(peerUID)","device_id":"peer-device","device_type":"web","role":"peer"}
            ]}}
            """)
        case "/api/rtc/rooms/\(callID)-room/signals":
            return jsonResult(#"{"ok":true,"data":{"items":[],"next_cursor":"next","has_more":false}}"#)
        case "/api/rtc/rooms/\(callID)-room/ice-credentials":
            return jsonResult(#"{"ok":true,"data":{"ice_servers":[],"rtc_token":"rtc-refreshed","ice_credential_expires_at":"","ice_credential_refresh_after":""}}"#)
        case "/api/rtc/calls/\(callID)/hangup", "/api/rtc/calls/\(callID)/downgrade":
            if path.hasSuffix("/hangup"), requestCount(path: path) <= hangupFailures {
                return jsonResult(#"{"ok":false,"error":{"code":"temporary_unavailable","message":"retry"}}"#, statusCode: 503)
            }
            return jsonResult(#"{"ok":true,"data":{}}"#)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func upload(
        for request: URLRequest,
        from data: Data,
        delegate: URLSessionTaskDelegate?
    ) async throws -> HTTPTransportResult {
        HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
    }

    func requestCount(path: String) -> Int {
        lock.withLock { pathCounts[path, default: 0] }
    }

    func idempotencyKeys(path: String) -> [String] {
        lock.withLock { mutationKeys[path] ?? [] }
    }

    func authorizationHeader(path: String) -> String? {
        lock.withLock { authorizationHeaders[path]?.last }
    }

    private func jsonResult(
        _ body: String,
        statusCode: Int = 200
    ) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(body.utf8),
            isHTTPResponse: true,
            statusCode: statusCode
        )
    }
}

// WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END
// WDT_IOS1_CALLKIT_ANSWER_20260921_END

final class RTCSystemEndHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var remainingFailuresByPath: [String: Int]
    private let failureDelayNanoseconds: UInt64
    private let fileConfigDecision: SuspendedBoolDecision?
    private let fileConfigLicenseFields: String?

    init(
        remainingFailuresByPath: [String: Int] = [:],
        failureDelayNanoseconds: UInt64 = 0,
        fileConfigDecision: SuspendedBoolDecision? = nil,
        fileConfigLicenseFields: String? = nil
    ) {
        self.remainingFailuresByPath = remainingFailuresByPath
        self.failureDelayNanoseconds = failureDelayNanoseconds
        self.fileConfigDecision = fileConfigDecision
        self.fileConfigLicenseFields = fileConfigLicenseFields
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock {
            capturedRequests.append(request)
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: same-origin provider responses must reach the suspended permission boundary.
        if request.httpMethod == "GET", request.url?.path == "/api/tenant/files/config",
           let fileConfigLicenseFields {
            let first = requestCount(path: "/api/tenant/files/config") == 1
            if first { _ = await fileConfigDecision?.wait() }
            return HTTPTransportResult(
                data: Data("{\"ok\":true,\"data\":{\(fileConfigLicenseFields)\"source\":\"test\",\"max_mb\":20}}".utf8),
                isHTTPResponse: true, statusCode: 200,
                responseURL: request.url
            )
        }
        if request.httpMethod == "GET", request.url?.path == "/api/rtc/provider", fileConfigLicenseFields != nil {
            return HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"voice_call_enabled":true,"video_call_enabled":true,"video_supported":true,"call_types":["audio","video"],"media_plane_configured":true,"ice_servers_configured":true}}"#.utf8),
                isHTTPResponse: true, statusCode: 200,
                responseURL: request.url
            )
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_END
        if request.httpMethod == "GET", request.url?.path == "/api/rtc/calls" {
            return HTTPTransportResult(
                data: Data(
                    #"{"ok":true,"data":{"calls":[{"id":"call-first","status":"ringing","room_id":"room-first","caller_uid":"friend-1","callee_uid":"uid-1","channel_id":"friend-1:uid-1","channel_type":"direct","call_type":"audio","state_version":1}]}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200,
                responseURL: request.url
            )
        }
        guard request.httpMethod == "POST",
              ["/reject", "/cancel", "/hangup", "/downgrade"].contains(where: {
                  request.url?.path.hasSuffix($0) == true
              }) else {
            throw URLError(.unsupportedURL)
        }
        let path = request.url?.path ?? ""
        let shouldFail = lock.withLock { () -> Bool in
            let remaining = remainingFailuresByPath[path] ?? 0
            guard remaining > 0 else { return false }
            remainingFailuresByPath[path] = remaining - 1
            return true
        }
        if shouldFail {
            if failureDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: failureDelayNanoseconds)
            }
            return HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"temporary_unavailable","message":"retry"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 503,
                responseURL: request.url
            )
        }
        return HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200,
            responseURL: request.url
        )
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

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    func idempotencyKeys(path: String) -> [String] {
        lock.withLock {
            capturedRequests
                .filter { $0.url?.path == path }
                .compactMap { request -> String? in
                    guard let body = request.httpBody,
                          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        return nil
                    }
                    return object["idempotency_key"] as? String
                }
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
}
