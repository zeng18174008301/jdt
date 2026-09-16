import Foundation

enum MessageDatabaseSchema {
    static let currentVersion = 4
    static let databaseFileName = "messages.sqlite"

    static let createVersionOneSQL = """
    CREATE TABLE IF NOT EXISTS scope_meta (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        schema_version INTEGER NOT NULL,
        scope_hash TEXT NOT NULL,
        canonical_scope_digest TEXT NOT NULL,
        rebuild_generation INTEGER NOT NULL DEFAULT 0,
        legacy_import_state TEXT NOT NULL DEFAULT 'pending',
        projection_revision INTEGER NOT NULL DEFAULT 0,
        writer_owner TEXT NOT NULL DEFAULT '',
        writer_fence INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        last_open_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS conversation (
        conversation_key TEXT PRIMARY KEY,
        channel_type TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        server_revision INTEGER NOT NULL DEFAULT 0,
        payload BLOB NOT NULL,
        last_message_id TEXT,
        last_msg_seq INTEGER NOT NULL DEFAULT 0,
        sort_at REAL NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        last_read_seq INTEGER NOT NULL DEFAULT 0,
        last_delivered_seq INTEGER NOT NULL DEFAULT 0,
        unread_count INTEGER NOT NULL DEFAULT 0,
        history_visible_from_seq INTEGER NOT NULL DEFAULT 1,
        history_limited INTEGER NOT NULL DEFAULT 0,
        history_boundary_confirmed INTEGER NOT NULL DEFAULT 0,
        requires_server_revalidation INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL,
        UNIQUE(channel_type, channel_id)
    );

    CREATE INDEX IF NOT EXISTS conversation_timeline
    ON conversation(pinned DESC, sort_at DESC, conversation_key);

    CREATE TABLE IF NOT EXISTS message (
        local_row_id TEXT PRIMARY KEY,
        conversation_key TEXT NOT NULL REFERENCES conversation(conversation_key) ON DELETE CASCADE,
        channel_key TEXT NOT NULL,
        message_id TEXT,
        channel_seq INTEGER,
        sender_uid TEXT NOT NULL,
        client_msg_no TEXT,
        content_type TEXT NOT NULL,
        body TEXT NOT NULL DEFAULT '',
        payload BLOB NOT NULL,
        server_version INTEGER NOT NULL DEFAULT 0,
        lifecycle_rank INTEGER NOT NULL DEFAULT 0,
        local_send_state TEXT NOT NULL DEFAULT '',
        is_tombstone INTEGER NOT NULL DEFAULT 0,
        created_at REAL,
        updated_at REAL NOT NULL
    );

    CREATE UNIQUE INDEX IF NOT EXISTS message_authority_id_unique
    ON message(message_id) WHERE message_id IS NOT NULL AND message_id <> '';
    CREATE UNIQUE INDEX IF NOT EXISTS message_channel_seq_unique
    ON message(channel_key, channel_seq) WHERE channel_seq IS NOT NULL AND channel_seq > 0;
    CREATE UNIQUE INDEX IF NOT EXISTS message_sender_client_unique
    ON message(sender_uid, client_msg_no) WHERE client_msg_no IS NOT NULL AND client_msg_no <> '';
    CREATE INDEX IF NOT EXISTS message_channel_page
    ON message(channel_key, channel_seq DESC, created_at DESC, local_row_id DESC);
    CREATE INDEX IF NOT EXISTS message_conversation_created
    ON message(conversation_key, created_at DESC, local_row_id DESC);

    CREATE TABLE IF NOT EXISTS message_extra (
        message_id TEXT NOT NULL,
        extra_type TEXT NOT NULL,
        version INTEGER NOT NULL,
        payload BLOB NOT NULL,
        created_at REAL,
        PRIMARY KEY(message_id, extra_type, version)
    );

    CREATE TABLE IF NOT EXISTS message_receipt (
        message_id TEXT NOT NULL,
        receipt_type TEXT NOT NULL,
        im_uid TEXT NOT NULL,
        device_id TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        created_at REAL,
        PRIMARY KEY(message_id, receipt_type, im_uid, device_id)
    );

    CREATE TABLE IF NOT EXISTS message_reaction (
        message_id TEXT NOT NULL,
        reaction_key TEXT NOT NULL,
        actor_uid TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        PRIMARY KEY(message_id, reaction_key, actor_uid)
    );

    CREATE TABLE IF NOT EXISTS channel_state (
        channel_key TEXT PRIMARY KEY,
        contiguous_seq INTEGER NOT NULL DEFAULT 0,
        max_observed_seq INTEGER NOT NULL DEFAULT 0,
        oldest_local_seq INTEGER NOT NULL DEFAULT 0,
        newest_local_seq INTEGER NOT NULL DEFAULT 0,
        conversation_cursor INTEGER NOT NULL DEFAULT 0,
        extras_cursor INTEGER NOT NULL DEFAULT 0,
        realtime_cursor INTEGER NOT NULL DEFAULT 0,
        history_visible_from_seq INTEGER NOT NULL DEFAULT 1,
        history_has_more INTEGER NOT NULL DEFAULT 1,
        history_generation INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gap_range (
        channel_key TEXT NOT NULL,
        start_seq INTEGER NOT NULL,
        end_seq INTEGER NOT NULL,
        state TEXT NOT NULL DEFAULT 'open',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        retry_at REAL,
        PRIMARY KEY(channel_key, start_seq, end_seq),
        CHECK(start_seq > 0 AND end_seq >= start_seq)
    );

    CREATE TABLE IF NOT EXISTS ack_cursor (
        channel_key TEXT NOT NULL,
        ack_type TEXT NOT NULL,
        desired_seq INTEGER NOT NULL DEFAULT 0,
        inflight_seq INTEGER NOT NULL DEFAULT 0,
        confirmed_seq INTEGER NOT NULL DEFAULT 0,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        retry_at REAL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(channel_key, ack_type)
    );

    CREATE TABLE IF NOT EXISTS outbox (
        client_msg_no TEXT PRIMARY KEY,
        operation_kind TEXT NOT NULL,
        conversation_key TEXT NOT NULL,
        channel_key TEXT NOT NULL,
        channel_type TEXT NOT NULL,
        scope_hash TEXT NOT NULL,
        payload BLOB NOT NULL,
        state TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at REAL,
        lease_owner TEXT NOT NULL DEFAULT '',
        lease_fence INTEGER NOT NULL DEFAULT 0,
        uncertain INTEGER NOT NULL DEFAULT 0,
        authoritative_message_id TEXT,
        authoritative_channel_seq INTEGER,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS outbox_ready
    ON outbox(state, next_attempt_at, created_at);

    CREATE TABLE IF NOT EXISTS attachment_transfer (
        transfer_id TEXT PRIMARY KEY,
        client_msg_no TEXT NOT NULL UNIQUE REFERENCES outbox(client_msg_no) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        file_id TEXT NOT NULL DEFAULT '',
        phase TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        background_task_id INTEGER,
        expires_at REAL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS media_cache (
        cache_key TEXT PRIMARY KEY,
        channel_key TEXT NOT NULL,
        message_id TEXT NOT NULL,
        file_id TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        last_access_at REAL NOT NULL,
        rebuildable INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS rtc_call_record (
        call_id TEXT PRIMARY KEY,
        conversation_key TEXT NOT NULL,
        peer_uid TEXT NOT NULL,
        direction TEXT NOT NULL,
        media_type TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at REAL,
        answered_at REAL,
        ended_at REAL,
        duration_seconds REAL,
        reason TEXT NOT NULL DEFAULT '',
        state_version INTEGER NOT NULL DEFAULT 0,
        message_id TEXT,
        channel_seq INTEGER
    );
    CREATE INDEX IF NOT EXISTS rtc_call_record_ended
    ON rtc_call_record(ended_at DESC, call_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
        local_row_id UNINDEXED,
        conversation_key UNINDEXED,
        body,
        tokenize = 'unicode61'
    );

    CREATE TRIGGER IF NOT EXISTS message_search_insert AFTER INSERT ON message
    WHEN NEW.is_tombstone = 0 AND NEW.body <> ''
    BEGIN
        INSERT INTO message_search(local_row_id, conversation_key, body)
        VALUES (NEW.local_row_id, NEW.conversation_key, NEW.body);
    END;

    CREATE TRIGGER IF NOT EXISTS message_search_update AFTER UPDATE ON message
    BEGIN
        DELETE FROM message_search WHERE local_row_id = OLD.local_row_id;
        INSERT INTO message_search(local_row_id, conversation_key, body)
        SELECT NEW.local_row_id, NEW.conversation_key, NEW.body
        WHERE NEW.is_tombstone = 0 AND NEW.body <> '';
    END;

    CREATE TRIGGER IF NOT EXISTS message_search_delete AFTER DELETE ON message
    BEGIN
        DELETE FROM message_search WHERE local_row_id = OLD.local_row_id;
    END;

    CREATE TABLE IF NOT EXISTS cleanup_stats (
        segment_key TEXT PRIMARY KEY,
        bytes INTEGER NOT NULL DEFAULT 0,
        last_access_at REAL NOT NULL,
        protection_reason TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE IF NOT EXISTS message_conflict (
        conflict_id TEXT PRIMARY KEY,
        channel_key TEXT NOT NULL,
        message_id TEXT,
        channel_seq INTEGER,
        client_msg_no TEXT,
        reason TEXT NOT NULL,
        created_at REAL NOT NULL
    );
    """

