import Foundation
import GRDB

extension MessagePersistenceCoordinator {
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
}
