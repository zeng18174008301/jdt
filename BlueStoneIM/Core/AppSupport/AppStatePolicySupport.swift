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

enum AppPolicyForcedAuthRequirement: String, CaseIterable, Hashable, Identifiable, Sendable {
    case realName
    case phone

    var id: String { rawValue }

    var promptTitle: String {
        switch self {
        case .realName:
            return "需要完成实名认证"
        case .phone:
            return "需要绑定手机号"
        }
    }

    var promptMessage: String {
        switch self {
        case .realName:
            return "您需完成实名认证才可正常使用"
        case .phone:
            return "您需完成手机号认证才可正常使用"
        }
    }

    var actionTitle: String {
        switch self {
        case .realName:
            return "去实名认证"
        case .phone:
            return "去绑定"
        }
    }

    static func pendingRequirement(
        policy: RemoteAppCurrentPolicy,
        user: IMUser
    ) -> AppPolicyForcedAuthRequirement? {
        if policy.requirePhoneVerification, !isPhoneComplete(user) {
            return .phone
        }
        if policy.requireRealName, !isRealNameComplete(user) {
            return .realName
        }
        return nil
    }

    static func isPhoneComplete(_ user: IMUser) -> Bool {
        user.phoneVerified
    }

    static func isRealNameComplete(_ user: IMUser) -> Bool {
        user.realNameVerified
    }
}

struct VerificationRequirementAuthorityProjection: Equatable {
    let phoneSatisfied: Bool
    let realNameSatisfied: Bool
}

func verificationRequirementAuthorityProjection(
    status: RemoteVerificationStatus,
    currentUser: IMUser
) -> VerificationRequirementAuthorityProjection? {
    guard !status.imUID.isEmpty,
          status.imUID == currentUser.id || status.imUID == currentUser.userID else {
        return nil
    }
    return VerificationRequirementAuthorityProjection(
        phoneSatisfied: status.phoneRequirementSatisfied == true,
        realNameSatisfied: status.realNameRequirementSatisfied == true
    )
}

struct ForcedAppPolicyAuthPresentationFence {
    private var promptDeferrals: Set<UUID> = []
    private(set) var pendingDestination: AppPolicyForcedAuthRequirement?

    var canExposePrompt: Bool {
        promptDeferrals.isEmpty && pendingDestination == nil
    }

    mutating func beginPromptDeferral() -> UUID {
        let token = UUID()
        promptDeferrals.insert(token)
        return token
    }

    @discardableResult
    mutating func endPromptDeferral(_ token: UUID) -> Bool {
        promptDeferrals.remove(token) != nil
    }

    mutating func beginDestinationTransition(
        _ requirement: AppPolicyForcedAuthRequirement
    ) -> Bool {
        guard pendingDestination == nil else { return false }
        pendingDestination = requirement
        return true
    }

    mutating func completeDestinationTransition() -> AppPolicyForcedAuthRequirement? {
        defer { pendingDestination = nil }
        return pendingDestination
    }

    mutating func cancelDestinationTransition() {
        pendingDestination = nil
    }

    mutating func reset() {
        promptDeferrals.removeAll()
        pendingDestination = nil
    }
}

