import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

// WDT_IOS1_REFACTOR_LIFECYCLE_ATOMIC_COMMIT_20261110_BEGIN
public extension ConversationStore {
    @discardableResult
    func deleteConversation(conversationID: String) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty,
                  let index = conversations.firstIndex(where: { $0.id == normalizedID }) else { return nil }
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            let removed = next.remove(at: index)
            commitConversationSnapshots(next, unreadUpdate: .delta(removing: [removed.conversation], adding: [], baseRevision: unreadRevision))
            return removed
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func insertDirectConversation(
        channelID: String,
        title: String,
        participant: IMUser,
        accentHex: UInt
    ) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedChannelID.isEmpty else { return nil }
            if let existing = conversationMessageSnapshot(id: normalizedChannelID) {
                return existing
            }
            let conversation = ConversationMessageSnapshot(
                id: normalizedChannelID,
                title: title,
                subtitle: "单聊",
                kind: .direct,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 0,
                accentHex: accentHex,
                participants: [participant],
                messages: [],
                avatarURL: participant.avatarURL,
                avatarVersion: participant.avatarVersion,
                avatarUpdatedAt: participant.avatarUpdatedAt
            )
            commitConversationSnapshots([conversation] + conversationMessageSnapshots(), unreadUpdate: .delta(removing: [], adding: [conversation.conversation], baseRevision: memorySnapshot.revision))
            return conversation
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func conversationsByChannelID(channelIDForConversation: (ConversationMessageSnapshot) -> String) -> [String: ConversationMessageSnapshot] {
        // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：手动建索引避免 Dictionary(grouping:) 为每个 channel 分配临时数组
        Self.indexedConversations(conversationMessageSnapshots(), channelIDForConversation: channelIDForConversation)
        // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束
    }

    // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：保留旧语义，只记录每个 channel 的第一条会话
    static func indexedConversations(
        _ rows: [ConversationMessageSnapshot],
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> [String: ConversationMessageSnapshot] {
        var result: [String: ConversationMessageSnapshot] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let channelID = channelIDForConversation(row)
            if result[channelID] == nil {
                result[channelID] = row
            }
        }
        return result
    }
    // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束

    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_BEGIN
    func conversationListPrecedes(_ lhs: ConversationMessageSnapshot, _ rhs: ConversationMessageSnapshot) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        return ConversationListOrder(row: lhs.conversation, messages: lhs.messages)
            < ConversationListOrder(row: rhs.conversation, messages: rhs.messages)
    }
    // WDT_IOS1_STORES_CONVERSATION_ROW_INDEX_20261112_END

    func toggleConversationPinned(conversationID: String) -> ConversationSettingChange? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
            let previousValue = conversationMessageSnapshot(at: index).isPinned
            var next = conversationMessageSnapshots()
            next[index].isPinned.toggle()
            let conversation = next[index]
            next.sort(by: conversationListPrecedes)
            commitConversationSnapshots(next, unreadUpdate: .preserve)
            return ConversationSettingChange(previousValue: previousValue, conversation: conversation)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func restoreConversationPinned(conversationID: String, to previousValue: Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            var next = conversationMessageSnapshots()
            next[index].isPinned = previousValue
            next.sort(by: conversationListPrecedes)
            commitConversationSnapshots(next, unreadUpdate: .preserve)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func toggleConversationMuted(conversationID: String) -> ConversationSettingChange? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
            let previousValue = conversationMessageSnapshot(at: index).isMuted
            mutateStoredConversation(at: index) { $0.isMuted.toggle() }
            return ConversationSettingChange(previousValue: previousValue, conversation: conversationMessageSnapshot(at: index))
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func restoreConversationMuted(conversationID: String, to previousValue: Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            mutateStoredConversation(at: index) { $0.isMuted = previousValue }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func setGroupConversationMuted(groupID: String, groupName: String, isMuted: Bool) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty || !normalizedName.isEmpty else { return false }
            guard let index = conversationMessageSnapshots().firstIndex(where: { conversation in
                (!normalizedID.isEmpty && conversation.id == normalizedID)
                    || (!normalizedName.isEmpty && conversation.title == normalizedName)
            }) else { return false }
            mutateStoredConversation(at: index) { $0.isMuted = isMuted }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func updateGroupAllMutedConversationPreview(
        groupID: String,
        groupName: String,
        message: String,
        time: String = "刚刚",
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty || !normalizedName.isEmpty else { return false }
            guard let index = conversationMessageSnapshots().firstIndex(where: { conversation in
                (!normalizedID.isEmpty && conversation.id == normalizedID)
                    || (!normalizedID.isEmpty && channelIDForConversation(conversation) == normalizedID)
                    || (!normalizedName.isEmpty && conversation.kind == .group && conversation.title == normalizedName)
            }) else { return false }
            mutateStoredConversation(at: index) { conversation in
                conversation.lastMessage = message
                conversation.time = time
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func removeParticipantFromGroupConversation(
        groupID: String,
        groupName: String,
        userID: String,
        memberCount: Int?
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedUserID.isEmpty,
                  !normalizedGroupID.isEmpty || !normalizedGroupName.isEmpty else { return false }
            guard let index = conversationMessageSnapshots().firstIndex(where: { conversation in
                (!normalizedGroupID.isEmpty && conversation.id == normalizedGroupID)
                    || (!normalizedGroupName.isEmpty && conversation.title == normalizedGroupName)
            }) else { return false }
            mutateStoredConversation(at: index) { conversation in
                conversation.participants.removeAll { $0.id == normalizedUserID }
                conversation.memberCount = memberCount
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func removeParticipantFromAllConversations(userID: String) -> Int {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedUserID.isEmpty else { return 0 }
            var removedCount = 0
            var next = conversationMessageSnapshots()
            for index in next.indices {
                let beforeCount = next[index].participants.count
                next[index].participants.removeAll { $0.id == normalizedUserID }
                removedCount += beforeCount - next[index].participants.count
            }
            if !next.isEmpty { commitConversationSnapshots(next) }
            return removedCount
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func updateConversationParticipants(_ transform: (IMUser) -> IMUser) -> Int {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            var updatedCount = 0
            var next = conversationMessageSnapshots()
            var didWrite = false
            for index in next.indices {
                guard !next[index].participants.isEmpty else { continue }
                var nextParticipants: [IMUser] = []
                nextParticipants.reserveCapacity(next[index].participants.count)
                for participant in next[index].participants {
                    let updatedParticipant = transform(participant)
                    if updatedParticipant != participant {
                        updatedCount += 1
                    }
                    nextParticipants.append(updatedParticipant)
                }
                if nextParticipants != next[index].participants {
                    next[index].participants = nextParticipants
                    didWrite = true
                }
            }
            if didWrite { commitConversationSnapshots(next) }
            return updatedCount
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // JHT_MOD_BEGIN APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改开始：头像投影只复制命中的会话/消息，避免整表拷贝和深比较
    public struct AvatarRealtimeConversationProjection: Sendable {
        public let uid: String
        public let url: String
        public let cacheVersion: String
        public let updatedAt: String

        public init(uid: String, url: String, cacheVersion: String, updatedAt: String) {
            self.uid = uid
            self.url = url
            self.cacheVersion = cacheVersion
            self.updatedAt = updatedAt
        }
    }

    public struct AvatarRealtimeConversationApplyResult: Sendable {
        public let conversationsChanged: Int
        public let participantsChanged: Int
        public let messagesChanged: Int

        public static let empty = AvatarRealtimeConversationApplyResult(
            conversationsChanged: 0,
            participantsChanged: 0,
            messagesChanged: 0
        )

        public var didChange: Bool {
            conversationsChanged > 0
        }

        public init(conversationsChanged: Int, participantsChanged: Int, messagesChanged: Int) {
            self.conversationsChanged = conversationsChanged
            self.participantsChanged = participantsChanged
            self.messagesChanged = messagesChanged
        }
    }

    @discardableResult
    func applyAvatarRealtimeProjectionsToConversations(
        _ projections: [String: AvatarRealtimeConversationProjection],
        currentUID: String,
        channelIDForConversation: (ConversationMessageSnapshot) -> String,
        projectParticipant: (IMUser) -> IMUser
    ) -> AvatarRealtimeConversationApplyResult {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard !projections.isEmpty else { return .empty }
            let projectionUIDs = Set(projections.keys)
            var updatedConversations = conversationMessageSnapshots()
            var conversationsChanged = 0
            var participantsChanged = 0
            var messagesChanged = 0

            for index in updatedConversations.indices {
                var conversation = updatedConversations[index]
                var conversationDidChange = false

                if !conversation.participants.isEmpty {
                    var nextParticipants = conversation.participants
                    var participantsDidChange = false
                    for participantIndex in nextParticipants.indices {
                        guard projectionUIDs.contains(nextParticipants[participantIndex].id) else { continue }
                        let updatedParticipant = projectParticipant(nextParticipants[participantIndex])
                        guard updatedParticipant != nextParticipants[participantIndex] else { continue }
                        nextParticipants[participantIndex] = updatedParticipant
                        participantsDidChange = true
                        participantsChanged += 1
                    }
                    if participantsDidChange {
                        conversation.participants = nextParticipants
                        conversationDidChange = true
                    }
                }

                if !conversation.messages.isEmpty {
                    var nextMessages = conversation.messages
                    var messagesDidChange = false
                    for messageIndex in nextMessages.indices {
                        let senderID = nextMessages[messageIndex].senderId
                        guard let projection = projections[senderID] else { continue }
                        var message = nextMessages[messageIndex]
                        var messageDidChange = false
                        if message.senderAvatarURL != projection.url {
                            message.senderAvatarURL = projection.url
                            messageDidChange = true
                        }
                        if message.senderAvatarVersion != projection.cacheVersion {
                            message.senderAvatarVersion = projection.cacheVersion
                            messageDidChange = true
                        }
                        if !projection.updatedAt.isEmpty,
                           message.senderAvatarUpdatedAt != projection.updatedAt {
                            message.senderAvatarUpdatedAt = projection.updatedAt
                            messageDidChange = true
                        }
                        guard messageDidChange else { continue }
                        nextMessages[messageIndex] = message
                        messagesDidChange = true
                        messagesChanged += 1
                    }
                    if messagesDidChange {
                        conversation.messages = nextMessages
                        conversationDidChange = true
                    }
                }

                if conversation.kind == .direct {
                    let remoteChannelID = channelIDForConversation(conversation)
                    let participantUIDs = conversation.participants.map(\.id)
                    if let peerUID = ConversationDirectPeerIdentity.directPeerUID(
                        conversationID: conversation.id,
                        remoteChannelID: remoteChannelID,
                        participantUIDs: participantUIDs,
                        currentUID: currentUID
                    ), let projection = projections[peerUID] {
                        if conversation.avatarURL != projection.url {
                            conversation.avatarURL = projection.url
                            conversationDidChange = true
                        }
                        if conversation.avatarVersion != projection.cacheVersion {
                            conversation.avatarVersion = projection.cacheVersion
                            conversationDidChange = true
                        }
                        if !projection.updatedAt.isEmpty,
                           conversation.avatarUpdatedAt != projection.updatedAt {
                            conversation.avatarUpdatedAt = projection.updatedAt
                            conversationDidChange = true
                        }
                    }
                }

                if conversationDidChange {
                    updatedConversations[index] = conversation
                    conversationsChanged += 1
                }
            }

            guard conversationsChanged > 0 else { return .empty }
            commitConversationSnapshots(updatedConversations)
            return AvatarRealtimeConversationApplyResult(
                conversationsChanged: conversationsChanged,
                participantsChanged: participantsChanged,
                messagesChanged: messagesChanged
            )
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }
    // JHT_MOD_END APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改结束

    @discardableResult
    func refreshDirectConversationProfiles(
        channelIDForConversation: (ConversationMessageSnapshot) -> String,
        titleForChannel: (String) -> String,
        participantsForChannel: (String) -> [IMUser]
    ) -> Int {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            var updatedConversationCount = 0
            var updatedConversations = conversationMessageSnapshots()
            for index in updatedConversations.indices where updatedConversations[index].kind == .direct {
                var didUpdate = false
                let channelID = channelIDForConversation(updatedConversations[index])
                let resolvedTitle = titleForChannel(channelID)
                if !resolvedTitle.isEmpty && resolvedTitle != updatedConversations[index].title {
                    updatedConversations[index].title = resolvedTitle
                    didUpdate = true
                }

                let participants = participantsForChannel(channelID)
                if !participants.isEmpty {
                    if participants != updatedConversations[index].participants {
                        updatedConversations[index].participants = participants
                        didUpdate = true
                    }
                    if let avatarUser = participants.first, !avatarUser.avatarURL.isEmpty {
                        if updatedConversations[index].avatarURL != avatarUser.avatarURL {
                            updatedConversations[index].avatarURL = avatarUser.avatarURL
                            didUpdate = true
                        }
                        if updatedConversations[index].avatarVersion != avatarUser.avatarVersion {
                            updatedConversations[index].avatarVersion = avatarUser.avatarVersion
                            didUpdate = true
                        }
                        if updatedConversations[index].avatarUpdatedAt != avatarUser.avatarUpdatedAt {
                            updatedConversations[index].avatarUpdatedAt = avatarUser.avatarUpdatedAt
                            didUpdate = true
                        }
                    }
                }

                if didUpdate {
                    updatedConversationCount += 1
                }
            }
            if updatedConversationCount > 0 {
                commitConversationSnapshots(updatedConversations)
            }
            return updatedConversationCount
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func setGroupConversationParticipants(
        groupID: String,
        groupName: String,
        participants: [IMUser],
        memberCount: Int?
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedGroupID.isEmpty || !normalizedGroupName.isEmpty else { return false }
            guard let index = conversationMessageSnapshots().firstIndex(where: { conversation in
                (!normalizedGroupID.isEmpty && conversation.id == normalizedGroupID)
                    || (!normalizedGroupName.isEmpty && conversation.title == normalizedGroupName)
            }) else { return false }
            mutateStoredConversation(at: index) { conversation in
                if !participants.isEmpty {
                    conversation.participants = participants
                }
                conversation.memberCount = resolvedGroupMemberCount(
                    incoming: memberCount,
                    existing: conversation.memberCount,
                    participants: participants
                )
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func upsertCreatedGroupConversation(
        groupID: String,
        name: String,
        members: [IMUser],
        invitedMemberCount: Int,
        accentHex: UInt,
        sortTimestamp: TimeInterval = Date().timeIntervalSince1970,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedGroupID.isEmpty else { return nil }

            if let index = groupConversationIndex(
                groupID: normalizedGroupID,
                groupName: "",
                matchByTitle: false,
                channelIDForConversation: channelIDForConversation
            ) {
                var conversation = conversationMessageSnapshot(at: index)
                conversation.title = name
                conversation.subtitle = "群聊"
                conversation.memberCount = max(conversation.memberCount ?? 0, members.count)
                if !members.isEmpty {
                    conversation.participants = members
                }
                commitConversationSnapshot(conversation, at: index)
                return conversation
            }

            let conversation = ConversationMessageSnapshot(
                id: normalizedGroupID,
                title: name,
                subtitle: "群聊",
                kind: .group,
                lastMessage: "群聊已创建",
                time: "刚刚",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: max(members.count, invitedMemberCount + 1),
                accentHex: accentHex,
                participants: members,
                messages: [],
                avatarURL: "",
                sortTimestamp: sortTimestamp
            )
            commitConversationSnapshots([conversation] + conversationMessageSnapshots(), unreadUpdate: .delta(removing: [], adding: [conversation.conversation], baseRevision: memorySnapshot.revision))
            return conversation
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func ensureGroupConversation(
        groupID: String,
        name: String,
        notice: String,
        members: [IMUser],
        muted: Bool,
        memberCount: Int?,
        preservesMemberCountWhenMissing: Bool = false,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        avatarIsAuthoritative: Bool = false,
        accentHex: UInt,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedGroupID.isEmpty || !normalizedName.isEmpty else { return nil }

            if let index = groupConversationIndex(
                groupID: normalizedGroupID,
                groupName: normalizedName,
                matchByTitle: true,
                channelIDForConversation: channelIDForConversation
            ) {
                var conversation = conversationMessageSnapshot(at: index)
                conversation.title = name
                conversation.subtitle = "群聊"
                if conversation.lastMessage.isEmpty {
                    conversation.lastMessage = notice
                }
                if memberCount != nil || !preservesMemberCountWhenMissing {
                    conversation.memberCount = resolvedGroupMemberCount(
                        incoming: memberCount,
                        existing: conversation.memberCount,
                        participants: members
                    )
                }
                if !members.isEmpty {
                    conversation.participants = members
                }
                if avatarIsAuthoritative {
                    conversation.avatarURL = avatarURL
                    conversation.avatarVersion = avatarVersion
                    conversation.avatarUpdatedAt = avatarUpdatedAt
                } else {
                    if !avatarURL.isEmpty {
                        conversation.avatarURL = avatarURL
                    }
                    if !avatarVersion.isEmpty {
                        conversation.avatarVersion = avatarVersion
                    }
                    if !avatarUpdatedAt.isEmpty {
                        conversation.avatarUpdatedAt = avatarUpdatedAt
                    }
                }
                if conversationMessageSnapshot(at: index) != conversation { commitConversationSnapshot(conversation, at: index) }
                return conversation
            }

            guard !normalizedGroupID.isEmpty else { return nil }
            let conversation = ConversationMessageSnapshot(
                id: normalizedGroupID,
                title: name,
                subtitle: "群聊",
                kind: .group,
                lastMessage: notice,
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: muted,
                memberCount: resolvedGroupMemberCount(incoming: memberCount, existing: nil, participants: members),
                accentHex: accentHex,
                participants: members,
                messages: [],
                avatarURL: avatarURL,
                avatarVersion: avatarVersion,
                avatarUpdatedAt: avatarUpdatedAt
            )
            commitConversationSnapshots(conversationMessageSnapshots() + [conversation], unreadUpdate: .delta(removing: [], adding: [conversation.conversation], baseRevision: memorySnapshot.revision))
            return conversation
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func replaceSystemConversation(_ buildConversation: (ConversationMessageSnapshot?) -> ConversationMessageSnapshot?) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            let previousSystem = conversationMessageSnapshots().first(where: { $0.kind == .system && $0.id == "system_notification" })
                ?? conversationMessageSnapshots().first(where: { $0.kind == .system })
            var removed: [Conversation] = []
            var added: [Conversation] = []
            var next = conversationMessageSnapshots().filter { row in
                guard row.kind == .system else { return true }
                removed.append(row.conversation); return false
            }
            if let conversation = buildConversation(previousSystem) {
                next.insert(conversation, at: 0)
                added.append(conversation.conversation)
            }
            publishConversationsIfChanged(next, unreadUpdate: .delta(removing: removed, adding: added, baseRevision: unreadRevision))
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func removeDirectConversations(
        peerID: String,
        directPeerID: (ConversationMessageSnapshot) -> String?
    ) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return }
            let unreadRevision = memorySnapshot.revision
            var removed: [Conversation] = []
            let next = conversationMessageSnapshots().filter { conversation in
                guard conversation.kind == .direct else { return true }
                if directPeerID(conversation) == normalizedID { removed.append(conversation.conversation); return false }
                if conversation.participants.contains(where: { $0.id == normalizedID }) { removed.append(conversation.conversation); return false }
                if conversation.id.split(separator: ":").map(String.init).contains(normalizedID) {
                    removed.append(conversation.conversation); return false
                }
                return true
            }
            commitConversationSnapshots(next, unreadUpdate: .delta(removing: removed, adding: [], baseRevision: unreadRevision))
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func groupConversationIndex(
        groupID: String,
        groupName: String,
        matchByTitle: Bool,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Int? {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Resolve canonical IDs first; unrelated direct chats must not run peer normalization.
        if !normalizedGroupID.isEmpty,
           let exact = conversations.firstIndex(where: { $0.id == normalizedGroupID }) { return exact }
        return conversationMessageSnapshots().firstIndex { conversation in
            guard conversation.kind == .group else { return false }
            if !normalizedGroupID.isEmpty,
               conversation.id == normalizedGroupID || channelIDForConversation(conversation) == normalizedGroupID {
                return true
            }
            if matchByTitle,
               !normalizedGroupName.isEmpty,
               conversation.kind == .group,
               conversation.title == normalizedGroupName {
                return true
            }
            return false
        }
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DIRECT_UNAVAILABLE_DEDUPE - 修改开始：好友不可用状态重复写入去重，action/context 变化仍通知 UI
    @discardableResult
    private func setHistoryMessageIfChanged(conversationID: String, message: String?) -> Bool {
        guard historyMessages[conversationID] != message else { return false }
        historyMessages[conversationID] = message
        return true
    }

    @discardableResult
    private func setDirectDisabledMessageIfChanged(conversationID: String, message: String?) -> Bool {
        guard directDisabledMessages[conversationID] != message else { return false }
        directDisabledMessages[conversationID] = message
        return true
    }

    @discardableResult
    private func setDirectFriendRequestContextIfChanged(
        conversationID: String,
        context: DirectFriendRequestContext?
    ) -> Bool {
        guard directFriendRequestContexts[conversationID] != context else { return false }
        directFriendRequestContexts[conversationID] = context // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110: the keyed availability publisher handles this change.
        return true
    }

    func setHistoryMessage(conversationID: String, message: String?) {
        setHistoryMessageIfChanged(conversationID: conversationID, message: message)
    }

    func setDirectDisabledMessage(conversationID: String, message: String?) {
        setDirectDisabledMessageIfChanged(conversationID: conversationID, message: message)
    }

    func directFriendRequestContext(conversationID: String) -> DirectFriendRequestContext? {
        directFriendRequestContexts[conversationID]
    }

    func hasDirectFriendRequestContexts() -> Bool {
        !directFriendRequestContexts.isEmpty
    }

    func setDirectFriendRequestContext(conversationID: String, context: DirectFriendRequestContext?) {
        setDirectFriendRequestContextIfChanged(conversationID: conversationID, context: context)
    }

    func markDirectConversationUnavailable(
        _ conversation: ConversationMessageSnapshot,
        context: DirectFriendRequestContext,
        fallbackMessage: String? = nil
    ) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard conversation.kind == .direct else { return }
            let message = fallbackMessage ?? context.disabledMessage
            setDirectFriendRequestContextIfChanged(conversationID: conversation.id, context: context)
            setDirectDisabledMessageIfChanged(conversationID: conversation.id, message: message)
            setHistoryMessageIfChanged(conversationID: conversation.id, message: message)
            if let index = conversationMessageSnapshots().firstIndex(where: { $0.id == conversation.id }),
               conversationMessageSnapshot(at: index).subtitle != "需要好友关系" || conversationMessageSnapshot(at: index).unread != 0 {
                mutateStoredConversation(at: index) { updated in
                    updated.subtitle = "需要好友关系"
                    updated.unread = 0
                }
            }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func clearDirectFriendRequestContext(conversationID: String) {
        setDirectFriendRequestContextIfChanged(conversationID: conversationID, context: nil)
    }

    func clearHistoryAndDirectDisabledMessages(conversationID: String) {
        setHistoryMessageIfChanged(conversationID: conversationID, message: nil)
        setDirectDisabledMessageIfChanged(conversationID: conversationID, message: nil)
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DIRECT_UNAVAILABLE_DEDUPE - 修改结束

    func beginApplyingFriend(conversationID: String) -> Bool {
        guard !conversationID.isEmpty, !applyingFriendIDs.contains(conversationID) else { return false }
        applyingFriendIDs.insert(conversationID)
        return true
    }

    func finishApplyingFriend(conversationID: String) {
        applyingFriendIDs.remove(conversationID)
    }

}
// WDT_IOS1_REFACTOR_LIFECYCLE_ATOMIC_COMMIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END
