import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
// This unchanged factory is compiled twice: first with the frozen original774 UI,
// then with candidate UI. Expected pixels come only from the original binary.
// Original production prefix IOS tree e23e01d0184e089914030b5679f2a3516c445deb.
// Full source/body provenance is kept in prefix-source-hashes.json, not a second
// implementation of the candidate renderer. No new compilation flags are used.
@MainActor enum ChatSecondarySurfaceOriginalReference {
    static let cases = ["menu-outgoing", "menu-incoming", "sender", "receipt-details", "receipt-private",
                        "receipt-disabled", "forward", "pinned", "announcement", "edit", "report", "reaction", "confirmation"]
    static func message(outgoing: Bool = true) -> ChatMessage {
        var message = ChatMessage(id: outgoing ? "secondary-message" : "secondary-message-peer", senderId: outgoing ? "uid-1" : "uid-2", senderName: outgoing ? "当前用户" : "原发送人",
            text: "原消息正文", time: "09:41", isOutgoing: outgoing, status: .sent, kind: .text,
            reactions: [], readBy: [], unreadBy: [], isPinned: true)
        message.senderAvatarSeed = outgoing ? 0x5D6BFF : 0x7C6BFF
        message.channelSeq = 7
        message.canViewReadDetails = true
        message.readCount = 3; message.unreadCount = 2
        return message
    }
    static func conversation(_ messages: [ChatMessage], kind: ConversationKind = .group) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(id: "secondary-chat", title: "原会话", subtitle: "群聊", kind: kind,
            lastMessage: "原消息正文", time: "09:41", unread: 0, isPinned: false, isMuted: false,
            memberCount: 5, accentHex: 0, participants: [], messages: messages)
    }
    static func surface(_ name: String, state: AppState) -> AnyView {
        let message = message(outgoing: name != "menu-incoming" && name != "report")
        switch name {
        case "menu-outgoing", "menu-incoming":
            return AnyView(MessageActionOverlay(message: message, conversationID: "secondary-chat",
                canShowReadActions: message.isOutgoing, readActionTitle: "已读列表", canForward: true,
                forwardDisabledReason: nil, canSaveAttachment: false, canFavoriteAsset: false,
                canReportMessage: !message.isOutgoing, canAdminDeleteForAll: true,
                editDisabledReason: nil, recallDisabledReason: nil, onDismiss: {}, onReact: { _ in },
                onMoreReactions: {}, onReply: {}, onCopy: {}, onRead: {}, onEdit: {}, onPin: {},
                onFavorite: {}, onForward: {}, onSaveAttachment: {}, onReport: {}, onDelete: {},
                onAdminDeleteForAll: {}, onRecall: {}))
        case "sender":
            return AnyView(UserQuickActionOverlay(user: state.currentUser, onDismiss: {}, onMention: {}, onDetail: {}))
        case "receipt-details", "receipt-private", "receipt-disabled":
            _ = state.applyReadReceiptDetailAuthority(name != "receipt-private", conversationID: "secondary-chat")
            return AnyView(ReadReceiptSheet(message: message, conversation: conversation([message]), readReceiptsEnabled: name != "receipt-disabled"))
        case "forward": return AnyView(ForwardMessageTargetSheet(sourceConversationID: "secondary-chat"))
        case "pinned": return AnyView(PinnedMessagesSheet(conversationID: "secondary-chat", onSelect: { _ in }, onUnpin: { _ in }))
        case "announcement": return AnyView(GroupAnnouncementSheet(group: state.groups[0]))
        case "edit": return AnyView(MessageEditSheet(message: message, conversationID: "secondary-chat", onAuthoritativeSuccess: { _ in true }))
        case "report": return AnyView(MessageReportSheet(message: message, conversationID: "secondary-chat"))
        case "reaction": return AnyView(ReactionPickerView(message: message, conversationID: "secondary-chat", fullPicker: AnyView(Text("完整 Emoji"))))
        default:
            let selection = PendingAttachmentSelection(kind: .file, name: "原视频.mp4", mimeType: "video/mp4", sizeBytes: 1_024, data: Data([1]), previewImage: nil)
            return AnyView(AttachmentSendConfirmationSheet(batch: selection.asBatch, onCancel: {}, onSend: {}))
        }
    }
}

@MainActor func secondarySurfaceHost(_ view: AnyView) throws -> HostedSimulatorUI<AnyView> {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let host = UIHostingController(rootView: view)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
    host.overrideUserInterfaceStyle = .light
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.frame = window.bounds; host.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: host)
}
@MainActor func secondarySurfaceRetire(_ host: HostedSimulatorUI<AnyView>) {
    host.controller.view.endEditing(true)
    host.controller.rootView = AnyView(EmptyView())
    host.window.isHidden = true; host.window.rootViewController = nil
}
@MainActor func secondarySurfaceWait(_ label: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<160 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(predicate(), label)
}
@MainActor func secondarySurfaceSnapshot(_ hosted: HostedSimulatorUI<AnyView>) async throws -> UIImage {
    try await Task.sleep(nanoseconds: 400_000_000)
    hosted.window.layoutIfNeeded(); hosted.controller.view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
    return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
        hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END
