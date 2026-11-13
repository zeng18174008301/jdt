import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI

public struct ChatReceiptInput {
    public let currentUser: IMUser
    public let canViewDetails: Bool
    public let showsGroupMemberCount: Bool
    public let peerDisplayName: String
    public let readBy: [ChatReadReceiptPresentation]
    public let unreadBy: [ChatReadReceiptPresentation]
    public let reactionDetails: [ChatReactionDetailPresentation]
    public let certifications: [String: ChatCertificationRendering.Reference]

    public init(currentUser: IMUser,
        canViewDetails: Bool,
        showsGroupMemberCount: Bool,
        peerDisplayName: String,
        readBy: [ChatReadReceiptPresentation],
        unreadBy: [ChatReadReceiptPresentation],
        reactionDetails: [ChatReactionDetailPresentation],
        certifications: [String: ChatCertificationRendering.Reference]) {
        self.currentUser = currentUser
        self.canViewDetails = canViewDetails
        self.showsGroupMemberCount = showsGroupMemberCount
        self.peerDisplayName = peerDisplayName
        self.readBy = readBy
        self.unreadBy = unreadBy
        self.reactionDetails = reactionDetails
        self.certifications = certifications
    }
}
// One value per original record. UID is not a display-name cache key.
public struct ChatReadReceiptPresentation: Identifiable {
    public let receipt: ReadReceipt
    public let displayName: String
    public var id: String { receipt.id }

    public init(receipt: ReadReceipt,
        displayName: String) {
        self.receipt = receipt
        self.displayName = displayName
    }
}
public struct ChatReactionDetailPresentation: Identifiable {
    public let reaction: ReactionDetail
    public let displayName: String
    public var id: String { reaction.id }

    public init(reaction: ReactionDetail,
        displayName: String) {
        self.reaction = reaction
        self.displayName = displayName
    }
}

public struct ChatReportDisplay: Equatable {
    public let reason: String?
    public let description: String?

    public init(reason: String? = nil,
        description: String? = nil) {
        self.reason = reason
        self.description = description
    }
}
public enum ChatReportOutcome {
    case submitted
    case alreadyReported(ChatReportDisplay)
    case failed
    case rejected
}
public struct ChatReportActions {
    public let submit: (String, String) async -> ChatReportOutcome
    public let lookup: () async -> ChatReportDisplay?

    public init(submit: @escaping (String, String) async -> ChatReportOutcome,
        lookup: @escaping () async -> ChatReportDisplay?) {
        self.submit = submit
        self.lookup = lookup
    }
}
public struct ChatMessageEntryActions {
    public let toggleSelection: () -> Void
    public let longPress: () -> Void
    public let read: () -> Void
    public let attachment: (ChatMessage) -> Void

    public init(toggleSelection: @escaping () -> Void,
        longPress: @escaping () -> Void,
        read: @escaping () -> Void,
        attachment: @escaping (ChatMessage) -> Void) {
        self.toggleSelection = toggleSelection
        self.longPress = longPress
        self.read = read
        self.attachment = attachment
    }
}
public struct ChatDeletionActions {
    public let adminDelete: (ChatMessage) -> Void
    public let failedDelete: (ChatMessage) -> Void

    public init(adminDelete: @escaping (ChatMessage) -> Void,
        failedDelete: @escaping (ChatMessage) -> Void) {
        self.adminDelete = adminDelete
        self.failedDelete = failedDelete
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
