// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain

typealias AttachmentUploadFailure = IM4Domain.AttachmentUploadFailure
typealias BatchForwardSenderProvenance = IM4Domain.BatchForwardSenderProvenance
typealias ConversationKind = IM4Domain.ConversationKind
typealias MessageKind = IM4Domain.MessageKind
typealias MessageDelivery = IM4Domain.MessageDelivery
typealias Reaction = IM4Domain.Reaction
typealias ReactionDetail = IM4Domain.ReactionDetail
typealias ReadReceipt = IM4Domain.ReadReceipt
typealias MentionIdentity = IM4Domain.MentionIdentity
typealias MessageReplyContext = IM4Domain.MessageReplyContext
typealias ChatMessage = IM4Domain.ChatMessage
typealias MessageMentionProjection = IM4Domain.MessageMentionProjection
typealias MessageSearchHit = IM4Domain.MessageSearchHit
typealias IMUser = IM4Domain.IMUser
typealias IMUserSearchMatcher = IM4Domain.IMUserSearchMatcher
typealias UserSearchResult = IM4Domain.UserSearchResult
typealias FriendApplyResolution = IM4Domain.FriendApplyResolution
typealias FriendAddPresentation = IM4Domain.FriendAddPresentation
typealias FriendRequest = IM4Domain.FriendRequest
typealias BlacklistItem = IM4Domain.BlacklistItem
typealias ConversationMessageSnapshot = IM4Domain.ConversationMessageSnapshot
typealias Conversation = IM4Domain.Conversation
typealias DirectConversationCallPeerResolver = IM4Domain.DirectConversationCallPeerResolver
typealias DirectConversationProfilePeerResolver = IM4Domain.DirectConversationProfilePeerResolver
typealias ConversationUnreadState = IM4Domain.ConversationUnreadState
typealias ConversationUnreadBadgeProjection = IM4Domain.ConversationUnreadBadgeProjection
typealias GroupInviteApproval = IM4Domain.GroupInviteApproval
typealias GroupInfo = IM4Domain.GroupInfo
typealias GroupAnnouncement = IM4Domain.GroupAnnouncement
typealias GroupAnnouncementPrivacyProjection = IM4Domain.GroupAnnouncementPrivacyProjection
typealias GroupAnnouncementRevisionProjection = IM4Domain.GroupAnnouncementRevisionProjection
typealias GroupJoinRequest = IM4Domain.GroupJoinRequest
typealias GroupMuteListItem = IM4Domain.GroupMuteListItem
typealias GroupMuteMode = IM4Domain.GroupMuteMode
typealias RTCCallRecordType = IM4Domain.RTCCallRecordType
typealias RTCCallRecordOutcome = IM4Domain.RTCCallRecordOutcome
typealias RTCCallRecordPayload = IM4Domain.RTCCallRecordPayload
typealias StickerMessageVariantSnapshot = IM4Domain.StickerMessageVariantSnapshot
typealias StickerMessageSnapshot = IM4Domain.StickerMessageSnapshot
typealias StickerResolvedFileAsset = IM4Domain.StickerResolvedFileAsset

let cancelledUserDisplayName = IM4Domain.cancelledUserDisplayName
let cancelledUserAvatarPath = IM4Domain.cancelledUserAvatarPath

func inferredAttachmentMediaCategory(kind: MessageKind, name: String, mimeType: String) -> String { IM4Domain.inferredAttachmentMediaCategory(kind: kind, name: name, mimeType: mimeType) }

func isCancelledUserStatus(_ rawValue: String) -> Bool { IM4Domain.isCancelledUserStatus(rawValue) }

func isCancelledUserAvatarURL(_ rawValue: String) -> Bool { IM4Domain.isCancelledUserAvatarURL(rawValue) }

func conversationListSupportsMutableActions(_ conversation: Conversation) -> Bool { IM4Domain.conversationListSupportsMutableActions(conversation) }

func boundedConversationMessageUnreadCount(_ count: Int, lastMsgSeq: Int64, lastReadSeq: Int64) -> Int { IM4Domain.boundedConversationMessageUnreadCount(count, lastMsgSeq: lastMsgSeq, lastReadSeq: lastReadSeq) }

func resolvedConversationUnreadState(remoteUnreadCount: Int, remoteUnreadReactionCount: Int, remoteHasReactionUnread: Bool, locallyReadThrough: Bool) -> ConversationUnreadState {
    IM4Domain.resolvedConversationUnreadState(remoteUnreadCount: remoteUnreadCount, remoteUnreadReactionCount: remoteUnreadReactionCount, remoteHasReactionUnread: remoteHasReactionUnread, locallyReadThrough: locallyReadThrough)
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_BEGIN
typealias InboxItem = IM4Domain.InboxItem
typealias DeviceSession = IM4Domain.DeviceSession
// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110_END
