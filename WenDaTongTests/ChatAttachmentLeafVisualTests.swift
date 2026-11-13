// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
import IM4Features
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
extension AttachmentDownloadTests {
    @MainActor
    func testAttachmentLeafContentVisualMatrix() throws {
        let state = AppState(api: makeClient(transport: FakeAttachmentHTTPTransport(results: [])),
                             apiContextOverride: attachmentContext(tenantID: "leaf-visual-\(UUID())"))
        func message(_ id: String, kind: MessageKind = .file, status: MessageDelivery = .sent, outgoing: Bool = false) -> ChatMessage {
            var value = ChatMessage(id: id, senderId: outgoing ? "uid-1" : "uid-2", senderName: "Peer", text: "报告.pdf", time: "",
                                    isOutgoing: outgoing, status: status, kind: kind, reactions: [], readBy: [], unreadBy: [], isPinned: false)
            value.attachmentFileID = id; value.attachmentName = "报告.pdf"; value.attachmentMimeType = "application/pdf"
            value.attachmentSizeBytes = 2_048; return value
        }
        var uploading = message("upload", status: .sending, outgoing: true); uploading.attachmentTransferProgress = 0.35
        var processing = message("process", status: .sending, outgoing: true); processing.attachmentUploadStatus = "processing"
        let failed = message("failed", status: .failed)
        var photo = message("photo", kind: .image); photo.attachmentMediaCategory = "image"; photo.attachmentMimeType = "image/png"
        var video = message("video", kind: .video); video.attachmentMediaCategory = "video"
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { c in
            UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        for (value, poster) in [(photo, false), (video, true)] {
            let key = AttachmentThumbnailCacheIdentity.generationKey(baseKey: state.chatAttachmentImageCacheKey(for: value, videoPoster: poster),
                generation: state.mediaCacheScopeContext?.sessionGeneration ?? 0)
            AvatarImageCache.shared.storePrepared(image, for: key, maxPixelSize: 768)
        }
        let samples = [message("document"), uploading, processing, failed, photo, video]
        for (index, scheme) in [ColorScheme.light, .dark].enumerated() {
            let root = VStack(spacing: 12) {
                ForEach(samples) { value in
                    ChatTimelineRow(
                        row: MessageRowModel(index: 0, message: value, showsSenderHeader: false,
                            senderUser: nil, displaySenderName: "", timeSeparatorText: nil),
                        conversationID: "direct-ui-chat", isGroupConversation: false,
                        onLongPress: {}, onReadTap: {}
                    )
                }
            }.padding(16).appStateEnvironment(state).environment(\.colorScheme, scheme)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 390, height: 1100))
            defer { hosted.window.isHidden = true }
            let snapshot = hostedSnapshotImage(hosted); XCTAssertGreaterThan(snapshot.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(snapshot, name: "attachment-leaves-\(index)"))
        }
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_REFACTOR_ATTACHMENT_LEAF_INPUTS_20261110_END
