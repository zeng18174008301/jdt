import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

enum LegacySnapshotImporter {
    static func snapshots(
        from conversations: [ConversationMessageSnapshot],
        channelResolver: (ConversationMessageSnapshot) -> (id: String, type: String),
        currentActorID: String
    ) -> [LocalMessageConversationSnapshot] {
        conversations.map { conversation in
            var seed = conversation
            seed.messageCoveredThroughSeq = 0
            seed.historyBoundaryConfirmed = false
            let channel = channelResolver(seed)
            return LocalMessageConversationSnapshot(
                conversation: seed,
                channelID: channel.id,
                channelType: channel.type,
                currentActorID: currentActorID,
                requiresServerRevalidation: true
            )
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
