// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

struct AppMessagePersistenceModelCodec: MessagePersistenceModelCodec {
    func conversation(from record: CachedConversation) -> ConversationMessageSnapshot { record.model }
    func message(from record: CachedMessage) -> ChatMessage { record.model }
    func sanitizedForDurableOutbox(_ record: CachedMessage) -> CachedMessage { record.sanitizedForDurableOutbox() }
    func peerUID(from record: RTCCallRecordPayload, viewerIsCaller: Bool) -> String { record.peerUID(viewerIsCaller: viewerIsCaller) }
}

extension SQLiteMessageRepository {
    static func open(scope: LocalMessageScope, paths: MessageDatabasePaths) async throws -> SQLiteMessageRepository {
        try await open(scope: scope, paths: paths, codec: AppMessagePersistenceModelCodec())
    }
}

extension LocalMessageScope {
    init(context: IMAPIContext) throws {
        try self.init(
            accountID: context.accountID ?? "",
            tenantID: context.tenantID ?? "",
            appID: IMAPIContext.normalizedIOSAppID(context.appID),
            actorID: context.imUID ?? "",
            deviceID: context.deviceID
        )
    }
}

extension SnapshotCache {
    convenience init(
        schemaVersion: Int = SnapshotCache.defaultSchemaVersion,
        maxAge: TimeInterval = SnapshotCache.defaultMaxAge,
        directoryURL: URL? = nil
    ) {
        self.init(schemaVersion: schemaVersion, maxAge: maxAge, directoryURL: directoryURL, codec: AppMessagePersistenceModelCodec())
    }
}

extension PersistedBlacklistItem {
    init(_ item: BlacklistItem) {
        self.init(id: item.id, name: item.name, reason: item.reason)
    }
    var model: BlacklistItem { BlacklistItem(id: id, name: name, reason: reason) }
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END
