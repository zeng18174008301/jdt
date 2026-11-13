// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import GRDB
import IM4Domain

extension SQLiteMessageRepository {
    public func loadInitialConversations(limit: Int = 50, messagesPerConversation: Int = 50) throws -> ([CachedConversation], LocalMessageLoadMetrics) {
        let started = CFAbsoluteTimeGetCurrent()
        let boundedLimit = min(max(limit, 1), 1_200)
        let boundedMessageLimit = min(max(messagesPerConversation, 1), 200)
        let conversations = try databasePool.read { db -> [CachedConversation] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT conversation_key, payload, last_msg_seq, last_read_seq
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
                var model = codec.conversation(from: metadata)
                let storedLastMsgSeq: Int64 = row["last_msg_seq"]
                let storedLastReadSeq: Int64 = row["last_read_seq"]
                model.lastMsgSeq = max(model.lastMsgSeq, storedLastMsgSeq)
                model.lastReadSeq = max(model.lastReadSeq, storedLastReadSeq)
                model.messages = Array(messages).map { codec.message(from: $0) }
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

    public func loadProfileContactProjection() throws -> LocalProfileContactProjection? {
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

    public func persistProfileContactProjection(_ projection: LocalProfileContactProjection) throws {
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

    public func loadOlderMessages(channelKey: String, beforeSeq: Int64, limit: Int = 50) throws -> [CachedMessage] {
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

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    public func loadSearchDateMessages(
        conversationID: String, days: [DateInterval], minimumSequence: Int64,
        excludedIDs: Set<String>, excludedSequences: Set<Int64>
    ) throws -> [ChatMessage] {
        try databasePool.read { db in
            var matches: [ChatMessage] = []
            for day in days.prefix(31) {
                try Task.checkCancellation()
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT payload
                    FROM message
                    WHERE conversation_key = ? AND created_at >= ? AND created_at < ?
                      AND channel_seq >= ? AND is_tombstone = 0
                    ORDER BY created_at ASC, local_row_id ASC
                    """, arguments: [conversationID, day.start.timeIntervalSince1970,
                        day.end.timeIntervalSince1970, max(1, minimumSequence)])
                while let row = try rows.next() {
                    try Task.checkCancellation()
                    let payload: Data = row["payload"]
                    guard let record = try? decoder.decode(CachedMessage.self, from: payload) else { continue }
                    let message = codec.message(from: record)
                    guard let date = message.createdAt, date >= day.start, date < day.end,
                          message.isHistorySearchDateContent,
                          !excludedIDs.contains(message.id), !excludedSequences.contains(message.channelSeq) else { continue }
                    matches.append(message)
                    break
                }
            }
            return matches
        }
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    public func search(_ query: String, limit: Int = 50) throws -> [LocalMessageSearchResult] {
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

    public func projectionRevisionFloor() throws -> Int64 {
        try databasePool.read { db in
            try assertWriter(db)
            return try Int64.fetchOne(db, sql: "SELECT projection_revision FROM scope_meta WHERE id = 1") ?? 0
        }
    }

    public func persistProjection(
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

    public func importLegacy(
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

    public func deleteConversation(conversationID: String) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(sql: "DELETE FROM rtc_call_record WHERE conversation_key = ?", arguments: [conversationID])
            try db.execute(sql: "DELETE FROM conversation WHERE conversation_key = ?", arguments: [conversationID])
        }
    }

    static func createdAtFromFallback(_ value: String) -> String {
        guard let range = value.range(of: ";created_at=") else { return "" }
        return String(value[range.upperBound...])
    }

    @discardableResult
    func persistConversation(
        _ snapshot: LocalMessageConversationSnapshot,
        source: LocalMessageProjectionSource,
        now: TimeInterval,
        db: Database,
        fastIdentityState: inout MessageIdentityAccumulator?,
        metrics: inout LocalMessageMergeMetrics
    ) throws -> Int {
        let conversation = codec.conversation(from: snapshot.metadata)
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
                ? codec.sanitizedForDurableOutbox(rawMessage)
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

    struct MessageIdentityAccumulator {
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
        if isPendingLocal, try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM outbox WHERE client_msg_no = ? AND state = 'cancelled')",
            arguments: [clientMessageID]
        ) == true {
            return .duplicate
        }
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
        let lifecycleRank = self.lifecycleRank(message)
        if let existing = identityRows.first {
            let previousPayload: Data = existing["payload"]
            let previousContentType: String = existing["content_type"]
            let previousMessage = try? decoder.decode(CachedMessage.self, from: previousPayload)
            let previousEditRevision = previousMessage?.editRevision ?? 0
            let existingRank: Int = existing["lifecycle_rank"]
            let advancesTombstone = lifecycleRank >= 30 && lifecycleRank > existingRank
            if !advancesTombstone && previousEditRevision > 0 && incomingEditRevision <= previousEditRevision {
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
                codec.peerUID(from: record, viewerIsCaller: message.isOutgoing),
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
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