    static let createProfileContactProjectionSQL = """
    CREATE TABLE IF NOT EXISTS profile_contact_projection (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        revision INTEGER NOT NULL,
        payload BLOB NOT NULL,
        updated_at REAL NOT NULL
    );
    """

    static let createMediaCacheVersionThreeSQL = """
    DROP TABLE IF EXISTS media_cache;

    CREATE TABLE IF NOT EXISTS attachment_meta (
        scope_hash TEXT NOT NULL,
        message_id TEXT NOT NULL,
        attachment_id TEXT NOT NULL,
        resource_id_kind TEXT NOT NULL,
        resource_id TEXT NOT NULL,
        content_version_kind TEXT NOT NULL,
        content_version TEXT NOT NULL,
        variant TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        checksum_sha256 TEXT,
        authority_state TEXT NOT NULL,
        authority_version TEXT NOT NULL,
        last_authorized_at REAL,
        offline_access_until REAL,
        created_at REAL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(scope_hash, message_id, attachment_id, variant),
        CHECK(authority_state IN ('active', 'processing', 'authorization_stale', 'recalled', 'deleted', 'forbidden', 'expired_business')),
        CHECK(resource_id_kind IN ('file_id', 'attachment_id', 'media_id', 'cache_key')),
        CHECK(content_version_kind IN ('checksum_sha256', 'version', 'size_created_at')),
        CHECK(variant IN ('thumbnail:320', 'thumbnail:640', 'preview:1600', 'original', 'video_poster'))
    );
    CREATE INDEX IF NOT EXISTS attachment_meta_authority
    ON attachment_meta(scope_hash, authority_state, offline_access_until);
    CREATE INDEX IF NOT EXISTS attachment_meta_resource
    ON attachment_meta(scope_hash, resource_id_kind, resource_id, content_version, variant);

    CREATE TABLE IF NOT EXISTS cache_entry (
        scope_hash TEXT NOT NULL,
        cache_identity TEXT PRIMARY KEY,
        attachment_id TEXT NOT NULL,
        variant TEXT NOT NULL,
        relative_path TEXT NOT NULL UNIQUE,
        local_state TEXT NOT NULL,
        size_bytes INTEGER NOT NULL DEFAULT 0,
        verified_size_bytes INTEGER,
        verified_checksum_sha256 TEXT,
        pinned_by_user INTEGER NOT NULL DEFAULT 0,
        protection_reason TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        last_accessed_at REAL NOT NULL,
        CHECK(local_state IN ('none', 'partial', 'verified_cached', 'evicted', 'corrupt')),
        CHECK(variant IN ('thumbnail:320', 'thumbnail:640', 'preview:1600', 'original', 'video_poster'))
    );
    CREATE INDEX IF NOT EXISTS cache_entry_scope_lru
    ON cache_entry(scope_hash, pinned_by_user, protection_reason, last_accessed_at);
    CREATE INDEX IF NOT EXISTS cache_entry_attachment_variant
    ON cache_entry(scope_hash, attachment_id, variant);

    CREATE TABLE IF NOT EXISTS cache_reference (
        scope_hash TEXT NOT NULL,
        message_id TEXT NOT NULL,
        attachment_id TEXT NOT NULL,
        conversation_key TEXT NOT NULL,
        cache_identity TEXT NOT NULL REFERENCES cache_entry(cache_identity) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        PRIMARY KEY(scope_hash, message_id, cache_identity)
    );
    CREATE INDEX IF NOT EXISTS cache_reference_conversation
    ON cache_reference(scope_hash, conversation_key);

    CREATE TABLE IF NOT EXISTS media_authority_tombstone (
        scope_hash TEXT NOT NULL,
        message_id TEXT NOT NULL,
        authority_state TEXT NOT NULL,
        authority_version TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(scope_hash, message_id),
        CHECK(authority_state IN ('authorization_stale', 'recalled', 'deleted', 'forbidden', 'expired_business'))
    );

    CREATE TABLE IF NOT EXISTS media_transfer_task (
        task_id TEXT PRIMARY KEY,
        scope_hash TEXT NOT NULL,
        scope_generation INTEGER NOT NULL,
        cache_identity TEXT NOT NULL,
        direction TEXT NOT NULL,
        transfer_state TEXT NOT NULL,
        signature_refresh_count INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        bytes_transferred INTEGER NOT NULL DEFAULT 0,
        error_code TEXT,
        updated_at REAL NOT NULL,
        CHECK(direction IN ('upload', 'download')),
        CHECK(signature_refresh_count BETWEEN 0 AND 1)
    );
    CREATE INDEX IF NOT EXISTS media_transfer_scope_identity
    ON media_transfer_task(scope_hash, cache_identity);
    """

