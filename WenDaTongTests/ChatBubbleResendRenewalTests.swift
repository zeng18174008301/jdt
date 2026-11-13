@testable import IM4Features
// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
extension HTTPTransportTests {
    @MainActor
    func testSameMountedBubbleRenewalRefreshesActualResend() async throws {
        let transport = F4ResendTransport(loginResult: try sessionReauthenticationLoginResult())
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: InMemoryProtectedSessionStore())
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let state = fixture.state
        let conversationID = "uid-1:uid-2"
        let message = ChatMessage(id: "f4-resend-row", senderId: "uid-1", senderName: "Stable sender",
                                  text: "Stable resend text", time: "", isOutgoing: true, status: .failed,
                                  kind: .text, reactions: [], readBy: [], unreadBy: [], canViewReadDetails: false, isPinned: false)
        var conversation = makeDirectConversation(id: conversationID); conversation.messages = [message]
        state.conversationStore.commitConversationSnapshots([conversation])
        let row = MessageRowModel(index: 0, message: message, showsSenderHeader: false,
                                  senderUser: nil, displaySenderName: "Stable sender", timeSeparatorText: nil)
        var latest: ChatBubbleAssemblyProbe?
        ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == message.id { latest = $0 } }
        defer { ChatBubbleAssemblyDiagnostics.capture = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        let host = UIHostingController(rootView: ChatTimelineRow(row: row, conversationID: conversationID, isGroupConversation: false,
                                                             onLongPress: {}, onReadTap: {}).appStateEnvironment(state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let hostIdentity = ObjectIdentifier(host); let viewIdentity = ObjectIdentifier(host.view)
        try await Task.sleep(nanoseconds: 150_000_000)
        let original = try XCTUnwrap(latest)
        let succeeded = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertTrue(succeeded)
        for _ in 0..<20 {
            if latest?.presentation.actionIdentity.sessionEpoch == state.apiContext.sessionEpoch { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let current = try XCTUnwrap(latest)
        XCTAssertEqual(current.presentation.actionIdentity.bindingGeneration, original.presentation.actionIdentity.bindingGeneration)
        XCTAssertEqual(current.presentation.actionIdentity.sessionEpoch, state.apiContext.sessionEpoch)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first, message)
        original.onResend()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sendRequests, 0)
        current.onResend()
        for _ in 0..<100 {
            if transport.sendRequests == 1,
               state.conversationStore.conversationMessageSnapshot(id: conversationID)?.messages.first?.status == .failed { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(transport.sendRequests, 1)
        XCTAssertEqual(ObjectIdentifier(host), hostIdentity); XCTAssertEqual(ObjectIdentifier(host.view), viewIdentity)
        XCTAssertEqual(row.message, message)
    }
}

private final class F4ResendTransport: HTTPTransport, @unchecked Sendable {
    private let login: RememberedLoginGateHTTPTransport
    private let lock = NSLock()
    private var count = 0
    var sendRequests: Int { lock.withLock { count } }

    init(loginResult: HTTPTransportResult) {
        login = RememberedLoginGateHTTPTransport(loginResult: loginResult)
        login.releaseLoginResponse()
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path == "/api/im/messages" {
            lock.withLock { count += 1 }
            return HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"synthetic_send_rejected","message":"Synthetic send rejected"}}"#.utf8),
                                       isHTTPResponse: true, statusCode: 400)
        }
        return try await login.data(for: request)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        try await login.upload(for: request, from: data, delegate: delegate)
    }
}
// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END

// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END
