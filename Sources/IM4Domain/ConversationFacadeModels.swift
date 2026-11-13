import Foundation

public func textRemovingGroupMemberTotals(_ raw: String) -> String {
    raw.replacingOccurrences(
        of: #"(?:(?:群(?:成员)?(?:总数|人数)?|共|当前|现有)\s*[：:]?\s*)?\d+\s*(?:名|位|个)?\s*(?:群成员|成员|人)"#,
        with: "群成员",
        options: .regularExpression
    ).replacingOccurrences(
        of: #"(?i)(?:(?:total|current)\s*)?\d+\s*(?:group\s*)?members?"#,
        with: "group members",
        options: .regularExpression
    )
}

private extension MessageReplyContext {
    func scrubbingGroupMemberTotals() -> MessageReplyContext {
        var scrubbed = self
        scrubbed.summary = textRemovingGroupMemberTotals(scrubbed.summary)
        return scrubbed
    }
}

public extension ConversationMessageSnapshot {
    func scrubbingGroupMemberTotals() -> ConversationMessageSnapshot {
        guard self.kind == .group else { return self }
        var scrubbed = self
        scrubbed.memberCount = nil
        scrubbed.subtitle = textRemovingGroupMemberTotals(scrubbed.subtitle)
        scrubbed.lastMessage = textRemovingGroupMemberTotals(scrubbed.lastMessage)
        scrubbed.mentionSummaryText = textRemovingGroupMemberTotals(scrubbed.mentionSummaryText)
        scrubbed.messages = scrubbed.messages.map { message in
            var scrubbedMessage = message
            scrubbedMessage.readCount = nil
            scrubbedMessage.unreadCount = nil
            scrubbedMessage.quote = scrubbedMessage.quote.map(textRemovingGroupMemberTotals)
            scrubbedMessage.replyContext = scrubbedMessage.replyContext?.scrubbingGroupMemberTotals()
            if scrubbedMessage.kind == .system {
                scrubbedMessage.text = textRemovingGroupMemberTotals(scrubbedMessage.text)
            }
            return scrubbedMessage
        }
        return scrubbed
    }
}


public struct ConversationUserLookup: Sendable {
// JHT_MOD_END APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改结束
    private var users: [String: IMUser] = [:]

    public init(currentUser: IMUser, currentIdentifiers: Set<String>, contacts: [IMUser], groupMembers: [IMUser]) {
        for identifier in currentIdentifiers where !identifier.isEmpty {
            users[identifier] = currentUser
        }
        for user in contacts + groupMembers {
            for value in [user.id, user.userID, user.username] {
                let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !identifier.isEmpty, users[identifier] == nil {
                    users[identifier] = user
                }
            }
        }
    }

