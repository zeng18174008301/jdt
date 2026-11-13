// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
import IM4Features
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testBubblePresentationBoundaryVisualMatrix() throws {
        let state = groupChatUIState(role: "owner", active: false, repairRequired: false)
        let peer = makeRemarkContractUser(id: "peer-ui", userID: "PEER-UI", name: "公共昵称")
        state.contacts = [peer]
        state.contactRemarks = [peer.userID: "客户备注"]
        let samples: [(MessageKind, String, Bool)] = [
            (.text, "你好 @公共昵称 👋", false), (.text, "已发送的消息", true),
            (.system, "系统通知：成员加入群「示例群」", false),
            (.contactCard, "个人名片：公共昵称", false), (.voice, "语音消息", true),
            (.file, "文档.pdf", false)
        ]
        for (index, appearance) in [ColorScheme.light, .dark].enumerated() {
            let messages = samples.enumerated().map { offset, sample in
                ChatMessage(
                    id: "visual-\(offset)", senderId: sample.2 ? state.currentUser.id : peer.id,
                    senderName: sample.2 ? state.currentUser.name : peer.name,
                    text: sample.1, time: "10:00", isOutgoing: sample.2, status: .sent, kind: sample.0,
                    reactions: [], readBy: [], unreadBy: [], attachmentMeta: sample.0 == .contactCard ? peer.userID : nil,
                    isPinned: false
                )
            }
            let root = ContactDirectoryPresentationView(store: state.contactStore) {
                VStack(spacing: 12) {
                    ForEach(messages) { message in
                        ChatTimelineRow(
                            row: MessageRowModel(index: 0, message: message, showsSenderHeader: message.kind == .text,
                                senderUser: message.isOutgoing ? state.currentUser : peer,
                                displaySenderName: "", timeSeparatorText: nil),
                            conversationID: "group-ui-chat", isGroupConversation: true,
                            onLongPress: {}, onReadTap: {}
                        )
                    }
                }.padding(16)
            }.appStateEnvironment(state).environment(\.colorScheme, appearance)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 390, height: 900))
            defer { hosted.window.isHidden = true }
            let image = hostedSnapshotImage(hosted)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "bubble-boundary-\(index)"))
        }
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
