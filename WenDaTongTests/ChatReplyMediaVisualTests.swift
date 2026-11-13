import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testReplyVoiceBoundaryVisualMatrix() throws {
        let state = directChatUIState(nickname: "公共昵称", remark: "客户备注")
        func message(_ id: String, outgoing: Bool, status: MessageDelivery = .sent) -> ChatMessage {
            ChatMessage(id: id, senderId: outgoing ? state.currentUser.id : "peer-ui", senderName: "公共昵称",
                        text: "语音消息", time: "", isOutgoing: outgoing, status: status, kind: .voice,
                        reactions: [], readBy: [], unreadBy: [], isPinned: false)
        }
        var sending = message("sending", outgoing: true, status: .sending)
        sending.attachmentTransferProgress = 0.35; sending.attachmentDurationSeconds = 12
        let playing = message("playing", outgoing: false)
        let failed = message("failed", outgoing: false, status: .failed)
        state.voiceMessagePlaybackStore.playingMessageID = playing.id
        state.voiceMessagePlaybackStore.state = .init(messageID: playing.id, elapsedMS: 1_000, durationMS: 4_000, isPlaying: true)
        for (index, scheme) in [ColorScheme.light, .dark].enumerated() {
            let root = ContactDirectoryPresentationView(store: state.contactStore) {
                VStack(spacing: 24) {
                    ReplyQuoteBlock(quote: "昵称：原消息内容", outgoing: false)
                    ReplyQuoteBlock(quote: "", context: .init(messageID: "source", senderID: "peer-ui", senderName: "公共昵称", summary: "编辑后的引用正文"), outgoing: true)
                        .padding(12).background(IMColor.brand).clipShape(RoundedRectangle(cornerRadius: 21))
                    ReplyQuoteBlock(quote: "", context: .init(messageID: "sticker", senderID: "peer-ui", senderName: "公共昵称", summary: "[表情]", contentType: "sticker"), outgoing: false, compact: true)
                    VoiceBubbleContent(message: sending, outgoing: true, conversationID: "direct-ui-chat")
                        .padding(12).background(IMColor.brand).clipShape(RoundedRectangle(cornerRadius: 21))
                    VoiceBubbleContent(message: playing, outgoing: false, conversationID: "direct-ui-chat")
                    VoiceBubbleContent(message: failed, outgoing: false, conversationID: "direct-ui-chat")
                }.padding(24)
            }.appStateEnvironment(state).environment(\.colorScheme, scheme)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 390, height: 900))
            defer { hosted.window.isHidden = true }
            let image = hostedSnapshotImage(hosted); XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "reply-voice-boundary-\(index)"))
        }
    }
}
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END
