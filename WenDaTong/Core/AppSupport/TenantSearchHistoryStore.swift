// WDT_IOS1_SEARCH_HISTORY_20261113_BEGIN
import CryptoKit
import Foundation

// Callers check the current session and conversation authority immediately before each operation.
@MainActor
final class TenantSearchHistoryStore {
    struct Account: Hashable {
        fileprivate let storageKey: String

        init?(deployment: String, account: String) {
            guard !deployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            storageKey = tenantSearchHistoryKey(deployment, account)
        }
    }

    struct Scope: Hashable {
        fileprivate let account: Account
        fileprivate let tenantKey: String
        fileprivate let subjectKey: String
        fileprivate let conversationKey: String?

        init?(account: Account, tenant: String, imSubject: String, conversation: String? = nil) {
            guard !tenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !imSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  conversation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else { return nil }
            self.account = account
            tenantKey = tenantSearchHistoryKey(tenant)
            subjectKey = tenantSearchHistoryKey(imSubject)
            conversationKey = conversation.map { tenantSearchHistoryKey($0) }
        }
    }

    private struct SubjectHistory: Codable, Equatable {
        var global: [String] = []
        var conversations: [String: [String]] = [:]

        var isEmpty: Bool { global.isEmpty && conversations.isEmpty }

        subscript(conversation: String?) -> [String] {
            get { conversation.map { conversations[$0] ?? [] } ?? global }
            set {
                if let conversation {
                    conversations[conversation] = newValue.isEmpty ? nil : newValue
                } else {
                    global = newValue
                }
            }
        }
    }

    private struct AccountHistory: Codable, Equatable {
        static let currentVersion = 1

        var version = Self.currentVersion
        var tenants: [String: [String: SubjectHistory]] = [:]
    }

    // The pending record contains only hashed scope keys. Queries stay in Keychain.
    private enum Purge: Codable, Hashable {
        case account
        case tenant(String)
        case conversation(tenant: String, conversation: String)
        case scope(tenant: String, subject: String, conversation: String?)

        func includes(_ scope: Scope) -> Bool {
            switch self {
            case .account:
                return true
            case .tenant(let tenant):
                return scope.tenantKey == tenant
            case .conversation(let tenant, let conversation):
                return scope.tenantKey == tenant && scope.conversationKey == conversation
            case .scope(let tenant, let subject, let conversation):
                return scope.tenantKey == tenant && scope.subjectKey == subject && scope.conversationKey == conversation
            }
        }

        func apply(to record: inout AccountHistory) {
            switch self {
            case .account:
                record.tenants.removeAll()
            case .tenant(let tenant):
                record.tenants[tenant] = nil
            case .conversation(let tenant, let conversation):
                guard let subjects = record.tenants[tenant] else { return }
                let remaining = subjects.compactMapValues { current -> SubjectHistory? in
                    var subject = current
                    subject[conversation] = []
                    return subject.isEmpty ? nil : subject
                }
                record.tenants[tenant] = remaining.isEmpty ? nil : remaining
            case .scope(let tenant, let subject, let conversation):
                guard var subjects = record.tenants[tenant], var history = subjects[subject] else { return }
                history[conversation] = []
                subjects[subject] = history.isEmpty ? nil : history
                record.tenants[tenant] = subjects.isEmpty ? nil : subjects
            }
        }
    }

    private static let service = "jianhuitong.ios.search.recent-queries.v1"
    private static let pendingKeyPrefix = "jianhuitong.ios.search.pending-purge.v1."
    private static let limit = 20
    private let secretStore: any RememberedLoginSecretStoring
    private let purgeDefaults: UserDefaults?
    private var pendingInMemory: [Account: Set<Purge>] = [:]

    convenience init() {
        self.init(secretStore: SystemRememberedLoginSecretStore(), purgeDefaults: .standard)
    }

    init(secretStore: any RememberedLoginSecretStoring, purgeDefaults: UserDefaults? = nil) {
        self.secretStore = secretStore
        self.purgeDefaults = purgeDefaults
    }

    func list(scope: Scope) -> [String] {
        if !flushPurges(scope.account) {
            guard let pending = pendingPurges(scope.account),
                  !pending.contains(where: { $0.includes(scope) }) else { return [] }
        }
        return load(scope.account)?.tenants[scope.tenantKey]?[scope.subjectKey]?[scope.conversationKey] ?? []
    }

