import AVFoundation
import Foundation
import IM4Domain
import IM4Stores // WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

typealias RTCVideoMediaEvent = IM4Domain.RTCVideoMediaEvent

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
struct RTCVideoSignalHTTPError: Error, RTCSignalHTTPFailureRepresenting, Sendable, Equatable, LocalizedError {
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
    let statusCode: Int
    let code: String
    let message: String

    var errorDescription: String? { message }
}

enum RTCVideoSignalFailurePolicy {
    private static func normalizedCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    static func isAuthoritativeTerminal(_ error: Error) -> Bool {
        guard let error = error as? RTCVideoSignalHTTPError else { return false }
        let code = normalizedCode(error.code)
        return (error.statusCode == 409 && code == "rtc_call_not_active")
            || (error.statusCode == 404 && code == "rtc_call_not_found")
    }

    static func shouldDropBestEffort(kind: RemoteRTCSignalKind, after error: Error) -> Bool {
        guard kind == .mediaState,
              let error = error as? RTCVideoSignalHTTPError else {
            return false
        }
        return error.statusCode == 422
            && normalizedCode(error.code) == "rtc_signal_payload_invalid"
    }
}

enum RTCVideoSignalPollingFailurePolicy {
    static func isLongPollTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    static func shouldEmitReconnecting(after error: Error, iceConnected: Bool) -> Bool {
        !(iceConnected && isLongPollTimeout(error))
    }
}

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
enum RTCVideoSignalPollingBackoffPolicy {
    static let failureDelayNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000,
        30_000_000_000
    ]
    static let quickEmptyMinimumDelayNanoseconds: UInt64 = 1_000_000_000

    static func delayNanoseconds(afterFailureCount failureCount: Int, stableKey: String) -> UInt64 {
        guard !failureDelayNanoseconds.isEmpty else { return 0 }
        let index = min(max(failureCount, 1) - 1, failureDelayNanoseconds.count - 1)
        let baseDelay = failureDelayNanoseconds[index]
        guard baseDelay > 0 else { return 0 }
        let jitterWindow = max(baseDelay / 5, 1)
        return addingClamped(baseDelay, deterministicJitterNanoseconds(stableKey: stableKey, modulo: jitterWindow))
    }

    static func shouldDelayQuickEmptyPage(
        itemCount: Int,
        previousCursor: String,
        nextCursor: String,
        elapsedNanoseconds: UInt64
    ) -> Bool {
        itemCount == 0
            && (nextCursor.isEmpty || nextCursor == previousCursor)
            && elapsedNanoseconds < quickEmptyMinimumDelayNanoseconds
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }

    private static func deterministicJitterNanoseconds(stableKey: String, modulo: UInt64) -> UInt64 {
        guard modulo > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash % modulo
    }
}

struct RTCVideoSignalPollingBackoffState {
    private(set) var failureCount = 0

    mutating func reset() {
        failureCount = 0
    }

    mutating func recordFailureAndDelayNanoseconds(stableKey: String) -> UInt64 {
        failureCount += 1
        return RTCVideoSignalPollingBackoffPolicy.delayNanoseconds(
            afterFailureCount: failureCount,
            stableKey: stableKey
        )
    }
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

enum RTCVideoMediaStatePayload {
    static func make(
        cameraEnabled: Bool? = nil,
        microphoneEnabled: Bool? = nil,
        mediaMode: String
    ) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "media_mode": .string(mediaMode)
        ]
        if let cameraEnabled {
            payload["camera_enabled"] = .bool(cameraEnabled)
        }
        if let microphoneEnabled {
            payload["microphone_enabled"] = .bool(microphoneEnabled)
        }
        return payload
    }
}

enum RTCVideoSignalLongPollPolicy {
    static let maximumWaitMS = 25_000
    static let timeoutSafetyMarginSeconds: TimeInterval = 5

    static func normalizedWaitMS(_ waitMS: Int) -> Int {
        min(max(waitMS, 0), maximumWaitMS)
    }

