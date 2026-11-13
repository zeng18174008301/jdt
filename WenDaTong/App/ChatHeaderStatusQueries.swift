import IM4Features
import SwiftUI
import UIKit

extension ChatView {
    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
    func backUnreadCount(total: Int) -> Int {
        guard let current = screenStores.conversations.conversation(id: conversationID), !current.isMuted else { return total }
        return max(0, total - max(0, current.unread))
    }
    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END

    private var directCallPeer: IMUser? {
        screenActions.people.directConversationCallPeer(for: conversation)
    }

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    var blacklistPeerIdentities: Set<String> {
        guard conversation.kind == .direct else { return [] }
        var identities = Set(directCallPeer.map(screenActions.people.userIdentityCandidates(for:)) ?? [])
        if let peerID = screenActions.people.directPeerID(for: conversation) {
            identities.insert(peerID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return identities
    }
    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END

    var directProfilePeer: IMUser? {
        screenActions.people.directConversationProfilePeer(for: conversation)
    }

    var conversationDisplayTitle: String {
        conversationDisplayTitle(for: conversation)
    }

    func conversationDisplayTitle(for conversation: ConversationMessageSnapshot) -> String {
        let resolvedPeerDisplayName = directProfilePeer.map {
            screenActions.people.remarkPreferredDisplayName(for: $0)
        }
        return ChatHeaderTitleDecision.resolve(
            kind: conversation.kind,
            resolvedPeerDisplayName: resolvedPeerDisplayName,
            conversationTitle: conversation.title
        )
    }

    private var canStartVoiceCall: Bool {
        guard conversation.kind == .direct, let directCallPeer else { return false }
        return screenActions.calls.canStartVoiceCall(with: directCallPeer)
    }

    private var canStartVideoCall: Bool {
        guard conversation.kind == .direct, let directCallPeer else { return false }
        return screenActions.calls.canStartVideoCall(with: directCallPeer)
    }

    var isVideoCallEntryVisible: Bool {
        conversation.kind == .direct
    }

    var voiceCallAccessibilityHint: String {
        screenActions.calls.callLicenseUnavailableMessage(for: .voice)
            ?? directCallPeer.flatMap(screenActions.calls.voiceCallUnavailableReason(for:)) ?? ""
    }

    var videoCallAccessibilityHint: String {
        directCallPeer.flatMap(screenActions.calls.videoCallUnavailableReason(for:)) ?? ""
    }

    var currentGroup: GroupInfo {
        if let group = screenActions.people.group(forConversationID: conversationID) {
            return group
        }
        let fallbackMemberCount = screenActions.people.groupMemberCount(
            first: conversation.memberCount, second: nil, showsCount: showsChatGroupMemberCount // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        )
        return GroupInfo(
            id: conversation.id,
            name: conversation.title,
            avatarURL: conversation.avatarURL,
            notice: "群资料同步中",
            owner: "",
            members: conversation.participants,
            admins: [],
            muted: conversation.isMuted,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            memberCount: fallbackMemberCount
        )
    }

    var groupMemberSubtitleText: String? {
        screenActions.people.groupMemberCount(
            first: currentGroup.memberCount,
            second: conversation.memberCount, showsCount: showsChatGroupMemberCount // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        ).map { "\($0) 人" }
    }

    func startVoiceCallFromConversation() {
        guard let directCallPeer else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ screenActions.toast(conversation.kind == .direct
                ? DirectConversationCallPeerResolver.unavailableMessage
                : "暂不支持群语音通话") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            return
        }
        guard screenActions.calls.guardCallLicenseForAction(.voice) else { return }
        guard canStartVoiceCall else {
            if conversation.kind != .direct {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast("暂不支持群语音通话")
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast(screenActions.calls.voiceCallUnavailableReason(for: directCallPeer) ?? "暂无法发起语音通话")
            }
            return
        }
        screenActions.calls.startOutgoingVoiceCall(to: directCallPeer, channelID: conversation.id)
    }

    func startVideoCallFromConversation() {
        guard let directCallPeer else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ screenActions.toast(conversation.kind == .direct
                ? DirectConversationCallPeerResolver.unavailableMessage
                : "暂不支持群视频通话") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            return
        }
        guard screenActions.calls.guardCallLicenseForAction(.video) else { return }
        guard canStartVideoCall else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ screenActions.toast(screenActions.calls.videoCallUnavailableReason(for: directCallPeer) ?? "暂无法发起视频通话")
            return
        }
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：聊天页直发视频先拉起轻量通话页，网络/权限准备继续异步执行
        screenActions.calls.startOutgoingVideoCall(to: directCallPeer, channelID: conversation.id, presentImmediately: true)
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
    }

    var conversationSendDisabledReason: String {
        screenActions.people.conversationSendDisabledReason(conversationID)
    }

    var composerDisabledReason: String {
        conversationSendDisabledReason.isEmpty ? groupMuteDisabledReason : conversationSendDisabledReason
    }

    var composerDisabledTitle: String {
        if conversationSendDisabledReason == screenActions.people.globalMutedMessage {
            return screenActions.people.globalMutedMessage
        }
        if conversationSendDisabledReason.isEmpty, isGroupAllMuted {
            return currentGroup.allMuteStatusText()
        }
        return conversationSendDisabledReason.isEmpty ? screenActions.people.globalMutedMessage : "当前无法发送消息"
    }

    var isReadOnlySystemConversation: Bool {
        conversation.kind == .system || (conversation.kind != .group && isSystemAccountConversation)
    }

    func isMessageAuthoredByCurrentUser(_ message: ChatMessage) -> Bool {
        guard message.kind != .system else { return false }
        return screenActions.people.isCurrentMessageSender(message.senderId)
    }

    func currentMessageSnapshot(for message: ChatMessage) -> ChatMessage {
        conversation.messages.first(where: { $0.id == message.id }) ?? message
    }

    private var isSystemAccountConversation: Bool {
        let hasSystemParticipant = conversation.participants.contains { user in
            let normalizedID = user.id.lowercased()
            return normalizedID.contains("system")
                || normalizedID.contains("bot")
                || user.name.contains("系统")
                || user.title.contains("系统")
        }
        return hasSystemParticipant || conversation.title.contains("系统")
    }

    private var isGroupAllMuted: Bool {
        conversation.kind == .group && !screenActions.people.canCurrentUserSend(in: currentGroup)
    }

    var composerIsDisabled: Bool {
        !conversationSendDisabledReason.isEmpty || isGroupAllMuted
    }

    var shouldShowGroupMuteStatus: Bool {
        disabledBannerDecision.groupMuteBanner != nil
    }

    private var groupMuteBannerDecision: GroupMuteBannerDecision? {
        guard conversation.kind == .group else { return nil }
        return GroupMuteBannerDecision.resolve(
            group: currentGroup,
            canManage: screenActions.people.canManageGroup(currentGroup)
        )
    }

    var disabledBannerDecision: ChatDisabledBannerDecision {
        ChatDisabledBannerDecision.resolve(
            groupMuteBanner: groupMuteBannerDecision,
            composerIsDisabled: composerIsDisabled
        )
    }

    var currentGroupAnnouncement: GroupAnnouncement? {
        screenActions.people.currentUnreadAnnouncement(for: currentGroup.id)
    }

    var currentGroupAnnouncementTitle: String {
        let title = currentGroupAnnouncement?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "群公告" : title
    }

    var currentGroupAnnouncementPreview: String {
        let summary = currentGroupAnnouncement?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        let content = currentGroupAnnouncement?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty { return content }
        return currentGroup.notice
    }

    var shouldShowGroupAnnouncement: Bool {
        conversation.kind == .group && showGroupAnnouncement && screenActions.people.hasUnreadAnnouncement(for: currentGroup.id)
    }

    private var groupMuteDisabledReason: String {
        if currentGroup.allMuteRepairRequired {
            return "禁言状态需要管理员修复；修复前普通成员无法发送，草稿会保留。"
        }
        if currentGroup.allMuteMode == .always
            || (currentGroup.allMuteMode == nil
                && currentGroup.allMuted
                && currentGroup.allMuteStart == nil
                && currentGroup.allMuteEnd == nil) {
            return "群主已开启一直禁言；群主和管理员可继续发言。"
        }
        return "\(currentGroup.allMuteStatusText())；群主和管理员可继续发言。"
    }

    var groupMuteStatusDetail: String {
        groupMuteBannerDecision?.detail ?? ""
    }

    func openCurrentGroupAnnouncement() {
        guard let announcement = currentGroupAnnouncement else { return }
        guard !isOpeningGroupAnnouncementDetail, !isMarkingGroupAnnouncementRead else { return }
        let groupID = currentGroup.id
        isOpeningGroupAnnouncementDetail = true
        screenActions.people.loadGroupAnnouncementDetail(groupID: groupID, announcementID: announcement.id, silent: false) { success in
            isOpeningGroupAnnouncementDetail = false
            guard success, conversation.kind == .group, currentGroup.id == groupID else { return }
            openedGroupAnnouncementID = announcement.id
            showGroupAnnouncementDetail = true
            screenActions.people.markGroupAnnouncementRead(groupID: groupID, announcementID: announcement.id)
        }
    }

    func closeCurrentGroupAnnouncementBanner() {
        markCurrentGroupAnnouncementRead()
    }

    private func markCurrentGroupAnnouncementRead() {
        guard !isMarkingGroupAnnouncementRead else { return }
        guard let announcement = currentGroupAnnouncement else {
            return
        }
        isMarkingGroupAnnouncementRead = true
        screenActions.people.markGroupAnnouncementRead(groupID: currentGroup.id, announcementID: announcement.id) { _ in
            isMarkingGroupAnnouncementRead = false
        }
    }

}
