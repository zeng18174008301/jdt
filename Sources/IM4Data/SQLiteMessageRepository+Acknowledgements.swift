// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import GRDB
import IM4Domain

extension SQLiteMessageRepository {
    public func recordAckDesired(
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

    public func recoverableAcks(
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

    public func ackStates(type: String) throws -> [LocalMessagePendingAck] {
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

    public func claimAcksForRetry(
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

    public func releaseAckForRetry(channelKey: String, type: String) throws {
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

    public func abandonAckClaimWithoutConsumingAttempt(
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

    public func confirmAck(channelKey: String, type: String, confirmedSeq: Int64) throws {
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

    func rebuildChannelStateAndGaps(
        _ snapshot: LocalMessageConversationSnapshot,
        preserveContiguousBecauseOfConflict: Bool,
        now: TimeInterval,
        db: Database,
        metrics: inout LocalMessageMergeMetrics
    ) throws {
        let conversation = codec.conversation(from: snapshot.metadata)
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
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
