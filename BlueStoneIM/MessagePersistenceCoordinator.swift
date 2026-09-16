import Foundation
import GRDB

private final class MessagePersistenceScopePurgeFence: @unchecked Sendable {
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

private final class MessagePersistenceCleanupTombstoneStore: @unchecked Sendable {
    private struct Locator {
        let scopeHash: String
        let legacyScopeHash: String
    }

    private let applicationSupportBase: URL?
    private let cachesBase: URL?
    private let forcePersistenceFailure: Bool

    init(applicationSupportBase: URL?, cachesBase: URL?, forcePersistenceFailure: Bool) {
        self.applicationSupportBase = applicationSupportBase
        self.cachesBase = cachesBase
        self.forcePersistenceFailure = forcePersistenceFailure
    }

    func persist(
        scopeHash: String,
        legacyScopeHash: String,
        fileManager: FileManager = .default
    ) throws {
        if forcePersistenceFailure {
            throw LocalMessageDatabaseError.backupExclusionFailed
        }
        try validateHash(scopeHash)
        try validateHash(legacyScopeHash)
        let markerURL = try markerURL(scopeHash: scopeHash, fileManager: fileManager)
        let root = markerURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let marker = [
            "message-media-cache/1",
            "scope_hash=\(scopeHash)",
            "legacy_scope_hash=\(legacyScopeHash)",
            ""
        ].joined(separator: "\n")
        try Data(marker.utf8).write(to: markerURL, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: markerURL.path
        )
    }

    /// Runs synchronously when the coordinator is created, before any session is
    /// restored. Markers contain only hashed locators, so logout cleanup does not
    /// depend on recovering the five raw scope fields in a later process.
    func drainPendingCleanup(fileManager: FileManager = .default) throws -> Set<String> {
        let roots = try storageRoots(fileManager: fileManager)
        var blockedScopeHashes = Set<String>()

        if fileManager.fileExists(atPath: roots.marker.path) {
            for name in try fileManager.contentsOfDirectory(atPath: roots.marker.path) {
                guard name.hasSuffix(".pending") else { continue }
                let scopeHash = String(name.dropLast(".pending".count))
                guard (try? validateHash(scopeHash)) != nil else { continue }
                let markerURL = roots.marker.appendingPathComponent(name, isDirectory: false)
                do {
                    let locator = try readLocator(at: markerURL, expectedScopeHash: scopeHash)
                    try purge(locator: locator, roots: roots, fileManager: fileManager)
                    try fileManager.removeItem(at: markerURL)
                } catch {
                    blockedScopeHashes.insert(scopeHash)
                }
            }
        }

        for root in [roots.localMessage, roots.media] {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            for name in try fileManager.contentsOfDirectory(atPath: root.path) {
                guard let hash = pendingResidueHash(name) else { continue }
                do {
                    try fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
                } catch {
                    blockedScopeHashes.insert(hash)
                }
            }
        }
        return blockedScopeHashes
    }

    func contains(scopeHash: String, fileManager: FileManager = .default) throws -> Bool {
        fileManager.fileExists(atPath: try markerURL(scopeHash: scopeHash, fileManager: fileManager).path)
    }