enum DisasterRecoveryFallbackClassifier {
    private static let recoverableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .dataNotAllowed
    ]

    private static let recoverableServerFragments = [
        "408",
        "500",
        "502",
        "503",
        "504",
        "request timeout",
        "timed out",
        "timeout",
        "internal server error",
        "bad gateway",
        "service unavailable",
        "gateway timeout",
        "cannot connect",
        "cannot find host",
        "could not connect",
        "network connection was lost",
        "not connected to the internet",
        "网络",
        "超时",
        "无法连接"
    ]

    private static let appFailClosedCodes: Set<String> = [
        "app_not_found",
        "unknown_app_id",
        "invalid_app_id",
        "app_disabled",
        "app_inactive",
        "not_found"
    ]

    private static let tenantRefreshFailClosedCodes: Set<String> = [
        "missing_token",
        "invalid_token",
        "expired_token",
        "im_token_grace_expired",
        "im_token_offline_window_exceeded",
        "token_tenant_mismatch",
        "token_binding_mismatch",
        "device_not_found",
        "device_disabled",
        "device_app_mismatch",
        "account_locked",
        "account_disabled",
        "tenant_member_disabled",
        "tenant_member_not_found",
        "tenant_service_stopped",
        "security_blocked",
        "rate_limited",
        "audit_write_failed",
        "token_sign_failed"
    ]

    static func shouldFallbackFromPlatformFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return recoverableURLErrorCodes.contains(urlError.code)
        }
        guard let apiError = error as? IMAPIError else { return false }
        switch apiError {
        case .server(let message):
            let normalized = normalize(message)
            return recoverableServerFragments.contains { normalized.contains($0) }
        case .httpStatus(let status, _):
            return status == 408 || (500...599).contains(status)
        case .businessForbidden(let code, let message, _):
            let normalizedCode = normalize(code)
            let normalizedMessage = normalize(message)
            return [
                "platform_unavailable",
                "platform_service_unavailable",
                "proxy_upstream_unavailable",
                "proxy_staging_unavailable",
            ].contains(normalizedCode)
                || recoverableServerFragments.contains { normalizedMessage.contains($0) }
        default:
            return false
        }
    }

    static func isAppPolicyFailClosedError(_ error: Error) -> Bool {
        let code = normalizedCode(from: error)
        guard !code.isEmpty else { return false }
        return appFailClosedCodes.contains(code)
            || appFailClosedCodes.contains { code.contains($0) }
    }

    static func isTenantRefreshFailClosedError(_ error: Error) -> Bool {
        let code = normalizedCode(from: error)
        guard !code.isEmpty else { return false }
        return tenantRefreshFailClosedCodes.contains(code)
            || tenantRefreshFailClosedCodes.contains { code.contains($0) }
    }

    static func normalizedCode(from error: Error) -> String {
        if let refreshError = error as? IMSessionRefreshRejectionError {
            return normalize(refreshError.code)
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .missingContext(let value):
                return normalize(value)
            case .businessForbidden(let code, _, _),
                 .conflict(let code, _),
                 .loginSecurity(let code, _, _),
                 .rateLimited(let code, _, _, _):
                return normalize(code)
            case .forbidden(let message),
                 .httpStatus(_, let message),
                 .server(let message),
                 .unauthorized(let message):
                return normalize(message)
            case .securityBlocked:
                return "security_blocked"
            default:
                return ""
            }
        }
        return normalize(String(describing: error))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum IMTenantIMTokenExpiryStore {
    private static let storageKey = "im2.ios.imTokenExpiresAt"

    static func save(_ expiresAt: Int64, defaults: UserDefaults = .standard) {
        guard expiresAt > 0 else { return }
        defaults.set(expiresAt, forKey: storageKey)
    }

    static func load(defaults: UserDefaults = .standard) -> Int64 {
        let value = defaults.object(forKey: storageKey)
        if let int = value as? Int64 { return int }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        return 0
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

enum IMAuthSessionPreemptiveRefreshPolicy {
    // Renew before the bearer reaches its hard boundary so realtime, sync and
    // sends do not all discover the same expiry through simultaneous 401s.
    // JHT_MOD_BEGIN AUTH_PREEMPTIVE_REFRESH_5MIN
    static let refreshSkewSeconds: TimeInterval = 300
    // JHT_MOD_END AUTH_PREEMPTIVE_REFRESH_5MIN
    // Re-evaluate wall time periodically. A single sleep until an absolute
    // expiry would be wrong after a manual/system clock jump.
    static let maximumClockRecheckSeconds: TimeInterval = 60
    static let inactiveSessionDiscoverySeconds: TimeInterval = 5
    static let retryAfterTransientFailureSeconds: TimeInterval = 30

    static func delayUntilRefresh(
        accessExpiresAt: Int64,
        now: TimeInterval
    ) -> TimeInterval? {
        guard accessExpiresAt > 0 else { return nil }
        return max(0, TimeInterval(accessExpiresAt) - now - refreshSkewSeconds)
    }

    static func boundedSleepSeconds(for delay: TimeInterval) -> TimeInterval {
        min(max(0, delay), maximumClockRecheckSeconds)
    }

    static func activeAccessExpiresAt(
        hasIMSession: Bool,
        contextAccessExpiresAt: Int64,
        tenantAccessExpiresAt: Int64,
        platformAccessExpiresAt: Int64,
        legacyIMAccessExpiresAt: Int64
    ) -> Int64 {
        if hasIMSession {
            let explicitIMExpiry = [tenantAccessExpiresAt, contextAccessExpiresAt]
                .filter { $0 > 0 }
                .min()
            return explicitIMExpiry ?? max(0, legacyIMAccessExpiresAt)
        }
        return [platformAccessExpiresAt, contextAccessExpiresAt]
            .filter { $0 > 0 }
            .min() ?? 0
    }
}

enum IMAuthSessionTerminationDisposition: Equatable, Sendable {
    case retryable
    case tenantLocal
    case global
}

enum IMAuthSessionTerminationPolicy {
    private static let authoritativeTerminalCodes: Set<String> = [
        "session_revoked",
        "session_family_revoked",
        "refresh_token_reused",
        "reauth_required",
        "device_revoked",
        "device_disabled",
        "device_blocked",
        "account_locked",
        "account_disabled",
        "tenant_member_disabled",
        "tenant_member_not_found",
        "tenant_service_stopped",
        "security_blocked",
        "risk_blocked",
        "password_changed",
        "credentials_changed",
        "auth_version_revoked"
    ]

    private static let authoritativeLegacyMessageFragments = [
        "session_revoked",
        "refresh_token_reused",
        "reauth_required",
        "device_revoked",
        "device_blocked",
        "account_blocked",
        "risk_blocked",
        "password_changed",
        "credentials_changed",
        "需要重新验证",
        "安全策略限制"
    ]

    static func isTerminal(code: String, legacyMessage: String = "") -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if authoritativeTerminalCodes.contains(normalizedCode) {
            return true
        }
        let normalizedMessage = legacyMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return authoritativeLegacyMessageFragments.contains { normalizedMessage.contains($0) }
    }

    static func disposition(
        code: String,
        legacyMessage: String = "",
        lifetimeMode: IMSessionLifetimeMode,
        authorityFamily: IMAuthSessionAuthorityFamily
    ) -> IMAuthSessionTerminationDisposition {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["session_expired", "refresh_token_expired"].contains(normalizedCode) {
            guard lifetimeMode == .absolute else { return .retryable }
            return authorityFamily == .tenant ? .tenantLocal : .global
        }
        let tenantCodes: Set<String> = [
            "tenant_member_revoked",
            "tenant_member_disabled",
            "tenant_member_not_found",
            "tenant_service_stopped"
        ]
        if tenantCodes.contains(normalizedCode) { return .tenantLocal }
        let authorityScopedCodes: Set<String> = ["session_revoked", "reauth_required"]
        if authorityScopedCodes.contains(normalizedCode) {
            return authorityFamily == .tenant ? .tenantLocal : .global
        }
        if isTerminal(code: normalizedCode, legacyMessage: legacyMessage) {
            return .global
        }
        return .retryable
    }
}

struct IMAppPolicyLastGoodEntry: Codable, Equatable {
    let appID: String
    let savedAt: TimeInterval
    let onlineExpiresAt: TimeInterval
    let maxStaleExpiresAt: TimeInterval
    let policy: RemoteAppCurrentPolicy

    var isOnlineFresh: Bool {
        onlineExpiresAt > Date().timeIntervalSince1970
    }

    var isWithinMaxStaleWindow: Bool {
        maxStaleExpiresAt > Date().timeIntervalSince1970
    }
}

struct GroupMemberCountVisibilityRecord: Codable, Equatable {
    let showGroupMemberCount: Bool
    let generation: Int64
    let contractVersion: Int
}

struct GroupMemberCountVisibilityDecision: Equatable {
    let effectivePolicy: RemoteTenantClientPolicy
    let authoritativeRecordToPersist: GroupMemberCountVisibilityRecord?
}

enum TenantDeviceMultiplicityPolicyState: Equatable {
    case unavailable
    case singleDevice
    case multipleDevices

    var presentationText: String {
        switch self {
        case .unavailable:
            return "同步中"
        case .singleDevice:
            return "1 台设备"
        case .multipleDevices:
            return "允许多设备"
        }
    }
}

struct TenantDevicePolicyAuthorityScope: Equatable {
    let tenantID: String
    let viewerID: String
    let appID: String
    let deviceID: String
    let sessionDiscriminator: String

    init?(context: IMAPIContext) {
        guard context.hasIMSession else { return nil }
        tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        viewerID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imToken = context.imToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sessionDiscriminator = sessionID.isEmpty ? imToken : "\(sessionID)|\(imToken)"
        guard !tenantID.isEmpty,
              !viewerID.isEmpty,
              !appID.isEmpty,
              !deviceID.isEmpty,
              !sessionDiscriminator.isEmpty else {
            return nil
        }
    }
}

struct TenantDevicePolicyRequestAuthority: Equatable {
    let scope: TenantDevicePolicyAuthorityScope
    let generation: UInt64
}

enum GroupMemberCountPolicyResolutionState: Equatable {
    case unresolved(scope: String, minimumGeneration: Int64)
    case authoritative(scope: String, generation: Int64)

    func permitsVisibleTotal(
        currentScope: String,
        policy: RemoteTenantClientPolicy?
    ) -> Bool {
        guard case .authoritative(let authoritativeScope, let acceptedGeneration) = self,
              !currentScope.isEmpty,
              authoritativeScope == currentScope,
              let policy,
              policy.groupMemberCountPolicyPresent,
              policy.groupMemberCountContractVersion >= 1,
              policy.groupMemberCountPolicyAuthoritative,
              policy.groupMemberCountPolicyGeneration >= acceptedGeneration else {
            return false
        }
        return policy.showGroupMemberCount
    }
}

func groupsScrubbingGroupMemberTotals(_ groups: [GroupInfo]) -> [GroupInfo] {
    groups.map { group in
        var scrubbed = group
        scrubbed.memberCount = nil
        return scrubbed
    }
}

struct GroupMemberCountScrubbedClientState {
    let groups: [GroupInfo]
    let conversations: [Conversation]
    let clearsTenantScopedSearchState: Bool
}

func clientStateScrubbingGroupMemberTotals(
    groups: [GroupInfo],
    conversations: [Conversation],
    clearSearchState: Bool
) -> GroupMemberCountScrubbedClientState {
    GroupMemberCountScrubbedClientState(
        groups: groupsScrubbingGroupMemberTotals(groups),
        conversations: conversations.map { $0.scrubbingGroupMemberTotals() },
        clearsTenantScopedSearchState: clearSearchState
    )
}

enum GroupMemberCountVisibilityStore {
    private static let storageKey = "tenant_group_member_count_visibility_v1"

    static func load(scope: String, defaults: UserDefaults = .standard) -> GroupMemberCountVisibilityRecord? {
        loadAll(defaults: defaults)[scope]
    }

    static func save(
        _ record: GroupMemberCountVisibilityRecord,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        guard !scope.isEmpty else { return }
        var records = loadAll(defaults: defaults)
        records[scope] = record
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func loadAll(defaults: UserDefaults) -> [String: GroupMemberCountVisibilityRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: GroupMemberCountVisibilityRecord].self, from: data) else {
            return [:]
        }
        return records
    }
}

