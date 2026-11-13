import Security
import SwiftUI
import UIKit
import WebKit

struct RememberedLoginCredentialScope: Hashable {
    let appID: String
    let deviceID: String

    init(appID: String, deviceID: String) {
        self.appID = IMAPIContext.normalizedIOSAppID(appID)
        self.deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(context: IMAPIContext) {
        self.init(appID: context.appID, deviceID: context.deviceID)
    }

    fileprivate var storageKey: String {
        Data("\(appID)\u{0}\(deviceID)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct RememberedLoginCredentials: Equatable {
    let mode: LoginMode
    let identifier: String
    let password: String
}

struct RememberedLoginCredentialIdentity: Codable, Equatable {
    let mode: LoginMode
    let normalizedIdentifier: String

    init?(mode: LoginMode, identifier: String) {
        let normalizedIdentifier = Self.normalize(identifier, mode: mode)
        guard !normalizedIdentifier.isEmpty else { return nil }
        self.mode = mode
        self.normalizedIdentifier = normalizedIdentifier
    }

    static func normalize(_ identifier: String, mode: LoginMode) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .phone:
            return trimmed.filter(\.isNumber)
        case .account:
            return trimmed.precomposedStringWithCompatibilityMapping.lowercased()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case normalizedIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modeValue = try container.decode(String.self, forKey: .mode)
        guard ["phone", "account"].contains(modeValue),
              let mode = LoginMode(rawValue: modeValue == "phone" ? "手机号" : "账号") else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "Unsupported remembered-login mode"
            )
        }
        let normalizedIdentifier = try container.decode(String.self, forKey: .normalizedIdentifier)
        guard let identity = Self(mode: mode, identifier: normalizedIdentifier),
              identity.normalizedIdentifier == normalizedIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .normalizedIdentifier,
                in: container,
                debugDescription: "Remembered-login identifier is not canonical"
            )
        }
        self = identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.storageValue, forKey: .mode)
        try container.encode(normalizedIdentifier, forKey: .normalizedIdentifier)
    }
}

struct RememberedLoginAutofillBinding: Equatable {
    let identity: RememberedLoginCredentialIdentity

    init?(credentials: RememberedLoginCredentials) {
        guard let identity = RememberedLoginCredentialIdentity(
            mode: credentials.mode,
            identifier: credentials.identifier
        ) else { return nil }
        self.identity = identity
    }

    func stillMatches(mode: LoginMode, identifier: String) -> Bool {
        RememberedLoginCredentialIdentity(mode: mode, identifier: identifier) == identity
    }
}

protocol RememberedLoginPreferencePersisting: AnyObject {
    func value(scope: RememberedLoginCredentialScope) -> Bool?
    func set(_ enabled: Bool, scope: RememberedLoginCredentialScope)
}

/// Persists only the user's non-secret checkbox choice. Login identifiers and
/// passwords remain exclusively under `RememberedLoginCredentialPersisting`.
final class UserDefaultsRememberedLoginPreferenceStore: RememberedLoginPreferencePersisting {
    private static let preferencePrefix = "jianhuitong.login.rememberCredentials.preference.v1"
    private static let legacyV2Prefix = "jianhuitong.login.rememberCredentials.v2"
    private static let legacyUnscopedEnabledKey = "jianhuitong.login.rememberCredentials.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value(scope: RememberedLoginCredentialScope) -> Bool? {
        guard scopeIsUsable(scope) else { return nil }
        let key = preferenceKey(scope)
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }

        // Capture the previous implementation's explicit choice before the
        // credential authority removes its legacy metadata during migration.
        for legacyKey in [legacyV2EnabledKey(scope), Self.legacyUnscopedEnabledKey] {
            guard let value = defaults.object(forKey: legacyKey) as? Bool else { continue }
            defaults.set(value, forKey: key)
            return value
        }
        return nil
    }

    func set(_ enabled: Bool, scope: RememberedLoginCredentialScope) {
        guard scopeIsUsable(scope) else { return }
        defaults.set(enabled, forKey: preferenceKey(scope))
    }

    private func scopeIsUsable(_ scope: RememberedLoginCredentialScope) -> Bool {
        !scope.appID.isEmpty && !scope.deviceID.isEmpty
    }

    private func preferenceKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.preferencePrefix).\(scope.storageKey)"
    }

    private func legacyV2EnabledKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2Prefix).\(scope.storageKey).enabled"
    }
}

