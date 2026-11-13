// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import GRDB

public actor SQLiteMessageRepository {
    let codec: any MessagePersistenceModelCodec
    let scope: LocalMessageScope
    let paths: MessageDatabasePaths

    let databasePool: DatabasePool
    let writerOwner: String
    private let writerFence: Int64
    let openedAtMilliseconds: Int
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public static func open(scope: LocalMessageScope, paths: MessageDatabasePaths, codec: any MessagePersistenceModelCodec) async throws -> SQLiteMessageRepository {
        try await Task.detached(priority: .userInitiated) {
            try SQLiteMessageRepository(scope: scope, paths: paths, codec: codec)
        }.value
    }

    private init(scope: LocalMessageScope, paths: MessageDatabasePaths, codec: any MessagePersistenceModelCodec) throws {
        let started = CFAbsoluteTimeGetCurrent()
        self.codec = codec
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
                  AND outbox.state IN ('staging_attachment', 'ready', 'sending', 'awaiting_ack', 'uncertain', 'retry_wait', 'confirmation_required')
                  AND attachment_transfer.phase <> 'committed'
                -- WDT_IOS1_HTTP_ROUTE_V5_20261113
                """,
                arguments: [scope.scopeHash]
            ))
        }
        try AttachmentTransferRepository.reconcile(
            activeRelativePaths: activeStagingPaths,
            paths: paths
        )
    }

    public func diagnostics() throws -> LocalMessageDatabaseDiagnostics {
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

    func assertWriter(_ db: Database) throws {
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

}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