    static func requestTimeout(waitMS: Int) -> TimeInterval {
        let waitSeconds = TimeInterval(normalizedWaitMS(waitMS)) / 1_000
        return waitSeconds + timeoutSafetyMarginSeconds
    }
}

struct RTCVideoCapturePolicy {
    static func shouldCapture(cameraEnabledIntent: Bool, isApplicationBackgrounded: Bool) -> Bool {
        cameraEnabledIntent && !isApplicationBackgrounded
    }
}

struct RTCVideoCameraFailurePolicy {
    static func resolvedIntent(requestedEnabled: Bool, previousIntent: Bool) -> Bool {
        requestedEnabled ? previousIntent : false
    }
}

struct RTCIncomingVideoAnswerPlan: Sendable, Equatable {
    let acceptedMode: String
    let startsVideoMedia: Bool
    let cameraEnabled: Bool
    let notice: String?

    static func resolve(
        requestedMode: String,
        cameraAvailable: Bool,
        cameraAuthorized: Bool
    ) -> RTCIncomingVideoAnswerPlan {
        let wantsVideo = requestedMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
        guard wantsVideo else {
            return RTCIncomingVideoAnswerPlan(
                acceptedMode: "audio",
                startsVideoMedia: false,
                cameraEnabled: false,
                notice: nil
            )
        }
        let cameraEnabled = cameraAvailable && cameraAuthorized
        let notice: String?
        if !cameraAvailable {
            notice = "摄像头暂不可用，已关闭摄像头继续视频通话"
        } else if !cameraAuthorized {
            notice = "摄像头权限未开启，已关闭摄像头继续视频通话"
        } else {
            notice = nil
        }
        return RTCIncomingVideoAnswerPlan(
            acceptedMode: "video",
            startsVideoMedia: true,
            cameraEnabled: cameraEnabled,
            notice: notice
        )
    }
}

typealias RTCVideoConnectionGate = IM4Stores.RTCVideoConnectionGate

struct RTCVideoSignalRuntimeState: Sendable, Equatable {
    private(set) var rtcToken: String
    private(set) var generation = 0
    private(set) var cursor = ""
    private(set) var receivedMessageIDs: Set<String> = []

    init(rtcToken: String) {
        self.rtcToken = rtcToken
    }

    mutating func rebindToken(_ token: String) {
        rtcToken = token
        generation &+= 1
    }

    mutating func stageTokenRebind(_ token: String) {
        rtcToken = token
    }

    mutating func invalidatePolling() {
        generation &+= 1
    }

    func isCurrent(generation: Int) -> Bool {
        self.generation == generation
    }

    func hasProcessed(_ messageID: String) -> Bool {
        !messageID.isEmpty && receivedMessageIDs.contains(messageID)
    }

    mutating func markProcessed(_ messageID: String) {
        if !messageID.isEmpty {
            receivedMessageIDs.insert(messageID)
        }
    }

    mutating func commitCursor(_ cursor: String) {
        self.cursor = cursor
    }
}

struct RTCVideoInBandCredentialRefreshState: Sendable, Equatable {
    private(set) var isPending = false
    private(set) var requiredAcknowledgedCursor = ""

    mutating func request() {
        isPending = true
    }

    mutating func requireAcknowledgement(of cursor: String) {
        guard isPending else { return }
        let normalized = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            requiredAcknowledgedCursor = normalized
        }
    }

    mutating func completeAfterAcknowledgement(
        acknowledgedCursor: String,
        didAcknowledgeAndCommit: Bool
    ) -> Bool {
        let normalized = acknowledgedCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPending,
              didAcknowledgeAndCommit,
              !requiredAcknowledgedCursor.isEmpty,
              normalized == requiredAcknowledgedCursor else {
            return false
        }
        isPending = false
        requiredAcknowledgedCursor = ""
        return true
    }

    mutating func reset() {
        isPending = false
        requiredAcknowledgedCursor = ""
    }
}

enum RTCVideoCredentialRefreshAction: Sendable, Equatable {
    case refreshAndNegotiate
    case retryNegotiation
    case rejectOutOfBand

