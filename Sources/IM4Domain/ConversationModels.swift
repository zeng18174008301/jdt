// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话模型允许安全跨后台投影任务传递
public struct Conversation: Identifiable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        id: String,
        title: String,
        subtitle: String,
        kind: ConversationKind,
        lastMessage: String,
        time: String,
        unread: Int,
        isPinned: Bool,
        isMuted: Bool,
        memberCount: Int? = nil,
        accentHex: UInt,
        participants: [IMUser],
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = "",
        hasUnreadReaction: Bool = false,
        unreadReactionCount: Int = 0,
        lastMsgSeq: Int64 = 0,
        messageCoveredThroughSeq: Int64 = 0,
        messageCoverageRequiresRecovery: Bool = false,
        lastReadSeq: Int64 = 0,
        firstUnreadSeq: Int64 = 0,
        firstUnreadMessageID: String = "",
        unreadAnchorSeq: Int64 = 0,
        unreadAnchorState: String = "",
        hasMention: Bool = false,
        mentionCount: Int = 0,
        mentionSummaryText: String = "",
        mentionSummaryMessageID: String = "",
        mentionSummaryChannelSeq: Int64 = 0,
        sortTimestamp: TimeInterval = 0,
        historyVisibleFromSeq: Int64 = 1,
        historyLimited: Bool = false,
        historyBoundaryConfirmed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.lastMessage = lastMessage
        self.time = time
        self.unread = unread
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.memberCount = memberCount
        self.accentHex = accentHex
        self.participants = participants
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.hasUnreadReaction = hasUnreadReaction
        self.unreadReactionCount = unreadReactionCount
        self.lastMsgSeq = lastMsgSeq
        self.messageCoveredThroughSeq = messageCoveredThroughSeq
        self.messageCoverageRequiresRecovery = messageCoverageRequiresRecovery
        self.lastReadSeq = lastReadSeq
        self.firstUnreadSeq = firstUnreadSeq
        self.firstUnreadMessageID = firstUnreadMessageID
        self.unreadAnchorSeq = unreadAnchorSeq
        self.unreadAnchorState = unreadAnchorState
        self.hasMention = hasMention
        self.mentionCount = mentionCount
        self.mentionSummaryText = mentionSummaryText
        self.mentionSummaryMessageID = mentionSummaryMessageID
        self.mentionSummaryChannelSeq = mentionSummaryChannelSeq
        self.sortTimestamp = sortTimestamp
        self.historyVisibleFromSeq = historyVisibleFromSeq
        self.historyLimited = historyLimited
        self.historyBoundaryConfirmed = historyBoundaryConfirmed
    }
    public let id: String
    public var title: String
    public var subtitle: String
    public let kind: ConversationKind
    public var lastMessage: String
    public var time: String
    public var unread: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var memberCount: Int?
    public let accentHex: UInt
    public var participants: [IMUser]
    // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
    // Message windows are owned by ScopedMessageMemoryStore.
    // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
    public var avatarURL: String = ""
    public var avatarVersion: String = ""
    public var avatarUpdatedAt: String = ""
    public var hasUnreadReaction: Bool = false
    public var unreadReactionCount: Int = 0
    public var lastMsgSeq: Int64 = 0
    public var messageCoveredThroughSeq: Int64 = 0
    public var messageCoverageRequiresRecovery: Bool = false
    public var lastReadSeq: Int64 = 0
    public var firstUnreadSeq: Int64 = 0
    public var firstUnreadMessageID: String = ""
    public var unreadAnchorSeq: Int64 = 0
    public var unreadAnchorState: String = ""
    public var hasMention: Bool = false
    public var mentionCount: Int = 0
    public var mentionSummaryText: String = ""
    public var mentionSummaryMessageID: String = ""
    public var mentionSummaryChannelSeq: Int64 = 0
    public var sortTimestamp: TimeInterval = 0
    public var historyVisibleFromSeq: Int64 = 1
    public var historyLimited: Bool = false
    public var historyBoundaryConfirmed: Bool = false
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

public func conversationListSupportsMutableActions(_ conversation: Conversation) -> Bool {
    conversation.kind != .system
}

// WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
extension Conversation {
    public var withoutMessages: Conversation {
        self // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110: metadata is already message-free.
    }
}
// WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END