    static let createMediaCacheVersionFourSQL = """
    CREATE TABLE IF NOT EXISTS media_authority_tombstone (
        scope_hash TEXT NOT NULL,
        message_id TEXT NOT NULL,
        authority_state TEXT NOT NULL,
        authority_version TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(scope_hash, message_id),
        CHECK(authority_state IN ('authorization_stale', 'recalled', 'deleted', 'forbidden', 'expired_business'))
    );

    CREATE TRIGGER IF NOT EXISTS media_transfer_task_state_insert
    BEFORE INSERT ON media_transfer_task
    WHEN NEW.transfer_state NOT IN (
        'idle', 'staged', 'queued', 'presigning', 'resolving_url', 'uploading',
        'confirming', 'awaiting_message_ack', 'downloading', 'signature_expired',
        'refreshing_url', 'verifying', 'committing', 'succeeded',
        'failed_retryable', 'failed_permanent', 'cancelled'
    )
    BEGIN
        SELECT RAISE(ABORT, 'invalid media transfer state');
    END;

    CREATE TRIGGER IF NOT EXISTS media_transfer_task_state_update
    BEFORE UPDATE OF transfer_state ON media_transfer_task
    WHEN NEW.transfer_state NOT IN (
        'idle', 'staged', 'queued', 'presigning', 'resolving_url', 'uploading',
        'confirming', 'awaiting_message_ack', 'downloading', 'signature_expired',
        'refreshing_url', 'verifying', 'committing', 'succeeded',
        'failed_retryable', 'failed_permanent', 'cancelled'
    )
    BEGIN
        SELECT RAISE(ABORT, 'invalid media transfer state');
    END;
    """
}
