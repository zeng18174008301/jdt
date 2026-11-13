import Foundation

final class MessagePersistenceScopePurgeFence: @unchecked Sendable {
    struct Token: Sendable {
        let id: UUID
        let scopeHash: String
    }

    private let lock = NSLock()
    private var activeTokens: [UUID: String] = [:]
    private var pendingCountByScope: [String: Int] = [:]
    private var waitersByScope: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedScopeHashes: Set<String> = []
    private var blocksAllScopes = false

    func register(scopeHash: String) -> Token {
        let token = Token(id: UUID(), scopeHash: scopeHash)
        lock.lock()
        activeTokens[token.id] = scopeHash
        pendingCountByScope[scopeHash, default: 0] += 1
        lock.unlock()
        return token
    }

    func complete(_ token: Token) {
        lock.lock()
        guard activeTokens.removeValue(forKey: token.id) != nil else {
            lock.unlock()
            return
        }
        let remaining = max((pendingCountByScope[token.scopeHash] ?? 1) - 1, 0)
        let waiters: [CheckedContinuation<Void, Never>]
        if remaining == 0 {
            pendingCountByScope.removeValue(forKey: token.scopeHash)
            waiters = waitersByScope.removeValue(forKey: token.scopeHash) ?? []
        } else {
            pendingCountByScope[token.scopeHash] = remaining
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForPendingPurge(scopeHash: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard (pendingCountByScope[scopeHash] ?? 0) > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            waitersByScope[scopeHash, default: []].append(continuation)
            lock.unlock()
        }
    }

    func block(scopeHash: String) {
        lock.lock()
        blockedScopeHashes.insert(scopeHash)
        lock.unlock()
    }

    func blockAll() {
        lock.lock()
        blocksAllScopes = true
        lock.unlock()
    }

    func isBlocked(scopeHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocksAllScopes || blockedScopeHashes.contains(scopeHash)
    }
}

// WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111: The tombstone file mechanism is implemented in IM4Data.
