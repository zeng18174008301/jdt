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

enum AvatarStage4ScreenshotScenario: String {
    case chatList = "chat-list"
    case groupChat = "group-chat"
    case incomingCall = "incoming-call"
    case activeCall = "active-call"
    case callRecords = "call-records"
}

enum GroupLifecycleScreenshotScenario: String {
    case member
    case admin
    case owner
    case dissolveConfirm = "dissolve-confirm"
}

enum GroupHistoryVisibilityScreenshotScenario: String {
    case ownerSettings = "owner-settings"
    case ownerSettingsLimited = "owner-settings-limited"
    case memberReadonly = "member-readonly"
    case restrictedGroup = "restricted-group"
    case restrictedGroupFiles = "restricted-group-files"
    case episodeWidened = "episode-widened"
    case directUnaffected = "direct-unaffected"
}

enum GlobalPolicyScreenshotScenario: String {
    case memberOff = "member-off"
    case memberOn = "member-on"
    case adminOff = "admin-off"
    case friendOff = "friend-off"
    case friendOn = "friend-on"
    case presence = "presence"
}

#if DEBUG
enum LicenseQuotaScreenshotScenario: String {
    case registration
    case onlineLimit = "online-limit"
    case onlineServiceUnavailable = "online-service-unavailable"
    case group
}

enum RegistrationResolutionScreenshotScenario: String {
    case pending
    case success
    case timeout
}

struct LicenseQuotaRegistrationPrefill: Equatable {
    let enterpriseCode: String
    let account: String
    let password: String
}
#endif

// Quality reporting retains only the original call's authority. Closing media
// grants a short, non-renewable tail window; it never grants media operations.
@MainActor
final class RTCQualityReportingSession {
    let context: IMAPIContext
    let scope: String
    let callID: String
    let roomID: String
    let direction: String
    let mediaMode: String
    let generation: UInt64
    private let uptime: () -> TimeInterval
    private var tokens: [String]
    private var tailDeadline: TimeInterval?
    private var invalidated = false

    init(context: IMAPIContext, scope: String, callID: String, roomID: String,
         direction: String, mediaMode: String, generation: UInt64, rtcToken: String,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.context = context
        self.scope = scope
        self.callID = callID
        self.roomID = roomID
        self.direction = direction
        self.mediaMode = mediaMode
        self.generation = generation
        self.tokens = [rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)]
        self.uptime = uptime
    }

    func finish() {
        if tailDeadline == nil { tailDeadline = uptime() + 5 }
    }

    func acceptRefreshedToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invalidated, tailDeadline == nil,
              RTCQualityTokenScope.hasWriteScope(normalized),
              tokens.last != normalized else { return }
        // A request already in flight may hold the immediately preceding token.
        tokens = Array(tokens.suffix(1)) + [normalized]
    }

    func requestContext(current: IMAPIContext, authenticated: Bool, scopeIsCurrent: Bool,
                        licensed: Bool, activeCallID: String?, activeDirection: String?,
                        generation: UInt64, rtcToken: String) throws -> IMAPIContext {
        guard !invalidated, !Task.isCancelled, authenticated, scopeIsCurrent, licensed,
              current.hasIMSession,
              context.accountID == current.accountID, context.tenantID == current.tenantID,
              context.imUID == current.imUID, context.appID == current.appID,
              context.deviceID == current.deviceID, context.sessionEpoch == current.sessionEpoch,
              activeCallID == nil || activeCallID == callID,
              activeDirection == nil || activeDirection == direction else {
            invalidated = true
            throw CancellationError()
        }
        if let tailDeadline {
            guard uptime() < tailDeadline else {
                invalidated = true
                throw CancellationError()
            }
        } else {
            guard generation == self.generation, activeCallID == callID else {
                invalidated = true
                throw CancellationError()
            }
        }
        guard tokens.contains(rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)),
              RTCQualityTokenScope.hasWriteScope(rtcToken) else { throw CancellationError() }
        return context
    }
}

struct RTCMediaHeartbeatSession {
    let generation: UInt64
    let callID: String
    let scope: String
    var context: IMAPIContext
    var roomID: String
    var rtcToken: String
    var selfParticipant: RemoteRTCRoomParticipant?
    var desiredMediaState: String
    var lastReportedMediaState: String?
    var connectedReportPending = false
    var hasReportedConnected = false
    var isFinishing = false
    var operationID: UUID? = nil
    let startedAt: Date
    var lastAuthoritativeSuccessAt: Date
}