protocol RememberedLoginCredentialPersisting: AnyObject {
    func load(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentials?

    @discardableResult
    func save(
        _ credentials: RememberedLoginCredentials,
        scope: RememberedLoginCredentialScope
    ) -> Bool

    func clear(scope: RememberedLoginCredentialScope)
}

enum RememberedLoginSecretRead {
    case found(Data)
    case missing
    case unavailable
}

protocol RememberedLoginSecretStoring: AnyObject {
    func data(service: String, account: String) -> Data?
    func read(service: String, account: String) -> RememberedLoginSecretRead
    func set(_ data: Data, service: String, account: String) -> Bool
    func delete(service: String, account: String) -> Bool
}

extension RememberedLoginSecretStoring {
    func read(service: String, account: String) -> RememberedLoginSecretRead {
        data(service: service, account: account).map(RememberedLoginSecretRead.found) ?? .missing
    }
}

final class SystemRememberedLoginSecretStore: RememberedLoginSecretStoring {
    func data(service: String, account: String) -> Data? {
        guard case .found(let data) = read(service: service, account: account) else { return nil }
        return data
    }

    func read(service: String, account: String) -> RememberedLoginSecretRead {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data else { return .unavailable }
        return .found(data)
    }

    func set(_ data: Data, service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class KeychainRememberedLoginCredentialStore: RememberedLoginCredentialPersisting {
    private struct ProtectedCredentialRecord: Codable {
        static let currentVersion = 4

        let version: Int
        let mode: String
        let normalizedIdentifier: String
        let password: String

        init(identity: RememberedLoginCredentialIdentity, password: String) {
            version = Self.currentVersion
            mode = identity.mode.storageValue
            normalizedIdentifier = identity.normalizedIdentifier
            self.password = password
        }
    }

    private struct ScopeDenyRecord: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let credentialAccounts: [String]

        init(credentialAccounts: [String]) {
            version = Self.currentVersion
            self.credentialAccounts = Array(Set(credentialAccounts.filter { !$0.isEmpty })).sorted()
        }
    }

    private static let keychainService = "jianhuitong.ios.login.remembered-credentials.v4"
    private static let indexService = "jianhuitong.ios.login.remembered-credentials-index.v4"
    private static let tombstoneService = "jianhuitong.ios.login.remembered-credentials-deny.v4"
    private static let tombstoneDefaultsPrefix = "jianhuitong.login.rememberCredentials.deny.v4"
    private static let legacyV3KeychainService = "jianhuitong.ios.login.remembered-credentials.v3"
    private static let legacyV2KeychainService = "jianhuitong.ios.login.remembered-password.v2"
    private static let legacyV2DefaultsPrefix = "jianhuitong.login.rememberCredentials.v2"
    private static let legacyEnabledKey = "jianhuitong.login.rememberCredentials.enabled"
    private static let legacyModeKey = "jianhuitong.login.rememberCredentials.mode"
    private static let legacyPhoneKey = "jianhuitong.login.rememberCredentials.phone"
    private static let legacyAccountKey = "jianhuitong.login.rememberCredentials.account"
    private static let legacyKeychainService = "jianhuitong.ios.login.remembered-password"
    private static let legacyKeychainAccount = "latest"

    private let defaults: UserDefaults
    private let secretStore: any RememberedLoginSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secretStore: any RememberedLoginSecretStoring = SystemRememberedLoginSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    func load(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentials? {
        guard scopeIsUsable(scope) else { return nil }
        guard !scopeIsBlocked(scope) else { return nil }
        guard purgeLegacyScopeRecords(scope: scope), purgeLegacyUnscopedRecord() else {
            _ = blockScope(scope)
            return nil
        }
        guard let indexData = secretStore.data(service: Self.indexService, account: scope.storageKey),
              let identity = try? JSONDecoder().decode(
                RememberedLoginCredentialIdentity.self,
                from: indexData
              ),
              let protectedData = secretStore.data(
                service: Self.keychainService,
                account: credentialAccount(scope: scope, identity: identity)
              ),
              let credentials = protectedCredentials(from: protectedData, expected: identity) else {
            clear(scope: scope)
            return nil
        }
        return credentials
    }

    @discardableResult
    func save(
        _ credentials: RememberedLoginCredentials,
        scope: RememberedLoginCredentialScope
    ) -> Bool {
        guard scopeIsUsable(scope),
              let identity = RememberedLoginCredentialIdentity(
                mode: credentials.mode,
                identifier: credentials.identifier
              ),
              !credentials.password.isEmpty else {
            clear(scope: scope)
            return false
        }
        let priorIndexData = secretStore.data(service: Self.indexService, account: scope.storageKey)
        let priorIdentity = priorIndexData.flatMap {
            try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: $0)
        }
        let account = credentialAccount(scope: scope, identity: identity)
        var accountsRequiringCleanup = blockedCredentialAccounts(scope)
        accountsRequiringCleanup.append(account)
        if let priorIdentity {
            accountsRequiringCleanup.append(credentialAccount(scope: scope, identity: priorIdentity))
        }
        guard blockScope(scope, credentialAccounts: accountsRequiringCleanup),
              priorIndexData == nil || priorIdentity != nil else { return false }
        let record = ProtectedCredentialRecord(identity: identity, password: credentials.password)
        guard let protectedData = try? JSONEncoder().encode(record),
              let indexData = try? JSONEncoder().encode(identity),
              secretStore.set(
            protectedData,
            service: Self.keychainService,
            account: account
        ), secretStore.data(service: Self.keychainService, account: account) == protectedData else {
            _ = deleteAndVerify(service: Self.keychainService, account: account)
            return false
        }
        let staleAccounts = Set(accountsRequiringCleanup).subtracting([account])
        for staleAccount in staleAccounts {
            guard deleteAndVerify(service: Self.keychainService, account: staleAccount) else {
                return false
            }
        }
        guard secretStore.set(
            indexData,
            service: Self.indexService,
            account: scope.storageKey
        ), secretStore.data(service: Self.indexService, account: scope.storageKey) == indexData else {
            _ = deleteAndVerify(service: Self.keychainService, account: account)
            return false
        }
        let staleCredentialsAreAbsent = staleAccounts.allSatisfy {
            secretStore.data(service: Self.keychainService, account: $0) == nil
        }
        guard purgeLegacyScopeRecords(scope: scope),
              purgeLegacyUnscopedRecord(),
              secretStore.data(service: Self.indexService, account: scope.storageKey) == indexData,
              secretStore.data(service: Self.keychainService, account: account) == protectedData,
              protectedCredentials(from: protectedData, expected: identity) != nil,
              staleCredentialsAreAbsent else { return false }
        return unblockScope(scope)
    }

    func clear(scope: RememberedLoginCredentialScope) {
        guard scopeIsUsable(scope) else { return }
        let indexData = secretStore.data(service: Self.indexService, account: scope.storageKey)
        let identity = indexData.flatMap {
            try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: $0)
        }
        var accountsRequiringCleanup = blockedCredentialAccounts(scope)
        if let identity {
            accountsRequiringCleanup.append(credentialAccount(scope: scope, identity: identity))
        }
        guard blockScope(scope, credentialAccounts: accountsRequiringCleanup) else { return }
        var fullyRemoved = indexData == nil || identity != nil
        for credentialAccount in Set(accountsRequiringCleanup) {
            fullyRemoved = deleteAndVerify(
                service: Self.keychainService,
                account: credentialAccount
            ) && fullyRemoved
        }
        if fullyRemoved {
            fullyRemoved = deleteAndVerify(
                service: Self.indexService,
                account: scope.storageKey
            ) && fullyRemoved
        }
        fullyRemoved = purgeLegacyScopeRecords(scope: scope) && fullyRemoved
        fullyRemoved = purgeLegacyUnscopedRecord() && fullyRemoved
        if fullyRemoved {
            _ = unblockScope(scope)
        }
    }

