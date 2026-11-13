// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import GRDB

extension SQLiteMessageRepository {
    public func removeMediaCacheReferences(conversationID: String) throws -> [IOSMediaCachePruneCandidate] {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: "DELETE FROM cache_reference WHERE scope_hash = ? AND conversation_key = ?",
                arguments: [scope.scopeHash, conversationID]
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT cache_identity, relative_path, size_bytes FROM cache_entry
                WHERE scope_hash = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM cache_reference
                    WHERE cache_reference.scope_hash = cache_entry.scope_hash
                      AND cache_reference.cache_identity = cache_entry.cache_identity
                  )
                """,
                arguments: [scope.scopeHash]
            )
            let candidates = rows.map {
                IOSMediaCachePruneCandidate(
                    cacheIdentity: $0["cache_identity"],
                    relativePath: $0["relative_path"],
                    sizeBytes: $0["size_bytes"]
                )
            }
            if !candidates.isEmpty {
                let placeholders = candidates.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM cache_entry WHERE scope_hash = ? AND cache_identity IN (\(placeholders))",
                    arguments: StatementArguments([scope.scopeHash] + candidates.map(\.cacheIdentity))
                )
            }
            return candidates
        }
    }

    public func removeMediaCacheReferences(
        conversationID: String,
        beforeChannelSequence: Int64,
        clearAll: Bool,
        at date: Date
    ) throws -> [IOSMediaCachePruneCandidate] {
        try databasePool.write { db in
            try assertWriter(db)
            let messageRows = try Row.fetchAll(
                db,
                sql: clearAll
                    ? """
                      SELECT DISTINCT cache_reference.message_id
                      FROM cache_reference
                      WHERE cache_reference.scope_hash = ? AND cache_reference.conversation_key = ?
                      """
                    : """
                      SELECT DISTINCT cache_reference.message_id
                      FROM cache_reference
                      JOIN message ON message.message_id = cache_reference.message_id
                      WHERE cache_reference.scope_hash = ?
                        AND cache_reference.conversation_key = ?
                        AND (message.channel_seq IS NULL OR message.channel_seq <= 0 OR message.channel_seq < ?)
                      """,
                arguments: clearAll
                    ? [scope.scopeHash, conversationID]
                    : [scope.scopeHash, conversationID, beforeChannelSequence]
            )
            let messageIDs = messageRows.map { $0["message_id"] as String }
            for messageID in messageIDs {
                try db.execute(
                    sql: """
                    INSERT INTO media_authority_tombstone (
                        scope_hash, message_id, authority_state, authority_version, updated_at
                    ) VALUES (?, ?, 'authorization_stale', '0', ?)
                    ON CONFLICT(scope_hash, message_id) DO UPDATE SET
                        authority_state = CASE
                            WHEN media_authority_tombstone.authority_state IN ('deleted', 'recalled', 'forbidden', 'expired_business')
                            THEN media_authority_tombstone.authority_state
                            ELSE 'authorization_stale'
                        END,
                        updated_at = MAX(media_authority_tombstone.updated_at, excluded.updated_at)
                    """,
                    arguments: [scope.scopeHash, messageID, date.timeIntervalSince1970]
                )
            }
            if !messageIDs.isEmpty {
                let placeholders = messageIDs.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM cache_reference WHERE scope_hash = ? AND conversation_key = ? AND message_id IN (\(placeholders))",
                    arguments: StatementArguments([scope.scopeHash, conversationID] + messageIDs)
                )
            }
            return try Self.deleteOrphanedMediaCacheEntries(db: db, scopeHash: scope.scopeHash)
        }
    }

    public func upsertMediaCache(
        authority: IOSMediaCacheAuthorityRecord,
        entry: IOSMediaCacheEntryRecord,
        conversationID: String
    ) throws -> Bool {
        guard authority.scopeHash == scope.scopeHash,
              entry.scopeHash == scope.scopeHash,
              authority.identity.persistentCacheIdentity == entry.cacheIdentity,
              authority.identity.variant == entry.variant,
              !authority.messageID.isEmpty,
              !authority.attachmentID.isEmpty else {
            throw LocalMessageDatabaseError.scopeMismatch
        }
        return try databasePool.write { db in
            try assertWriter(db)
            if let tombstone = try Row.fetchOne(
                db,
                sql: """
                SELECT authority_state, authority_version
                FROM media_authority_tombstone
                WHERE scope_hash = ? AND message_id = ?
                """,
                arguments: [scope.scopeHash, authority.messageID]
            ) {
                let currentState = MediaCacheAuthorityState(
                    rawValue: tombstone["authority_state"] as String
                ) ?? .authorizationStale
                let currentVersion: String = tombstone["authority_version"]
                guard Self.acceptsAuthority(
                    currentState: currentState,
                    currentVersion: currentVersion,
                    incomingState: authority.state,
                    incomingVersion: authority.authorityVersion
                ) else { return false }
            }
            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT authority_state, authority_version
                FROM attachment_meta
                WHERE scope_hash = ? AND message_id = ? AND attachment_id = ? AND variant = ?
                """,
                arguments: [scope.scopeHash, authority.messageID, authority.attachmentID, authority.identity.variant.rawValue]
            )
            if let existing {
                let currentState = MediaCacheAuthorityState(rawValue: existing["authority_state"] as String) ?? .authorizationStale
                let currentVersion: String = existing["authority_version"]
                guard Self.acceptsAuthority(
                    currentState: currentState,
                    currentVersion: currentVersion,
                    incomingState: authority.state,
                    incomingVersion: authority.authorityVersion
                ) else { return false }
            }
            try db.execute(
                sql: """
                INSERT INTO attachment_meta (
                    scope_hash, message_id, attachment_id, resource_id_kind, resource_id,
                    content_version_kind, content_version, variant, mime_type, size_bytes,
                    checksum_sha256, authority_state, authority_version, last_authorized_at,
                    offline_access_until, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope_hash, message_id, attachment_id, variant) DO UPDATE SET
                    resource_id_kind = excluded.resource_id_kind,
                    resource_id = excluded.resource_id,
                    content_version_kind = excluded.content_version_kind,
                    content_version = excluded.content_version,
                    mime_type = excluded.mime_type,
                    size_bytes = excluded.size_bytes,
                    checksum_sha256 = excluded.checksum_sha256,
                    authority_state = excluded.authority_state,
                    authority_version = excluded.authority_version,
                    last_authorized_at = excluded.last_authorized_at,
                    offline_access_until = excluded.offline_access_until,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    authority.scopeHash,
                    authority.messageID,
                    authority.attachmentID,
                    authority.identity.resourceIDKind?.rawValue ?? MediaCacheResourceIDKind.attachmentID.rawValue,
                    authority.identity.primaryStableID,
                    authority.identity.contentVersionKindAndValue?.0.rawValue ?? MediaCacheContentVersionKind.version.rawValue,
                    authority.identity.contentVersionKindAndValue?.1 ?? "0",
                    authority.identity.variant.rawValue,
                    authority.mimeType,
                    authority.sizeBytes,
                    authority.checksumSHA256,
                    authority.state.rawValue,
                    authority.authorityVersion,
                    authority.lastAuthorizedAt?.timeIntervalSince1970,
                    authority.offlineAccessUntil?.timeIntervalSince1970,
                    authority.createdAt?.timeIntervalSince1970,
                    authority.updatedAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO cache_entry (
                    scope_hash, cache_identity, attachment_id, variant, relative_path,
                    local_state, size_bytes, verified_size_bytes, verified_checksum_sha256,
                    pinned_by_user, protection_reason, created_at, last_accessed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cache_identity) DO UPDATE SET
                    relative_path = excluded.relative_path,
                    local_state = excluded.local_state,
                    size_bytes = excluded.size_bytes,
                    verified_size_bytes = excluded.verified_size_bytes,
                    verified_checksum_sha256 = excluded.verified_checksum_sha256,
                    pinned_by_user = MAX(cache_entry.pinned_by_user, excluded.pinned_by_user),
                    protection_reason = CASE
                        WHEN cache_entry.protection_reason <> '' THEN cache_entry.protection_reason
                        ELSE excluded.protection_reason
                    END,
                    last_accessed_at = excluded.last_accessed_at
                """,
                arguments: [
                    entry.scopeHash,
                    entry.cacheIdentity,
                    entry.attachmentID,
                    entry.variant.rawValue,
                    entry.relativePath,
                    entry.localState.rawValue,
                    entry.sizeBytes,
                    entry.verifiedSizeBytes,
                    entry.verifiedChecksumSHA256,
                    entry.pinnedByUser,
                    entry.protectionReason,
                    entry.createdAt.timeIntervalSince1970,
                    entry.lastAccessedAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO cache_reference (
                    scope_hash, message_id, attachment_id, conversation_key, cache_identity, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope_hash, message_id, cache_identity) DO UPDATE SET
                    attachment_id = excluded.attachment_id,
                    conversation_key = excluded.conversation_key
                """,
                arguments: [
                    scope.scopeHash,
                    authority.messageID,
                    authority.attachmentID,
                    conversationID,
                    entry.cacheIdentity,
                    authority.updatedAt.timeIntervalSince1970
                ]
            )
            if authority.state == .active {
                try db.execute(
                    sql: "DELETE FROM media_authority_tombstone WHERE scope_hash = ? AND message_id = ?",
                    arguments: [scope.scopeHash, authority.messageID]
                )
            }
            return true
        }
    }

    public func mediaCacheLookup(
        cacheIdentity: String,
        messageID: String,
        now: Date,
        offline: Bool
    ) throws -> IOSMediaCacheIndexedLookup? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    attachment_meta.message_id, attachment_meta.attachment_id,
                    attachment_meta.resource_id_kind, attachment_meta.resource_id,
                    attachment_meta.content_version_kind, attachment_meta.content_version,
                    attachment_meta.mime_type, attachment_meta.size_bytes AS authority_size_bytes,
                    attachment_meta.checksum_sha256, attachment_meta.authority_state,
                    attachment_meta.authority_version, attachment_meta.last_authorized_at,
                    attachment_meta.offline_access_until, attachment_meta.created_at AS authority_created_at,
                    attachment_meta.updated_at,
                    cache_entry.cache_identity, cache_entry.variant, cache_entry.relative_path,
                    cache_entry.local_state, cache_entry.size_bytes, cache_entry.verified_size_bytes,
                    cache_entry.verified_checksum_sha256, cache_entry.pinned_by_user,
                    cache_entry.protection_reason, cache_entry.created_at, cache_entry.last_accessed_at
                FROM cache_entry
                JOIN cache_reference
                  ON cache_reference.scope_hash = cache_entry.scope_hash
                 AND cache_reference.cache_identity = cache_entry.cache_identity
                JOIN attachment_meta
                 ON attachment_meta.scope_hash = cache_entry.scope_hash
                 AND attachment_meta.message_id = cache_reference.message_id
                 AND attachment_meta.attachment_id = cache_reference.attachment_id
                 AND attachment_meta.variant = cache_entry.variant
                WHERE cache_entry.scope_hash = ? AND cache_entry.cache_identity = ?
                  AND cache_reference.message_id = ?
                  AND attachment_meta.authority_state = 'active'
                ORDER BY attachment_meta.last_authorized_at DESC
                LIMIT 1
                """,
                arguments: [scope.scopeHash, cacheIdentity, messageID]
            ) else { return nil }
            guard let state = MediaCacheAuthorityState(rawValue: row["authority_state"] as String),
                  let localState = MediaCacheLocalState(rawValue: row["local_state"] as String),
                  let variant = MediaCacheVariant(rawValue: row["variant"] as String),
                  localState == .verifiedCached else { return nil }
            let resourceKind = Self.resourceKind(for: variant)
            let resourceIDKind = MediaCacheResourceIDKind(rawValue: row["resource_id_kind"] as String)
            let resourceID: String = row["resource_id"]
            let contentKind = MediaCacheContentVersionKind(rawValue: row["content_version_kind"] as String)
            let contentVersion: String = row["content_version"]
            let identity = MediaResourceIdentity(
                resourceKind: resourceKind,
                scope: scope.scopeHash,
                fileID: resourceIDKind == .fileID ? resourceID : "",
                attachmentID: resourceIDKind == .attachmentID ? resourceID : "",
                mediaID: resourceIDKind == .mediaID ? resourceID : "",
                cacheKey: resourceIDKind == .cacheKey ? resourceID : "",
                version: contentKind == .version ? contentVersion : "",
                checksumSHA256: contentKind == .checksumSHA256 ? contentVersion : (row["checksum_sha256"] as String? ?? ""),
                createdAt: contentKind == .sizeCreatedAt ? Self.createdAtFromFallback(contentVersion) : "",
                variant: variant,
                mimeType: row["mime_type"],
                sizeBytes: row["authority_size_bytes"]
            )
            let authority = IOSMediaCacheAuthorityRecord(
                scopeHash: scope.scopeHash,
                messageID: row["message_id"],
                attachmentID: row["attachment_id"],
                identity: identity,
                mimeType: row["mime_type"],
                sizeBytes: row["authority_size_bytes"],
                checksumSHA256: row["checksum_sha256"],
                state: state,
                authorityVersion: row["authority_version"],
                lastAuthorizedAt: Self.date(row["last_authorized_at"] as Double?),
                offlineAccessUntil: Self.date(row["offline_access_until"] as Double?),
                createdAt: Self.date(row["authority_created_at"] as Double?),
                updatedAt: Self.date(row["updated_at"] as Double?) ?? .distantPast
            )
            guard authority.permitsOpen(now: now, allowOffline: offline) else { return nil }
            let entry = IOSMediaCacheEntryRecord(
                scopeHash: scope.scopeHash,
                cacheIdentity: row["cache_identity"],
                attachmentID: row["attachment_id"],
                variant: variant,
                relativePath: row["relative_path"],
                localState: localState,
                sizeBytes: row["size_bytes"],
                verifiedSizeBytes: row["verified_size_bytes"],
                verifiedChecksumSHA256: row["verified_checksum_sha256"],
                pinnedByUser: row["pinned_by_user"],
                protectionReason: row["protection_reason"],
                createdAt: Self.date(row["created_at"] as Double?) ?? .distantPast,
                lastAccessedAt: Self.date(row["last_accessed_at"] as Double?) ?? .distantPast
            )
            return IOSMediaCacheIndexedLookup(authority: authority, entry: entry)
        }
    }

    public func touchMediaCache(cacheIdentity: String, at date: Date) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: "UPDATE cache_entry SET last_accessed_at = ? WHERE scope_hash = ? AND cache_identity = ?",
                arguments: [date.timeIntervalSince1970, scope.scopeHash, cacheIdentity]
            )
        }
    }

    /// Extends an offline lease only after the caller has completed an online authority
    /// refresh.  A lease refresh never revives a deny/tombstone row.
    public func renewMediaCacheAuthority(
        cacheIdentity: String,
        messageID: String,
        authorizedAt: Date,
        offlineAccessUntil: Date?
    ) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: """
                UPDATE attachment_meta
                SET last_authorized_at = ?, offline_access_until = ?, updated_at = ?
                WHERE scope_hash = ? AND authority_state = 'active'
                  AND EXISTS (
                    SELECT 1 FROM cache_reference
                    WHERE cache_reference.scope_hash = attachment_meta.scope_hash
                      AND cache_reference.message_id = attachment_meta.message_id
                      AND cache_reference.attachment_id = attachment_meta.attachment_id
                      AND cache_reference.cache_identity = ?
                  )
                  AND attachment_meta.message_id = ?
                """,
                arguments: [
                    authorizedAt.timeIntervalSince1970,
                    offlineAccessUntil?.timeIntervalSince1970,
                    authorizedAt.timeIntervalSince1970,
                    scope.scopeHash,
                    cacheIdentity,
                    messageID
                ]
            )
        }
    }

    public func markMediaCacheState(cacheIdentity: String, state: MediaCacheLocalState) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: "UPDATE cache_entry SET local_state = ? WHERE scope_hash = ? AND cache_identity = ?",
                arguments: [state.rawValue, scope.scopeHash, cacheIdentity]
            )
        }
    }

    public func mediaCacheStatistics(resourceKind: MediaResourceKind? = nil) throws -> IOSMediaCacheStatistics {
        try databasePool.read { db in
            let variants = resourceKind.map(Self.variants(for:)) ?? []
            let variantClause = variants.isEmpty
                ? ""
                : " AND variant IN (\(variants.map { _ in "?" }.joined(separator: ",")))"
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(CASE WHEN local_state = 'verified_cached' THEN 1 ELSE 0 END), 0) AS file_count,
                       COALESCE(SUM(CASE WHEN local_state = 'verified_cached' THEN size_bytes ELSE 0 END), 0) AS total_bytes,
                       COALESCE(SUM(CASE WHEN local_state = 'verified_cached' THEN size_bytes ELSE 0 END), 0) AS verified_bytes,
                       COALESCE(SUM(CASE WHEN local_state = 'corrupt' THEN 1 ELSE 0 END), 0) AS corrupt_count
                FROM cache_entry WHERE scope_hash = ?\(variantClause)
                """,
                arguments: StatementArguments([scope.scopeHash] + variants.map(\.rawValue))
            )
            return IOSMediaCacheStatistics(
                fileCount: row?["file_count"] ?? 0,
                totalBytes: row?["total_bytes"] ?? 0,
                verifiedBytes: row?["verified_bytes"] ?? 0,
                corruptCount: row?["corrupt_count"] ?? 0
            )
        }
    }

    public func mediaCachePruneCandidates(
        bytesToFree: Int64,
        resourceKind: MediaResourceKind? = nil
    ) throws -> [IOSMediaCachePruneCandidate] {
        guard bytesToFree > 0 else { return [] }
        return try databasePool.read { db in
            let variants = resourceKind.map(Self.variants(for:)) ?? []
            let variantClause = variants.isEmpty
                ? ""
                : " AND variant IN (\(variants.map { _ in "?" }.joined(separator: ",")))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT cache_identity, relative_path, size_bytes
                FROM cache_entry
                WHERE scope_hash = ? AND pinned_by_user = 0 AND protection_reason = ''
                  AND local_state IN ('corrupt', 'evicted', 'verified_cached')
                  \(variantClause)
                ORDER BY CASE local_state WHEN 'corrupt' THEN 0 WHEN 'evicted' THEN 1 ELSE 2 END,
                         last_accessed_at ASC, cache_identity ASC
                """,
                arguments: StatementArguments([scope.scopeHash] + variants.map(\.rawValue))
            )
            var remaining = bytesToFree
            var result: [IOSMediaCachePruneCandidate] = []
            for row in rows where remaining > 0 {
                let candidate = IOSMediaCachePruneCandidate(
                    cacheIdentity: row["cache_identity"],
                    relativePath: row["relative_path"],
                    sizeBytes: row["size_bytes"]
                )
                result.append(candidate)
                remaining -= max(candidate.sizeBytes, 0)
            }
            return result
        }
    }

    public func removeMediaCacheEntries(cacheIdentities: [String]) throws {
        guard !cacheIdentities.isEmpty else { return }
        try databasePool.write { db in
            try assertWriter(db)
            let placeholders = cacheIdentities.map { _ in "?" }.joined(separator: ",")
            var arguments = [scope.scopeHash]
            arguments.append(contentsOf: cacheIdentities)
            try db.execute(
                sql: "DELETE FROM cache_entry WHERE scope_hash = ? AND cache_identity IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }
    }

    public func invalidateMediaCache(
        messageID: String,
        state: MediaCacheAuthorityState,
        authorityVersion: String,
        at date: Date
    ) throws -> [IOSMediaCachePruneCandidate] {
        try databasePool.write { db in
            try assertWriter(db)
            let existingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT attachment_id, variant, authority_state, authority_version
                FROM attachment_meta
                WHERE scope_hash = ? AND message_id = ?
                """,
                arguments: [scope.scopeHash, messageID]
            )
            let existingTombstone = try Row.fetchOne(
                db,
                sql: """
                SELECT authority_state, authority_version
                FROM media_authority_tombstone
                WHERE scope_hash = ? AND message_id = ?
                """,
                arguments: [scope.scopeHash, messageID]
            )
            if let existingTombstone {
                let currentState = MediaCacheAuthorityState(
                    rawValue: existingTombstone["authority_state"] as String
                ) ?? .authorizationStale
                let currentVersion: String = existingTombstone["authority_version"]
                guard Self.acceptsAuthority(
                    currentState: currentState,
                    currentVersion: currentVersion,
                    incomingState: state,
                    incomingVersion: authorityVersion
                ) else { return [] }
            }
            var acceptedAny = existingRows.isEmpty
            for row in existingRows {
                let currentState = MediaCacheAuthorityState(rawValue: row["authority_state"] as String)
                    ?? .authorizationStale
                let currentVersion: String = row["authority_version"]
                guard Self.acceptsAuthority(
                    currentState: currentState,
                    currentVersion: currentVersion,
                    incomingState: state,
                    incomingVersion: authorityVersion
                ) else { continue }
                acceptedAny = true
                try db.execute(
                    sql: """
                    UPDATE attachment_meta
                    SET authority_state = ?, authority_version = ?, offline_access_until = NULL, updated_at = ?
                    WHERE scope_hash = ? AND message_id = ? AND attachment_id = ? AND variant = ?
                    """,
                    arguments: [
                        state.rawValue,
                        authorityVersion,
                        date.timeIntervalSince1970,
                        scope.scopeHash,
                        messageID,
                        row["attachment_id"] as String,
                        row["variant"] as String
                    ]
                )
            }
            guard acceptedAny else { return [] }
            try db.execute(
                sql: """
                INSERT INTO media_authority_tombstone (
                    scope_hash, message_id, authority_state, authority_version, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(scope_hash, message_id) DO UPDATE SET
                    authority_state = excluded.authority_state,
                    authority_version = excluded.authority_version,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    scope.scopeHash,
                    messageID,
                    state.rawValue,
                    authorityVersion,
                    date.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: "DELETE FROM cache_reference WHERE scope_hash = ? AND message_id = ?",
                arguments: [scope.scopeHash, messageID]
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT cache_identity, relative_path, size_bytes FROM cache_entry
                WHERE scope_hash = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM cache_reference
                    WHERE cache_reference.scope_hash = cache_entry.scope_hash
                      AND cache_reference.cache_identity = cache_entry.cache_identity
                  )
                """,
                arguments: [scope.scopeHash]
            )
            let candidates = rows.map {
                IOSMediaCachePruneCandidate(
                    cacheIdentity: $0["cache_identity"],
                    relativePath: $0["relative_path"],
                    sizeBytes: $0["size_bytes"]
                )
            }
            if !candidates.isEmpty {
                let placeholders = candidates.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM cache_entry WHERE scope_hash = ? AND cache_identity IN (\(placeholders))",
                    arguments: StatementArguments([scope.scopeHash] + candidates.map(\.cacheIdentity))
                )
            }
            return candidates
        }
    }

    private static func acceptsAuthority(
        currentState: MediaCacheAuthorityState,
        currentVersion: String,
        incomingState: MediaCacheAuthorityState,
        incomingVersion: String
    ) -> Bool {
        guard let incoming = canonicalUnsignedDecimal(incomingVersion) else { return false }
        let current = canonicalUnsignedDecimal(currentVersion) ?? "0"
        let comparison: ComparisonResult
        if incoming.count != current.count {
            comparison = incoming.count > current.count ? .orderedDescending : .orderedAscending
        } else {
            comparison = incoming.compare(current, options: .literal)
        }
        if comparison != .orderedSame { return comparison == .orderedDescending }
        return authorityRank(incomingState) >= authorityRank(currentState)
    }

    private static func canonicalUnsignedDecimal(_ value: String) -> String? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            return nil
        }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func shouldAcceptMediaCacheAuthority(
        currentState: MediaCacheAuthorityState,
        currentVersion: String,
        incomingState: MediaCacheAuthorityState,
        incomingVersion: String
    ) -> Bool {
        acceptsAuthority(
            currentState: currentState,
            currentVersion: currentVersion,
            incomingState: incomingState,
            incomingVersion: incomingVersion
        )
    }

    private static func authorityRank(_ state: MediaCacheAuthorityState) -> Int {
        switch state {
        case .deleted: 7
        case .recalled: 6
        case .forbidden: 5
        case .expiredBusiness: 4
        case .authorizationStale: 3
        case .processing: 2
        case .active: 1
        }
    }

    private static func resourceKind(for variant: MediaCacheVariant) -> MediaResourceKind {
        switch variant {
        case .thumbnail320, .thumbnail640, .videoPoster: .thumbnail
        case .preview1600: .preview
        case .original: .original
        }
    }

    private static func variants(for resourceKind: MediaResourceKind) -> [MediaCacheVariant] {
        switch resourceKind {
        case .thumbnail: [.thumbnail320, .thumbnail640, .videoPoster]
        case .preview: [.preview1600]
        case .original: [.original]
        }
    }

    private static func date(_ timestamp: Double?) -> Date? {
        timestamp.map(Date.init(timeIntervalSince1970:))
    }

    private static func deleteOrphanedMediaCacheEntries(
        db: Database,
        scopeHash: String
    ) throws -> [IOSMediaCachePruneCandidate] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT cache_identity, relative_path, size_bytes FROM cache_entry
            WHERE scope_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM cache_reference
                WHERE cache_reference.scope_hash = cache_entry.scope_hash
                  AND cache_reference.cache_identity = cache_entry.cache_identity
              )
            """,
            arguments: [scopeHash]
        )
        let candidates = rows.map {
            IOSMediaCachePruneCandidate(
                cacheIdentity: $0["cache_identity"],
                relativePath: $0["relative_path"],
                sizeBytes: $0["size_bytes"]
            )
        }
        if !candidates.isEmpty {
            let placeholders = candidates.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM cache_entry WHERE scope_hash = ? AND cache_identity IN (\(placeholders))",
                arguments: StatementArguments([scopeHash] + candidates.map(\.cacheIdentity))
            )
        }
        return candidates
    }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
