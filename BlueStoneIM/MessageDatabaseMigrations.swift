import Foundation
import GRDB

enum MessageDatabaseMigrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("local-message-v1") { db in
            try db.execute(sql: MessageDatabaseSchema.createVersionOneSQL)
        }
        migrator.registerMigration("local-message-v2-profile-contact") { db in
            try db.execute(sql: MessageDatabaseSchema.createProfileContactProjectionSQL)
        }
        migrator.registerMigration("local-message-v3-media-cache") { db in
            try db.execute(sql: MessageDatabaseSchema.createMediaCacheVersionThreeSQL)
        }
        migrator.registerMigration("local-message-v4-media-authority") { db in
            if try db.tableExists("cache_reference"),
               try !db.columns(in: "cache_reference").contains(where: { $0.name == "attachment_id" }) {
                try db.execute(
                    sql: "ALTER TABLE cache_reference ADD COLUMN attachment_id TEXT NOT NULL DEFAULT ''"
                )
                try db.execute(
                    sql: """
                    UPDATE cache_reference
                    SET attachment_id = COALESCE((
                        SELECT attachment_meta.attachment_id
                        FROM attachment_meta
                        JOIN cache_entry
                          ON cache_entry.scope_hash = cache_reference.scope_hash
                         AND cache_entry.cache_identity = cache_reference.cache_identity
                        WHERE attachment_meta.scope_hash = cache_reference.scope_hash
                          AND attachment_meta.message_id = cache_reference.message_id
                          AND attachment_meta.variant = cache_entry.variant
                        ORDER BY attachment_meta.updated_at DESC
                        LIMIT 1
                    ), '')
                    """
                )
            }
            try db.execute(sql: MessageDatabaseSchema.createMediaCacheVersionFourSQL)
        }
        return migrator
    }
}
