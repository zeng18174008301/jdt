import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

struct RTCPeerParticipantWaitPolicy: Sendable, Equatable {
    static let production = RTCPeerParticipantWaitPolicy(
        maximumAttempts: 60,
        pollIntervalNanoseconds: 250_000_000
    )

    let maximumAttempts: Int
    let pollIntervalNanoseconds: UInt64

    var maximumScheduledWaitNanoseconds: UInt64 {
        UInt64(max(0, maximumAttempts - 1)) * pollIntervalNanoseconds
    }
}

enum RTCPeerParticipantWaitError: Error, Equatable {
    case cancelled
    case timedOut
}

struct RTCCallTerminalMarker: Equatable {
    let callID: String
    var reason: String
    var stateVersion: Int64
}

enum RTCTerminalCompensationAction: Equatable {
    case reject
    case cancel
    case hangup
}

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
protocol RTCSignalHTTPFailureRepresenting {
    var statusCode: Int { get }
    var code: String { get }
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
enum RTCRequestBackoffPolicy {
    static let discoveryFailureDelayNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000,
        30_000_000_000
    ]
    static let terminalFailureDelayNanoseconds: [UInt64] = [
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000,
        30_000_000_000
    ]
    static let maximumTerminalAttempts = 6

    static func delayNanoseconds(
        afterFailureCount failureCount: Int,
        delays: [UInt64],
        stableKey: String
    ) -> UInt64 {
        guard !delays.isEmpty else { return 0 }
        let index = min(max(failureCount, 1) - 1, delays.count - 1)
        let baseDelay = delays[index]
        guard baseDelay > 0 else { return 0 }
        let jitterWindow = max(baseDelay / 5, 1)
        return addingClamped(baseDelay, deterministicJitterNanoseconds(stableKey: stableKey, modulo: jitterWindow))
    }

    static func retryAfterNanoseconds(from error: Error) -> UInt64? {
        guard case let IMAPIError.rateLimited(_, _, retryAfterSeconds, _) = error,
              let retryAfterSeconds,
              retryAfterSeconds > 0 else {
            return nil
        }
        let seconds = UInt64(retryAfterSeconds)
        guard seconds <= UInt64.max / 1_000_000_000 else {
            return UInt64.max
        }
        return seconds * 1_000_000_000
    }

    static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
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

enum RTCRefreshEndpoint {
    case calls
    case events
}

enum RTCRefreshResult {
    case success
    case skipped
    case cancelled
    case failed(Error)

    var failedError: Error? {
        guard case let .failed(error) = self else { return nil }
        return error
    }
}

struct RTCRefreshBatchResult {
    var events: RTCRefreshResult = .skipped
    var calls: RTCRefreshResult = .skipped
}

struct RTCDiscoveryEndpointBackoff {
    private(set) var failureCount = 0
    var nextAttemptAtNanoseconds: UInt64 = 0

    mutating func reset() {
        failureCount = 0
        nextAttemptAtNanoseconds = 0
    }

    mutating func record(
        _ result: RTCRefreshResult,
        endpoint: RTCRefreshEndpoint,
        nowNanoseconds: UInt64,
        delays: [UInt64]
    ) {
        switch result {
        case .success:
            reset()
        case .failed(let error):
            failureCount += 1
            let retryAfter = RTCRequestBackoffPolicy.retryAfterNanoseconds(from: error)
            let policyDelay = RTCRequestBackoffPolicy.delayNanoseconds(
                afterFailureCount: failureCount,
                delays: delays,
                stableKey: "\(endpoint)-\(failureCount)"
            )
            nextAttemptAtNanoseconds = RTCRequestBackoffPolicy.addingClamped(
                nowNanoseconds,
                max(retryAfter ?? 0, policyDelay)
            )
        case .skipped, .cancelled:
            break
        }
    }

    func remainingDelayNanoseconds(nowNanoseconds: UInt64) -> UInt64? {
        guard nextAttemptAtNanoseconds > nowNanoseconds else { return nil }
        return nextAttemptAtNanoseconds - nowNanoseconds
    }
}

enum RTCTerminalCompensationRetryDecision {
    case retry(afterNanoseconds: UInt64)
    case satisfied
    case pause
}

enum RTCTerminalCompensationRetryPolicy {
    static func decision(
        for error: Error,
        attemptCount: Int,
        stableKey: String,
        failureDelays: [UInt64],
        maximumAttempts: Int
    ) -> RTCTerminalCompensationRetryDecision {
        if isAlreadyTerminal(error) {
            return .satisfied
        }
        if attemptCount >= maximumAttempts || isAuthorizationFailure(error) {
            return .pause
        }
        let retryAfter = RTCRequestBackoffPolicy.retryAfterNanoseconds(from: error)
        let policyDelay = RTCRequestBackoffPolicy.delayNanoseconds(
            afterFailureCount: attemptCount,
            delays: failureDelays,
            stableKey: stableKey
        )
        return .retry(afterNanoseconds: max(retryAfter ?? 0, policyDelay))
    }