    static func resolve(inBandRequest: Bool, inBandRefreshPending: Bool) -> Self {
        if inBandRequest {
            return inBandRefreshPending ? .retryNegotiation : .refreshAndNegotiate
        }
        return inBandRefreshPending ? .rejectOutOfBand : .refreshAndNegotiate
    }
}

struct RTCVideoCredentialRefreshSnapshot: Sendable, Equatable {
    let sessionEpoch: Int
    let callID: String
    let roomID: String
    let rtcToken: String

    func matches(
        sessionEpoch: Int,
        callID: String,
        roomID: String,
        rtcToken: String
    ) -> Bool {
        self.sessionEpoch == sessionEpoch
            && self.callID == callID
            && self.roomID == roomID
            && self.rtcToken == rtcToken
    }
}

enum RTCVideoSignalBatchProcessor {
    @MainActor
    static func process(
        _ items: [RemoteRTCSignalItem],
        state: inout RTCVideoSignalRuntimeState,
        generation: Int,
        handle: @MainActor (RemoteRTCSignalItem) async throws -> Void
    ) async throws {
        for item in items {
            try Task.checkCancellation()
            guard state.isCurrent(generation: generation) else {
                throw CancellationError()
            }
            if state.hasProcessed(item.messageID) {
                continue
            }
            try await handle(item)
            guard state.isCurrent(generation: generation) else {
                throw CancellationError()
            }
            state.markProcessed(item.messageID)
        }
    }
}

enum RTCVideoSignalOutboxError: Error, Equatable {
    case capacityExceeded
}

struct RTCVideoSignalOutbox: Sendable, Equatable {
    let capacity: Int
    private(set) var pending: [RemoteRTCSignalEnvelope] = []

    init(capacity: Int = 512) {
        self.capacity = max(capacity, 1)
    }

    mutating func enqueue(_ envelope: RemoteRTCSignalEnvelope) throws {
        if pending.contains(where: { $0.messageID == envelope.messageID }) {
            return
        }
        if envelope.kind == .mediaState,
           let existingIndex = pending.firstIndex(where: { $0.kind == .mediaState }) {
            pending[existingIndex] = envelope
            return
        }
        if envelope.kind != .mediaState {
            // media_state is best-effort and its lower sequence becomes stale
            // once a later SDP/ICE envelope is sent. Discard it instead of
            // reordering sequence numbers or poisoning critical signaling.
            pending.removeAll { $0.kind == .mediaState }
        }
        if pending.count >= capacity {
            throw RTCVideoSignalOutboxError.capacityExceeded
        }
        pending.append(envelope)
    }

    mutating func markDelivered(messageID: String) {
        pending.removeAll { $0.messageID == messageID }
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
    }
}

enum RTCVideoCredentialSchedule {
    static func delay(
        refreshAfter: String,
        expiresAt: String,
        now: Date = Date()
    ) -> TimeInterval? {
        let formatter = ISO8601DateFormatter()
        if let refreshDate = formatter.date(from: refreshAfter) {
            return max(1, refreshDate.timeIntervalSince(now))
        }
        if let expiryDate = formatter.date(from: expiresAt) {
            return max(1, expiryDate.timeIntervalSince(now) - 300)
        }
        return nil
    }
}

enum RTCVideoICERestartAction: Equatable {
    case restartAndOffer
    case requestCallerRestart
}

enum RTCVideoICERestartPolicy {
    static func action(isCaller: Bool) -> RTCVideoICERestartAction {
        isCaller ? .restartAndOffer : .requestCallerRestart
    }
}

enum RTCQualityTokenScope {
    static let writeScope = "rtc:quality:write"

    static func hasWriteScope(_ token: String) -> Bool {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let payload = base64URLData(String(components[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let scopes = object["scopes"] as? [String] else {
            return false
        }
        return scopes.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == writeScope
        }
    }

    private static func base64URLData(_ raw: String) -> Data? {
        var normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: normalized)
    }
}
