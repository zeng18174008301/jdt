import Foundation
import GRDB

actor SQLiteMessageRepository {
    let scope: LocalMessageScope
    let paths: MessageDatabasePaths

    private let databasePool: DatabasePool
    private let writerOwner: String
    private let writerFence: Int64
    private let openedAtMilliseconds: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static func open(scope: LocalMessageScope, paths: MessageDatabasePaths) async throws -> SQLiteMessageRepository {
        try await Task.detached(priority: .userInitiated) {
            try SQLiteMessageRepository(scope: scope, paths: paths)
        }.value
    }

    private init(scope: LocalMessageScope, paths: MessageDatabasePaths) throws {
        let started = CFAbsoluteTimeGetCurrent()
        self.scope = scope
        self.paths = paths
        writerOwner = UUID().uuidString.lowercased()
        try paths.prepare()

        var configuration = Configuration()
        configuration.label = "wenxintong.local-message.\(scope.scopeHash.prefix(12))"
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        databasePool = try DatabasePool(path: paths.databaseURL.path, configuration: configuration)
        try databasePool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try MessageDatabaseMigrations.migrator().migrate(databasePool)

        let check = try databasePool.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
        }
        guard check.lowercased() == "ok" else {
            throw LocalMessageDatabaseError.databaseCorrupt
        }

        let owner = writerOwner
        let now = Date().timeIntervalSince1970
        var claimedFence: Int64 = 0
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT scope_hash, writer_fence FROM scope_meta WHERE id = 1") {
                let storedHash: String = row["scope_hash"]
                if storedHash == scope.legacyLocalMessageScopeHash {
                    for table in [
                        "outbox",
                        "attachment_meta",
                        "cache_entry",
                        "cache_reference",
                        "media_transfer_task",
                        "media_authority_tombstone"
                    ] where try db.tableExists(table) {
                        try db.execute(
                            sql: "UPDATE \(table) SET scope_hash = ? WHERE scope_hash = ?",
                            arguments: [scope.scopeHash, storedHash]
                        )
                    }
                    try db.execute(
                        sql: "UPDATE scope_meta SET scope_hash = ?, canonical_scope_digest = ? WHERE id = 1",
                        arguments: [scope.scopeHash, scope.scopeHash]
                    )
                } else if storedHash != scope.scopeHash {
                    throw LocalMessageDatabaseError.scopeMismatch
                }
                let currentFence: Int64 = row["writer_fence"]
                claimedFence = currentFence &+ 1
                try db.execute(
                    sql: """
                    UPDATE scope_meta
                    SET schema_version = ?, canonical_scope_digest = ?, writer_owner = ?, writer_fence = ?,
                        projection_revision = 0, last_open_at = ?
                    WHERE id = 1
                    """,
                    arguments: [MessageDatabaseSchema.currentVersion, scope.scopeHash, owner, claimedFence, now]
                )
            } else {
                claimedFence = 1
                try db.execute(
                    sql: """
                    INSERT INTO scope_meta (
                        id, schema_version, scope_hash, canonical_scope_digest,
                        writer_owner, writer_fence, created_at, last_open_at
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        MessageDatabaseSchema.currentVersion,
                        scope.scopeHash,
                        scope.scopeHash,
                        owner,
                        claimedFence,
                        now,
                        now
                    ]
                )
            }
        }
        writerFence = claimedFence
        openedAtMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
        let activeStagingPaths = try databasePool.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                SELECT attachment_transfer.relative_path
                FROM attachment_transfer
                JOIN outbox USING(client_msg_no)
                WHERE outbox.scope_hash = ?
                  AND outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                  AND attachment_transfer.phase <> 'committed'
                """,
                arguments: [scope.scopeHash]
            ))
        }
        try AttachmentTransferRepository.reconcile(
            activeRelativePaths: activeStagingPaths,
            paths: paths
        )
    }

    func loadInitialConversations(limit: Int = 50, messagesPerConversation: Int = 50) throws -> ([CachedConversation], LocalMessageLoadMetrics) {
        let started = CFAbsoluteTimeGetCurrent()
        let boundedLimit = min(max(limit, 1), 1_200)
        let boundedMessageLimit = min(max(messagesPerConversation, 1), 200)
        let conversations = try databasePool.read { db -> [CachedConversation] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT conversation_key, payload
                FROM conversation
                ORDER BY pinned DESC, sort_at DESC, conversation_key
                LIMIT ?
                """,
                arguments: [boundedLimit]
            )
            return try rows.compactMap { row in
                let conversationID: String = row["conversation_key"]
                let payload: Data = row["payload"]
                guard let metadata = try? decoder.decode(CachedConversation.self, from: payload) else { return nil }
                let messageRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT payload
                    FROM message
                    WHERE conversation_key = ?
                    ORDER BY COALESCE(created_at, 0) DESC, COALESCE(channel_seq, 0) DESC, local_row_id DESC
                    LIMIT ?
                    """,
                    arguments: [conversationID, boundedMessageLimit]
                )
                let messages = messageRows.compactMap { messageRow -> CachedMessage? in
                    let messagePayload: Data = messageRow["payload"]
                    return try? decoder.decode(CachedMessage.self, from: messagePayload)
                }.reversed()
                var model = metadata.model
                model.messages = Array(messages).map(\.model)
                return CachedConversation(conversation: model, messageLimit: boundedMessageLimit)
            }
        }
        let messageCount = conversations.reduce(0) { $0 + $1.messages.count }
        return (
            conversations,
            LocalMessageLoadMetrics(
                openMilliseconds: openedAtMilliseconds,
                queryMilliseconds: Int((CFAbsoluteTimeGetCurrent() - started) * 1_000),
                conversationCount: conversations.count,
                messageCount: messageCount
            )
        )
    }

    func loadProfileContactProjection() throws -> LocalProfileContactProjection? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT revision, payload FROM profile_contact_projection WHERE id = 1"
            ) else { return nil }
            let revision: Int64 = row["revision"]
            let payload: Data = row["payload"]
            guard revision >= 0,
                  var projection = try? decoder.decode(LocalProfileContactProjection.self, from: payload) else {
                return nil
            }
            if projection.revision != UInt64(revision) {
                projection = LocalProfileContactProjection(
                    revision: UInt64(revision),
                    contacts: projection.contacts,
                    remarks: projection.remarks,
                    blacklist: projection.blacklist,
                    originalNames: projection.originalNames
                )
            }
            return projection
        }
    }

    func persistProfileContactProjection(_ projection: LocalProfileContactProjection) throws {
        guard projection.revision <= UInt64(Int64.max) else {
            throw LocalMessageDatabaseError.identityConflict
        }
        let revision = Int64(projection.revision)
        let payload = try encoder.encode(projection)
        let now = Date().timeIntervalSince1970
        try databasePool.write { db in
            try assertWriter(db)
            let storedRevision = try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM profile_contact_projection WHERE id = 1"
            ) ?? -1
            guard revision >= storedRevision else { throw LocalMessageDatabaseError.staleSession }
            try db.execute(
                sql: """
                INSERT INTO profile_contact_projection (id, revision, payload, updated_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    revision = excluded.revision,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                WHERE excluded.revision >= profile_contact_projection.revision
                """,
                arguments: [revision, payload, now]
            )
        }
    }

    func loadOlderMessages(channelKey: String, beforeSeq: Int64, limit: Int = 50) throws -> [CachedMessage] {
        let boundedLimit = min(max(limit, 1), 100)
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT payload
                FROM message
                WHERE channel_key = ? AND channel_seq > 0 AND channel_seq < ?
                ORDER BY channel_seq DESC, local_row_id DESC
                LIMIT ?
                """,
                arguments: [channelKey, beforeSeq, boundedLimit]
            )
            return rows.compactMap { row -> CachedMessage? in
                let payload: Data = row["payload"]
                return try? decoder.decode(CachedMessage.self, from: payload)
            }.reversed()
        }
    }

    func search(_ query: String, limit: Int = 50) throws -> [LocalMessageSearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let boundedLimit = min(max(limit, 1), 100)
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message.conversation_key, message.payload
                FROM message_search
                JOIN message ON message.local_row_id = message_search.local_row_id
                WHERE message_search MATCH ?
                ORDER BY bm25(message_search), message.created_at DESC
                LIMIT ?
                """,
                arguments: [normalized, boundedLimit]
            )
            return rows.compactMap { row -> LocalMessageSearchResult? in
                let conversationID: String = row["conversation_key"]
                let payload: Data = row["payload"]
                guard let message = try? decoder.decode(CachedMessage.self, from: payload) else { return nil }
                return LocalMessageSearchResult(conversationID: conversationID, message: message)
            }
        }
    }

    func projectionRevisionFloor() throws -> Int64 {
        try databasePool.read { db in
            try assertWriter(db)
            return try Int64.fetchOne(db, sql: "SELECT projection_revision FROM scope_meta WHERE id = 1") ?? 0
        }
    }

    func persistProjection(
        _ snapshots: [LocalMessageConversationSnapshot],
        source: LocalMessageProjectionSource,
        revision: Int64,
        replaceMissingConversations: Bool
    ) throws -> LocalMessageMergeMetrics {
        if snapshots.isEmpty {
            guard replaceMissingConversations else { return LocalMessageMergeMetrics() }
            try databasePool.write { db in
                try assertWriter(db)
                let storedRevision = try Int64.fetchOne(
                    db,
                    sql: "SELECT projection_revision FROM scope_meta WHERE id = 1"
                ) ?? 0
                guard revision >= storedRevision else { throw LocalMessageDatabaseError.staleSession }
                try db.execute(sql: "DELETE FROM conversation")
                try db.execute(sql: "DELETE FROM rtc_call_record")
                try db.execute(
                    sql: "UPDATE scope_meta SET projection_revision = ?, last_open_at = ? WHERE id = 1",
                    arguments: [revision, Date().timeIntervalSince1970]
                )
            }
            return LocalMessageMergeMetrics()
        }
        let now = Date().timeIntervalSince1970
        return try databasePool.write { db in
            try assertWriter(db)
            let storedRevision = try Int64.fetchOne(
                db,
                sql: "SELECT projection_revision FROM scope_meta WHERE id = 1"
            ) ?? 0
            guard revision >= storedRevision else { throw LocalMessageDatabaseError.staleSession }

            var metrics = LocalMessageMergeMetrics()
            var fastIdentityState: MessageIdentityAccumulator? = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message"
            ) == 0 ? MessageIdentityAccumulator() : nil
            var retainedConversationIDs: [String] = []
            retainedConversationIDs.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                retainedConversationIDs.append(snapshot.metadata.id)
                let perConversationConflicts = try persistConversation(
                    snapshot,
                    source: source,
                    now: now,
                    db: db,
                    fastIdentityState: &fastIdentityState,
                    metrics: &metrics
                )
                try rebuildChannelStateAndGaps(
                    snapshot,
                    preserveContiguousBecauseOfConflict: perConversationConflicts > 0,
                    now: now,
                    db: db,
                    metrics: &metrics
                )
            }
            if replaceMissingConversations, !retainedConversationIDs.isEmpty {
                let placeholders = retainedConversationIDs.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM conversation WHERE conversation_key NOT IN (\(placeholders))",
                    arguments: StatementArguments(retainedConversationIDs)
                )
                try db.execute(
                    sql: "DELETE FROM rtc_call_record WHERE conversation_key NOT IN (SELECT conversation_key FROM conversation)"
                )
            }
            try db.execute(
                sql: "UPDATE scope_meta SET projection_revision = ?, last_open_at = ? WHERE id = 1",
                arguments: [revision, now]
            )
            return metrics
        }
    }

    func importLegacy(
        _ snapshots: [LocalMessageConversationSnapshot],
        revision: Int64
    ) throws -> Bool {
        guard !snapshots.isEmpty else { return false }
        let state = try databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT legacy_import_state FROM scope_meta WHERE id = 1") ?? "pending"
        }
        if state == "complete" {
            return try databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0) > 0
            }
        }
        _ = try persistProjection(
            snapshots,
            source: .legacySnapshot,
            revision: revision,
            replaceMissingConversations: false
        )
        return try databasePool.write { db in
            try assertWriter(db)
            let conversationCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
            guard conversationCount > 0 else { return false }
            try db.execute(sql: "UPDATE scope_meta SET legacy_import_state = 'complete' WHERE id = 1")
            return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0) == conversationCount
        }
    }

    func enqueueOutgoing(
        _ intent: LocalMessageOutgoingIntent,
        revision: Int64
    ) throws -> LocalMessageMergeMetrics {
        let clientMessageID = intent.message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientMessageID.isEmpty else { throw LocalMessageDatabaseError.identityConflict }
        let stagedAttachment = try intent.attachment.map {
            try AttachmentTransferRepository.stage(
                $0,
                clientMessageID: clientMessageID,
                paths: paths
            )
        }
        let now = Date().timeIntervalSince1970
        do {
            return try databasePool.write { db in
                try assertWriter(db)
                var metrics = LocalMessageMergeMetrics()
                var fastIdentityState: MessageIdentityAccumulator?
                _ = try persistConversation(
                    intent.conversation,
                    source: .outbox,
                    now: now,
                    db: db,
                    fastIdentityState: &fastIdentityState,
                    metrics: &metrics
                )
                let payload = try encoder.encode(intent.message.sanitizedForDurableOutbox())
                let initialState = stagedAttachment == nil
                    ? LocalMessageOutboxState.ready.rawValue
                    : LocalMessageOutboxState.stagingAttachment.rawValue
                try db.execute(
                    sql: """
                    INSERT INTO outbox (
                        client_msg_no, operation_kind, conversation_key, channel_key, channel_type,
                        scope_hash, payload, state, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(client_msg_no) DO UPDATE SET
                        operation_kind = excluded.operation_kind,
                        conversation_key = excluded.conversation_key,
                        channel_key = excluded.channel_key,
                        channel_type = excluded.channel_type,
                        payload = excluded.payload,
                        state = CASE
                            WHEN outbox.state IN ('acked', 'sending') THEN outbox.state
                            ELSE excluded.state
                        END,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        clientMessageID,
                        intent.operationKind,
                        intent.conversation.metadata.id,
                        intent.conversation.channelID,
                        intent.conversation.channelType,
                        scope.scopeHash,
                        payload,
                        initialState,
                        now,
                        now
                    ]
                )
                if let stagedAttachment {
                    try db.execute(
                        sql: """
                        INSERT INTO attachment_transfer (
                            transfer_id, client_msg_no, relative_path, file_name, mime_type,
                            size_bytes, checksum, phase, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'staged', ?)
                        ON CONFLICT(client_msg_no) DO UPDATE SET
                            relative_path = excluded.relative_path,
                            file_name = excluded.file_name,
                            mime_type = excluded.mime_type,
                            size_bytes = excluded.size_bytes,
                            checksum = excluded.checksum,
                            phase = attachment_transfer.phase,
                            file_id = attachment_transfer.file_id,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [
                            "transfer:\(clientMessageID)",
                            clientMessageID,
                            stagedAttachment.relativePath,
                            stagedAttachment.fileName,
                            stagedAttachment.mimeType,
                            stagedAttachment.sizeBytes,
                            stagedAttachment.checksum,
                            now
                        ]
                    )
                    try db.execute(
                        sql: "UPDATE outbox SET state = CASE WHEN state = 'sending' THEN state ELSE 'ready' END, updated_at = ? WHERE client_msg_no = ?",
                        arguments: [now, clientMessageID]
                    )
                }
                try db.execute(
                    sql: "UPDATE scope_meta SET projection_revision = MAX(projection_revision, ?) WHERE id = 1",
                    arguments: [revision]
                )
                return metrics
            }
        } catch {
            if let stagedAttachment {
                AttachmentTransferRepository.remove(stagedAttachment, paths: paths)
            }
            throw error
        }
    }

    func updateOutboxState(
        clientMessageID: String,
        state: LocalMessageOutboxState,
        uncertain: Bool = false,
        fileID: String? = nil,
        attachmentPhase: String? = nil,
        now: Date = Date(),
        retryAfter: TimeInterval? = nil,
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) throws {
        let nowValue = now.timeIntervalSince1970
        try databasePool.write { db in
            try assertWriter(db)
            let current = try Row.fetchOne(
                db,
                sql: "SELECT state, attempt_count FROM outbox WHERE client_msg_no = ? AND state <> 'acked'",
                arguments: [clientMessageID]
            )
            guard let current else { return }
            let currentState: String = current["state"]
            let attemptCount: Int = current["attempt_count"]
            let nextAttemptCount = state == .sending && currentState != LocalMessageOutboxState.sending.rawValue
                ? attemptCount + 1
                : attemptCount
            let nextAttemptAt: TimeInterval?
            switch state {
            case .sending, .awaitingAcknowledgement, .uncertain, .retryWait:
                nextAttemptAt = nowValue + replayPolicy.retryDelay(
                    afterAttempt: max(1, nextAttemptCount),
                    retryAfter: retryAfter
                )
            case .stagingAttachment, .ready, .failedPermanent, .acknowledged, .cancelled:
                nextAttemptAt = nil
            }
            try db.execute(
                sql: """
                UPDATE outbox
                SET state = ?, uncertain = ?,
                    attempt_count = ?, next_attempt_at = ?,
                    lease_owner = CASE WHEN ? = 'sending' THEN lease_owner ELSE '' END,
                    lease_fence = CASE WHEN ? = 'sending' THEN lease_fence ELSE 0 END,
                    updated_at = ?
                WHERE client_msg_no = ? AND state <> 'acked'
                """,
                arguments: [
                    state.rawValue,
                    uncertain,
                    nextAttemptCount,
                    nextAttemptAt,
                    state.rawValue,
                    state.rawValue,
                    nowValue,
                    clientMessageID
                ]
            )
            if let attachmentPhase {
                try db.execute(
                    sql: """
                    UPDATE attachment_transfer
                    SET phase = ?, file_id = CASE WHEN ? = '' THEN file_id ELSE ? END, updated_at = ?
                    WHERE client_msg_no = ?
                    """,
                    arguments: [attachmentPhase, fileID ?? "", fileID ?? "", nowValue, clientMessageID]
                )
            }
        }
        if state == .acknowledged || state == .cancelled || state == .failedPermanent {
            try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: clientMessageID))
        }
    }

    func confirmOutgoing(
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        projection: LocalMessageConversationSnapshot,
        revision: Int64
    ) throws {
        guard !authoritativeMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              authoritativeChannelSeq > 0 else {
            throw LocalMessageDatabaseError.identityConflict
        }
        let now = Date().timeIntervalSince1970
        try databasePool.write { db in
            try assertWriter(db)
            _ = try acknowledgeOutgoingAuthority(
                clientMessageID: clientMessageID,
                authoritativeMessageID: authoritativeMessageID,
                authoritativeChannelSeq: authoritativeChannelSeq,
                channelKey: projection.channelID,
                now: now,
                db: db
            )
            var metrics = LocalMessageMergeMetrics()
            var fastIdentityState: MessageIdentityAccumulator?
            _ = try persistConversation(
                projection,
                source: .serverAcknowledgement,
                now: now,
                db: db,
                fastIdentityState: &fastIdentityState,
                metrics: &metrics
            )
            try rebuildChannelStateAndGaps(
                projection,
                preserveContiguousBecauseOfConflict: metrics.conflict > 0,
                now: now,
                db: db,
                metrics: &metrics
            )
            try db.execute(
                sql: "UPDATE scope_meta SET projection_revision = MAX(projection_revision, ?) WHERE id = 1",
                arguments: [revision]
            )
        }
        try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: clientMessageID))
    }

    @discardableResult
    func acknowledgeOutgoingAuthority(
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        channelKey: String
    ) throws -> Bool {
        let normalizedClientMessageID = clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessageID = authoritativeMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelKey = channelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientMessageID.isEmpty,
              !normalizedMessageID.isEmpty,
              !normalizedChannelKey.isEmpty,
              authoritativeChannelSeq > 0 else {
            throw LocalMessageDatabaseError.identityConflict
        }
        let now = Date().timeIntervalSince1970
        let acknowledged = try databasePool.write { db in
            try assertWriter(db)
            return try acknowledgeOutgoingAuthority(
                clientMessageID: normalizedClientMessageID,
                authoritativeMessageID: normalizedMessageID,
                authoritativeChannelSeq: authoritativeChannelSeq,
                channelKey: normalizedChannelKey,
                now: now,
                db: db
            )
        }
        if acknowledged {
            try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: normalizedClientMessageID))
        }
        return acknowledged
    }

    func outgoingAuthority(clientMessageID: String) throws -> LocalMessageOutgoingAuthority? {
        let normalizedClientMessageID = clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientMessageID.isEmpty else { return nil }
        return try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT client_msg_no, state, authoritative_message_id, authoritative_channel_seq
                FROM outbox
                WHERE client_msg_no = ? AND scope_hash = ?
                """,
                arguments: [normalizedClientMessageID, scope.scopeHash]
            ) else { return nil }
            return LocalMessageOutgoingAuthority(
                clientMessageID: row["client_msg_no"],
                state: row["state"],
                authoritativeMessageID: row["authoritative_message_id"],
                authoritativeChannelSeq: row["authoritative_channel_seq"]
            )
        }
    }

    func deleteConversation(conversationID: String) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(sql: "DELETE FROM rtc_call_record WHERE conversation_key = ?", arguments: [conversationID])
            try db.execute(sql: "DELETE FROM conversation WHERE conversation_key = ?", arguments: [conversationID])
        }
    }

    func removeMediaCacheReferences(conversationID: String) throws -> [IOSMediaCachePruneCandidate] {
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

    func removeMediaCacheReferences(
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

    func recordAckDesired(
        channelKey: String,
        type: String,
        desiredSeq: Int64,
        resetRetryBudget: Bool = false
    ) throws -> Int64 {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["read", "delivery"].contains(normalizedType), desiredSeq > 0 else { return 0 }
        let now = Date().timeIntervalSince1970
        return try databasePool.write { db in
            try assertWriter(db)
            let contiguous = try Int64.fetchOne(
                db,
                sql: "SELECT contiguous_seq FROM channel_state WHERE channel_key = ?",
                arguments: [channelKey]
            ) ?? 0
            let clamped = min(desiredSeq, contiguous)
            guard clamped > 0 else { return 0 }
            try db.execute(
                sql: """
                INSERT INTO ack_cursor (channel_key, ack_type, desired_seq, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(channel_key, ack_type) DO UPDATE SET
                    desired_seq = MAX(ack_cursor.desired_seq, excluded.desired_seq),
                    inflight_seq = CASE
                        WHEN ? OR excluded.desired_seq > ack_cursor.desired_seq THEN 0
                        ELSE ack_cursor.inflight_seq
                    END,
                    attempt_count = CASE
                        WHEN ? OR excluded.desired_seq > ack_cursor.desired_seq THEN 0
                        ELSE ack_cursor.attempt_count
                    END,
                    retry_at = CASE
                        WHEN ? OR excluded.desired_seq > ack_cursor.desired_seq THEN NULL
                        ELSE ack_cursor.retry_at
                    END,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    channelKey,
                    normalizedType,
                    clamped,
                    now,
                    resetRetryBudget,
                    resetRetryBudget,
                    resetRetryBudget
                ]
            )
            return try Int64.fetchOne(
                db,
                sql: "SELECT desired_seq FROM ack_cursor WHERE channel_key = ? AND ack_type = ?",
                arguments: [channelKey, normalizedType]
            ) ?? clamped
        }
    }

    func recoverableAcks(
        type: String,
        retryPolicy: LocalMessageAckRetryPolicy = .standard
    ) throws -> [LocalMessagePendingAck] {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["read", "delivery"].contains(normalizedType) else { return [] }
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT channel_key, ack_type, desired_seq, inflight_seq, confirmed_seq,
                       attempt_count, retry_at
                FROM ack_cursor
                WHERE ack_type = ?
                  AND desired_seq > confirmed_seq
                  AND attempt_count < ?
                ORDER BY COALESCE(retry_at, 0), updated_at, channel_key
                """,
                arguments: [normalizedType, retryPolicy.maximumAutomaticAttempts]
            )
            return rows.map(Self.pendingAck(from:))
        }
    }

    func ackStates(type: String) throws -> [LocalMessagePendingAck] {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["read", "delivery"].contains(normalizedType) else { return [] }
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT channel_key, ack_type, desired_seq, inflight_seq, confirmed_seq,
                       attempt_count, retry_at
                FROM ack_cursor
                WHERE ack_type = ?
                ORDER BY channel_key
                """,
                arguments: [normalizedType]
            )
            return rows.map(Self.pendingAck(from:))
        }
    }

    func claimAcksForRetry(
        type: String,
        channelKey: String? = nil,
        now: Date = Date(),
        limit: Int = 20,
        retryPolicy: LocalMessageAckRetryPolicy = .standard
    ) throws -> [LocalMessagePendingAck] {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["read", "delivery"].contains(normalizedType) else { return [] }
        let timestamp = now.timeIntervalSince1970
        let boundedLimit = min(max(limit, 1), 100)
        return try databasePool.write { db in
            try assertWriter(db)
            let rows: [Row]
            if let channelKey {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT channel_key, ack_type, desired_seq, inflight_seq, confirmed_seq,
                           attempt_count, retry_at
                    FROM ack_cursor
                    WHERE ack_type = ? AND channel_key = ?
                      AND desired_seq > confirmed_seq
                      AND attempt_count < ?
                      AND (retry_at IS NULL OR retry_at <= ?)
                    LIMIT ?
                    """,
                    arguments: [
                        normalizedType,
                        channelKey,
                        retryPolicy.maximumAutomaticAttempts,
                        timestamp,
                        boundedLimit
                    ]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT channel_key, ack_type, desired_seq, inflight_seq, confirmed_seq,
                           attempt_count, retry_at
                    FROM ack_cursor
                    WHERE ack_type = ?
                      AND desired_seq > confirmed_seq
                      AND attempt_count < ?
                      AND (retry_at IS NULL OR retry_at <= ?)
                    ORDER BY COALESCE(retry_at, 0), updated_at, channel_key
                    LIMIT ?
                    """,
                    arguments: [
                        normalizedType,
                        retryPolicy.maximumAutomaticAttempts,
                        timestamp,
                        boundedLimit
                    ]
                )
            }
            var claimed: [LocalMessagePendingAck] = []
            for row in rows {
                let item = Self.pendingAck(from: row)
                let nextAttemptCount = item.attemptCount + 1
                let retryAt = timestamp + retryPolicy.retryDelay(afterAttempt: nextAttemptCount)
                try db.execute(
                    sql: """
                    UPDATE ack_cursor
                    SET inflight_seq = desired_seq,
                        attempt_count = ?,
                        retry_at = ?,
                        updated_at = ?
                    WHERE channel_key = ? AND ack_type = ?
                      AND desired_seq > confirmed_seq
                      AND attempt_count = ?
                    """,
                    arguments: [
                        nextAttemptCount,
                        retryAt,
                        timestamp,
                        item.channelID,
                        item.type,
                        item.attemptCount
                    ]
                )
                guard db.changesCount == 1 else { continue }
                claimed.append(
                    LocalMessagePendingAck(
                        channelID: item.channelID,
                        type: item.type,
                        desiredSeq: item.desiredSeq,
                        inflightSeq: item.desiredSeq,
                        confirmedSeq: item.confirmedSeq,
                        attemptCount: nextAttemptCount,
                        retryAt: retryAt
                    )
                )
            }
            return claimed
        }
    }

    func releaseAckForRetry(channelKey: String, type: String) throws {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: """
                UPDATE ack_cursor
                SET inflight_seq = 0, updated_at = ?
                WHERE channel_key = ? AND ack_type = ? AND desired_seq > confirmed_seq
                """,
                arguments: [Date().timeIntervalSince1970, channelKey, normalizedType]
            )
        }
    }

    func abandonAckClaimWithoutConsumingAttempt(
        channelKey: String,
        type: String,
        claimedSeq: Int64,
        claimedAttemptCount: Int
    ) throws {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: """
                UPDATE ack_cursor
                SET inflight_seq = 0,
                    attempt_count = MAX(0, attempt_count - 1),
                    retry_at = NULL,
                    updated_at = ?
                WHERE channel_key = ? AND ack_type = ?
                  AND desired_seq = ? AND inflight_seq = ? AND attempt_count = ?
                  AND desired_seq > confirmed_seq
                """,
                arguments: [
                    Date().timeIntervalSince1970,
                    channelKey,
                    normalizedType,
                    claimedSeq,
                    claimedSeq,
                    claimedAttemptCount
                ]
            )
        }
    }

    func confirmAck(channelKey: String, type: String, confirmedSeq: Int64) throws {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date().timeIntervalSince1970
        try databasePool.write { db in
            try assertWriter(db)
            let contiguous = try Int64.fetchOne(
                db,
                sql: "SELECT contiguous_seq FROM channel_state WHERE channel_key = ?",
                arguments: [channelKey]
            ) ?? 0
            let clamped = min(max(0, confirmedSeq), contiguous)
            try db.execute(
                sql: """
                INSERT INTO ack_cursor (channel_key, ack_type, desired_seq, confirmed_seq, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(channel_key, ack_type) DO UPDATE SET
                    desired_seq = MAX(ack_cursor.desired_seq, excluded.desired_seq),
                    confirmed_seq = MAX(ack_cursor.confirmed_seq, excluded.confirmed_seq),
                    inflight_seq = CASE WHEN ack_cursor.inflight_seq <= excluded.confirmed_seq THEN 0 ELSE ack_cursor.inflight_seq END,
                    attempt_count = CASE
                        WHEN MAX(ack_cursor.confirmed_seq, excluded.confirmed_seq) >= MAX(ack_cursor.desired_seq, excluded.desired_seq)
                        THEN 0 ELSE ack_cursor.attempt_count
                    END,
                    retry_at = CASE
                        WHEN MAX(ack_cursor.confirmed_seq, excluded.confirmed_seq) >= MAX(ack_cursor.desired_seq, excluded.desired_seq)
                        THEN NULL ELSE ack_cursor.retry_at
                    END,
                    updated_at = excluded.updated_at
                """,
                arguments: [channelKey, normalizedType, clamped, clamped, now]
            )
        }
    }

    func ackCheckpoint(channelKey: String, type: String) throws -> (desired: Int64, confirmed: Int64) {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT desired_seq, confirmed_seq FROM ack_cursor WHERE channel_key = ? AND ack_type = ?",
                arguments: [channelKey, type]
            ) else { return (0, 0) }
            return (row["desired_seq"], row["confirmed_seq"])
        }
    }

    func ackState(channelKey: String, type: String) throws -> LocalMessagePendingAck? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT channel_key, ack_type, desired_seq, inflight_seq, confirmed_seq,
                       attempt_count, retry_at
                FROM ack_cursor
                WHERE channel_key = ? AND ack_type = ?
                """,
                arguments: [channelKey, type]
            ) else { return nil }
            return Self.pendingAck(from: row)
        }
    }

    private nonisolated static func pendingAck(from row: Row) -> LocalMessagePendingAck {
        LocalMessagePendingAck(
            channelID: row["channel_key"],
            type: row["ack_type"],
            desiredSeq: row["desired_seq"],
            inflightSeq: row["inflight_seq"],
            confirmedSeq: row["confirmed_seq"],
            attemptCount: row["attempt_count"],
            retryAt: row["retry_at"]
        )
    }

    func pendingOutbox(
        now: Date = Date(),
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) throws -> [LocalMessageRecoveredOutbox] {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT outbox.client_msg_no, outbox.conversation_key, outbox.channel_key,
                       outbox.channel_type, outbox.operation_kind, outbox.state,
                       outbox.attempt_count, outbox.next_attempt_at, outbox.payload,
                       attachment_transfer.relative_path, attachment_transfer.file_name,
                       attachment_transfer.mime_type, attachment_transfer.size_bytes,
                       attachment_transfer.file_id, attachment_transfer.phase
                FROM outbox
                LEFT JOIN attachment_transfer USING(client_msg_no)
                WHERE outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                  AND outbox.scope_hash = ?
                  AND outbox.attempt_count < ?
                  AND (outbox.next_attempt_at IS NULL OR outbox.next_attempt_at <= ?)
                ORDER BY outbox.created_at, outbox.client_msg_no
                """,
                arguments: [
                    scope.scopeHash,
                    replayPolicy.maximumAutomaticAttempts,
                    now.timeIntervalSince1970
                ]
            )
            return rows.compactMap { recoveredOutbox(from: $0, replayPolicy: replayPolicy) }
        }
    }

    func recoverableOutbox(
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) throws -> [LocalMessageRecoveredOutbox] {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT outbox.client_msg_no, outbox.conversation_key, outbox.channel_key,
                       outbox.channel_type, outbox.operation_kind, outbox.state,
                       outbox.attempt_count, outbox.next_attempt_at, outbox.payload,
                       attachment_transfer.relative_path, attachment_transfer.file_name,
                       attachment_transfer.mime_type, attachment_transfer.size_bytes,
                       attachment_transfer.file_id, attachment_transfer.phase
                FROM outbox
                LEFT JOIN attachment_transfer USING(client_msg_no)
                WHERE outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                  AND outbox.scope_hash = ?
                ORDER BY outbox.created_at, outbox.client_msg_no
                """,
                arguments: [scope.scopeHash]
            )
            return rows.compactMap { recoveredOutbox(from: $0, replayPolicy: replayPolicy) }
        }
    }

    func claimOutboxForReplay(
        authorizationGeneration: UInt64,
        trigger: LocalMessageOutboxReplayTrigger,
        clientMessageID: String?,
        now: Date = Date(),
        limit: Int = 20,
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard
    ) throws -> [LocalMessageRecoveredOutbox] {
        guard authorizationGeneration > 0,
              let authorizationFence = Int64(exactly: authorizationGeneration) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let normalizedClientMessageID = clientMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trigger == .userInitiated, normalizedClientMessageID.isEmpty {
            throw LocalMessageDatabaseError.identityConflict
        }
        let boundedLimit = min(max(1, limit), 100)
        let nowValue = now.timeIntervalSince1970
        return try databasePool.write { db in
            try assertWriter(db)
            let ids: [String]
            switch trigger {
            case .automatic:
                ids = try String.fetchAll(
                    db,
                    sql: """
                    SELECT client_msg_no
                    FROM outbox
                    WHERE scope_hash = ?
                      AND state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                      AND attempt_count < ?
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                    ORDER BY created_at, client_msg_no
                    LIMIT ?
                    """,
                    arguments: [
                        scope.scopeHash,
                        replayPolicy.maximumAutomaticAttempts,
                        nowValue,
                        boundedLimit
                    ]
                )
            case .userInitiated:
                ids = try String.fetchAll(
                    db,
                    sql: """
                    SELECT client_msg_no
                    FROM outbox
                    WHERE scope_hash = ? AND client_msg_no = ?
                      AND state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                    LIMIT 1
                    """,
                    arguments: [scope.scopeHash, normalizedClientMessageID]
                )
            }
            guard !ids.isEmpty else { return [] }
            for id in ids {
                let attemptCount = try Int.fetchOne(
                    db,
                    sql: "SELECT attempt_count FROM outbox WHERE client_msg_no = ?",
                    arguments: [id]
                ) ?? 0
                let nextAttemptCount = attemptCount + 1
                let nextAttemptAt = nowValue + replayPolicy.retryDelay(afterAttempt: nextAttemptCount)
                try db.execute(
                    sql: """
                    UPDATE outbox
                    SET state = 'sending', attempt_count = ?, next_attempt_at = ?,
                        lease_owner = ?, lease_fence = ?, updated_at = ?
                    WHERE client_msg_no = ? AND scope_hash = ? AND state <> 'acked'
                    """,
                    arguments: [
                        nextAttemptCount,
                        nextAttemptAt,
                        writerOwner,
                        authorizationFence,
                        nowValue,
                        id,
                        scope.scopeHash
                    ]
                )
            }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT outbox.client_msg_no, outbox.conversation_key, outbox.channel_key,
                       outbox.channel_type, outbox.operation_kind, outbox.state,
                       outbox.attempt_count, outbox.next_attempt_at, outbox.payload,
                       attachment_transfer.relative_path, attachment_transfer.file_name,
                       attachment_transfer.mime_type, attachment_transfer.size_bytes,
                       attachment_transfer.file_id, attachment_transfer.phase
                FROM outbox
                LEFT JOIN attachment_transfer USING(client_msg_no)
                WHERE outbox.client_msg_no IN (\(placeholders))
                ORDER BY outbox.created_at, outbox.client_msg_no
                """,
                arguments: StatementArguments(ids)
            )
            return rows.compactMap { recoveredOutbox(from: $0, replayPolicy: replayPolicy) }
        }
    }

    func loadStagedAttachment(for item: LocalMessageRecoveredOutbox) throws -> Data? {
        guard let relativePath = item.attachmentRelativePath,
              let expectedSize = item.attachmentSizeBytes else { return nil }
        let checksum = try databasePool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT checksum FROM attachment_transfer WHERE client_msg_no = ?",
                arguments: [item.clientMessageID]
            ) ?? ""
        }
        guard !checksum.isEmpty else { throw LocalMessageDatabaseError.missingStagedAttachment }
        return try AttachmentTransferRepository.load(
            relativePath: relativePath,
            expectedSizeBytes: expectedSize,
            expectedChecksum: checksum,
            paths: paths
        )
    }

    func stagedAttachmentFileURL(for item: LocalMessageRecoveredOutbox) throws -> URL? {
        guard let relativePath = item.attachmentRelativePath,
              let expectedSize = item.attachmentSizeBytes else { return nil }
        let checksum = try databasePool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT checksum FROM attachment_transfer WHERE client_msg_no = ?",
                arguments: [item.clientMessageID]
            ) ?? ""
        }
        guard !checksum.isEmpty else { throw LocalMessageDatabaseError.missingStagedAttachment }
        return try AttachmentTransferRepository.loadFileURL(
            relativePath: relativePath,
            expectedSizeBytes: expectedSize,
            expectedChecksum: checksum,
            paths: paths
        )
    }

    func diagnostics() throws -> LocalMessageDatabaseDiagnostics {
        try databasePool.read { db in
            let meta = try Row.fetchOne(
                db,
                sql: "SELECT schema_version, scope_hash, writer_fence FROM scope_meta WHERE id = 1"
            )
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
            let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
            return LocalMessageDatabaseDiagnostics(
                scopeHash: meta?["scope_hash"] ?? "",
                schemaVersion: meta?["schema_version"] ?? 0,
                journalMode: journalMode,
                quickCheck: quickCheck,
                writerFence: meta?["writer_fence"] ?? 0,
                backupExcluded: try paths.isBackupExcluded(),
                conversationCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0,
                messageCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0,
                outboxCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE state <> 'acked' AND state <> 'cancelled'") ?? 0,
                gapCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gap_range") ?? 0
            )
        }
    }

    func upsertMediaCache(
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

    func mediaCacheLookup(
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

    func touchMediaCache(cacheIdentity: String, at date: Date) throws {
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
    func renewMediaCacheAuthority(
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

    func markMediaCacheState(cacheIdentity: String, state: MediaCacheLocalState) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(
                sql: "UPDATE cache_entry SET local_state = ? WHERE scope_hash = ? AND cache_identity = ?",
                arguments: [state.rawValue, scope.scopeHash, cacheIdentity]
            )
        }
    }

    func mediaCacheStatistics(resourceKind: MediaResourceKind? = nil) throws -> IOSMediaCacheStatistics {
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

    func mediaCachePruneCandidates(
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

    func removeMediaCacheEntries(cacheIdentities: [String]) throws {
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

    func invalidateMediaCache(
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

    private func recoveredOutbox(
        from row: Row,
        replayPolicy: LocalMessageOutboxReplayPolicy
    ) -> LocalMessageRecoveredOutbox? {
        let payload: Data = row["payload"]
        guard let message = try? decoder.decode(CachedMessage.self, from: payload) else { return nil }
        let attemptCount: Int = row["attempt_count"]
        return LocalMessageRecoveredOutbox(
            clientMessageID: row["client_msg_no"],
            conversationID: row["conversation_key"],
            channelID: row["channel_key"],
            channelType: row["channel_type"],
            operationKind: row["operation_kind"],
            state: row["state"],
            attemptCount: attemptCount,
            nextAttemptAt: row["next_attempt_at"],
            requiresUserInitiatedReplay: attemptCount >= replayPolicy.maximumAutomaticAttempts,
            message: message,
            attachmentRelativePath: row["relative_path"],
            attachmentFileName: row["file_name"],
            attachmentMimeType: row["mime_type"],
            attachmentSizeBytes: row["size_bytes"],
            attachmentFileID: row["file_id"],
            attachmentPhase: row["phase"]
        )
    }

    private func assertWriter(_ db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT scope_hash, writer_owner, writer_fence FROM scope_meta WHERE id = 1"
        ) else { throw LocalMessageDatabaseError.scopeMismatch }
        let storedScope: String = row["scope_hash"]
        let storedOwner: String = row["writer_owner"]
        let storedFence: Int64 = row["writer_fence"]
        guard storedScope == scope.scopeHash else { throw LocalMessageDatabaseError.scopeMismatch }
        guard storedOwner == writerOwner, storedFence == writerFence else {
            throw LocalMessageDatabaseError.staleWriter
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

    private static func createdAtFromFallback(_ value: String) -> String {
        guard let range = value.range(of: ";created_at=") else { return "" }
        return String(value[range.upperBound...])
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

    @discardableResult
    private func acknowledgeOutgoingAuthority(
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        channelKey: String,
        now: TimeInterval,
        db: Database
    ) throws -> Bool {
        guard let outbox = try Row.fetchOne(
            db,
            sql: """
            SELECT channel_key, state, authoritative_message_id, authoritative_channel_seq
            FROM outbox
            WHERE client_msg_no = ? AND scope_hash = ?
            """,
            arguments: [clientMessageID, scope.scopeHash]
        ) else { return false }
        let storedChannelKey: String = outbox["channel_key"]
        guard storedChannelKey == channelKey else {
            throw LocalMessageDatabaseError.identityConflict
        }
        let storedState: String = outbox["state"]
        let storedMessageID: String? = outbox["authoritative_message_id"]
        let storedChannelSeq: Int64? = outbox["authoritative_channel_seq"]
        if storedState == LocalMessageOutboxState.acknowledged.rawValue {
            guard storedMessageID == authoritativeMessageID,
                  storedChannelSeq == authoritativeChannelSeq else {
                throw LocalMessageDatabaseError.identityConflict
            }
            return true
        }

        let localRowID = try String.fetchOne(
            db,
            sql: "SELECT local_row_id FROM message WHERE sender_uid = ? AND client_msg_no = ?",
            arguments: [scope.actorID, clientMessageID]
        )
        // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：ACK 目标 remote 若已绑定其它 client_msg_no，禁止静默删除当前 local 行
        let authoritativeRow = try Row.fetchOne(
            db,
            sql: "SELECT local_row_id, client_msg_no FROM message WHERE message_id = ? OR (channel_key = ? AND channel_seq = ?) LIMIT 1",
            arguments: [authoritativeMessageID, channelKey, authoritativeChannelSeq]
        )
        let authoritativeRowID: String? = authoritativeRow?["local_row_id"]
        let authoritativeClientMessageID = ((authoritativeRow?["client_msg_no"] as String?) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let authoritativeRowID,
           authoritativeRowID != (localRowID ?? ""),
           !authoritativeClientMessageID.isEmpty,
           authoritativeClientMessageID != clientMessageID {
            throw LocalMessageDatabaseError.identityConflict
        }
        // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
        if let localRowID, let authoritativeRowID, localRowID != authoritativeRowID {
            try db.execute(sql: "DELETE FROM message WHERE local_row_id = ?", arguments: [localRowID])
        } else if let localRowID {
            try db.execute(
                sql: "UPDATE message SET message_id = ?, channel_seq = ?, updated_at = ? WHERE local_row_id = ?",
                arguments: [authoritativeMessageID, authoritativeChannelSeq, now, localRowID]
            )
        }
        try db.execute(
            sql: """
            UPDATE outbox
            SET state = 'acked', uncertain = 0, next_attempt_at = NULL,
                lease_owner = '', lease_fence = 0,
                authoritative_message_id = ?, authoritative_channel_seq = ?, updated_at = ?
            WHERE client_msg_no = ? AND scope_hash = ?
            """,
            arguments: [authoritativeMessageID, authoritativeChannelSeq, now, clientMessageID, scope.scopeHash]
        )
        try db.execute(
            sql: "UPDATE attachment_transfer SET phase = 'committed', updated_at = ? WHERE client_msg_no = ?",
            arguments: [now, clientMessageID]
        )
        return true
    }

    @discardableResult
    private func persistConversation(
        _ snapshot: LocalMessageConversationSnapshot,
        source: LocalMessageProjectionSource,
        now: TimeInterval,
        db: Database,
        fastIdentityState: inout MessageIdentityAccumulator?,
        metrics: inout LocalMessageMergeMetrics
    ) throws -> Int {
        let conversation = snapshot.metadata.model
        let metadataPayload = try encoder.encode(snapshot.metadata)
        let latestMessage = snapshot.messages.max { lhs, rhs in
            if lhs.channelSeq != rhs.channelSeq { return lhs.channelSeq < rhs.channelSeq }
            return (lhs.createdAt ?? 0) < (rhs.createdAt ?? 0)
        }
        try db.execute(
            sql: """
            INSERT INTO conversation (
                conversation_key, channel_type, channel_id, payload, last_message_id,
                last_msg_seq, sort_at, pinned, muted, last_read_seq, unread_count,
                history_visible_from_seq, history_limited, history_boundary_confirmed,
                requires_server_revalidation, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_key) DO UPDATE SET
                channel_type = excluded.channel_type,
                channel_id = excluded.channel_id,
                payload = excluded.payload,
                last_message_id = excluded.last_message_id,
                last_msg_seq = MAX(conversation.last_msg_seq, excluded.last_msg_seq),
                sort_at = MAX(conversation.sort_at, excluded.sort_at),
                pinned = excluded.pinned,
                muted = excluded.muted,
                last_read_seq = MAX(conversation.last_read_seq, excluded.last_read_seq),
                unread_count = excluded.unread_count,
                history_visible_from_seq = MAX(conversation.history_visible_from_seq, excluded.history_visible_from_seq),
                history_limited = excluded.history_limited,
                history_boundary_confirmed = excluded.history_boundary_confirmed,
                requires_server_revalidation = CASE
                    WHEN excluded.requires_server_revalidation = 0 THEN 0
                    ELSE conversation.requires_server_revalidation
                END,
                updated_at = excluded.updated_at
            """,
            arguments: [
                snapshot.metadata.id,
                snapshot.channelType,
                snapshot.channelID,
                metadataPayload,
                latestMessage?.id,
                conversation.lastMsgSeq,
                conversation.sortTimestamp,
                conversation.isPinned,
                conversation.isMuted,
                conversation.lastReadSeq,
                max(0, conversation.unread),
                max(1, conversation.historyVisibleFromSeq),
                conversation.historyLimited,
                conversation.historyBoundaryConfirmed,
                snapshot.requiresServerRevalidation,
                now
            ]
        )

        var conflicts = 0
        for rawMessage in snapshot.messages {
            let message = source == .outbox
                ? rawMessage.sanitizedForDurableOutbox()
                : rawMessage
            let identityKeys = messageIdentityKeys(
                message,
                channelKey: snapshot.channelID,
                currentActorID: snapshot.currentActorID
            )
            let assumeNewIdentity: Bool
            if !identityKeys.isEmpty,
               var accumulator = fastIdentityState,
               accumulator.keys.isDisjoint(with: identityKeys) {
                accumulator.keys.formUnion(identityKeys)
                fastIdentityState = accumulator
                assumeNewIdentity = true
            } else {
                assumeNewIdentity = false
            }
            let outcome = try upsertMessage(
                message,
                conversationKey: snapshot.metadata.id,
                channelKey: snapshot.channelID,
                currentActorID: snapshot.currentActorID,
                now: now,
                db: db,
                assumeNewIdentity: assumeNewIdentity
            )
            switch outcome {
            case .inserted: metrics.inserted += 1
            case .updated: metrics.updated += 1
            case .duplicate: metrics.duplicate += 1
            case .conflict:
                conflicts += 1
                metrics.conflict += 1
            }
        }
        return conflicts
    }

    private enum MessageUpsertOutcome {
        case inserted
        case updated
        case duplicate
        case conflict
    }

    private struct MessageIdentityAccumulator {
        var keys = Set<String>()
    }

    private func messageIdentityKeys(
        _ message: CachedMessage,
        channelKey: String,
        currentActorID: String
    ) -> Set<String> {
        var keys = Set<String>()
        let identifier = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.channelSeq > 0 {
            if !identifier.isEmpty { keys.insert("message:\(identifier)") }
            keys.insert("sequence:\(channelKey):\(message.channelSeq)")
        } else if message.isOutgoing, !identifier.isEmpty {
            keys.insert("client:\(currentActorID):\(identifier)")
        }
        if let callID = message.rtcCallRecord?.callID {
            keys.insert("rtc_call:\(callID)")
        }
        return keys
    }

    private func upsertMessage(
        _ message: CachedMessage,
        conversationKey: String,
        channelKey: String,
        currentActorID: String,
        now: TimeInterval,
        db: Database,
        assumeNewIdentity: Bool = false
    ) throws -> MessageUpsertOutcome {
        let messageID = message.channelSeq > 0 ? message.id.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let declaredSenderUID = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderUID = message.isOutgoing
            ? currentActorID
            : (declaredSenderUID.isEmpty ? "unknown" : declaredSenderUID)
        let isPendingLocal = message.channelSeq <= 0
            && message.isOutgoing
            && !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let clientMessageID = isPendingLocal ? message.id.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if let callRecord = message.rtcCallRecord {
            guard !messageID.isEmpty, message.channelSeq > 0 else {
                try recordConflict(
                    messageID: messageID,
                    channelKey: channelKey,
                    channelSeq: message.channelSeq,
                    clientMessageID: clientMessageID,
                    reason: "rtc_call_record_missing_authority_identity",
                    now: now,
                    db: db
                )
                return .conflict
            }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT conversation_key, message_id, channel_seq FROM rtc_call_record WHERE call_id = ?",
                arguments: [callRecord.callID]
            ) {
                let existingConversationKey: String = existing["conversation_key"]
                let existingMessageID: String? = existing["message_id"]
                let existingChannelSeq: Int64? = existing["channel_seq"]
                guard existingConversationKey == conversationKey,
                      existingMessageID == messageID,
                      existingChannelSeq == message.channelSeq else {
                    try recordConflict(
                        messageID: messageID,
                        channelKey: channelKey,
                        channelSeq: message.channelSeq,
                        clientMessageID: clientMessageID,
                        reason: "rtc_call_record_identity_collision",
                        now: now,
                        db: db
                    )
                    return .conflict
                }
            }
        }

        let identityRows = assumeNewIdentity ? [] : try Row.fetchAll(
            db,
            sql: """
            SELECT local_row_id, payload, lifecycle_rank, content_type
            FROM message
            WHERE (? <> '' AND message_id = ?)
               OR (? > 0 AND channel_key = ? AND channel_seq = ?)
               OR (? <> '' AND sender_uid = ? AND client_msg_no = ?)
            """,
            arguments: [
                messageID,
                messageID,
                message.channelSeq,
                channelKey,
                message.channelSeq,
                clientMessageID,
                senderUID,
                clientMessageID
            ]
        )
        let candidateIDs = Set(identityRows.map { row -> String in row["local_row_id"] })
        guard candidateIDs.count <= 1 else {
            try recordConflict(
                messageID: messageID,
                channelKey: channelKey,
                channelSeq: message.channelSeq,
                clientMessageID: clientMessageID,
                reason: "authority_identity_collision",
                now: now,
                db: db
            )
            return .conflict
        }
        let incomingEditRevision = message.editRevision ?? 0
        if let existing = identityRows.first {
            let previousPayload: Data = existing["payload"]
            let previousContentType: String = existing["content_type"]
            let previousMessage = try? decoder.decode(CachedMessage.self, from: previousPayload)
            let previousEditRevision = previousMessage?.editRevision ?? 0
            if previousEditRevision > 0 && incomingEditRevision <= previousEditRevision {
                return .duplicate
            }
            let previousRecord = previousMessage?.rtcCallRecord
            let nextRecord = message.rtcCallRecord
            let nextContentType = message.contentType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let involvesRTC = previousContentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
                || nextContentType == "rtc_call_record"
                || previousRecord != nil
                || nextRecord != nil
            guard !involvesRTC || (
                previousRecord != nil
                    && previousRecord == nextRecord
                    && previousMessage?.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
                        == message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
                    && previousMessage?.isOutgoing == message.isOutgoing
                    && previousMessage?.contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == message.contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) else {
                try recordConflict(
                    messageID: messageID,
                    channelKey: channelKey,
                    channelSeq: message.channelSeq,
                    clientMessageID: clientMessageID,
                    reason: "rtc_call_record_terminal_payload_collision",
                    now: now,
                    db: db
                )
                return .conflict
            }
        }

        let existingRowID = candidateIDs.first
        let rowID = existingRowID
            ?? (!messageID.isEmpty ? "message:\(messageID)" : "client:\(senderUID):\(clientMessageID)")
        let lifecycleRank = self.lifecycleRank(message)
        let isTombstone = lifecycleRank >= 30
        let body = isTombstone ? "" : message.text
        let payload = try encoder.encode(message)
        let normalizedContentType = message.contentType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let persistedContentType = normalizedContentType.isEmpty ? message.kind : normalizedContentType
        if let existing = identityRows.first {
            let existingRank: Int = existing["lifecycle_rank"]
            if existingRank > lifecycleRank { return .duplicate }
            let previousPayload: Data = existing["payload"]
            if previousPayload == payload, existingRank == lifecycleRank {
                if let callRecord = message.rtcCallRecord {
                    try upsertRTCCallRecord(
                        callRecord,
                        message: message,
                        conversationKey: conversationKey,
                        messageID: messageID,
                        db: db
                    )
                }
                return .duplicate
            }
            try db.execute(
                sql: """
                UPDATE message SET
                    conversation_key = ?, channel_key = ?,
                    message_id = CASE WHEN ? = '' THEN message_id ELSE ? END,
                    channel_seq = CASE WHEN ? > 0 THEN ? ELSE channel_seq END,
                    sender_uid = ?,
                    client_msg_no = CASE WHEN ? = '' THEN client_msg_no ELSE ? END,
                    content_type = ?, body = ?, payload = ?,
                    server_version = MAX(server_version, ?),
                    lifecycle_rank = MAX(lifecycle_rank, ?),
                    local_send_state = ?, is_tombstone = ?,
                    created_at = COALESCE(?, created_at), updated_at = ?
                WHERE local_row_id = ?
                """,
                arguments: [
                    conversationKey,
                    channelKey,
                    messageID,
                    messageID,
                    message.channelSeq,
                    message.channelSeq,
                    senderUID,
                    clientMessageID,
                    clientMessageID,
                    persistedContentType,
                    body,
                    payload,
                    incomingEditRevision,
                    lifecycleRank,
                    message.status,
                    isTombstone,
                    message.createdAt,
                    now,
                    rowID
                ]
            )
            if let callRecord = message.rtcCallRecord {
                try upsertRTCCallRecord(
                    callRecord,
                    message: message,
                    conversationKey: conversationKey,
                    messageID: messageID,
                    db: db
                )
            }
            return .updated
        }

        try db.execute(
            sql: """
            INSERT INTO message (
                local_row_id, conversation_key, channel_key, message_id, channel_seq,
                sender_uid, client_msg_no, content_type, body, payload,
                server_version, lifecycle_rank, local_send_state, is_tombstone, created_at, updated_at
            ) VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, 0), ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                rowID,
                conversationKey,
                channelKey,
                messageID,
                message.channelSeq,
                senderUID,
                clientMessageID,
                persistedContentType,
                body,
                payload,
                incomingEditRevision,
                lifecycleRank,
                message.status,
                isTombstone,
                message.createdAt,
                now
            ]
        )
        if let callRecord = message.rtcCallRecord {
            try upsertRTCCallRecord(
                callRecord,
                message: message,
                conversationKey: conversationKey,
                messageID: messageID,
                db: db
            )
        }
        return .inserted
    }

    private func upsertRTCCallRecord(
        _ record: RTCCallRecordPayload,
        message: CachedMessage,
        conversationKey: String,
        messageID: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO rtc_call_record (
                call_id, conversation_key, peer_uid, direction, media_type, status,
                started_at, answered_at, ended_at, duration_seconds, reason,
                state_version, message_id, channel_seq
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(call_id) DO NOTHING
            """,
            arguments: [
                record.callID,
                conversationKey,
                record.peerUID(viewerIsCaller: message.isOutgoing),
                message.isOutgoing ? "outgoing" : "incoming",
                record.callType.rawValue,
                record.finalOutcome.rawValue,
                record.startedAt.timeIntervalSince1970,
                record.answeredAt?.timeIntervalSince1970,
                record.endedAt.timeIntervalSince1970,
                Double(record.durationSeconds),
                record.reasonCode,
                messageID,
                message.channelSeq
            ]
        )
    }

    private func rebuildChannelStateAndGaps(
        _ snapshot: LocalMessageConversationSnapshot,
        preserveContiguousBecauseOfConflict: Bool,
        now: TimeInterval,
        db: Database,
        metrics: inout LocalMessageMergeMetrics
    ) throws {
        let conversation = snapshot.metadata.model
        let floor = max(1, conversation.historyVisibleFromSeq)
        if floor > 1 {
            try db.execute(
                sql: "DELETE FROM message WHERE channel_key = ? AND channel_seq > 0 AND channel_seq < ?",
                arguments: [snapshot.channelID, floor]
            )
            try db.execute(
                sql: "DELETE FROM rtc_call_record WHERE conversation_key = ? AND message_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM message WHERE message.message_id = rtc_call_record.message_id)",
                arguments: [snapshot.metadata.id]
            )
        }
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT contiguous_seq, max_observed_seq, history_visible_from_seq FROM channel_state WHERE channel_key = ?",
            arguments: [snapshot.channelID]
        )
        let existingContiguous: Int64 = existing?["contiguous_seq"] ?? Int64(floor - 1)
        let existingMax: Int64 = existing?["max_observed_seq"] ?? 0
        let requestedContiguous = snapshot.requiresServerRevalidation
            ? Int64(floor - 1)
            : max(Int64(floor - 1), conversation.messageCoveredThroughSeq)
        let contiguous = preserveContiguousBecauseOfConflict
            ? min(existingContiguous, requestedContiguous)
            : requestedContiguous
        let maxObserved = max(
            existingMax,
            conversation.lastMsgSeq,
            snapshot.messages.map(\.channelSeq).max() ?? 0
        )
        let sequences = try Int64.fetchAll(
            db,
            sql: "SELECT channel_seq FROM message WHERE channel_key = ? AND channel_seq > ? ORDER BY channel_seq",
            arguments: [snapshot.channelID, contiguous]
        )
        let oldest = try Int64.fetchOne(
            db,
            sql: "SELECT MIN(channel_seq) FROM message WHERE channel_key = ? AND channel_seq > 0",
            arguments: [snapshot.channelID]
        ) ?? 0
        let newest = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(channel_seq) FROM message WHERE channel_key = ? AND channel_seq > 0",
            arguments: [snapshot.channelID]
        ) ?? 0
        try db.execute(sql: "DELETE FROM gap_range WHERE channel_key = ?", arguments: [snapshot.channelID])
        if snapshot.requiresServerRevalidation, maxObserved >= Int64(floor) {
            try insertGap(
                channelKey: snapshot.channelID,
                start: Int64(floor),
                end: maxObserved,
                db: db
            )
            metrics.gapCount += 1
        } else {
            var cursor = max(contiguous + 1, Int64(floor))
            for sequence in sequences where sequence <= maxObserved {
                if sequence > cursor {
                    try insertGap(channelKey: snapshot.channelID, start: cursor, end: sequence - 1, db: db)
                    metrics.gapCount += 1
                }
                cursor = max(cursor, sequence + 1)
            }
            if maxObserved >= cursor {
                try insertGap(channelKey: snapshot.channelID, start: cursor, end: maxObserved, db: db)
                metrics.gapCount += 1
            }
        }
        try db.execute(
            sql: """
            INSERT INTO channel_state (
                channel_key, contiguous_seq, max_observed_seq, oldest_local_seq,
                newest_local_seq, history_visible_from_seq, history_has_more, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(channel_key) DO UPDATE SET
                contiguous_seq = excluded.contiguous_seq,
                max_observed_seq = MAX(channel_state.max_observed_seq, excluded.max_observed_seq),
                oldest_local_seq = excluded.oldest_local_seq,
                newest_local_seq = excluded.newest_local_seq,
                history_visible_from_seq = MAX(channel_state.history_visible_from_seq, excluded.history_visible_from_seq),
                history_has_more = excluded.history_has_more,
                updated_at = excluded.updated_at
            """,
            arguments: [
                snapshot.channelID,
                contiguous,
                maxObserved,
                oldest,
                newest,
                floor,
                !conversation.historyBoundaryConfirmed,
                now
            ]
        )
        try db.execute(
            sql: """
            UPDATE ack_cursor
            SET desired_seq = MIN(desired_seq, ?),
                inflight_seq = MIN(inflight_seq, ?),
                confirmed_seq = MIN(confirmed_seq, ?),
                updated_at = ?
            WHERE channel_key = ?
            """,
            arguments: [contiguous, contiguous, contiguous, now, snapshot.channelID]
        )
        let readDesired = min(max(0, conversation.lastReadSeq), contiguous)
        if readDesired > 0 {
            try upsertAck(
                channelKey: snapshot.channelID,
                type: "read",
                desired: readDesired,
                confirmed: readDesired,
                now: now,
                db: db
            )
        }
        let deliveryDesired = min(
            snapshot.messages
                .filter { !$0.isOutgoing && $0.channelSeq > 0 }
                .map(\.channelSeq)
                .max() ?? 0,
            contiguous
        )
        if deliveryDesired > 0 {
            try upsertAck(
                channelKey: snapshot.channelID,
                type: "delivery",
                desired: deliveryDesired,
                confirmed: 0,
                now: now,
                db: db
            )
        }
    }

    private func insertGap(channelKey: String, start: Int64, end: Int64, db: Database) throws {
        guard start > 0, end >= start else { return }
        try db.execute(
            sql: "INSERT INTO gap_range (channel_key, start_seq, end_seq) VALUES (?, ?, ?)",
            arguments: [channelKey, start, end]
        )
    }

    private func upsertAck(
        channelKey: String,
        type: String,
        desired: Int64,
        confirmed: Int64,
        now: TimeInterval,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO ack_cursor (channel_key, ack_type, desired_seq, confirmed_seq, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(channel_key, ack_type) DO UPDATE SET
                desired_seq = MAX(ack_cursor.desired_seq, excluded.desired_seq),
                confirmed_seq = MAX(ack_cursor.confirmed_seq, excluded.confirmed_seq),
                updated_at = excluded.updated_at
            """,
            arguments: [channelKey, type, desired, confirmed, now]
        )
    }

    private func recordConflict(
        messageID: String,
        channelKey: String,
        channelSeq: Int64,
        clientMessageID: String,
        reason: String,
        now: TimeInterval,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO message_conflict (
                conflict_id, channel_key, message_id, channel_seq, client_msg_no, reason, created_at
            ) VALUES (?, ?, NULLIF(?, ''), NULLIF(?, 0), NULLIF(?, ''), ?, ?)
            """,
            arguments: [UUID().uuidString.lowercased(), channelKey, messageID, channelSeq, clientMessageID, reason, now]
        )
    }

    private func lifecycleRank(_ message: CachedMessage) -> Int {
        let event = (message.systemEventType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if event.contains("admin_delete") || event.contains("admin_deleted") { return 50 }
        if event == "delete" || event == "deleted" { return 40 }
        if message.status == MessageDelivery.recalled.rawValue { return 30 }
        if message.isEdited { return 20 }
        return 10
    }
}
