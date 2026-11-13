// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import GRDB

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
private enum OutboxSendEvidence: Int {
    case unrecorded = 0
    case unconfirmed = 1
    // Legacy zero also covered ambiguous failures.
    case knownUnsent = 2
    case legacyClaimUnconfirmed = 3
    case legacyClaimUnsent = 4
    case v5ClaimUnsent = 5

    var claimUsesV5: Bool? {
        switch self {
        case .legacyClaimUnconfirmed, .legacyClaimUnsent: return false
        case .v5ClaimUnsent: return true
        default: return nil
        }
    }

    var provesUnsent: Bool { self == .knownUnsent || self == .legacyClaimUnsent || self == .v5ClaimUnsent }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

extension SQLiteMessageRepository {
    public func enqueueOutgoing(
        _ intent: LocalMessageOutgoingIntent,
        revision: Int64
    ) throws -> LocalMessageMergeMetrics {
        let clientMessageID = intent.message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientMessageID.isEmpty else { throw LocalMessageDatabaseError.identityConflict }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if try outgoingAuthority(clientMessageID: clientMessageID)?.state == LocalMessageOutboxState.confirmationRequired.rawValue {
            throw LocalMessageDatabaseError.identityConflict
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
                let existing = try String.fetchOne(db, sql: "SELECT state FROM outbox WHERE client_msg_no = ?", arguments: [clientMessageID])
                if ["cancelled", LocalMessageOutboxState.confirmationRequired.rawValue].contains(existing ?? "") {
                    throw LocalMessageDatabaseError.identityConflict
                } // WDT_IOS1_HTTP_ROUTE_V5_20261113
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
                let payload = try encoder.encode(codec.sanitizedForDurableOutbox(intent.message))
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

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    private static let unconfirmedReplaySQL = """
        (uncertain = \(OutboxSendEvidence.legacyClaimUnconfirmed.rawValue) OR
         (state IN ('sending', 'awaiting_ack', 'uncertain', 'retry_wait')
          AND uncertain NOT IN (\(OutboxSendEvidence.knownUnsent.rawValue),
                                \(OutboxSendEvidence.legacyClaimUnsent.rawValue), \(OutboxSendEvidence.v5ClaimUnsent.rawValue))
          AND (state IN ('awaiting_ack', 'uncertain') OR uncertain = \(OutboxSendEvidence.unconfirmed.rawValue)
               OR NOT (attempt_count <= 1 AND EXISTS (
                    SELECT 1 FROM attachment_transfer WHERE attachment_transfer.client_msg_no = outbox.client_msg_no
                      AND attachment_transfer.phase IN ('staged', 'config', 'presign', 'video_presigned',
                          'uploaded', 'video_accelerated_uploaded', 'finalized')
               )))))
        """

    public func prepareOutgoingSend(clientMessageID: String, selectedV5: Bool,
                                    protect: Bool) throws -> LocalMessageSendAdmission {
        try databasePool.write { db in
            try assertWriter(db)
            let row = try Row.fetchOne(db, sql: """
                SELECT state, uncertain FROM outbox WHERE scope_hash = ? AND client_msg_no = ?
                """, arguments: [scope.scopeHash, clientMessageID])
            guard let row else { throw LocalMessageDatabaseError.identityConflict }
            let state: String = row["state"]
            if state == LocalMessageOutboxState.confirmationRequired.rawValue { return .confirmationRequired }
            guard ["sending", "awaiting_ack"].contains(state) else { throw LocalMessageDatabaseError.identityConflict }
            let evidence = OutboxSendEvidence(rawValue: row["uncertain"]) ?? .unrecorded
            if evidence.claimUsesV5.map({ $0 != selectedV5 }) == true
                || (protect && evidence == .legacyClaimUnconfirmed) {
                try deferOutgoingSend(db, id: clientMessageID, knownUnsent: evidence.provesUnsent)
                return evidence.provesUnsent ? .deferred : .confirmationRequired
            }
            if protect {
                try reserveOutgoingSend(db, id: clientMessageID)
            } else if evidence.claimUsesV5 != nil || evidence.provesUnsent {
                let consumed: OutboxSendEvidence = evidence == .legacyClaimUnconfirmed ? .unconfirmed : .unrecorded
                try db.execute(sql: "UPDATE outbox SET uncertain = ? WHERE scope_hash = ? AND client_msg_no = ?",
                               arguments: [consumed.rawValue, scope.scopeHash, clientMessageID])
            }
            return .send(knownUnsent: evidence.provesUnsent || protect)
        }
    }

    public func deferKnownUnsentOutgoingSend(clientMessageID: String) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try deferOutgoingSend(db, id: clientMessageID, knownUnsent: true)
        }
    }

