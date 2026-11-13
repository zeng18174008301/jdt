import Foundation
import GRDB
import IM4Data // WDT_IOS1_MESSAGE_CLEANUP_TOMBSTONE_DATA_20261111

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
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112
    nonisolated let scopeRetirementMediaRegistry: IOSMediaCacheStoreRegistry
    private let scopePurgeBarrier: (@Sendable () async -> Void)?
    private nonisolated let forceScopeCleanupFallbackFailureForTesting: Bool
    private nonisolated let scheduledScopePurgeFence = MessagePersistenceScopePurgeFence()
    private nonisolated let cleanupTombstoneStore: MessagePersistenceCleanupTombstoneStore
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private var outgoingConfirmationPermit = LocalMessageConfirmationPermit()
    private var active: ActiveRepository? {
        willSet {
            outgoingConfirmationPermit.revoke()
            outgoingConfirmationPermit = LocalMessageConfirmationPermit()
        }
    }
#if DEBUG
    private var beforeHistoryConfirmationWrite: (@Sendable () async -> Void)?

    func setBeforeHistoryConfirmationWriteForTesting(_ operation: (@Sendable () async -> Void)?) {
        beforeHistoryConfirmationWrite = operation
    }
#endif
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    private var nextCoordinatorEpoch: UInt64 = 0
    private var latestSessionGeneration: UInt64?
    private var latestSessionScopeHash: String?
    private var retiredGenerationByScope: [String: UInt64] = [:]
    private var scopeTransitionInProgress = false
    private var scopeTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
    init(
        applicationSupportBase: URL? = nil,
        cachesBase: URL? = nil,
        cleanupPendingAttachmentFilesOnInit: Bool = false,
        scopePurgeBarrier: (@Sendable () async -> Void)? = nil,
        forceCleanupTombstoneFailureForTesting: Bool = false,
        forceScopeCleanupFallbackFailureForTesting: Bool = false
    ) {
        self.init(
            applicationSupportBase: applicationSupportBase,
            cachesBase: cachesBase,
            scopeRetirementMediaRegistry: .shared,
            cleanupPendingAttachmentFilesOnInit: cleanupPendingAttachmentFilesOnInit,
            scopePurgeBarrier: scopePurgeBarrier,
            forceCleanupTombstoneFailureForTesting: forceCleanupTombstoneFailureForTesting,
            forceScopeCleanupFallbackFailureForTesting: forceScopeCleanupFallbackFailureForTesting
        )
    }

    init(
        applicationSupportBase: URL? = nil,
        cachesBase: URL? = nil,
        scopeRetirementMediaRegistry: IOSMediaCacheStoreRegistry,
        cleanupPendingAttachmentFilesOnInit: Bool = false,
        scopePurgeBarrier: (@Sendable () async -> Void)? = nil,
        forceCleanupTombstoneFailureForTesting: Bool = false,
        forceScopeCleanupFallbackFailureForTesting: Bool = false
    ) {
        self.applicationSupportBase = applicationSupportBase
        self.cachesBase = cachesBase
        self.scopeRetirementMediaRegistry = scopeRetirementMediaRegistry
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
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END

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

    func stagedVideoUploadSource(
        ticket: LocalMessageSessionTicket, clientMessageID: String, expectedSizeBytes: Int64
    ) async throws -> StagedVideoUploadSource {
        let repository = try repository(for: ticket)
        return try await repository.stagedVideoUploadSource(clientMessageID: clientMessageID, expectedSizeBytes: expectedSizeBytes)
    }

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    func prepareOutgoingSend(ticket: LocalMessageSessionTicket, clientMessageID: String,
                             selectedV5: Bool, protect: Bool) async throws -> IM4Data.LocalMessageSendAdmission {
        try await repository(for: ticket).prepareOutgoingSend(clientMessageID: clientMessageID,
            selectedV5: selectedV5, protect: protect)
    }

    func deferKnownUnsentOutgoingSend(ticket: LocalMessageSessionTicket, clientMessageID: String) async throws {
        try await repository(for: ticket).deferKnownUnsentOutgoingSend(clientMessageID: clientMessageID)
    }

    func reserveOutgoingSend(ticket: LocalMessageSessionTicket, clientMessageID: String) async throws {
        try await repository(for: ticket).reserveOutgoingSend(clientMessageID: clientMessageID)
    }

    func releaseUnsentOutgoing(ticket: LocalMessageSessionTicket, clientMessageID: String) async {
        try? await repository(for: ticket).releaseUnsentOutgoing(clientMessageID: clientMessageID)
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

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

    func discardFailedOutgoing(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        conversationID: String,
        channelID: String,
        channelType: String
    ) async throws -> Bool {
        let repository = try repository(for: ticket)
        return try await repository.discardFailedOutgoing(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            channelID: channelID,
            channelType: channelType
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

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    func loadSearchDateMessages(
        ticket: LocalMessageSessionTicket, conversationID: String, days: [DateInterval],
        minimumSequence: Int64, excludedIDs: Set<String>, excludedSequences: Set<Int64>
    ) async throws -> [ChatMessage] {
        let repository = try readRepository(for: ticket)
        return try await repository.loadSearchDateMessages(conversationID: conversationID, days: days,
            minimumSequence: minimumSequence, excludedIDs: excludedIDs, excludedSequences: excludedSequences)
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
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
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard,
        holdLegacyUnconfirmedSends: Bool = false // WDT_IOS1_HTTP_ROUTE_V5_20261113
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
            replayPolicy: replayPolicy,
            holdLegacyUnconfirmedSends: holdLegacyUnconfirmedSends
        )
    }

    @discardableResult
    func acknowledgeOutgoingAuthority(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        channelKey: String,
        historyRoutePermit: LocalMessageConfirmationPermit? = nil // WDT_IOS1_HTTP_ROUTE_V5_20261113
    ) async throws -> Bool {
        let repository = try repository(for: ticket)
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if let historyRoutePermit {
            let cancellation = LocalMessageConfirmationPermit()
            let confirmation = LocalMessageHistoryConfirmation(route: historyRoutePermit,
                storage: outgoingConfirmationPermit, cancellation: cancellation)
            return try await withTaskCancellationHandler {
#if DEBUG
                await beforeHistoryConfirmationWrite?()
#endif
                return try await repository.acknowledgeOutgoingAuthority(
                    clientMessageID: clientMessageID, authoritativeMessageID: authoritativeMessageID,
                    authoritativeChannelSeq: authoritativeChannelSeq, channelKey: channelKey, confirmation: confirmation
                )
            } onCancel: {
                cancellation.revoke()
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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

    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
    nonisolated func waitForScheduledScopePurge(scopeHash: String) async {
        await scheduledScopePurgeFence.waitForPendingPurge(scopeHash: scopeHash)
    }
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END

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

    func repository(for ticket: LocalMessageSessionTicket) throws -> SQLiteMessageRepository {
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
        // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112
        await waitForScheduledScopePurge(scopeHash: scope.scopeHash)
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
