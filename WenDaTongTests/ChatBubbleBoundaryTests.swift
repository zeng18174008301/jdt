@testable import IM4Features
import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testMountedBubbleRetainedActionsRejectFourSessionTransitions() async throws {
        for transition in ["tenant", "logout-login", "A-B-A", "reauthentication"] {
            let state = directChatUIState(nickname: "Peer", remark: nil)
            let peer = try XCTUnwrap(state.contacts.first)
            let message = ChatMessage(
                id: "action-row", senderId: peer.id, senderName: peer.name, text: "Hello",
                time: "", isOutgoing: false, status: .sent, kind: .text,
                reactions: [], readBy: [], unreadBy: [], isPinned: false
            )
            var probe: ChatBubbleAssemblyProbe?
            var events: [String] = []
            ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == message.id { probe = $0 } }
            defer { ChatBubbleAssemblyDiagnostics.capture = nil }
            func surface(_ identity: UUID) -> some View {
                ChatTimelineRow(
                    row: MessageRowModel(index: 0, message: message, showsSenderHeader: true,
                        senderUser: peer, displaySenderName: "", timeSeparatorText: nil),
                    conversationID: "direct-ui-chat", isGroupConversation: false,
                    onLongPress: { events.append("long") }, onReadTap: { events.append("read") },
                    onSenderTap: { _ in events.append("sender") },
                    onAttachmentTap: { _ in events.append("attachment") }
                 ).appStateEnvironment(state).id(identity)
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
            let host = UIHostingController(rootView: surface(UUID()))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(nanoseconds: 150_000_000)
            let original = try XCTUnwrap(probe)
            original.onReadTap(); original.onSenderTap(peer); original.onLongPress(); original.onAttachmentTap(message)
            XCTAssertEqual(events, ["read", "sender", "long", "attachment"], transition)
            let originalContext = state.apiContext
            var next = originalContext
            switch transition {
            case "tenant": next.tenantID = "another-tenant"; state.apiContext = next
            case "logout-login": next.imToken = nil; state.apiContext = next; state.apiContext = originalContext
            case "A-B-A": next.tenantID = "another-tenant"; state.apiContext = next; state.apiContext = originalContext
            default: next.sessionEpoch = UUID().uuidString; state.apiContext = next
            }
            original.onReadTap(); original.onSenderTap(peer); original.onLongPress(); original.onAttachmentTap(message)
            XCTAssertEqual(events.count, 4, transition)
            probe = nil; host.rootView = surface(UUID())
            try await Task.sleep(nanoseconds: 150_000_000)
            let replacement = try XCTUnwrap(probe)
            XCTAssertNotEqual(replacement.presentation.actionIdentity, original.presentation.actionIdentity, transition)
            replacement.onReadTap()
            XCTAssertEqual(events, ["read", "sender", "long", "attachment", "read"], transition)
        }
    }

    @MainActor
    func testMountedBubblePresentationRefreshesReadPolicyWithoutChangingMessage() async throws {
        let state = directChatUIState(nickname: "Peer", remark: nil)
        let message = ChatMessage(
            id: "policy-row", senderId: state.currentUser.id, senderName: state.currentUser.name,
            text: "Hello", time: "", isOutgoing: true, status: .sent, kind: .text,
            reactions: [], readBy: [], unreadBy: [], readStateKnown: true, isPinned: false
        )
        var observed: [ChatBubbleAssemblyProbe] = []
        var tappedUser: IMUser?
        let initialUser = state.currentUser
        ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == message.id { observed.append($0) } }
        defer { ChatBubbleAssemblyDiagnostics.capture = nil }
        func surface(_ receipts: Bool) -> some View {
            ChatTimelineRow(
                row: MessageRowModel(index: 0, message: message, showsSenderHeader: false,
                    senderUser: nil, displaySenderName: "", timeSeparatorText: nil),
                conversationID: "direct-ui-chat", isGroupConversation: false,
                onLongPress: {}, onReadTap: {}, onSenderTap: { tappedUser = $0 }
            )
                .appStateEnvironment(state).environment(\.chatReadReceiptsEnabled, receipts)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        let host = UIHostingController(rootView: surface(true))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        let firstProbe = try XCTUnwrap(observed.last)
        let enabled = firstProbe.presentation
        XCTAssertEqual(enabled.currentUser, initialUser)
        XCTAssertTrue(enabled.readReceiptsEnabled); XCTAssertEqual(enabled.deliveryText, "未读")
        let updatedUser = initialUser.withName("Latest tap identity")
        state.setCurrentUser(updatedUser)
        firstProbe.onCurrentUserTap()
        XCTAssertEqual(tappedUser, updatedUser)
        host.rootView = surface(false)
        try await Task.sleep(nanoseconds: 150_000_000)
        let disabled = try XCTUnwrap(observed.last?.presentation)
        XCTAssertFalse(disabled.readReceiptsEnabled); XCTAssertEqual(disabled.deliveryText, "已发送")
        XCTAssertNotEqual(enabled, disabled)
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