    static func normalizedErrorCode(_ error: Error) -> String {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .unauthorized:
                return "unauthorized"
            case .forbidden:
                return "forbidden"
            case .businessForbidden(let code, _, _):
                return code.isEmpty ? "business_forbidden" : code
            case .conflict(let code, _):
                return code.isEmpty ? "conflict" : code
            case .httpStatus(let statusCode, _):
                return "http_\(statusCode)"
            case .server:
                return "server"
            case .securityBlocked:
                return "security_blocked"
            case .loginSecurity(let code, _, _):
                return code.isEmpty ? "login_security" : code
            case .rateLimited(let code, _, _, _):
                return code.isEmpty ? "rate_limited" : code
            case .missingContext:
                return "missing_context"
            case .badURL:
                return "bad_url"
            case .forcedAuthRequired:
                return "forced_auth_required"
            case .emptyResponse:
                return "empty_response"
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? "cancelled" : "url_\(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    private static func isAuthorizationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .unauthorized, .forbidden, .businessForbidden, .securityBlocked, .loginSecurity, .forcedAuthRequired:
            return true
        default:
            return false
        }
    }

    private static func isAlreadyTerminal(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .conflict(let code, _), .businessForbidden(let code, _, _):
            return [
                "rtc_call_not_found",
                "rtc_call_not_active",
                "rtc_call_not_ringing",
                "rtc_call_already_ended",
                "rtc_call_already_terminal"
            ].contains(code)
        default:
            return false
        }
    }
}

struct PendingRTCTerminalCompensation {
    let callID: String
    let action: RTCTerminalCompensationAction
    let reason: String
    var context: IMAPIContext
    let scope: String
    let idempotencyKey: String
    var attemptCount: Int
    var nextAttemptAtNanoseconds: UInt64
    var lastErrorCode: String?
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

// JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
enum RTCSignalPollingBackoffPolicy {
    static let failureDelayNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000,
        30_000_000_000
    ]
    // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：连接/重连阶段缩短空轮询等待，降低跨端接听后的信令等待时间
    static let quickEmptyConnectingDelayNanoseconds: UInt64 = 150_000_000
    // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
    static let quickEmptyMinimumDelayNanoseconds: UInt64 = 1_000_000_000

    static func delayNanoseconds(afterFailureCount failureCount: Int, stableKey: String, error: Error) -> UInt64 {
        let policyDelay = RTCRequestBackoffPolicy.delayNanoseconds(
            afterFailureCount: failureCount,
            delays: failureDelayNanoseconds,
            stableKey: stableKey
        )
        return max(RTCRequestBackoffPolicy.retryAfterNanoseconds(from: error) ?? 0, policyDelay)
    }

    static func shouldDelayQuickEmptyPage(
        itemCount: Int,
        previousCursor: String,
        nextCursor: String,
        elapsedNanoseconds: UInt64
    ) -> Bool {
        quickEmptyDelayNanoseconds(
            itemCount: itemCount,
            previousCursor: previousCursor,
            nextCursor: nextCursor,
            elapsedNanoseconds: elapsedNanoseconds,
            isConnected: true
        ) != nil
    }

    // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：未连通时保留轻量节流，但不再固定阻塞 1s 等对端 offer/answer/candidate
    static func quickEmptyDelayNanoseconds(
        itemCount: Int,
        previousCursor: String,
        nextCursor: String,
        elapsedNanoseconds: UInt64,
        isConnected: Bool
    ) -> UInt64? {
        guard itemCount == 0,
              nextCursor.isEmpty || nextCursor == previousCursor else {
            return nil
        }
        let delay = isConnected ? quickEmptyMinimumDelayNanoseconds : quickEmptyConnectingDelayNanoseconds
        return elapsedNanoseconds < delay ? delay : nil
    }
    // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束