public enum DirectConversationCallPeerResolver {
    public struct ContactLookup {
        private let contacts: [IMUser]
        private let identities: [Set<String>]
        private let indicesByIdentity: [String: Set<Int>]

        public init(contacts: [IMUser]) {
            self.contacts = contacts
            identities = contacts.map { DirectConversationCallPeerResolver.identityIdentifiers(for: $0) }
            var indices: [String: Set<Int>] = [:]
            for (index, identifiers) in identities.enumerated() {
                for identifier in identifiers {
                    indices[identifier, default: []].insert(index)
                }
            }
            indicesByIdentity = indices
        }

        // Match the original contacts.first(where:) ordering across all supplied aliases.
        public func firstContact(matchingAny identifiers: [String]) -> IMUser? {
            let index = identifiers.compactMap { indicesByIdentity[$0]?.min() }.min()
            return index.map { contacts[$0] }
        }

        fileprivate func firstContact(matching identifier: String) -> IMUser? {
            guard let index = indicesByIdentity[identifier]?.min() else { return nil }
            return contacts[index]
        }

        fileprivate func uniqueContact(matching identifiers: Set<String>, excluding currentIDs: Set<String>) -> IMUser? {
            var matchingIndices: Set<Int> = []
            for identifier in identifiers {
                matchingIndices.formUnion(indicesByIdentity[identifier] ?? [])
            }
            let eligible = matchingIndices.filter { identities[$0].isDisjoint(with: currentIDs) }
            guard eligible.count == 1, let index = eligible.first else { return nil }
            return contacts[index]
        }
    }

    public static let unavailableMessage = "目标信息同步中，请稍后再试"

    public static func resolve(
        conversation: Conversation,
        currentIdentityIDs: Set<String>,
        contacts: [IMUser],
        contactLookup: ContactLookup? = nil
    ) -> IMUser? {
        guard conversation.kind == .direct else { return nil }
        let normalizedCurrentIDs = Set(currentIdentityIDs.compactMap(normalizedIdentifier))

        if !conversation.participants.isEmpty {
            let peers = conversation.participants.filter { participant in
                identityIdentifiers(for: participant).isDisjoint(with: normalizedCurrentIDs)
            }
            guard peers.count == 1 else { return nil }
            return refreshedContactSnapshot(for: peers[0], contacts: contacts, currentIdentityIDs: normalizedCurrentIDs, contactLookup: contactLookup)
                ?? peers[0]
        }

        let channelPeerIDs = Set(
            conversation.id
                .split { character in
                    character == ":" || character == "|" || character == ","
                }
                .compactMap { normalizedIdentifier(String($0)) }
                .filter { !normalizedCurrentIDs.contains($0) }
        )
        guard channelPeerIDs.count == 1 else { return nil }

        if let contactLookup {
            return contactLookup.uniqueContact(matching: channelPeerIDs, excluding: normalizedCurrentIDs)
        }
        let matchingContacts = contacts.filter { contact in
            !identityIdentifiers(for: contact).isDisjoint(with: channelPeerIDs)
                && identityIdentifiers(for: contact).isDisjoint(with: normalizedCurrentIDs)
        }
        guard matchingContacts.count == 1 else { return nil }
        return matchingContacts[0]
    }

    private static func refreshedContactSnapshot(
        for participant: IMUser,
        contacts: [IMUser],
        currentIdentityIDs: Set<String>,
        contactLookup: ContactLookup?
    ) -> IMUser? {
        let participantIDs = identityIdentifiers(for: participant)
        guard !participantIDs.isEmpty else { return nil }
        if let contactLookup {
            return contactLookup.uniqueContact(matching: participantIDs, excluding: currentIdentityIDs)
        }
        let matchingContacts = contacts.filter { contact in
            !identityIdentifiers(for: contact).isDisjoint(with: participantIDs)
                && identityIdentifiers(for: contact).isDisjoint(with: currentIdentityIDs)
        }
        return matchingContacts.count == 1 ? matchingContacts[0] : nil
    }

    private static func identityIdentifiers(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username].compactMap(normalizedIdentifier))
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
public enum DirectConversationProfilePeerResolver {
    public static let unavailableMessage = "联系人资料同步中，请稍后再试"