enum RTCMediaStateHeartbeatFailurePolicy {
    static let defaultIntervalNanoseconds: UInt64 = 10_000_000_000
    static let authoritativeTerminalGraceSeconds: TimeInterval = 90
    static let stateVersionConflictRetryLimit = 2

    static func normalizedErrorCode(_ error: Error) -> String {
        if let signalError = error as? RTCVideoSignalHTTPError {
            return signalError.code.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case let .conflict(code, _),
                 let .businessForbidden(code, _, _),
                 let .loginSecurity(code, _, _),
                 let .rateLimited(code, _, _, _):
                return code.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
            default:
                return ""
            }
        }
        return ""
    }

    static func needsParticipantRejoin(_ error: Error) -> Bool {
        ["rtc_participant_lease_expired", "rtc_participant_required"].contains(normalizedErrorCode(error))
    }

    static func isStateVersionConflict(_ error: Error) -> Bool {
        guard let signalError = error as? RTCVideoSignalHTTPError else { return false }
        return signalError.statusCode == 409
            && normalizedErrorCode(signalError) == "rtc_state_version_conflict"
    }

    static func stateVersionConflictRetryDelayNanoseconds(attempt: Int, callID: String) -> UInt64 {
        let normalizedAttempt = UInt64(max(1, attempt))
        let base = normalizedAttempt * 150_000_000
        let stableJitter = callID.utf8.reduce(UInt64(0)) { partial, byte in
            (partial &* 1099511628211) &+ UInt64(byte)
        } % 150_000_000
        return base + stableJitter
    }

    static func isAuthoritativeTerminal(_ error: Error) -> Bool {
        guard let signalError = error as? RTCVideoSignalHTTPError else { return false }
        let code = normalizedErrorCode(signalError)
        return (signalError.statusCode == 409 && code == "rtc_call_not_active")
            || (signalError.statusCode == 404 && code == "rtc_call_not_found")
    }

    static func shouldFinishLocalCall(
        after error: Error,
        lastAuthoritativeSuccessAt: Date,
        now: Date
    ) -> Bool {
        isAuthoritativeTerminal(error)
            && now.timeIntervalSince(lastAuthoritativeSuccessAt) >= authoritativeTerminalGraceSeconds
    }
}

enum DirectCallCapabilityKind: Hashable {
    case voice
    case video
}

struct DirectCallContextBinding: Equatable {
    private enum SessionIdentity: Equatable {
        case authenticated(id: String, authVersion: Int64)
        case legacyToken(String)
    }

    let accountID: String
    let tenantID: String
    let imUID: String
    let appID: String
    let deviceID: String
    private let sessionEpoch: String
    private let hasIMSession: Bool
    private let sessionIdentity: SessionIdentity

