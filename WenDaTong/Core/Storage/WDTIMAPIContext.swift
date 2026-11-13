// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation
import IM4Data

typealias IMStoredAuthSession = IM4Data.IMStoredAuthSession

extension IMStoredAuthSession {
    var isUsable: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedTokenType: String {
        tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var usesTenantLocalRefreshEndpoint: Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        // `trs_` is the authoritative tenant refresh-session family. Older
        // clients/tests persisted `trt_` (the refresh-token family) into this
        // field, so retain it only as migration compatibility.
        return normalizedSessionID.hasPrefix("trs_")
            || normalizedSessionID.hasPrefix("trt_")
    }
}

enum IMAuthSessionAuthorityFamily: String, Hashable, Sendable {
    case tenant
    case platform
    case none
}

/// Retire an in-flight page after same-session token rotation; never accept it
/// under a newer fence. The loader restarts with a fresh cursor and context.
struct ConversationPageAuthority {
    private(set) var context: IMAPIContext

    mutating func validate(current: IMAPIContext) throws {
        try Task.checkCancellation()
        guard current.hasIMSession else { throw CancellationError() }
        if current.isSameAuthAuthority(as: context.authSessionFence) { return }
        guard current.credentialsAdvanced(since: context.authSessionFence) else {
            throw CancellationError()
        }
        context = current
        throw ConversationPageFailure(statusCode: 0, code: "conversation_page_credentials_advanced")
    }
}

struct IMAuthSessionFence: Equatable, Hashable, Sendable {
    let epoch: String
    let credentialRevision: Int64
    let principalKey: String
    let platformSessionID: String
    let tenantSessionID: String
    let authorityFamily: IMAuthSessionAuthorityFamily
    let authVersion: Int64
    let sessionGeneration: Int64

    var authoritySessionID: String {
        switch authorityFamily {
        case .tenant:
            return tenantSessionID
        case .platform:
            return platformSessionID
        case .none:
            return ""
        }
    }
}

private struct IMProtectedSessionSnapshot: Codable, Equatable {
    let formatVersion: Int
    let platformToken: String?
    let accountID: String?
    let tenantID: String?
    let imUID: String?
    let imToken: String?
    let tenantAPIBaseURL: String?
    let imAPIBaseURL: String?
    let platformAuthSession: IMStoredAuthSession?
    let tenantAuthSession: IMStoredAuthSession?
    let appID: String
    let deviceID: String
    let accessExpiresAt: Int64
    let credentialRevision: Int64
    let sessionEpoch: String
    let pendingRefreshRequestID: String?
}
enum IMProtectedSessionSaveResult: Equatable {
    case committed
    case failed

    var isCommitted: Bool { self == .committed }
}

struct IMAPIContext {
    static let canonicalIOSAppID: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "WXTAppRuntimeID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty,
              configured.utf8.count <= 128,
              configured.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\t")) == nil else {
//            return "jianhuitong-ios"