    @discardableResult
    func add(_ query: String, scope: Scope) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mirror the search endpoint's keyword length contract.
        guard !term.isEmpty, term.utf8.count <= 256, term.unicodeScalars.count <= 64 else { return false }
        return editScope(scope) { current in
            [term] + current.lazy.filter { $0 != term }.prefix(Self.limit - 1)
        }
    }

    @discardableResult
    func remove(_ query: String, scope: Scope) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return editScope(scope) { $0.filter { $0 != term } }
    }

    @discardableResult
    func clear(scope: Scope) -> Bool {
        purge(.scope(tenant: scope.tenantKey, subject: scope.subjectKey, conversation: scope.conversationKey),
              account: scope.account)
    }

    @discardableResult
    func clearTenant(_ tenant: String, account: Account) -> Bool {
        guard !tenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return purge(.tenant(tenantSearchHistoryKey(tenant)), account: account)
    }

    @discardableResult
    func clearConversation(_ conversation: String, tenant: String, account: Account) -> Bool {
        guard !tenant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return purge(.conversation(tenant: tenantSearchHistoryKey(tenant), conversation: tenantSearchHistoryKey(conversation)),
                     account: account)
    }

    @discardableResult
    func clearAccount(_ account: Account) -> Bool {
        purge(.account, account: account)
    }

    private func purge(_ target: Purge, account: Account) -> Bool {
        if target == .account {
            savePurges([.account], account: account)
        } else {
            guard let pending = pendingPurges(account) else { return false }
            savePurges(pending.contains(.account) ? pending : pending.union([target]), account: account)
        }
        return flushPurges(account)
    }

    private func pendingPurges(_ account: Account) -> Set<Purge>? {
        if let pending = pendingInMemory[account] { return pending }
        guard let data = purgeDefaults?.data(forKey: Self.pendingKeyPrefix + account.storageKey) else { return [] }
        return try? JSONDecoder().decode(Set<Purge>.self, from: data)
    }

    private func savePurges(_ purges: Set<Purge>, account: Account) {
        guard let purgeDefaults else {
            pendingInMemory[account] = purges.isEmpty ? nil : purges
            return
        }
        let key = Self.pendingKeyPrefix + account.storageKey
        if purges.isEmpty {
            pendingInMemory[account] = nil
            purgeDefaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(purges) {
            pendingInMemory[account] = nil
            purgeDefaults.set(data, forKey: key)
        } else {
            pendingInMemory[account] = purges
        }
    }

    private func flushPurges(_ account: Account) -> Bool {
        guard let pending = pendingPurges(account) else { return false }
        guard !pending.isEmpty else { return true }
        let succeeded: Bool
        if pending.contains(.account) {
            succeeded = secretStore.delete(service: Self.service, account: account.storageKey)
        } else {
            succeeded = editAccount(account) { record in
                for target in pending { target.apply(to: &record) }
            }
        }
        if succeeded { savePurges([], account: account) }
        return succeeded
    }

    private func editScope(_ scope: Scope, edit: ([String]) -> [String]) -> Bool {
        guard let pending = pendingPurges(scope.account), flushPurges(scope.account),
              !pending.contains(where: { $0.includes(scope) }) else { return false }
        return editAccount(scope.account) { record in
            var subjects = record.tenants[scope.tenantKey] ?? [:]
            var subject = subjects[scope.subjectKey] ?? SubjectHistory()
            subject[scope.conversationKey] = edit(subject[scope.conversationKey])
            subjects[scope.subjectKey] = subject.isEmpty ? nil : subject
            record.tenants[scope.tenantKey] = subjects.isEmpty ? nil : subjects
        }
    }

    private func editAccount(_ account: Account, edit: (inout AccountHistory) -> Void) -> Bool {
        guard let original = load(account) else { return false }
        var updated = original
        edit(&updated)
        guard updated != original else { return true }
        if updated.tenants.isEmpty { return secretStore.delete(service: Self.service, account: account.storageKey) }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        return secretStore.set(data, service: Self.service, account: account.storageKey)
    }

    private func load(_ account: Account) -> AccountHistory? {
        switch secretStore.read(service: Self.service, account: account.storageKey) {
        case .missing:
            return AccountHistory()
        case .unavailable:
            return nil
        case .found(let data):
            guard let record = try? JSONDecoder().decode(AccountHistory.self, from: data),
                  record.version == AccountHistory.currentVersion else { return nil }
            return record
        }
    }
}

private func tenantSearchHistoryKey(_ parts: String...) -> String {
    var bytes = Data()
    for part in parts {
        let value = part.utf8
        bytes.append(contentsOf: "\(value.count):".utf8)
        bytes.append(contentsOf: value)
    }
    return Data(SHA256.hash(data: bytes)).base64EncodedString()
}
// WDT_IOS1_SEARCH_HISTORY_20261113_END