struct LocalHiddenConversationRecord: Codable, Equatable, Sendable {
    let conversationID: String
    let channelID: String
    let channelType: String
    let hiddenThroughSeq: Int64
    let hiddenAt: TimeInterval

    init(
        conversationID: String,
        channelID: String,
        channelType: String,
        hiddenThroughSeq: Int64,
        hiddenAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelType = Self.normalizedChannelType(channelType)
        self.hiddenThroughSeq = max(0, hiddenThroughSeq)
        self.hiddenAt = hiddenAt
    }

    var key: String {
        Self.recordKey(channelID: channelID, channelType: channelType)
    }

    static func recordKey(channelID: String, channelType: String) -> String {
        let normalizedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedChannelType(channelType))|\(normalizedID)"
    }

    static func normalizedChannelType(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "group" { return "group" }
        if normalized == "system" || normalized == "system_notification" || normalized == "system_message" {
            return "system"
        }
        return "direct"
    }
}

enum LocalHiddenConversationStore {
    private static let storageKey = "local_hidden_conversations_v1"

    static func load(scope: String, defaults: UserDefaults = .standard) -> [String: LocalHiddenConversationRecord] {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return [:] }
        return loadAll(defaults: defaults)[normalizedScope] ?? [:]
    }

    static func save(
        _ records: [String: LocalHiddenConversationRecord],
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return }
        var allRecords = loadAll(defaults: defaults)
        if records.isEmpty {
            allRecords.removeValue(forKey: normalizedScope)
        } else {
            allRecords[normalizedScope] = records
        }
        guard let data = try? JSONEncoder().encode(allRecords) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func hide(
        _ record: LocalHiddenConversationRecord,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        guard !record.channelID.isEmpty else { return }
        var records = load(scope: scope, defaults: defaults)
        records[record.key] = record
        save(records, scope: scope, defaults: defaults)
    }

    static func remove(
        channelID: String,
        channelType: String,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        var records = load(scope: scope, defaults: defaults)
        let key = LocalHiddenConversationRecord.recordKey(channelID: channelID, channelType: channelType)
        records.removeValue(forKey: key)
        save(records, scope: scope, defaults: defaults)
    }

    private static func loadAll(defaults: UserDefaults) -> [String: [String: LocalHiddenConversationRecord]] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: [String: LocalHiddenConversationRecord]].self, from: data) else {
            return [:]
        }
        return records
    }
}