    func clear(scopeHash: String, fileManager: FileManager = .default) throws {
        let markerURL = try markerURL(scopeHash: scopeHash, fileManager: fileManager)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    private func markerURL(scopeHash: String, fileManager: FileManager) throws -> URL {
        try validateHash(scopeHash)
        return try storageRoots(fileManager: fileManager).marker
            .appendingPathComponent("\(scopeHash).pending", isDirectory: false)
    }

    private func storageRoots(fileManager: FileManager) throws -> (
        marker: URL,
        localMessage: URL,
        media: URL
    ) {
        let supportBase = try applicationSupportBase
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let cacheBase = try cachesBase
            ?? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let supportProductRoot = supportBase.appendingPathComponent("BlueStoneIM", isDirectory: true)
        return (
            marker: supportProductRoot.appendingPathComponent(
                "LocalMessagePendingCleanup",
                isDirectory: true
            ),
            localMessage: supportProductRoot.appendingPathComponent("LocalMessage", isDirectory: true),
            media: cacheBase
                .appendingPathComponent("BlueStoneIM", isDirectory: true)
                .appendingPathComponent("Media", isDirectory: true)
        )
    }

    private func readLocator(at markerURL: URL, expectedScopeHash: String) throws -> Locator {
        let contents = try String(contentsOf: markerURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 3,
              lines[0] == "message-media-cache/1",
              lines[1].hasPrefix("scope_hash="),
              lines[2].hasPrefix("legacy_scope_hash=") else {
            throw LocalMessageDatabaseError.invalidScopeField("cleanup_marker")
        }
        let scopeHash = String(lines[1].dropFirst("scope_hash=".count))
        let legacyScopeHash = String(lines[2].dropFirst("legacy_scope_hash=".count))
        try validateHash(scopeHash)
        try validateHash(legacyScopeHash)
        guard scopeHash == expectedScopeHash else {
            throw LocalMessageDatabaseError.scopeMismatch
        }
        return Locator(scopeHash: scopeHash, legacyScopeHash: legacyScopeHash)
    }

    private func purge(
        locator: Locator,
        roots: (marker: URL, localMessage: URL, media: URL),
        fileManager: FileManager
    ) throws {
        var seen = Set<String>()
        for (root, hash) in [
            (roots.localMessage, locator.scopeHash),
            (roots.localMessage, locator.legacyScopeHash),
            (roots.media, locator.scopeHash)
        ] {
            let exactURL = root.appendingPathComponent(hash, isDirectory: true)
            if seen.insert(exactURL.standardizedFileURL.path).inserted,
               fileManager.fileExists(atPath: exactURL.path) {
                try fileManager.removeItem(at: exactURL)
            }
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let prefix = ".\(hash).pending-cleanup-"
            for name in try fileManager.contentsOfDirectory(atPath: root.path)
                where name.hasPrefix(prefix) && pendingResidueHash(name) == hash {
                try fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    private func pendingResidueHash(_ name: String) -> String? {
        guard name.first == ".",
              let range = name.range(of: ".pending-cleanup-") else { return nil }
        let hash = String(name[name.index(after: name.startIndex)..<range.lowerBound])
        let suffix = String(name[range.upperBound...])
        guard (try? validateHash(hash)) != nil,
              UUID(uuidString: suffix) != nil else { return nil }
        return hash
    }

    private func validateHash(_ value: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw LocalMessageDatabaseError.invalidScopeField("scope_hash")
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

actor MessagePersistenceCoordinator {
    static let shared = MessagePersistenceCoordinator(cleanupPendingAttachmentFilesOnInit: true)

    private struct ActiveRepository {
        let scope: LocalMessageScope
        let sessionGeneration: UInt64
        let coordinatorEpoch: UInt64
        let repository: SQLiteMessageRepository
    }

    private nonisolated let applicationSupportBase: URL?
    private nonisolated let cachesBase: URL?
    private let scopePurgeBarrier: (@Sendable () async -> Void)?
    private nonisolated let forceScopeCleanupFallbackFailureForTesting: Bool
    private nonisolated let scheduledScopePurgeFence = MessagePersistenceScopePurgeFence()
    private nonisolated let cleanupTombstoneStore: MessagePersistenceCleanupTombstoneStore
    private var active: ActiveRepository?
    private var nextCoordinatorEpoch: UInt64 = 0
    private var latestSessionGeneration: UInt64?
    private var latestSessionScopeHash: String?
    private var retiredGenerationByScope: [String: UInt64] = [:]
    private var scopeTransitionInProgress = false
    private var scopeTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        applicationSupportBase: URL? = nil,
        cachesBase: URL? = nil,
        cleanupPendingAttachmentFilesOnInit: Bool = false,
        scopePurgeBarrier: (@Sendable () async -> Void)? = nil,
        forceCleanupTombstoneFailureForTesting: Bool = false,
        forceScopeCleanupFallbackFailureForTesting: Bool = false
    ) {
        self.applicationSupportBase = applicationSupportBase
        self.cachesBase = cachesBase
        self.scopePurgeBarrier = scopePurgeBarrier
        self.forceScopeCleanupFallbackFailureForTesting = forceScopeCleanupFallbackFailureForTesting
        cleanupTombstoneStore = MessagePersistenceCleanupTombstoneStore(
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase,
            forcePersistenceFailure: forceCleanupTombstoneFailureForTesting
        )
        if cleanupPendingAttachmentFilesOnInit {
            try? PendingAttachmentFileStore.removeOrphanedFiles()
        }
        do {
            let blockedScopeHashes = try cleanupTombstoneStore.drainPendingCleanup()
            for scopeHash in blockedScopeHashes {
                scheduledScopePurgeFence.block(scopeHash: scopeHash)
            }
        } catch {
            scheduledScopePurgeFence.blockAll()
        }
    }

    func activateAndLoad(
        context: IMAPIContext,
        sessionGeneration: UInt64,
        conversationLimit: Int = 50,
        messagesPerConversation: Int = 50
    ) async throws -> LocalMessageDatabaseLoadResult {
        let activated = try await activate(context: context, sessionGeneration: sessionGeneration)
        let loaded = try await activated.repository.loadInitialConversations(
            limit: conversationLimit,
            messagesPerConversation: messagesPerConversation
        )
        let profileContactProjection = try await activated.repository.loadProfileContactProjection()
        let pending = try await activated.repository.pendingOutbox()
        return LocalMessageDatabaseLoadResult(
            ticket: LocalMessageSessionTicket(
                scopeHash: activated.scope.scopeHash,
                sessionGeneration: sessionGeneration,
                coordinatorEpoch: activated.coordinatorEpoch
            ),
            conversations: loaded.0,
            profileContactProjection: profileContactProjection,
            pendingOutbox: pending,
            metrics: loaded.1
        )
    }

    func ensureTicket(context: IMAPIContext, sessionGeneration: UInt64) async throws -> LocalMessageSessionTicket {
        let activated = try await activate(context: context, sessionGeneration: sessionGeneration)
        return LocalMessageSessionTicket(
            scopeHash: activated.scope.scopeHash,
            sessionGeneration: sessionGeneration,
            coordinatorEpoch: activated.coordinatorEpoch
        )
    }

    func projectionRevisionFloor(ticket: LocalMessageSessionTicket) async throws -> Int64 {
        let repository = try self.repository(for: ticket)
        let revision = try await repository.projectionRevisionFloor()
        _ = try self.repository(for: ticket)
        return revision
    }

    func persist(
        ticket: LocalMessageSessionTicket,
        snapshots: [LocalMessageConversationSnapshot],
        source: LocalMessageProjectionSource,
        revision: Int64,
        replaceMissingConversations: Bool = false
    ) async throws -> LocalMessageMergeMetrics {
        let repository = try repository(for: ticket)
        return try await repository.persistProjection(
            snapshots,
            source: source,
            revision: revision,
            replaceMissingConversations: replaceMissingConversations
        )
    }

    func persistProfileContactProjection(
        ticket: LocalMessageSessionTicket,
        projection: LocalProfileContactProjection
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.persistProfileContactProjection(projection)
    }

    func importLegacy(
        ticket: LocalMessageSessionTicket,
        snapshots: [LocalMessageConversationSnapshot],
        revision: Int64
    ) async throws -> Bool {
        let repository = try repository(for: ticket)
        return try await repository.importLegacy(snapshots, revision: revision)
    }

    func enqueueOutgoing(
        ticket: LocalMessageSessionTicket,
        intent: LocalMessageOutgoingIntent,
        revision: Int64
    ) async throws -> LocalMessageMergeMetrics {
        let repository = try repository(for: ticket)
        return try await repository.enqueueOutgoing(intent, revision: revision)
    }

    func updateOutboxState(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        state: LocalMessageOutboxState,
        uncertain: Bool = false,
        fileID: String? = nil,
        attachmentPhase: String? = nil,
        now: Date = Date(),
        retryAfter: TimeInterval? = nil,
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.updateOutboxState(
            clientMessageID: clientMessageID,
            state: state,
            uncertain: uncertain,
            fileID: fileID,
            attachmentPhase: attachmentPhase,
            now: now,
            retryAfter: retryAfter,
            replayPolicy: replayPolicy
        )
    }

    func confirmOutgoing(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        projection: LocalMessageConversationSnapshot,
        revision: Int64
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.confirmOutgoing(
            clientMessageID: clientMessageID,
            authoritativeMessageID: authoritativeMessageID,
            authoritativeChannelSeq: authoritativeChannelSeq,
            projection: projection,
            revision: revision
        )
    }

    func deleteConversation(ticket: LocalMessageSessionTicket, conversationID: String) async throws {
        let repository = try repository(for: ticket)
        try await repository.deleteConversation(conversationID: conversationID)
    }

    func removeMediaCacheReferences(
        ticket: LocalMessageSessionTicket,
        conversationID: String
    ) async throws -> [IOSMediaCachePruneCandidate] {
        let repository = try repository(for: ticket)
        return try await repository.removeMediaCacheReferences(conversationID: conversationID)
    }

    func removeMediaCacheReferences(
        ticket: LocalMessageSessionTicket,
        conversationID: String,
        beforeChannelSequence: Int64,
        clearAll: Bool,
        at date: Date = Date()
    ) async throws -> [IOSMediaCachePruneCandidate] {
        let repository = try repository(for: ticket)
        return try await repository.removeMediaCacheReferences(
            conversationID: conversationID,
            beforeChannelSequence: beforeChannelSequence,
            clearAll: clearAll,
            at: date
        )
    }

    func recordAckDesired(
        ticket: LocalMessageSessionTicket,
        channelKey: String,
        type: String,
        desiredSeq: Int64,
        resetRetryBudget: Bool = false
    ) async throws -> Int64 {
        let repository = try repository(for: ticket)
        return try await repository.recordAckDesired(
            channelKey: channelKey,
            type: type,
            desiredSeq: desiredSeq,
            resetRetryBudget: resetRetryBudget
        )
    }

    func recoverableAcks(
        ticket: LocalMessageSessionTicket,
        type: String,
        retryPolicy: LocalMessageAckRetryPolicy = .standard
    ) async throws -> [LocalMessagePendingAck] {
        let repository = try readRepository(for: ticket)
        return try await repository.recoverableAcks(type: type, retryPolicy: retryPolicy)
    }

    func ackStates(
        ticket: LocalMessageSessionTicket,
        type: String
    ) async throws -> [LocalMessagePendingAck] {
        let repository = try readRepository(for: ticket)
        return try await repository.ackStates(type: type)
    }

    func claimAcksForRetry(
        ticket: LocalMessageSessionTicket,
        type: String,
        channelKey: String? = nil,
        now: Date = Date(),
        limit: Int = 20,
        retryPolicy: LocalMessageAckRetryPolicy = .standard
    ) async throws -> [LocalMessagePendingAck] {
        let repository = try repository(for: ticket)
        return try await repository.claimAcksForRetry(
            type: type,
            channelKey: channelKey,
            now: now,
            limit: limit,
            retryPolicy: retryPolicy
        )
    }

    func releaseAckForRetry(
        ticket: LocalMessageSessionTicket,
        channelKey: String,
        type: String
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.releaseAckForRetry(channelKey: channelKey, type: type)
    }

    func abandonAckClaimWithoutConsumingAttempt(
        ticket: LocalMessageSessionTicket,
        channelKey: String,
        type: String,
        claimedSeq: Int64,
        claimedAttemptCount: Int
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.abandonAckClaimWithoutConsumingAttempt(
            channelKey: channelKey,
            type: type,
            claimedSeq: claimedSeq,
            claimedAttemptCount: claimedAttemptCount
        )
    }

    func confirmAck(
        ticket: LocalMessageSessionTicket,
        channelKey: String,
        type: String,
        confirmedSeq: Int64
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.confirmAck(channelKey: channelKey, type: type, confirmedSeq: confirmedSeq)
    }

    func loadOlderMessages(
        ticket: LocalMessageSessionTicket,
        channelKey: String,
        beforeSeq: Int64,
        limit: Int = 50
    ) async throws -> [CachedMessage] {
        let repository = try readRepository(for: ticket)
        return try await repository.loadOlderMessages(
            channelKey: channelKey,
            beforeSeq: beforeSeq,
            limit: limit
        )
    }

    func search(
        ticket: LocalMessageSessionTicket,
        query: String,
        limit: Int = 50
    ) async throws -> [LocalMessageSearchResult] {
        let repository = try readRepository(for: ticket)
        return try await repository.search(query, limit: limit)
    }

    func pendingOutbox(ticket: LocalMessageSessionTicket) async throws -> [LocalMessageRecoveredOutbox] {
        let repository = try repository(for: ticket)
        return try await repository.pendingOutbox()
    }

    func recoverableOutbox(ticket: LocalMessageSessionTicket) async throws -> [LocalMessageRecoveredOutbox] {
        let repository = try readRepository(for: ticket)
        return try await repository.recoverableOutbox()
    }

    func claimOutboxForReplay(
        ticket: LocalMessageSessionTicket,
        authorizationGeneration: UInt64,
        trigger: LocalMessageOutboxReplayTrigger,
        clientMessageID: String?,
        now: Date = Date(),
        limit: Int = 20,
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) async throws -> [LocalMessageRecoveredOutbox] {
        guard ticket.sessionGeneration == authorizationGeneration else {
            throw LocalMessageDatabaseError.staleSession
        }
        let repository = try repository(for: ticket)
        return try await repository.claimOutboxForReplay(
            authorizationGeneration: authorizationGeneration,
            trigger: trigger,
            clientMessageID: clientMessageID,
            now: now,
            limit: limit,
            replayPolicy: replayPolicy
        )
    }

    @discardableResult
    func acknowledgeOutgoingAuthority(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        channelKey: String
    ) async throws -> Bool {
        let repository = try repository(for: ticket)
        return try await repository.acknowledgeOutgoingAuthority(
            clientMessageID: clientMessageID,
            authoritativeMessageID: authoritativeMessageID,
            authoritativeChannelSeq: authoritativeChannelSeq,
            channelKey: channelKey
        )
    }

    func outgoingAuthority(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String
    ) async throws -> LocalMessageOutgoingAuthority? {
        let repository = try readRepository(for: ticket)
        return try await repository.outgoingAuthority(clientMessageID: clientMessageID)
    }

    func loadStagedAttachment(
        ticket: LocalMessageSessionTicket,
        item: LocalMessageRecoveredOutbox
    ) async throws -> Data? {
        let repository = try repository(for: ticket)
        return try await repository.loadStagedAttachment(for: item)
    }

    func stagedAttachmentFileURL(
        ticket: LocalMessageSessionTicket,
        item: LocalMessageRecoveredOutbox
    ) async throws -> URL? {
        let repository = try repository(for: ticket)
        return try await repository.stagedAttachmentFileURL(for: item)
    }

    func diagnostics(ticket: LocalMessageSessionTicket) async throws -> LocalMessageDatabaseDiagnostics {
        let repository = try repository(for: ticket)
        return try await repository.diagnostics()
    }

    func upsertMediaCache(
        ticket: LocalMessageSessionTicket,
        authority: IOSMediaCacheAuthorityRecord,
        entry: IOSMediaCacheEntryRecord,
        conversationID: String
    ) async throws -> Bool {
        let repository = try repository(for: ticket)
        return try await repository.upsertMediaCache(
            authority: authority,
            entry: entry,
            conversationID: conversationID
        )
    }

    func mediaCacheLookup(
        ticket: LocalMessageSessionTicket,
        cacheIdentity: String,
        messageID: String,
        now: Date = Date(),
        offline: Bool
    ) async throws -> IOSMediaCacheIndexedLookup? {
        let repository = try repository(for: ticket)
        return try await repository.mediaCacheLookup(
            cacheIdentity: cacheIdentity,
            messageID: messageID,
            now: now,
            offline: offline
        )
    }

    func touchMediaCache(
        ticket: LocalMessageSessionTicket,
        cacheIdentity: String,
        at date: Date = Date()
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.touchMediaCache(cacheIdentity: cacheIdentity, at: date)
    }

    func renewMediaCacheAuthority(
        ticket: LocalMessageSessionTicket,
        cacheIdentity: String,
        messageID: String,
        authorizedAt: Date = Date(),
        offlineAccessUntil: Date?
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.renewMediaCacheAuthority(
            cacheIdentity: cacheIdentity,
            messageID: messageID,
            authorizedAt: authorizedAt,
            offlineAccessUntil: offlineAccessUntil
        )
    }

    func markMediaCacheState(
        ticket: LocalMessageSessionTicket,
        cacheIdentity: String,
        state: MediaCacheLocalState
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.markMediaCacheState(cacheIdentity: cacheIdentity, state: state)
    }

    func mediaCacheStatistics(
        ticket: LocalMessageSessionTicket,
        resourceKind: MediaResourceKind? = nil
    ) async throws -> IOSMediaCacheStatistics {
        let repository = try repository(for: ticket)
        return try await repository.mediaCacheStatistics(resourceKind: resourceKind)
    }

    func mediaCachePruneCandidates(
        ticket: LocalMessageSessionTicket,
        bytesToFree: Int64,
        resourceKind: MediaResourceKind? = nil
    ) async throws -> [IOSMediaCachePruneCandidate] {
        let repository = try repository(for: ticket)
        return try await repository.mediaCachePruneCandidates(
            bytesToFree: bytesToFree,
            resourceKind: resourceKind
        )
    }

    func removeMediaCacheEntries(
        ticket: LocalMessageSessionTicket,
        cacheIdentities: [String]
    ) async throws {
        let repository = try repository(for: ticket)
        try await repository.removeMediaCacheEntries(cacheIdentities: cacheIdentities)
    }

    func invalidateMediaCache(
        ticket: LocalMessageSessionTicket,
        messageID: String,
        state: MediaCacheAuthorityState,
        authorityVersion: String,
        at date: Date = Date()
    ) async throws -> [IOSMediaCachePruneCandidate] {
        let repository = try repository(for: ticket)
        return try await repository.invalidateMediaCache(
            messageID: messageID,
            state: state,
            authorityVersion: authorityVersion,
            at: date
        )
    }

    func detach(ticket: LocalMessageSessionTicket?) {
        guard let ticket, let active,
              active.scope.scopeHash == ticket.scopeHash,
              active.coordinatorEpoch == ticket.coordinatorEpoch else { return }
        self.active = nil
        nextCoordinatorEpoch &+= 1
    }

    @discardableResult
    nonisolated func schedulePurgeExactScope(
        context: IMAPIContext,
        through sessionGeneration: UInt64,
        beforePurge: @escaping @Sendable () async -> Void = {}
    ) throws -> Task<Bool, Never> {
        let scope = try preparePendingScopeCleanup(context: context)
        let token = scheduledScopePurgeFence.register(scopeHash: scope.scopeHash)
        return Task {
            await beforePurge()
            let purged = (try? await self.purgeExactScope(
                context: context,
                through: sessionGeneration
            )) ?? false
            self.scheduledScopePurgeFence.complete(token)
            return purged
        }
    }

    nonisolated func persistPendingScopeCleanup(context: IMAPIContext) throws {
        _ = try preparePendingScopeCleanup(context: context)
    }

    nonisolated func hasPendingScopeCleanup(context: IMAPIContext) throws -> Bool {
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
        return try cleanupTombstoneStore.contains(scopeHash: scope.scopeHash)
            || paths.hasPendingCleanupResidue()
    }

    private nonisolated func preparePendingScopeCleanup(
        context: IMAPIContext
    ) throws -> LocalMessageScope {
        let scope = try LocalMessageScope(context: context)
        do {
            try cleanupTombstoneStore.persist(
                scopeHash: scope.scopeHash,
                legacyScopeHash: scope.legacyLocalMessageScopeHash
            )
        } catch {
            if forceScopeCleanupFallbackFailureForTesting {
                scheduledScopePurgeFence.block(scopeHash: scope.scopeHash)
                throw error
            }
            let paths = try MessageDatabasePaths(
                scope: scope,
                applicationSupportBase: applicationSupportBase,
                cachesBase: cachesBase
            )
            do {
                try paths.quarantineExactScopeForPendingCleanup()
            } catch {
                do {
                    try paths.purgeExactScope()
                } catch {
                    scheduledScopePurgeFence.block(scopeHash: scope.scopeHash)
                    throw error
                }
            }
        }
        return scope
    }

    func purgeExactScope(context: IMAPIContext) async throws {
        let scope = try LocalMessageScope(context: context)
        await acquireScopeTransition()
        defer { releaseScopeTransition() }
        let generationToRetire = active?.scope.scopeHash == scope.scopeHash
            ? active?.sessionGeneration
            : (latestSessionScopeHash == scope.scopeHash ? latestSessionGeneration : nil)
        retireGeneration(generationToRetire, for: scope.scopeHash)
        if active?.scope.scopeHash == scope.scopeHash {
            active = nil
            nextCoordinatorEpoch &+= 1
        }
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
        await scopePurgeBarrier?()
        try paths.purgeExactScope()
        try cleanupTombstoneStore.clear(scopeHash: scope.scopeHash)
    }

    @discardableResult
    func purgeExactScope(
        context: IMAPIContext,
        through sessionGeneration: UInt64
    ) async throws -> Bool {
        let scope = try LocalMessageScope(context: context)
        await acquireScopeTransition()
        defer { releaseScopeTransition() }
        if latestSessionScopeHash == scope.scopeHash,
           let latestSessionGeneration,
           latestSessionGeneration > sessionGeneration {
            return false
        }
        if let active, active.scope.scopeHash == scope.scopeHash {
            guard active.sessionGeneration <= sessionGeneration else { return false }
            self.active = nil
            nextCoordinatorEpoch &+= 1
        }
        retireGeneration(sessionGeneration, for: scope.scopeHash)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
        await scopePurgeBarrier?()
        try paths.purgeExactScope()
        try cleanupTombstoneStore.clear(scopeHash: scope.scopeHash)
        return true
    }

    private func repository(for ticket: LocalMessageSessionTicket) throws -> SQLiteMessageRepository {
        guard let active,
              active.scope.scopeHash == ticket.scopeHash,
              active.sessionGeneration == ticket.sessionGeneration,
              active.coordinatorEpoch == ticket.coordinatorEpoch else {
            throw LocalMessageDatabaseError.staleSession
        }
        return active.repository
    }

    private func readRepository(for ticket: LocalMessageSessionTicket) throws -> SQLiteMessageRepository {
        guard let active,
              active.scope.scopeHash == ticket.scopeHash else {
            throw LocalMessageDatabaseError.staleSession
        }
        return active.repository
    }

    private func activate(
        context: IMAPIContext,
        sessionGeneration: UInt64
    ) async throws -> ActiveRepository {
        let scope = try LocalMessageScope(context: context)
        if scheduledScopePurgeFence.isBlocked(scopeHash: scope.scopeHash) {
            throw LocalMessageDatabaseError.staleSession
        }
        await scheduledScopePurgeFence.waitForPendingPurge(scopeHash: scope.scopeHash)
        if scheduledScopePurgeFence.isBlocked(scopeHash: scope.scopeHash) {
            throw LocalMessageDatabaseError.staleSession
        }
        await acquireScopeTransition()
        defer { releaseScopeTransition() }
        try finishPendingScopeCleanupIfNeeded(scope: scope)
        if let retiredGeneration = retiredGenerationByScope[scope.scopeHash],
           sessionGeneration <= retiredGeneration {
            throw LocalMessageDatabaseError.staleSession
        }
        if let latestSessionGeneration {
            guard sessionGeneration >= latestSessionGeneration else {
                throw LocalMessageDatabaseError.staleSession
            }
            if sessionGeneration == latestSessionGeneration,
               latestSessionScopeHash != scope.scopeHash {
                throw LocalMessageDatabaseError.staleSession
            }
        }
        if let active, active.scope.scopeHash == scope.scopeHash {
            guard active.sessionGeneration != sessionGeneration else { return active }
            guard sessionGeneration > active.sessionGeneration else {
                throw LocalMessageDatabaseError.staleSession
            }
            recordLatestSession(generation: sessionGeneration, scopeHash: scope.scopeHash)
            nextCoordinatorEpoch &+= 1
            let rebound = ActiveRepository(
                scope: active.scope,
                sessionGeneration: sessionGeneration,
                coordinatorEpoch: nextCoordinatorEpoch,
                repository: active.repository
            )
            self.active = rebound
            return rebound
        }
        recordLatestSession(generation: sessionGeneration, scopeHash: scope.scopeHash)
        if active != nil {
            active = nil
            nextCoordinatorEpoch &+= 1
        }
        nextCoordinatorEpoch &+= 1
        let epoch = nextCoordinatorEpoch
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
        let repository: SQLiteMessageRepository
        do {
            repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        } catch LocalMessageDatabaseError.databaseCorrupt {
            try await Task.detached(priority: .utility) {
                try paths.prepare()
                try paths.quarantineDatabaseSidecars()
            }.value
            repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            try await Task.detached(priority: .utility) {
                try paths.prepare()
                try paths.quarantineDatabaseSidecars()
            }.value
            repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        }
        let activated = ActiveRepository(
            scope: scope,
            sessionGeneration: sessionGeneration,
            coordinatorEpoch: epoch,
            repository: repository
        )
        active = activated
        return activated
    }

    private func finishPendingScopeCleanupIfNeeded(scope: LocalMessageScope) throws {
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase
        )
        guard try cleanupTombstoneStore.contains(scopeHash: scope.scopeHash)
                || paths.hasPendingCleanupResidue() else { return }
        if active?.scope.scopeHash == scope.scopeHash {
            active = nil
            nextCoordinatorEpoch &+= 1
        }
        try paths.purgeExactScope()
        try cleanupTombstoneStore.clear(scopeHash: scope.scopeHash)
    }

    private func recordLatestSession(generation: UInt64, scopeHash: String) {
        if let currentGeneration = latestSessionGeneration {
            guard generation > currentGeneration else { return }
            latestSessionGeneration = generation
            latestSessionScopeHash = scopeHash
        } else {
            latestSessionGeneration = generation
            latestSessionScopeHash = scopeHash
        }
    }

    private func retireGeneration(_ generation: UInt64?, for scopeHash: String) {
        guard let generation else { return }
        retiredGenerationByScope[scopeHash] = max(
            retiredGenerationByScope[scopeHash] ?? 0,
            generation
        )
    }

    private func acquireScopeTransition() async {
        if !scopeTransitionInProgress {
            scopeTransitionInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            scopeTransitionWaiters.append(continuation)
        }
    }

    private func releaseScopeTransition() {
        guard !scopeTransitionWaiters.isEmpty else {
            scopeTransitionInProgress = false
            return
        }
        let continuation = scopeTransitionWaiters.removeFirst()
        continuation.resume()
    }
}