               return "wendatong-ios"

        }
        return configured
    }()

    private static let storedSessionKeys = [
        "im2.ios.platformToken",
        "im2.ios.accountID",
        "im2.ios.tenantID",
        "im2.ios.imUID",
        "im2.ios.imToken",
        "im2.ios.tenantAPIBaseURL",
        "im2.ios.imAPIBaseURL",
        "im2.ios.platformAuthSession",
        "im2.ios.tenantAuthSession",
        "im2.ios.protectedSessionSnapshot.v2"
    ]
    private static let platformAuthSessionKey = "im2.ios.platformAuthSession"
    private static let tenantAuthSessionKey = "im2.ios.tenantAuthSession"
    private static let protectedSessionSnapshotKey = "im2.ios.protectedSessionSnapshot.v2"
    private static let sessionClearedMarkerKey = "im2.ios.sessionClearedAt"

    var platformToken: String?
    var accountID: String?
    var tenantID: String?
    var imUID: String?
    var imToken: String?
    var tenantAPIBaseURL: String?
    var imAPIBaseURL: String?
    var platformAuthSession: IMStoredAuthSession?
    var tenantAuthSession: IMStoredAuthSession?
    var appID: String
    var deviceID: String
    var accessExpiresAt: Int64
    var credentialRevision: Int64
    var sessionEpoch: String
    var pendingRefreshRequestID: String?

    var hasIMSession: Bool {
        tenantID?.isEmpty == false && imUID?.isEmpty == false && imToken?.isEmpty == false
    }

    var hasRefreshSession: Bool {
        platformAuthSession?.isUsable == true || tenantAuthSession?.isUsable == true
    }

    var authorityLifetimeMode: IMSessionLifetimeMode {
        if let tenantAuthSession, tenantAuthSession.isUsable {
            return tenantAuthSession.lifetimeMode
        }
        return platformAuthSession?.lifetimeMode ?? .absolute
    }

    var authSessionFence: IMAuthSessionFence {
        let authorityFamily: IMAuthSessionAuthorityFamily
        let authoritySession: IMStoredAuthSession?
        if let tenantAuthSession, tenantAuthSession.isUsable {
            authorityFamily = .tenant
            authoritySession = tenantAuthSession
        } else if let platformAuthSession, platformAuthSession.isUsable {
            authorityFamily = .platform
            authoritySession = platformAuthSession
        } else {
            authorityFamily = .none
            authoritySession = nil
        }
        return IMAuthSessionFence(
            epoch: sessionEpoch,
            credentialRevision: credentialRevision,
            principalKey: [accountID ?? "", tenantID ?? "", imUID ?? "", appID, deviceID]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "|"),
            platformSessionID: platformAuthSession?.sessionID ?? "",
            tenantSessionID: tenantAuthSession?.sessionID ?? "",
            authorityFamily: authorityFamily,
            authVersion: authoritySession?.authVersion ?? 0,
            sessionGeneration: authoritySession?.sessionGeneration ?? 0
        )
    }

    func isSameAuthAuthority(as fence: IMAuthSessionFence) -> Bool {
        authSessionFence == fence
    }

    func credentialsAdvanced(since fence: IMAuthSessionFence) -> Bool {
        let current = authSessionFence
        return current.principalKey == fence.principalKey
            && current.epoch == fence.epoch
            && current.authorityFamily == fence.authorityFamily
            && current.authoritySessionID == fence.authoritySessionID
            && current.credentialRevision > fence.credentialRevision
    }

    func accepts(authVersion: Int64, sessionGeneration: Int64, for fence: IMAuthSessionFence) -> Bool {
        guard isSameAuthAuthority(as: fence) else { return false }
        let current = authSessionFence
        if authVersion > 0, current.authVersion > 0, authVersion < current.authVersion {
            return false
        }
        if sessionGeneration > 0,
           current.sessionGeneration > 0,
           sessionGeneration < current.sessionGeneration {
            return false
        }
        return true
    }

    static func load(
        defaults: UserDefaults = .standard,
        sessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore()
    ) -> IMAPIContext {
        var deviceID = defaults.string(forKey: "im2.ios.deviceID") ?? ""
        if deviceID.isEmpty {
            deviceID = "ios-\(UUID().uuidString)"
            defaults.set(deviceID, forKey: "im2.ios.deviceID")
        }
        let storedAppID = defaults.string(forKey: "im2.ios.appID")
        let appID = configuredIOSAppID(storedAppID: storedAppID)
        if shouldClearStoredSessionForAppIDMigration(storedAppID: storedAppID, normalizedAppID: appID) {
            removeStoredSessionValues(defaults: defaults, sessionStore: sessionStore)
            defaults.set(Date().timeIntervalSince1970, forKey: sessionClearedMarkerKey)
        }
        defaults.set(appID, forKey: "im2.ios.appID")
        let sessionWasExplicitlyCleared = defaults.object(forKey: sessionClearedMarkerKey) != nil
        if sessionWasExplicitlyCleared {
            // Logout/app migration authority always wins. A failed Keychain
            // delete may leave bytes behind, but a tombstone must never be
            // removed merely because that obsolete snapshot still decodes.
            removeStoredSessionValues(defaults: defaults, sessionStore: sessionStore)
        }
        if !sessionWasExplicitlyCleared,
           let snapshot = protectedSessionSnapshot(sessionStore: sessionStore),
           normalizedIOSAppID(snapshot.appID) == appID,
           snapshot.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) == deviceID {
            return IMAPIContext(
                platformToken: snapshot.platformToken,
                accountID: snapshot.accountID,
                tenantID: snapshot.tenantID,
                imUID: snapshot.imUID,
                imToken: snapshot.imToken,
                tenantAPIBaseURL: snapshot.tenantAPIBaseURL,
                imAPIBaseURL: snapshot.imAPIBaseURL,
                platformAuthSession: snapshot.platformAuthSession,
                tenantAuthSession: snapshot.tenantAuthSession,
                appID: snapshot.appID,
                deviceID: snapshot.deviceID,
                accessExpiresAt: snapshot.accessExpiresAt,
                credentialRevision: snapshot.credentialRevision,
                sessionEpoch: snapshot.sessionEpoch,
                pendingRefreshRequestID: snapshot.pendingRefreshRequestID
            )
        }
        return IMAPIContext(
            platformToken: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.platformToken", defaults: defaults, sessionStore: sessionStore),
            accountID: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.accountID", defaults: defaults, sessionStore: sessionStore),
            tenantID: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.tenantID", defaults: defaults, sessionStore: sessionStore),
            imUID: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.imUID", defaults: defaults, sessionStore: sessionStore),
            imToken: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.imToken", defaults: defaults, sessionStore: sessionStore),
            tenantAPIBaseURL: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.tenantAPIBaseURL", defaults: defaults, sessionStore: sessionStore),
            imAPIBaseURL: sessionWasExplicitlyCleared ? nil : storedSessionValue(forKey: "im2.ios.imAPIBaseURL", defaults: defaults, sessionStore: sessionStore),
            platformAuthSession: sessionWasExplicitlyCleared ? nil : storedAuthSession(forKey: platformAuthSessionKey, defaults: defaults, sessionStore: sessionStore),
            tenantAuthSession: sessionWasExplicitlyCleared ? nil : storedAuthSession(forKey: tenantAuthSessionKey, defaults: defaults, sessionStore: sessionStore),
            appID: appID,
            deviceID: deviceID,
            accessExpiresAt: 0,
            credentialRevision: 0,
            sessionEpoch: UUID().uuidString,
            pendingRefreshRequestID: nil
        )
    }

    static var allowsRuntimeAppIDOverride: Bool {
        #if DEBUG
        IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(debugBuild: true)
        #else
        false
        #endif
    }

    static func configuredIOSAppID(storedAppID: String?) -> String {
        normalizedIOSAppID(storedAppID, allowCustomAppID: allowsRuntimeAppIDOverride)
    }

    static func shouldClearStoredSessionForAppIDMigration(storedAppID: String?, normalizedAppID: String) -> Bool {
        let stored = (storedAppID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return false }
        let normalized = normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == canonicalIOSAppID && stored != normalized
    }

    static func normalizedIOSAppID(_ rawValue: String?) -> String {
        normalizedIOSAppID(rawValue, allowCustomAppID: allowsRuntimeAppIDOverride)
    }

    static func normalizedIOSAppID(_ rawValue: String?, allowCustomAppID: Bool) -> String {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", "jht-ios-main", "ios-main", "web-main", "web-demo", "com.jianhuitongqiyetest.app", "com.jianhuitongim.app", "com.jianhuitong.app":
            return canonicalIOSAppID
        default:
            return allowCustomAppID ? trimmed : canonicalIOSAppID
        }
    }

    init(
        platformToken: String?,
        accountID: String?,
        tenantID: String?,
        imUID: String?,
        imToken: String?,
        tenantAPIBaseURL: String? = nil,
        imAPIBaseURL: String? = nil,
        platformAuthSession: IMStoredAuthSession?,
        tenantAuthSession: IMStoredAuthSession?,
        appID: String,
        deviceID: String,
        accessExpiresAt: Int64 = 0,
        credentialRevision: Int64 = 0,
        sessionEpoch: String = UUID().uuidString,
        pendingRefreshRequestID: String? = nil
    ) {
        self.platformToken = platformToken
        self.accountID = accountID
        self.tenantID = tenantID
        self.imUID = imUID
        self.imToken = imToken
        self.tenantAPIBaseURL = tenantAPIBaseURL
        self.imAPIBaseURL = imAPIBaseURL
        self.platformAuthSession = platformAuthSession
        self.tenantAuthSession = tenantAuthSession
        self.appID = IMAPIContext.normalizedIOSAppID(appID)
        self.deviceID = deviceID
        self.accessExpiresAt = max(0, accessExpiresAt)
        self.credentialRevision = max(0, credentialRevision)
        let normalizedEpoch = sessionEpoch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionEpoch = normalizedEpoch.isEmpty ? UUID().uuidString : normalizedEpoch
        let normalizedRefreshID = pendingRefreshRequestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.pendingRefreshRequestID = normalizedRefreshID.isEmpty ? nil : normalizedRefreshID
    }

    static func iosAppIDCandidates(preferred rawValue: String?) -> [String] {
        iosAppIDCandidates(preferred: rawValue, allowCustomAppID: allowsRuntimeAppIDOverride)
    }

    static func iosAppIDCandidates(preferred rawValue: String?, allowCustomAppID: Bool) -> [String] {
        guard allowCustomAppID else {
            return [canonicalIOSAppID]
        }
        let preferred = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return [
            canonicalIOSAppID,
            normalizedIOSAppID(preferred),
            preferred,
            "jht-ios-main",
            "ios-main",
            "web-main",
            "web-demo"
        ].compactMap { candidate -> String? in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }
    }

    static func clearStoredSession(
        resetDeviceIdentity: Bool = false,
        defaults: UserDefaults = .standard,
        sessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore()
    ) {
        // The tombstone is the authoritative logout commit. Persist it before
        // best-effort credential deletion so a crash between the two steps can
        // never resurrect an older protected snapshot.
        defaults.set(Date().timeIntervalSince1970, forKey: sessionClearedMarkerKey)
        defaults.synchronize()
        removeStoredSessionValues(defaults: defaults, sessionStore: sessionStore)
        if resetDeviceIdentity {
            defaults.removeObject(forKey: "im2.ios.deviceID")
        }
        defaults.synchronize()
    }

    private static func removeStoredSessionValues(
        defaults: UserDefaults,
        sessionStore: any IMProtectedSessionStoring
    ) {
        sessionStore.deleteAll()
        storedSessionKeys.forEach {
            sessionStore.deleteString(forKey: $0)
            defaults.removeObject(forKey: $0)
        }
        IMCurrentUserIdentityCache.clearAll(defaults: defaults)
        SplashSnapshotStore.clearAll(defaults: defaults)
    }

    private static func storedSessionValue(
        forKey key: String,
        defaults: UserDefaults,
        sessionStore: any IMProtectedSessionStoring
    ) -> String? {
        if let keychainValue = sessionStore.string(forKey: key) {
            defaults.removeObject(forKey: key)
            return keychainValue
        }
        guard let legacyValue = defaults.string(forKey: key),
              !legacyValue.isEmpty else {
            return nil
        }
        if sessionStore.setString(legacyValue, forKey: key) {
            defaults.removeObject(forKey: key)
        }
        // Historical compatibility only: if protected storage is temporarily
        // inaccessible, retain the existing migration source and keep this
        // launch authenticated. New session values are never written here.
        return legacyValue
    }

    private static func protectedSessionSnapshot(
        sessionStore: any IMProtectedSessionStoring
    ) -> IMProtectedSessionSnapshot? {
        guard let value = sessionStore.string(forKey: protectedSessionSnapshotKey),
              let data = value.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(IMProtectedSessionSnapshot.self, from: data),
              snapshot.formatVersion == 2,
              !snapshot.sessionEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return snapshot
    }

    private static func storedAuthSession(
        forKey key: String,
        defaults: UserDefaults,
        sessionStore: any IMProtectedSessionStoring
    ) -> IMStoredAuthSession? {
        guard let value = storedSessionValue(
            forKey: key,
            defaults: defaults,
            sessionStore: sessionStore
        ),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(IMStoredAuthSession.self, from: data)
    }

    private func setOptionalAuthSession(
        _ value: IMStoredAuthSession?,
        forKey key: String,
        defaults: UserDefaults,
        sessionStore: any IMProtectedSessionStoring
    ) -> Bool {
        if let value, value.isUsable,
           let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            guard sessionStore.setString(encoded, forKey: key),
                  sessionStore.string(forKey: key) == encoded else { return false }
            defaults.removeObject(forKey: key)
            return true
        } else {
            let deleted = sessionStore.deleteString(forKey: key)
            defaults.removeObject(forKey: key)
            return deleted && sessionStore.string(forKey: key) == nil
        }
    }

    private func setOptionalSession(
        _ value: String?,
        forKey key: String,
        defaults: UserDefaults,
        sessionStore: any IMProtectedSessionStoring
    ) -> Bool {
        if let value, !value.isEmpty {
            guard sessionStore.setString(value, forKey: key),
                  sessionStore.string(forKey: key) == value else { return false }
            defaults.removeObject(forKey: key)
            return true
        } else {
            let deleted = sessionStore.deleteString(forKey: key)
            defaults.removeObject(forKey: key)
            return deleted && sessionStore.string(forKey: key) == nil
        }
    }

    @discardableResult
    func save(
        defaults: UserDefaults = .standard,
        sessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore()
    ) -> IMProtectedSessionSaveResult {
        let normalizedAppID = Self.normalizedIOSAppID(appID)
        let snapshot = IMProtectedSessionSnapshot(
            formatVersion: 2,
            platformToken: platformToken,
            accountID: accountID,
            tenantID: tenantID,
            imUID: imUID,
            imToken: imToken,
            tenantAPIBaseURL: tenantAPIBaseURL,
            imAPIBaseURL: imAPIBaseURL,
            platformAuthSession: platformAuthSession,
            tenantAuthSession: tenantAuthSession,
            appID: normalizedAppID,
            deviceID: deviceID,
            accessExpiresAt: accessExpiresAt,
            credentialRevision: credentialRevision,
            sessionEpoch: sessionEpoch,
            pendingRefreshRequestID: pendingRefreshRequestID
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let encoded = String(data: data, encoding: .utf8),
              sessionStore.setString(encoded, forKey: Self.protectedSessionSnapshotKey),
              sessionStore.string(forKey: Self.protectedSessionSnapshotKey) == encoded else {
            return .failed
        }
        defaults.set(normalizedAppID, forKey: "im2.ios.appID")
        defaults.set(deviceID, forKey: "im2.ios.deviceID")
        // One Keychain item is the commit record. SecItemUpdate atomically
        // replaces it, so a crash leaves either the prior complete snapshot or
        // this complete snapshot; it can never expose a mixed token family.
        defaults.removeObject(forKey: Self.sessionClearedMarkerKey)
        Self.storedSessionKeys.forEach { key in
            guard key != Self.protectedSessionSnapshotKey else { return }
            _ = sessionStore.deleteString(forKey: key)
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        return .committed
    }

    mutating func persistAuthSession(
        _ session: RemoteAuthSession?,
        fallbackTokenType: String?,
        fallbackTenantID: String?,
        fallbackAccessExpiresAt: Int64 = 0
    ) {
        guard let session, session.isUsable else { return }
        let tokenType = session.normalizedTokenType.isEmpty ? (fallbackTokenType ?? "") : session.normalizedTokenType
        let tenant = session.tenantID.isEmpty ? (fallbackTenantID ?? "") : session.tenantID
        let previous = tokenType == "platform" ? platformAuthSession : tenantAuthSession
        let nextAuthVersion = session.authVersion > 0 ? session.authVersion : (previous?.authVersion ?? 0)
        let nextSessionGeneration = session.sessionGeneration > 0 ? session.sessionGeneration : (previous?.sessionGeneration ?? 0)
        // JHT_MOD_BEGIN AUTH_REFRESH_EXPIRES_AT_PERSISTENCE
        let nextAccessExpiresAt = session.accessExpiresAt > 0
            ? session.accessExpiresAt
            : (fallbackAccessExpiresAt > 0 ? fallbackAccessExpiresAt : (previous?.accessExpiresAt ?? 0))
        // JHT_MOD_END AUTH_REFRESH_EXPIRES_AT_PERSISTENCE
        let stored = IMStoredAuthSession(
            sessionID: session.sessionID,
            refreshToken: session.refreshToken,
            refreshExpiresAt: session.refreshExpiresAt,
            tokenType: tokenType,
            tenantID: tenant,
            accountID: accountID ?? "",
            appID: Self.normalizedIOSAppID(session.appID.isEmpty ? appID : session.appID),
            deviceID: session.deviceID.isEmpty ? deviceID : session.deviceID,
            clientType: session.clientType.isEmpty ? "ios" : session.clientType,
            authVersion: nextAuthVersion,
            sessionGeneration: nextSessionGeneration,
            accessExpiresAt: nextAccessExpiresAt,
            lifetimeMode: session.lifetimeMode
        )
        if let previous,
           previous.sessionID != stored.sessionID
            || previous.accountID != stored.accountID
            || previous.tenantID != stored.tenantID
            || previous.appID != stored.appID
            || previous.deviceID != stored.deviceID {
            sessionEpoch = UUID().uuidString
        }
        credentialRevision &+= 1
        if nextAccessExpiresAt > 0 {
            accessExpiresAt = nextAccessExpiresAt
        }
        if stored.normalizedTokenType == "platform" {
            platformAuthSession = stored
        } else {
            tenantAuthSession = stored
        }
    }

    mutating func advanceAccessCredential(
        authVersion: Int64,
        sessionGeneration: Int64,
        accessExpiresAt: Int64
    ) {
        if let current = tenantAuthSession {
            tenantAuthSession = IMStoredAuthSession(
                sessionID: current.sessionID,
                refreshToken: current.refreshToken,
                refreshExpiresAt: current.refreshExpiresAt,
                tokenType: current.tokenType,
                tenantID: current.tenantID,
                accountID: current.accountID,
                appID: current.appID,
                deviceID: current.deviceID,
                clientType: current.clientType,
                authVersion: authVersion > 0 ? authVersion : current.authVersion,
                sessionGeneration: sessionGeneration > 0 ? sessionGeneration : current.sessionGeneration,
                accessExpiresAt: accessExpiresAt > 0 ? accessExpiresAt : current.accessExpiresAt,
                lifetimeMode: current.lifetimeMode
            )
        }
        if accessExpiresAt > 0 {
            self.accessExpiresAt = accessExpiresAt
        }
        credentialRevision &+= 1
    }

    mutating func clearSession(
        defaults: UserDefaults = .standard,
        sessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore()
    ) {
        credentialRevision &+= 1
        sessionEpoch = UUID().uuidString
        IMCurrentUserIdentityCache.clearAll(defaults: defaults)
        platformToken = nil
        accountID = nil
        tenantID = nil
        imUID = nil
        imToken = nil
        tenantAPIBaseURL = nil
        imAPIBaseURL = nil
        platformAuthSession = nil
        tenantAuthSession = nil
        accessExpiresAt = 0
        pendingRefreshRequestID = nil
        Self.clearStoredSession(defaults: defaults, sessionStore: sessionStore)
    }

    func registrationPlatformContext(
        sessionID: String, tenantID: String, sessionStore: any IMProtectedSessionStoring
    ) -> IMAPIContext? {
        guard platformAuthSession?.sessionID == sessionID, platformToken?.isEmpty == false,
              let snapshot = Self.protectedSessionSnapshot(sessionStore: sessionStore),
              accountID == snapshot.accountID,
              Self.normalizedIOSAppID(snapshot.appID) == Self.normalizedIOSAppID(appID),
              snapshot.deviceID == deviceID, snapshot.tenantID == tenantID,
              let platform = snapshot.platformAuthSession, platform.isUsable,
              platform.sessionID == sessionID, platform.normalizedTokenType == "platform",
              platform.appID == Self.normalizedIOSAppID(appID), platform.deviceID == deviceID,
              platform.clientType == "ios", platform.accountID == snapshot.accountID,
              snapshot.platformToken?.isEmpty == false else { return nil }
        var restored = self
        restored.platformToken = snapshot.platformToken
        restored.accountID = snapshot.accountID
        restored.tenantID = snapshot.tenantID
        restored.platformAuthSession = platform
        restored.credentialRevision = snapshot.credentialRevision
        restored.sessionEpoch = snapshot.sessionEpoch
        restored.pendingRefreshRequestID = snapshot.pendingRefreshRequestID
        restored.discardRegistrationIMState()
        return restored
    }

    mutating func discardRegistrationIMState() {
        imUID = nil
        imToken = nil
        tenantAPIBaseURL = nil
        imAPIBaseURL = nil
        tenantAuthSession = nil
        accessExpiresAt = platformAuthSession?.accessExpiresAt ?? 0
    }

    mutating func clearIMSessionPreservingPlatform(
        defaults: UserDefaults = .standard,
        sessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore()
    ) {
        credentialRevision &+= 1
        sessionEpoch = UUID().uuidString
        IMCurrentUserIdentityCache.clear(context: self, defaults: defaults)
        tenantID = nil
        imUID = nil
        imToken = nil
        tenantAPIBaseURL = nil
        imAPIBaseURL = nil
        tenantAuthSession = nil
        accessExpiresAt = platformAuthSession?.accessExpiresAt ?? 0
        pendingRefreshRequestID = nil
        save(defaults: defaults, sessionStore: sessionStore)
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END