func resolveGroupMemberCountVisibility(
    storedAuthoritative: GroupMemberCountVisibilityRecord?,
    incoming: RemoteTenantClientPolicy
) -> GroupMemberCountVisibilityDecision {
    if !incoming.groupMemberCountPolicyPresent ||
        incoming.groupMemberCountContractVersion < 1 ||
        !incoming.groupMemberCountPolicyAuthoritative {
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming.settingGroupMemberCountVisibility(
                false,
                authoritative: false
            ),
            authoritativeRecordToPersist: nil
        )
    }

    let incomingRecord = GroupMemberCountVisibilityRecord(
        showGroupMemberCount: incoming.showGroupMemberCount,
        generation: incoming.groupMemberCountPolicyGeneration,
        contractVersion: incoming.groupMemberCountContractVersion
    )
    if !incoming.showGroupMemberCount {
        if let storedAuthoritative,
           incoming.groupMemberCountPolicyGeneration < storedAuthoritative.generation {
            return GroupMemberCountVisibilityDecision(
                effectivePolicy: incoming.settingGroupMemberCountVisibility(
                    false,
                    generation: storedAuthoritative.generation,
                    contractVersion: max(
                        incoming.groupMemberCountContractVersion,
                        storedAuthoritative.contractVersion
                    )
                ),
                authoritativeRecordToPersist: nil
            )
        }
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming,
            authoritativeRecordToPersist: incomingRecord
        )
    }

    if let storedAuthoritative,
       (
        storedAuthoritative.showGroupMemberCount
            ? incoming.groupMemberCountPolicyGeneration < storedAuthoritative.generation
            : incoming.groupMemberCountPolicyGeneration <= storedAuthoritative.generation
       ) {
        return GroupMemberCountVisibilityDecision(
            effectivePolicy: incoming.settingGroupMemberCountVisibility(
                false,
                generation: storedAuthoritative.generation,
                contractVersion: max(
                    incoming.groupMemberCountContractVersion,
                    storedAuthoritative.contractVersion
                )
            ),
            authoritativeRecordToPersist: nil
        )
    }

    return GroupMemberCountVisibilityDecision(
        effectivePolicy: incoming,
        authoritativeRecordToPersist: incomingRecord
    )
}