    init(context: IMAPIContext) {
        // WDT_RTC_IOS1_AUTODROP_20260921_BEGIN: stable call ownership ignores normal token rotation.
        accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appID = IMAPIContext.normalizedIOSAppID(context.appID)
        deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionEpoch = context.sessionEpoch
        hasIMSession = context.hasIMSession
        if let session = context.tenantAuthSession, session.isUsable {
            sessionIdentity = .authenticated(
                id: session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
                authVersion: session.authVersion
            )
        } else {
            sessionIdentity = .legacyToken(context.imToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        // WDT_RTC_IOS1_AUTODROP_20260921_END
    }
}

struct DirectCallAttempt: Equatable {
    let kind: DirectCallCapabilityKind
    let context: DirectCallContextBinding
    let capabilityGeneration: UInt64
    let callID: String
    let peerID: String
    let mediaMode: String
    let operationID: UUID
}

struct DirectCallCleanupObligation {
    let callID: String
    var context: IMAPIContext
    let sourceAttempt: DirectCallAttempt
    let responsibleOperationID: UUID

    func transferred(to attempt: DirectCallAttempt) -> DirectCallCleanupObligation {
        DirectCallCleanupObligation(
            callID: callID,
            context: context,
            sourceAttempt: sourceAttempt,
            responsibleOperationID: attempt.operationID
        )
    }
}

struct PhoneBindingChallengeSessionScope: Equatable {
    let tenantID: String
    let imUID: String
    let accountID: String
    let appID: String
    let deviceID: String
    let sessionDiscriminator: String

    init?(context: IMAPIContext) {
        guard context.hasIMSession else { return nil }
        tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appID = IMAPIContext.normalizedIOSAppID(context.appID)
        deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let authSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imToken = context.imToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sessionDiscriminator = authSessionID.isEmpty ? imToken : "\(authSessionID)|\(imToken)"
        guard !tenantID.isEmpty,
              !imUID.isEmpty,
              !sessionDiscriminator.isEmpty else {
            return nil
        }
    }
}

struct PendingPhoneBindingChallenge: Equatable {
    let sessionScope: PhoneBindingChallengeSessionScope
    let normalizedPhone: String
    let requestID: String
    let issueGeneration: UInt64
}

enum AvatarUploadFailureStage: String, Equatable, Sendable {
    case presign
    case put
    case commit
    case unknown
}

struct AvatarUploadResult: Equatable, Sendable {
    let success: Bool
    let failureStage: AvatarUploadFailureStage?
    let safeCode: String?
    let status: Int?

    static let succeeded = AvatarUploadResult(success: true, failureStage: nil, safeCode: nil, status: nil)

    static func failed(
        _ stage: AvatarUploadFailureStage,
        safeCode: String? = nil,
        status: Int? = nil
    ) -> AvatarUploadResult {
        AvatarUploadResult(success: false, failureStage: stage, safeCode: safeCode, status: status)
    }
}

struct TenantContextRoleAuthority: Equatable {
    let appID: String
    let tenantID: String
    let imUID: String
    let role: String
}

enum RememberedLoginCommitOutcome: Equatable {
    case authorityGuardRejected
    case protectedStoreWriteFailed
    case committedAndImmediatelyReadable

    static func classify(
        authorityAccepted: Bool,
        protectedStoreWriteSucceeded: Bool,
        immediateReadMatched: Bool
    ) -> RememberedLoginCommitOutcome {
        guard authorityAccepted else { return .authorityGuardRejected }
        guard protectedStoreWriteSucceeded, immediateReadMatched else {
            return .protectedStoreWriteFailed
        }
        return .committedAndImmediatelyReadable
    }
}

#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
enum RememberedLoginCommitDiagnostics {
    private static let key = "post_authoritative_success_remember_commit_class"

    static func record(
        _ outcome: RememberedLoginCommitOutcome,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value(for: outcome), forKey: key)
    }

    static func latest(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    private static func value(for outcome: RememberedLoginCommitOutcome) -> String {
        switch outcome {
        case .authorityGuardRejected:
            return "authority_guard_rejected"
        case .protectedStoreWriteFailed:
            return "protected_store_write_failed"
        case .committedAndImmediatelyReadable:
            return "committed_and_immediately_readable"
        }
    }
}

enum PostLoginSuccessConsumptionStage: String, CaseIterable {
    case requestSent = "request_sent"
    case responseDecoded = "response_decoded"
    case generationCurrent = "generation_current"
    case completeEntered = "complete_entered"
    case tenantDataApplied = "tenant_data_applied"
    case enterpriseIMSessionRejected = "enterprise_im_session_rejected"
    case workspaceResolutionEntered = "workspace_resolution_entered"
    case workspaceSelectionTerminal = "workspace_selection_terminal"
    case authenticatedMainTerminal = "authenticated_main_terminal"
    case caughtAfterRequest = "caught_after_request"

    fileprivate var ordinal: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

@MainActor
enum PostLoginSuccessConsumptionDiagnostics {
    private static let key = "post_login_success_consumption_stage"
    private static var activeGeneration: Int?

    static func begin(
        generation: Int,
        defaults: UserDefaults = .standard
    ) {
        activeGeneration = generation
        defaults.set(PostLoginSuccessConsumptionStage.requestSent.rawValue, forKey: key)
    }

    static func advance(
        _ stage: PostLoginSuccessConsumptionStage,
        generation: Int,
        defaults: UserDefaults = .standard
    ) {
        guard activeGeneration == generation else { return }
        let current = defaults.string(forKey: key)
            .flatMap(PostLoginSuccessConsumptionStage.init(rawValue:))
        guard current == nil || stage.ordinal >= (current?.ordinal ?? 0) else { return }
        defaults.set(stage.rawValue, forKey: key)
    }

    static func latest(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }
}

enum GroupForegroundFirstClearOrigin: String, CaseIterable {
    case groupBundleRemoteError = "GROUP_BUNDLE_REMOTE_ERROR"
    case authRefreshTerminal = "AUTH_REFRESH_TERMINAL"
    case otherLocal = "OTHER_LOCAL"
    case none = "NONE"
}

enum GroupForegroundAuthRefreshRouteClass: String, CaseIterable {
    case platformTenant = "PLATFORM_TENANT"
    case tenantLocal = "TENANT_LOCAL"
    case platformAccount = "PLATFORM_ACCOUNT"
    case none = "NONE"

    static func resolve(context: IMAPIContext) -> Self {
        if let tenantSession = context.tenantAuthSession, tenantSession.isUsable {
            return tenantSession.usesTenantLocalRefreshEndpoint ? .tenantLocal : .platformTenant
        }
        if context.platformAuthSession?.isUsable == true {
            return .platformAccount
        }
        return .none
    }
}

enum GroupForegroundFirstOutcomeClass: String, CaseIterable {
    case success = "2XX"
    case unauthorized = "401"
    case forbidden = "403"
    case serverError = "5XX"
    case transport = "TRANSPORT"
    case decode = "DECODE"
    case noResponse = "NO_RESPONSE"

    static func classify(_ error: Error?) -> Self {
        guard let error else { return .success }
        if error is URLError { return .transport }
        if error is DecodingError { return .decode }
        guard let apiError = error as? IMAPIError else { return .noResponse }
        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .forbidden, .forcedAuthRequired, .businessForbidden, .securityBlocked, .loginSecurity, .rateLimited:
            return .forbidden
        case .httpStatus(let status, _):
            if status == 401 { return .unauthorized }
            if status == 403 { return .forbidden }
            if (500...599).contains(status) { return .serverError }
            return .noResponse
        case .emptyResponse:
            return .noResponse
        case .missingContext, .badURL, .conflict, .server:
            return .noResponse
        }
    }
}

enum GroupForegroundSafeCodeClass: String, CaseIterable {
    case unauthorized = "UNAUTHORIZED"
    case forbidden = "FORBIDDEN"
    case sessionExpired = "SESSION_EXPIRED"
    case refreshTokenExpired = "REFRESH_TOKEN_EXPIRED"
    case sessionRevoked = "SESSION_REVOKED"
    case refreshTokenReused = "REFRESH_TOKEN_REUSED"
    case reauthRequired = "REAUTH_REQUIRED"
    case deviceBlocked = "DEVICE_BLOCKED"
    case accountBlocked = "ACCOUNT_BLOCKED"
    case riskBlocked = "RISK_BLOCKED"
    case securityBlocked = "SECURITY_BLOCKED"
    case unknown = "UNKNOWN"

    static func classify(_ error: Error?) -> Self {
        guard let error else { return .unknown }
        let normalized = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        let ordered: [(String, Self)] = [
            ("refresh_token_expired", .refreshTokenExpired),
            ("refresh_token_reused", .refreshTokenReused),
            ("session_expired", .sessionExpired),
            ("session_revoked", .sessionRevoked),
            ("reauth_required", .reauthRequired),
            ("device_blocked", .deviceBlocked),
            ("account_blocked", .accountBlocked),
            ("risk_blocked", .riskBlocked),
            ("security_blocked", .securityBlocked),
            ("unauthorized", .unauthorized),
            ("forbidden", .forbidden)
        ]
        return ordered.first(where: { normalized.contains($0.0) })?.1 ?? .unknown
    }
}

@MainActor
enum GroupForegroundSessionClearDiagnostics {
    private static let key = "ios_grp03_foreground_session_clear_diagnostic"
    private static var active = false
    private static var firstClearOrigin = GroupForegroundFirstClearOrigin.none
    private static var routeClass = GroupForegroundAuthRefreshRouteClass.none
    private static var firstOutcomeClass = GroupForegroundFirstOutcomeClass.noResponse
    private static var didRecordPrimaryOutcome = false
    private static var safeCodeClass = GroupForegroundSafeCodeClass.unknown
    private static var tenantIMFallbackAttempted = false
    private static var tenantIMFallbackOutcomeClass = GroupForegroundFirstOutcomeClass.noResponse
    private static var scopeCurrentAtDecision = false
    private static var clearSessionCount = 0
    private static var postAuthenticated = false
    private static var postHasRefreshSession = false
    private static var postHasIMSession = false
    private static var sessionWasPresent = false

    static func begin(
        context: IMAPIContext,
        scopeCurrent: Bool,
        postAuthenticated: Bool,
        defaults: UserDefaults = .standard
    ) {
        active = true
        firstClearOrigin = .none
        routeClass = GroupForegroundAuthRefreshRouteClass.resolve(context: context)
        firstOutcomeClass = .noResponse
        didRecordPrimaryOutcome = false
        safeCodeClass = .unknown
        tenantIMFallbackAttempted = false
        tenantIMFallbackOutcomeClass = .noResponse
        scopeCurrentAtDecision = scopeCurrent
        clearSessionCount = 0
        self.postAuthenticated = postAuthenticated
        postHasRefreshSession = context.hasRefreshSession
        postHasIMSession = context.hasIMSession
        sessionWasPresent = context.hasRefreshSession || context.hasIMSession
        persist(defaults: defaults)
    }

    static func suspend() {
        active = false
    }

    static func recordPrimaryOutcome(
        error: Error?,
        scopeCurrent: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard active else { return }
        if !didRecordPrimaryOutcome {
            firstOutcomeClass = GroupForegroundFirstOutcomeClass.classify(error)
            safeCodeClass = GroupForegroundSafeCodeClass.classify(error)
            didRecordPrimaryOutcome = true
        }
        scopeCurrentAtDecision = scopeCurrent
        persist(defaults: defaults)
    }

    static func recordTenantIMFallback(
        attempted: Bool,
        error: Error?,
        scopeCurrent: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard active else { return }
        tenantIMFallbackAttempted = attempted
        if attempted {
            tenantIMFallbackOutcomeClass = GroupForegroundFirstOutcomeClass.classify(error)
        }
        scopeCurrentAtDecision = scopeCurrent
        persist(defaults: defaults)
    }

    static func recordClear(
        origin: GroupForegroundFirstClearOrigin,
        scopeCurrent: Bool,
        postAuthenticated: Bool,
        postHasRefreshSession: Bool,
        postHasIMSession: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard active else { return }
        let hasSession = postHasRefreshSession || postHasIMSession
        let observedClear = sessionWasPresent && !hasSession
        if observedClear {
            clearSessionCount += 1
            if firstClearOrigin == .none {
                firstClearOrigin = origin
            }
        }
        sessionWasPresent = hasSession
        scopeCurrentAtDecision = scopeCurrent
        self.postAuthenticated = postAuthenticated
        self.postHasRefreshSession = postHasRefreshSession
        self.postHasIMSession = postHasIMSession
        persist(defaults: defaults)
    }

    static func recordPostDecision(
        scopeCurrent: Bool,
        postAuthenticated: Bool,
        context: IMAPIContext,
        defaults: UserDefaults = .standard
    ) {
        guard active else { return }
        let hasSession = context.hasRefreshSession || context.hasIMSession
        if sessionWasPresent, !hasSession {
            recordClear(
                origin: .otherLocal,
                scopeCurrent: scopeCurrent,
                postAuthenticated: postAuthenticated,
                postHasRefreshSession: context.hasRefreshSession,
                postHasIMSession: context.hasIMSession,
                defaults: defaults
            )
            return
        }
        sessionWasPresent = hasSession
        scopeCurrentAtDecision = scopeCurrent
        self.postAuthenticated = postAuthenticated
        postHasRefreshSession = context.hasRefreshSession
        postHasIMSession = context.hasIMSession
        persist(defaults: defaults)
    }

    static func latest(defaults: UserDefaults = .standard) -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    private static func persist(defaults: UserDefaults) {
        defaults.set([
            "firstClearOrigin": firstClearOrigin.rawValue,
            "authRefreshRouteClass": routeClass.rawValue,
            "firstOutcomeClass": firstOutcomeClass.rawValue,
            "safeCodeClass": safeCodeClass.rawValue,
            "tenantIMFallbackAttempted": tenantIMFallbackAttempted,
            "tenantIMFallbackOutcomeClass": tenantIMFallbackOutcomeClass.rawValue,
            "scopeCurrentAtDecision": scopeCurrentAtDecision,
            "clearSessionCount": clearSessionCount,
            "postAuthenticated": postAuthenticated,
            "postHasRefreshSession": postHasRefreshSession,
            "postHasIMSession": postHasIMSession
        ], forKey: key)
    }
}
#endif

struct PendingRememberedLoginAttempt {
    let generation: Int
    let scope: RememberedLoginCredentialScope
    let credentials: RememberedLoginCredentials
}

struct ResolvedAvatarRealtimeProjection {
    let value: AvatarRealtimeProjectionValue
    let url: String
}

struct PendingRegistrationAttempt {
    let requestID: String
    let appID: String
    let deviceID: String
    let failureScreen: AuthScreen
    let startedAt: TimeInterval
}