    private func previousIdentity(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentialIdentity? {
        guard let data = secretStore.data(service: Self.indexService, account: scope.storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: data)
    }

    private func credentialAccount(
        scope: RememberedLoginCredentialScope,
        identity: RememberedLoginCredentialIdentity
    ) -> String {
        Data(
            "\(scope.storageKey)\u{0}\(identity.mode.storageValue)\u{0}\(identity.normalizedIdentifier)".utf8
        )
        .base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
    }

    private func scopeIsUsable(_ scope: RememberedLoginCredentialScope) -> Bool {
        !scope.appID.isEmpty && !scope.deviceID.isEmpty
    }

    private func exactMode(_ value: String?) -> LoginMode? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "phone": return .phone
        case "account": return .account
        default: return nil
        }
    }

    private func protectedCredentials(
        from data: Data,
        expected identity: RememberedLoginCredentialIdentity
    ) -> RememberedLoginCredentials? {
        guard let record = try? JSONDecoder().decode(ProtectedCredentialRecord.self, from: data),
              record.version == ProtectedCredentialRecord.currentVersion,
              let mode = exactMode(record.mode),
              let decodedIdentity = RememberedLoginCredentialIdentity(
                mode: mode,
                identifier: record.normalizedIdentifier
              ),
              decodedIdentity == identity else {
            return nil
        }
        guard !record.password.isEmpty else { return nil }
        return RememberedLoginCredentials(
            mode: mode,
            identifier: identity.normalizedIdentifier,
            password: record.password
        )
    }

