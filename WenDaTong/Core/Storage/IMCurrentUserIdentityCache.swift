// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_BEGIN
import Foundation
import IM4Data

typealias IMStoredCurrentUserIdentity = IM4Data.IMStoredCurrentUserIdentity
typealias IMStoredCurrentProfileAuthorityCheckpoint = IM4Data.IMStoredCurrentProfileAuthorityCheckpoint

extension IMStoredCurrentUserIdentity {
    var isUsable: Bool {
        !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        user: IMUser,
        context: IMAPIContext,
        scope: String,
        profileAuthorityCheckpoint: CurrentProfileAuthorityCheckpoint? = nil,
        savedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.init(
            scope: scope,
            tenantID: context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            imUID: context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            accountID: context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            id: user.id.trimmingCharacters(in: .whitespacesAndNewlines),
            userID: user.userID.trimmingCharacters(in: .whitespacesAndNewlines),
            username: user.username.trimmingCharacters(in: .whitespacesAndNewlines),
            name: user.name.trimmingCharacters(in: .whitespacesAndNewlines),
            title: user.title.trimmingCharacters(in: .whitespacesAndNewlines),
            department: user.department.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: user.phone.trimmingCharacters(in: .whitespacesAndNewlines),
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines),
            email: user.email.trimmingCharacters(in: .whitespacesAndNewlines),
            status: user.status.trimmingCharacters(in: .whitespacesAndNewlines),
            enterprise: user.enterprise.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarSeed: user.avatarSeed,
            avatarURL: user.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarVersion: user.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarUpdatedAt: user.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines),
            badges: user.badges,
            profileAuthorityCheckpoint: IMStoredCurrentProfileAuthorityCheckpoint(
                checkpoint: profileAuthorityCheckpoint
            ),
            savedAt: savedAt
        )
    }

    var authorityCheckpoint: CurrentProfileAuthorityCheckpoint? {
        profileAuthorityCheckpoint?.makeCheckpoint()
    }

    func makeUser(fallbackEnterprise: String, fallbackSeed: UInt) -> IMUser {
        let resolvedID = id.isEmpty ? imUID : id
        let resolvedUserID = userID.isEmpty ? resolvedID : userID
        let resolvedName = name.isEmpty ? (username.isEmpty ? resolvedID : username) : name
        return IMUser(
            id: resolvedID,
            userID: resolvedUserID,
            username: username,
            name: resolvedName,
            title: title,
            department: department,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email.isEmpty ? accountID : email,
            status: status.isEmpty ? "在线" : status,
            enterprise: enterprise.isEmpty ? fallbackEnterprise : enterprise,
            avatarSeed: avatarSeed == 0 ? fallbackSeed : avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: badges
        )
    }
}

extension IMStoredCurrentProfileAuthorityCheckpoint {
    init?(checkpoint: CurrentProfileAuthorityCheckpoint?) {
        guard let checkpoint else { return nil }
        self.init(
            tenantID: checkpoint.scope.tenantID,
            actorIMUID: checkpoint.scope.actorIMUID,
            appID: checkpoint.scope.appID,
            userRevision: checkpoint.userRevision,
            identityGeneration: checkpoint.identityGeneration,
            nickname: checkpoint.nickname,
            avatar: checkpoint.avatar
        )
    }

    func makeCheckpoint() -> CurrentProfileAuthorityCheckpoint? {
        guard let scope = CurrentProfileAuthorityScope(
            tenantID: tenantID,
            actorIMUID: actorIMUID,
            appID: appID
        ),
              userRevision >= 0,
              identityGeneration >= 0 else {
            return nil
        }
        return CurrentProfileAuthorityCheckpoint(
            scope: scope,
            userRevision: userRevision,
            identityGeneration: identityGeneration,
            nickname: nickname,
            avatar: avatar
        )
    }
}

enum IMCurrentUserIdentityCache {
    static func scopeKey(for context: IMAPIContext) -> String {
        scopeKey(
            tenantID: context.tenantID ?? "",
            imUID: context.imUID ?? "",
            appID: IMAPIContext.normalizedIOSAppID(context.appID)
        )
    }

    static func scopeKey(tenantID: String, imUID: String, appID: String) -> String {
        [
            tenantID,
            imUID,
            appID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    private static func legacyScopeKey(for context: IMAPIContext) -> String {
        legacyScopeKey(
            tenantID: context.tenantID ?? "",
            imUID: context.imUID ?? "",
            accountID: context.accountID ?? ""
        )
    }

    private static func legacyScopeKey(tenantID: String, imUID: String, accountID: String) -> String {
        [
            tenantID,
            imUID,
            accountID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    static func load(context: IMAPIContext, defaults: UserDefaults = .standard) -> IMStoredCurrentUserIdentity? {
        let scope = scopeKey(for: context)
        let identities = storedIdentities(defaults: defaults)
        if !scope.isEmpty,
           let identity = identities[scope],
           identity.isUsable {
            return identity
        }
        let legacyScope = legacyScopeKey(for: context)
        guard !legacyScope.isEmpty,
              legacyScope != scope,
              let legacyIdentity = identities[legacyScope],
              legacyIdentity.isUsable else {
            return nil
        }
        return legacyIdentity
    }

    static func save(
        _ user: IMUser,
        context: IMAPIContext,
        profileAuthorityCheckpoint: CurrentProfileAuthorityCheckpoint? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard context.hasIMSession else { return }
        let scope = scopeKey(for: context)
        guard !scope.isEmpty else { return }
        var identities = storedIdentities(defaults: defaults)
        identities[scope] = IMStoredCurrentUserIdentity(
            user: user,
            context: context,
            scope: scope,
            profileAuthorityCheckpoint: profileAuthorityCheckpoint
        )
        persist(identities, defaults: defaults)
    }

    static func clear(context: IMAPIContext, defaults: UserDefaults = .standard) {
        let scope = scopeKey(for: context)
        let legacyScope = legacyScopeKey(for: context)
        guard !scope.isEmpty || !legacyScope.isEmpty else { return }
        var identities = storedIdentities(defaults: defaults)
        if !scope.isEmpty {
            identities.removeValue(forKey: scope)
        }
        if !legacyScope.isEmpty {
            identities.removeValue(forKey: legacyScope)
        }
        persist(identities, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        IM4Data.CurrentUserIdentityRecordStore.clearAll(defaults: defaults)
    }

    private static func storedIdentities(defaults: UserDefaults) -> [String: IMStoredCurrentUserIdentity] {
        IM4Data.CurrentUserIdentityRecordStore.loadAll(defaults: defaults)
    }

    private static func persist(_ identities: [String: IMStoredCurrentUserIdentity], defaults: UserDefaults) {
        IM4Data.CurrentUserIdentityRecordStore.persist(identities, defaults: defaults)
    }
}
// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_END