    private func deferOutgoingSend(_ db: Database, id: String, knownUnsent: Bool) throws {
        try db.execute(sql: """
            UPDATE outbox SET state = ?, uncertain = ?, next_attempt_at = NULL,
                lease_owner = '', lease_fence = 0, updated_at = ?
            WHERE scope_hash = ? AND client_msg_no = ?
              AND state IN ('sending', 'awaiting_ack')
            """, arguments: [
                knownUnsent ? "retry_wait" : "confirmation_required",
                knownUnsent ? OutboxSendEvidence.knownUnsent.rawValue : OutboxSendEvidence.unconfirmed.rawValue,
                Date().timeIntervalSince1970, scope.scopeHash, id
            ])
    }

    /// The reservation must commit before the transport may send the write.
    public func reserveOutgoingSend(clientMessageID: String) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try reserveOutgoingSend(db, id: clientMessageID)
        }
    }

    private func reserveOutgoingSend(_ db: Database, id: String) throws {
        try db.execute(sql: """
            UPDATE outbox SET state = 'confirmation_required', uncertain = 1, next_attempt_at = NULL,
                lease_owner = '', lease_fence = 0, updated_at = ?
            WHERE scope_hash = ? AND client_msg_no = ? AND state IN ('sending', 'awaiting_ack')
            """, arguments: [Date().timeIntervalSince1970, scope.scopeHash, id])
        guard db.changesCount == 1 else { throw LocalMessageDatabaseError.identityConflict }
    }

    public func releaseUnsentOutgoing(clientMessageID: String) throws {
        try databasePool.write { db in
            try assertWriter(db)
            try db.execute(sql: """
                UPDATE outbox SET state = 'sending', uncertain = ?, updated_at = ?
                WHERE scope_hash = ? AND client_msg_no = ? AND state = 'confirmation_required'
                """, arguments: [OutboxSendEvidence.knownUnsent.rawValue, Date().timeIntervalSince1970, scope.scopeHash, clientMessageID])
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    public func updateOutboxState(
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
        let didUpdate = try databasePool.write { db in
            try assertWriter(db)
            let current = try Row.fetchOne(
                db,
                sql: "SELECT state, attempt_count, uncertain FROM outbox WHERE client_msg_no = ? AND state NOT IN ('acked', 'cancelled')",
                arguments: [clientMessageID]
            )
            guard let current else { return false }
            let currentState: String = current["state"]
            guard currentState != LocalMessageOutboxState.confirmationRequired.rawValue else { return false } // WDT_IOS1_HTTP_ROUTE_V5_20261113
            let attemptCount: Int = current["attempt_count"]
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            let previousEvidence = OutboxSendEvidence(rawValue: current["uncertain"]) ?? .unrecorded
            let evidence: OutboxSendEvidence
            if uncertain {
                evidence = .unconfirmed
            } else if previousEvidence.claimUsesV5 != nil, state == .sending || state == .awaitingAcknowledgement {
                evidence = previousEvidence
            } else if state == .retryWait, previousEvidence.provesUnsent {
                evidence = .knownUnsent
            } else {
                evidence = .unrecorded
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
            case .stagingAttachment, .ready, .confirmationRequired, .failedPermanent, .acknowledged, .cancelled:
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
                    evidence.rawValue,
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
            return true
        }
        if didUpdate, state == .acknowledged || state == .cancelled || state == .failedPermanent {
            try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: clientMessageID))
        }
    }

    public func discardFailedOutgoing(
        clientMessageID: String,
        conversationID: String,
        channelID: String,
        channelType: String
    ) throws -> Bool {
        let now = Date().timeIntervalSince1970
        let discarded = try databasePool.write { db in
            try assertWriter(db)
            // Keep the cancellation as a fence against old snapshots and retries.
            try db.execute(
                sql: """
                INSERT INTO outbox (
                    client_msg_no, operation_kind, conversation_key, channel_key, channel_type,
                    scope_hash, payload, state, created_at, updated_at
                ) VALUES (?, 'discard', ?, ?, ?, ?, ?, 'cancelled', ?, ?)
                ON CONFLICT(client_msg_no) DO UPDATE SET
                    state = 'cancelled', payload = excluded.payload, next_attempt_at = NULL,
                    lease_owner = '', lease_fence = 0, updated_at = excluded.updated_at
                WHERE outbox.scope_hash = excluded.scope_hash
                  AND outbox.conversation_key = excluded.conversation_key
                  AND outbox.state NOT IN ('sending', 'awaiting_ack', 'confirmation_required', 'acked')
                """,
                arguments: [clientMessageID, conversationID, channelID, channelType, scope.scopeHash, Data("{}".utf8), now, now]
            )
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "DELETE FROM attachment_transfer WHERE client_msg_no = ?", arguments: [clientMessageID])
            try db.execute(
                sql: "DELETE FROM message WHERE conversation_key = ? AND client_msg_no = ? AND COALESCE(channel_seq, 0) = 0",
                arguments: [conversationID, clientMessageID]
            )
            return true
        }
        if discarded {
            try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: clientMessageID))
        }
        return discarded
    }

    public func confirmOutgoing(
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
    public func acknowledgeOutgoingAuthority(
        clientMessageID: String,
        authoritativeMessageID: String,
        authoritativeChannelSeq: Int64,
        channelKey: String,
        confirmation: LocalMessageHistoryConfirmation? = nil // WDT_IOS1_HTTP_ROUTE_V5_20261113
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
        func acknowledge(_ db: Database) throws -> Bool {
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
        func cleanUp(_ acknowledged: Bool) {
            if acknowledged {
                try? FileManager.default.removeItem(at: paths.stagedAttachmentURL(clientMessageID: normalizedClientMessageID))
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if let confirmation {
            return try databasePool.writeWithoutTransaction { db in
                try confirmation.withCurrent {}
                // Wait for SQLite's writer reservation before acquiring the authority locks.
                try db.beginTransaction(.immediate)
                do {
                    return try confirmation.withCurrent {
                        let acknowledged = try acknowledge(db)
                        try db.commit()
                        cleanUp(acknowledged)
                        return acknowledged
                    }
                } catch {
                    try db.rollback()
                    throw error
                }
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        let acknowledged = try databasePool.write(acknowledge)
        cleanUp(acknowledged)
        return acknowledged
    }

    public func outgoingAuthority(clientMessageID: String) throws -> LocalMessageOutgoingAuthority? {
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

    public func pendingOutbox(
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
                WHERE outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait', 'confirmation_required')
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

    public func recoverableOutbox(
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
                WHERE outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait', 'confirmation_required')
                  AND outbox.scope_hash = ?
                ORDER BY outbox.created_at, outbox.client_msg_no
                """,
                arguments: [scope.scopeHash]
            )
            return rows.compactMap { recoveredOutbox(from: $0, replayPolicy: replayPolicy) }
        }
    }

    public func claimOutboxForReplay(
        authorizationGeneration: UInt64,
        trigger: LocalMessageOutboxReplayTrigger,
        clientMessageID: String?,
        now: Date = Date(),
        limit: Int = 20,
        replayPolicy: LocalMessageOutboxReplayPolicy = .standard,
        holdLegacyUnconfirmedSends: Bool = false
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
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            // Classify before either claim while holding the same scope writer.
            // A first attachment attempt is known unsent only while a durable
            // checkpoint proves that it has yet to enter message submission.
            if holdLegacyUnconfirmedSends {
                try db.execute(sql: """
                    UPDATE outbox
                    SET state = 'confirmation_required', uncertain = ?, next_attempt_at = NULL,
                        lease_owner = '', lease_fence = 0, updated_at = ?
                    WHERE scope_hash = ?
                      AND state IN ('sending', 'awaiting_ack', 'uncertain', 'retry_wait')
                      AND NOT (state = 'sending' AND lease_owner = ? AND lease_fence = ?
                               AND COALESCE(next_attempt_at, 0) > ?)
                      AND (\(Self.unconfirmedReplaySQL))
                    """, arguments: [
                        OutboxSendEvidence.unconfirmed.rawValue, nowValue, scope.scopeHash,
                        writerOwner, authorizationFence, nowValue
                    ])
            }
            // confirmation_required is excluded from both claims across feature defaults.
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
                      AND (NOT ? OR NOT (state = 'sending' AND lease_owner = ? AND lease_fence = ?
                                         AND COALESCE(next_attempt_at, 0) > ?))
                    LIMIT 1
                    """,
                    arguments: [scope.scopeHash, normalizedClientMessageID, holdLegacyUnconfirmedSends,
                                writerOwner, authorizationFence, nowValue]
                )
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
            guard !ids.isEmpty else { return [] }
            for id in ids {
                let row = try Row.fetchOne(db, sql: """
                    SELECT attempt_count, (\(Self.unconfirmedReplaySQL)) AS unconfirmed
                    FROM outbox WHERE client_msg_no = ? AND scope_hash = ?
                    """, arguments: [id, scope.scopeHash])
                guard let row else { throw LocalMessageDatabaseError.identityConflict }
                let attemptCount: Int = row["attempt_count"]
                let unconfirmed: Bool = row["unconfirmed"]
                let claim: OutboxSendEvidence = holdLegacyUnconfirmedSends ? .v5ClaimUnsent
                    : (unconfirmed ? .legacyClaimUnconfirmed : .legacyClaimUnsent)
                let nextAttemptCount = attemptCount + 1
                let nextAttemptAt = nowValue + replayPolicy.retryDelay(afterAttempt: nextAttemptCount)
                try db.execute(
                    sql: """
                    UPDATE outbox
                    SET state = 'sending', attempt_count = ?, next_attempt_at = ?,
                        uncertain = ?,
                        lease_owner = ?, lease_fence = ?, updated_at = ?
                    WHERE client_msg_no = ? AND scope_hash = ? AND state <> 'acked'
                    """,
                    arguments: [
                        nextAttemptCount,
                        nextAttemptAt,
                        claim.rawValue,
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

    public func stagedVideoUploadSource(clientMessageID: String, expectedSizeBytes: Int64) throws -> StagedVideoUploadSource {
        let row = try databasePool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT relative_path, size_bytes, checksum FROM attachment_transfer WHERE client_msg_no = ?",
                arguments: [clientMessageID]
            )
        }
        guard let row,
              let relativePath: String = row["relative_path"],
              let size: Int64 = row["size_bytes"], size == expectedSizeBytes,
              let storedChecksum: String = row["checksum"] else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        let checksum = MessageAttachmentChecksum.normalizedSHA256(storedChecksum)
        let url = try paths.resolveScopeRelativePath(relativePath)
        guard !checksum.isEmpty, url.standardizedFileURL == paths.stagedAttachmentURL(clientMessageID: clientMessageID).standardizedFileURL,
              try PendingAttachmentFileStore.regularFileSize(at: url) == expectedSizeBytes else {
            throw LocalMessageDatabaseError.missingStagedAttachment
        }
        return StagedVideoUploadSource(url: url, checksum: checksum)
    }

    public func loadStagedAttachment(for item: LocalMessageRecoveredOutbox) throws -> Data? {
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

    public func stagedAttachmentFileURL(for item: LocalMessageRecoveredOutbox) throws -> URL? {
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
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