extension RemoteTenantClientPolicy {
    func settingGroupMemberCountVisibility(
        _ visible: Bool,
        generation: Int64? = nil,
        contractVersion: Int? = nil,
        authoritative: Bool? = nil
    ) -> RemoteTenantClientPolicy {
        RemoteTenantClientPolicy(
            allowMemberGroupCreation: allowMemberGroupCreation,
            hideMembershipSystemMessages: hideMembershipSystemMessages,
            clientFriendRequests: clientFriendRequests,
            showGroupMemberCount: visible,
            groupMemberCountPolicyGeneration: generation ?? groupMemberCountPolicyGeneration,
            groupMemberCountContractVersion: contractVersion ?? groupMemberCountContractVersion,
            groupMemberCountPolicyAuthoritative: authoritative ?? groupMemberCountPolicyAuthoritative,
            groupMemberCountPolicyPresent: groupMemberCountPolicyPresent,
            showOnlineStatus: showOnlineStatus,
            showLastLoginTime: showLastLoginTime,
            loginRequireBoundDevice: loginRequireBoundDevice,
            multiDeviceEnabled: multiDeviceEnabled,
            multiDeviceContractVersion: multiDeviceContractVersion,
            multiDevicePolicyAuthoritative: multiDevicePolicyAuthoritative,
            multiDevicePolicyPresent: multiDevicePolicyPresent,
            messageExportEnabled: messageExportEnabled
        )
    }
}