    public static func resolve(
        conversation: ConversationMessageSnapshot,
        currentIdentityIDs: Set<String>,
        contacts: [IMUser],
        fallbackEnterprise: String,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil
    ) -> IMUser? {
        guard conversation.kind == .direct else { return nil }
        if let resolved = DirectConversationCallPeerResolver.resolve(
            conversation: conversation.conversation,
            currentIdentityIDs: currentIdentityIDs,
            contacts: contacts,
            contactLookup: contactLookup
        ) {
            return resolved
        }

        let normalizedCurrentIDs = Set(currentIdentityIDs.compactMap(normalizedIdentifier))
        let incoming = conversation.messages.reversed().first { message in
            guard !message.isOutgoing,
                  let senderID = normalizedIdentifier(message.senderId) else {
                return false
            }
            return !normalizedCurrentIDs.contains(senderID)
        }
        guard let incoming,
              let senderID = normalizedIdentifier(incoming.senderId) else {
            return nil
        }

        let contact: IMUser?
        if let contactLookup {
            contact = contactLookup.firstContact(matching: senderID)
        } else {
            contact = contacts.first { contact in
                !identityIdentifiers(for: contact).isDisjoint(with: [senderID])
            }
        }
        if let contact { return contact }

        let senderName = incoming.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = !senderName.isEmpty
            ? senderName
            : (!conversationTitle.isEmpty ? conversationTitle : senderID)
        return IMUser(
            id: senderID,
            userID: senderID,
            name: displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "",
            enterprise: fallbackEnterprise,
            avatarSeed: incoming.senderAvatarSeed,
            avatarURL: incoming.senderAvatarURL,
            avatarVersion: incoming.senderAvatarVersion,
            avatarUpdatedAt: incoming.senderAvatarUpdatedAt,
            badges: []
        )
    }

    private static func identityIdentifiers(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username].compactMap(normalizedIdentifier))
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct ConversationUnreadState: Equatable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        unreadCount: Int,
        hasUnreadReaction: Bool,
        unreadReactionCount: Int,
        hasUnreadMessages: Bool
    ) {
        self.unreadCount = unreadCount
        self.hasUnreadReaction = hasUnreadReaction
        self.unreadReactionCount = unreadReactionCount
        self.hasUnreadMessages = hasUnreadMessages
    }
    public let unreadCount: Int
    public let hasUnreadReaction: Bool
    public let unreadReactionCount: Int
    public let hasUnreadMessages: Bool
}

public func boundedConversationMessageUnreadCount(_ count: Int, lastMsgSeq: Int64, lastReadSeq: Int64) -> Int {
    let count = max(0, count)
    guard lastMsgSeq > 0, lastReadSeq > 0 else { return count }
    return min(count, Int(clamping: max(0, lastMsgSeq - lastReadSeq)))
}

// WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN
public enum ConversationUnreadBadgeProjection {
    public static func contribution(_ conversation: Conversation, excludingConversationID: String? = nil) -> Int {
        guard !conversation.isMuted, conversation.id != excludingConversationID else { return 0 }
        return max(0, conversation.unread)
    }

    // Keep the authoritative full calculation for whole-list rebuilds and DEBUG verification.
    public static func total(
        _ conversations: [Conversation],
        excludingConversationID: String? = nil
    ) -> Int {
        conversations.reduce(into: 0) { total, conversation in
            total += contribution(conversation, excludingConversationID: excludingConversationID)
        }
    }
}
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END


public func resolvedConversationUnreadState(
    remoteUnreadCount: Int,
    remoteUnreadReactionCount: Int,
    remoteHasReactionUnread: Bool,
    locallyReadThrough: Bool
) -> ConversationUnreadState {
    let remoteUnread = max(0, remoteUnreadCount)
    let explicitReactionCount = max(0, remoteUnreadReactionCount)
    let hasReactionUnread = remoteHasReactionUnread || explicitReactionCount > 0
    let reactionCount = hasReactionUnread ? max(explicitReactionCount, 1) : 0
    let unreadCount = locallyReadThrough
        ? reactionCount
        : max(remoteUnread, reactionCount)
    let hasUnreadMessages = !locallyReadThrough && remoteUnread > reactionCount

    return ConversationUnreadState(
        unreadCount: unreadCount,
        hasUnreadReaction: hasReactionUnread,
        unreadReactionCount: reactionCount,
        hasUnreadMessages: hasUnreadMessages
    )
}

// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
