import Foundation

enum LegacySnapshotImporter {
    static func snapshots(
        from conversations: [Conversation],
        channelResolver: (Conversation) -> (id: String, type: String),
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
}