    private func clearLegacyV2Record(scope: RememberedLoginCredentialScope) -> Bool {
        defaults.removeObject(forKey: legacyV2EnabledKey(scope))
        defaults.removeObject(forKey: legacyV2ModeKey(scope))
        defaults.removeObject(forKey: legacyV2IdentifierKey(scope))
        return deleteAndVerify(
            service: Self.legacyV2KeychainService,
            account: scope.storageKey
        )
    }

    private func purgeLegacyScopeRecords(scope: RememberedLoginCredentialScope) -> Bool {
        let removedV3 = deleteAndVerify(
            service: Self.legacyV3KeychainService,
            account: scope.storageKey
        )
        let removedV2 = clearLegacyV2Record(scope: scope)
        return removedV3 && removedV2
    }

    private func legacyV2EnabledKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).enabled"
    }

    private func legacyV2ModeKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).mode"
    }

    private func legacyV2IdentifierKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).identifier"
    }

    private func tombstoneDefaultsKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.tombstoneDefaultsPrefix).\(scope.storageKey)"
    }

    private func scopeIsBlocked(_ scope: RememberedLoginCredentialScope) -> Bool {
        defaults.bool(forKey: tombstoneDefaultsKey(scope))
            || secretStore.data(service: Self.tombstoneService, account: scope.storageKey) != nil
    }

    private func blockedCredentialAccounts(_ scope: RememberedLoginCredentialScope) -> [String] {
        guard let data = secretStore.data(service: Self.tombstoneService, account: scope.storageKey),
              let record = try? JSONDecoder().decode(ScopeDenyRecord.self, from: data),
              record.version == ScopeDenyRecord.currentVersion else { return [] }
        return record.credentialAccounts
    }

    @discardableResult
    private func blockScope(
        _ scope: RememberedLoginCredentialScope,
        credentialAccounts: [String] = []
    ) -> Bool {
        defaults.set(true, forKey: tombstoneDefaultsKey(scope))
        let existingData = secretStore.data(service: Self.tombstoneService, account: scope.storageKey)
        let existingRecord: ScopeDenyRecord?
        if let existingData {
            existingRecord = try? JSONDecoder().decode(ScopeDenyRecord.self, from: existingData)
            guard existingRecord?.version == ScopeDenyRecord.currentVersion else { return false }
        } else {
            existingRecord = nil
        }
        let record = ScopeDenyRecord(
            credentialAccounts: (existingRecord?.credentialAccounts ?? []) + credentialAccounts
        )
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return secretStore.set(
            data,
            service: Self.tombstoneService,
            account: scope.storageKey
        ) && secretStore.data(
            service: Self.tombstoneService,
            account: scope.storageKey
        ) == data
    }

    @discardableResult
    private func unblockScope(_ scope: RememberedLoginCredentialScope) -> Bool {
        guard secretStore.delete(service: Self.tombstoneService, account: scope.storageKey),
              secretStore.data(service: Self.tombstoneService, account: scope.storageKey) == nil else {
            return false
        }
        defaults.removeObject(forKey: tombstoneDefaultsKey(scope))
        return !scopeIsBlocked(scope)
    }

    @discardableResult
    private func deleteAndVerify(service: String, account: String) -> Bool {
        secretStore.delete(service: service, account: account)
            && secretStore.data(service: service, account: account) == nil
    }

    private func purgeLegacyUnscopedRecord() -> Bool {
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        defaults.removeObject(forKey: Self.legacyModeKey)
        defaults.removeObject(forKey: Self.legacyPhoneKey)
        defaults.removeObject(forKey: Self.legacyAccountKey)
        return deleteAndVerify(
            service: Self.legacyKeychainService,
            account: Self.legacyKeychainAccount
        )
    }
}