    static func shouldStopPolling(after error: Error) -> Bool {
        if error is CancellationError || error is RTCCredentialError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if let signalError = error as? RTCSignalHTTPFailureRepresenting {
            return [401, 403, 404, 409].contains(signalError.statusCode)
        }
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .unauthorized, .forbidden, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity, .forcedAuthRequired:
            return true
        case .httpStatus(let statusCode, _):
            return [401, 403, 404, 409].contains(statusCode)
        case .missingContext, .badURL, .server, .rateLimited, .emptyResponse:
            return false
        }
    }
}

struct RTCSignalPollingBackoffState {
    private(set) var failureCount = 0

    mutating func reset() {
        failureCount = 0
    }

    mutating func recordFailureAndDelayNanoseconds(stableKey: String, error: Error) -> UInt64 {
        failureCount += 1
        return RTCSignalPollingBackoffPolicy.delayNanoseconds(
            afterFailureCount: failureCount,
            stableKey: stableKey,
            error: error
        )
    }
}
// JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911

func normalizedMainlandPhone(_ rawValue: String) -> String {
    String(rawValue.filter(\.isNumber).prefix(11))
}

func isValidMainlandPhone(_ phone: String) -> Bool {
    let normalized = normalizedMainlandPhone(phone)
    guard normalized.count == 11,
          normalized.first == "1",
          let second = normalized.dropFirst().first else {
        return false
    }
    return "3456789".contains(second)
}

func maskedPhoneDisplayText(_ rawValue: String, emptyText: String = "") -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return emptyText }
    let compact = trimmed
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
    if compact.contains("*") || compact.contains("•") {
        return compact
    }
    let digits = compact.filter(\.isNumber)
    switch digits.count {
    case 11:
        return "\(String(digits.prefix(3)))****\(String(digits.suffix(4)))"
    case 10:
        return "\(String(digits.prefix(3)))*****\(String(digits.suffix(3)))"
    default:
        guard digits.count >= 7 else { return compact }
        return "\(String(digits.prefix(3)))****\(String(digits.suffix(4)))"
    }
}

func resolvedCurrentUserUsername(remoteUsername: String, fallbackUsername: String? = nil, currentUsername: String) -> String {
    let remote = remoteUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    if !remote.isEmpty { return remote }
    let fallback = fallbackUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !fallback.isEmpty { return fallback }
    return currentUsername.trimmingCharacters(in: .whitespacesAndNewlines)
}

func containsSendableMessageContent(_ rawValue: String) -> Bool {
    rawValue.unicodeScalars.contains { scalar in
        !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

func normalizedSendableMessageText(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return containsSendableMessageContent(trimmed) ? trimmed : ""
}

func shouldPreserveNewerSystemConversationSnapshot(
    previousSortTimestamp: TimeInterval,
    latestInboxSortTimestamp: TimeInterval
) -> Bool {
    previousSortTimestamp > 0
        && (latestInboxSortTimestamp <= 0 || previousSortTimestamp > latestInboxSortTimestamp)
}

func isWenxinUserIDLikeToken(_ rawValue: String) -> Bool {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.range(of: "^[A-Z]{2,4}-U[0-9]{6}$", options: .regularExpression) != nil {
        let prefix = String(value.prefix { $0 >= "A" && $0 <= "Z" })
        return prefix != "WXT" && prefix != "YQM"
    }
    guard value.count == 11, value.hasPrefix("WXT") else { return false }

    let suffix = value.dropFirst(3)
    guard suffix.count == 8 else { return false }

    let isLegacy = suffix.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 48 && scalar.value <= 57
    }
    if isLegacy {
        return true
    }

    let letters = suffix.prefix(2)
    let digits = suffix.dropFirst(2)
    return letters.count == 2
        && digits.count == 6
        && letters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 65 && scalar.value <= 90
        }
        && digits.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
}

let messagePinForbiddenText = "仅群主和管理员才能置顶"
let globalMutedMessageText = "当前时段已开启全员禁言"
let groupMemberMutedMessageText = "你已被禁言，无法在该群发送消息"
let groupMemberNotFoundText = "你已不在该群聊"
let groupHistoryLimitedMessageText = "你只能查看本次入群后的消息"
let realNameVerificationFailedText = "实名认证失败，请检查资料正确性！"
let fileListMessageBackfillConversationLimit = 20
let fileListMessageBackfillWindowLimit = 20
let realtimeIngestFlushDelayNanoseconds: UInt64 = 80_000_000
let realtimeIngestFlushLimit = 500