    public func user(for identifier: String) -> IMUser? {
        users[identifier.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

public enum ConversationChannelIdentityMapper: Sendable {
    public static func user(_ user: IMUser, matchesIdentifier identifier: String) -> Bool {
        let normalizedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .contains(normalizedID)
    }

    public static func currentIdentitySet(
        currentUser: IMUser,
        apiIMUID: String?,
        accountID: String?
    ) -> Set<String> {
        Set([
            currentUser.id,
            currentUser.userID,
            currentUser.username,
            apiIMUID ?? "",
            accountID ?? ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    public static func remoteChannelID(
        for conversation: ConversationMessageSnapshot,
        currentUser: IMUser,
        apiIMUID: String?,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        switch conversation.kind {
        case .direct:
            let currentID = (apiIMUID?.isEmpty == false ? apiIMUID : currentUser.id) ?? currentUser.id
            let currentIDs = Set([currentID, currentUser.id, apiIMUID ?? ""].filter { !$0.isEmpty })
            let existingParts = directChannelParts(conversation.id)
            if existingParts.count >= 2,
               existingParts.contains(where: { currentIDs.contains($0) }),
               existingParts.contains(where: { !currentIDs.contains($0) }) {
                return normalizedRemoteChannelID(
                    conversation.id,
                    channelType: "direct",
                    currentID: currentID,
                    currentIDs: currentIDs,
                    lookup: lookup,
                    fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
                )
            }
            let peer = conversation.participants
                .map(\.id)
                .first { !$0.isEmpty && !currentIDs.contains($0) }
                ?? existingParts.first { !$0.isEmpty && !currentIDs.contains($0) }
                ?? (!conversation.id.isEmpty && !currentIDs.contains(conversation.id) ? conversation.id : "")
            let canonicalPeer = canonicalDirectParticipantID(
                peer,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
            guard !currentID.isEmpty, !peer.isEmpty, currentID != peer else {
                return conversation.id
            }
            return [currentID, canonicalPeer].sorted().joined(separator: ":")
        case .group:
            // Group titles are mutable and multiple channels can share a title.
            return conversation.id
        case .system:
            return "system_notification"
        }
    }

    public static func normalizedRemoteChannelID(
        _ channelID: String,
        channelType: String,
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let trimmedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversationKind(from: channelType, channelID: trimmedID) == .system {
            return "system_notification"
        }
        if conversationKind(from: channelType, channelID: trimmedID) == .direct {
            return canonicalDirectChannelID(
                trimmedID,
                currentID: currentID,
                currentIDs: currentIDs,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
        }
        return trimmedID
    }

    public static func directChannelParts(_ channelID: String) -> [String] {
        channelID
            .split { char in char == ":" || char == "|" || char == "," }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func apiChannelType(for kind: ConversationKind) -> String {
        switch kind {
        case .direct: return "direct"
        case .group: return "group"
        case .system: return "system"
        }
    }

    public static func conversationKind(from channelType: String, channelID: String = "") -> ConversationKind {
        let normalizedType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedType == "group" { return .group }
        if normalizedType == "system" || normalizedType == "system_notification" || normalizedType == "system_message" {
            return .system
        }
        if normalizedID == "system_notification"
            || normalizedID == "system_message"
            || normalizedID.hasPrefix("system_")
            || normalizedID.contains(":system_") {
            return .system
        }
        return .direct
    }

    private static func canonicalDirectChannelID(
        _ channelID: String,
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let trimmedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return "" }
        let parts = directChannelParts(trimmedID)
        if parts.count >= 2 {
            if let peer = parts.first(where: { !currentIDs.contains($0) }),
               !currentID.isEmpty {
                let canonicalPeer = canonicalDirectParticipantID(
                    peer,
                    lookup: lookup,
                    fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
                )
                return [currentID, canonicalPeer].filter { !$0.isEmpty }.sorted().joined(separator: ":")
            }
            return Array(Set(parts)).sorted().joined(separator: ":")
        }
        if let only = parts.first,
           !currentID.isEmpty,
           !currentIDs.contains(only) {
            let canonicalPeer = canonicalDirectParticipantID(
                only,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
            return [currentID, canonicalPeer].filter { !$0.isEmpty }.sorted().joined(separator: ":")
        }
        return trimmedID
    }

    private static func canonicalDirectParticipantID(
        _ rawID: String,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        guard let user = lookup?.user(for: normalized) else {
            return fallbackCanonicalParticipantID?(normalized) ?? normalized
        }
        if !user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.id
        }
        if !user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.userID
        }
        return normalized
    }
}

public struct DirectFriendRequestContext: Equatable, Sendable {
// JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DIRECT_FRIEND_CONTEXT_EQUATABLE - 修改结束
    public let targetUID: String
    public let canApplyFriend: Bool?
    public let friendRequestStatus: String
    public let reasonCode: String
    public let friendAction: String
    public let friendFlow: String

    public init(
        targetUID: String,
        canApplyFriend: Bool?,
        friendRequestStatus: String,
        reasonCode: String,
        friendAction: String = "",
        friendFlow: String = ""
    ) {
        self.targetUID = targetUID
        self.canApplyFriend = canApplyFriend
        self.friendRequestStatus = friendRequestStatus
        self.reasonCode = reasonCode
        self.friendAction = friendAction
        self.friendFlow = friendFlow
    }

    public var normalizedStatus: String {
        friendRequestStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalizedReason: String {
        reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isPending: Bool {
        ["pending", "pending_out", "applied", "waiting", "reviewing"].contains(normalizedStatus)
    }

    public var blocksApply: Bool {
        let blockedFragments = [
            "blocked",
            "disabled",
            "blacklist",
            "account_locked",
            "account_disabled",
            "account_cancelled",
            "account_canceled",
            "target_user_unavailable",
            "target_user_disabled",
            "target_user_cancelled",
            "target_user_canceled",
            "target_type_not_allowed",
            "friend_target_not_allowed",
            "system_user",
            "bot_user",
            "service_user",
            "test_user"
        ]
        return blockedFragments.contains { normalizedStatus.contains($0) || normalizedReason.contains($0) }
    }

    public var allowsApply: Bool {
        guard !targetUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isPending,
              !blocksApply else {
            return false
        }
        let action = friendAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if action == "none" { return false }
        if action == "request" || action == "direct_add" { return true }
        return canApplyFriend ?? true
    }

    public var disabledMessage: String {
        if isPending {
            return FriendAddPresentation.sentMessage
        }
        if normalizedStatus.contains("cancel") || normalizedReason.contains("cancel") {
            return "该用户已注销，无法互动"
        }
        if blocksApply {
            return "当前关系状态暂不可申请好友"
        }
        return "需先添加好友后才能发起私聊"
    }

    public var actionTitle: String {
        FriendAddPresentation.actionTitle
    }
}

public enum ConversationDirectPeerIdentity {
    public static func directPeerUID(
        conversationID: String,
        remoteChannelID: String,
        participantUIDs: [String],
        currentUID: String
    ) -> String? {
        guard !currentUID.isEmpty else { return nil }
        func parts(_ value: String) -> [String] {
            let rawParts = value
                .split { $0 == ":" || $0 == "|" || $0 == "," }
                .map(String.init)
                .filter { !$0.isEmpty }
            if rawParts.count == 3,
               let prefix = rawParts.first?.lowercased(),
               ["direct", "dm", "single"].contains(prefix) {
                return Array(rawParts.dropFirst())
            }
            return rawParts
        }
        for channelID in [remoteChannelID, conversationID] {
            let channelParts = parts(channelID)
            guard channelParts.contains(currentUID) else { continue }
            let peers = Set(channelParts.filter { $0 != currentUID })
            if peers.count == 1 {
                return peers.first
            }
        }
        let participantPeers = Set(participantUIDs.filter {
            !$0.isEmpty && $0 != currentUID
        })
        if participantPeers.count == 1 {
            return participantPeers.first
        }
        let weakChannelPeers = Set(
            [remoteChannelID, conversationID]
                .flatMap(parts)
                .filter { !$0.isEmpty && $0 != currentUID }
        )
        return weakChannelPeers.count == 1 ? weakChannelPeers.first : nil
    }
}