enum IMAppPolicyLastGoodStore {
    private static let storageKey = "im2.ios.lastGoodAppPolicies.v1"

    static func save(_ policy: RemoteAppCurrentPolicy, appID rawAppID: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID.isEmpty ? policy.appID : rawAppID)
        guard !appID.isEmpty, policy.isUsable else { return }
        var entries = loadAll(defaults: defaults)
        let ttl = TimeInterval(max(0, policy.cacheTTLSeconds))
        entries[appID] = IMAppPolicyLastGoodEntry(
            appID: appID,
            savedAt: now.timeIntervalSince1970,
            onlineExpiresAt: now.addingTimeInterval(ttl).timeIntervalSince1970,
            // Kept in the persisted v1 shape for downgrade compatibility. It is
            // no longer an eviction boundary: a verified policy remains the
            // last-good authority until an explicit higher revision disables it.
            maxStaleExpiresAt: .greatestFiniteMagnitude,
            policy: policy
        )
        persist(entries, defaults: defaults)
    }

    static func usable(appID rawAppID: String, defaults: UserDefaults = .standard, now: Date = Date()) -> IMAppPolicyLastGoodEntry? {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.isEmpty,
              let entry = loadAll(defaults: defaults)[appID],
              entry.policy.isUsable else {
            return nil
        }
        return entry
    }

    static func clear(appID rawAppID: String, defaults: UserDefaults = .standard) {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        guard !appID.isEmpty else { return }
        var entries = loadAll(defaults: defaults)
        entries.removeValue(forKey: appID)
        persist(entries, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func loadAll(defaults: UserDefaults) -> [String: IMAppPolicyLastGoodEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: IMAppPolicyLastGoodEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ entries: [String: IMAppPolicyLastGoodEntry], defaults: UserDefaults) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
