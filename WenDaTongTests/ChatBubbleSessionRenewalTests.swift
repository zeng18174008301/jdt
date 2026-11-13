@testable import IM4Features
import XCTest
import SwiftUI
import UIKit
import Combine
@testable import WenDaTong

// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
extension HTTPTransportTests {
    @MainActor
    func testSameMountedBubbleRebindsAfterLegitimateSameScopeRenewal() async throws {
        try await assertSameMountedBubbleRenewal(storageFailure: false)
    }

    @MainActor
    func testSameMountedBubbleRebindsGenerationWhenRenewalCannotRebindStorage() async throws {
        try await assertSameMountedBubbleRenewal(storageFailure: true)
    }

    @MainActor
    func testSameMountedBubbleKeepsActionsDuringIdentityPreservingTokenRotation() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: InMemoryProtectedSessionStore())
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let state = fixture.state
        let message = f4BubbleMessage(state: state)
        let row = f4BubbleRow(message)
        var latest: ChatBubbleAssemblyProbe?
        var events: [String] = []
        ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == message.id { latest = $0 } }
        defer { ChatBubbleAssemblyDiagnostics.capture = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 440)
        let host = UIHostingController(rootView: f4BubbleSurface(state: state, row: row) { events.append($0) })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        let original = try XCTUnwrap(latest)
        var rotated = state.apiContext; rotated.imToken = "identity-preserving-synthetic-rotation"
        state.apiContext = rotated
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(latest?.presentation.actionIdentity, original.presentation.actionIdentity)
        f4Invoke(original, message: message)
        XCTAssertEqual(events, ["read", "sender", "menu", "attachment"])
    }

    @MainActor
    private func assertSameMountedBubbleRenewal(storageFailure: Bool) async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        transport.releaseLoginResponse()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: InMemoryProtectedSessionStore())
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let state = fixture.state
        if storageFailure {
            // Owned isolated fixture only; exercise the real generation-before-await failure path.
            let support = fixture.root.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
            try Data("not-a-directory".utf8).write(to: support)
        }
        let message = f4BubbleMessage(state: state)
        let row = f4BubbleRow(message)
        var latest: ChatBubbleAssemblyProbe?
        var captures = 0
        var events: [String] = []
        var globalUpdates = 0
        let global = state.objectWillChange.sink { globalUpdates += 1 }
        defer { global.cancel() }
        ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == message.id { latest = $0; captures += 1 } }
        defer { ChatBubbleAssemblyDiagnostics.capture = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 440)
        let host = UIHostingController(rootView: f4BubbleSurface(state: state, row: row) { events.append($0) })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let hostIdentity = ObjectIdentifier(host); let viewIdentity = ObjectIdentifier(host.view)
        try await Task.sleep(nanoseconds: 150_000_000)
        let original = try XCTUnwrap(latest)
        let initialCaptures = captures
        let initialScope = state.tenantInteractionStore.snapshot.activeScope
        f4Invoke(original, message: message)
        XCTAssertEqual(events, ["read", "sender", "menu", "attachment"])
        let succeeded = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertEqual(succeeded, !storageFailure)
        XCTAssertEqual(transport.loginRequestCount, 1)
        XCTAssertEqual(try LocalMessageScope(context: state.apiContext), try LocalMessageScope(context: fixture.original))
        XCTAssertEqual(state.tenantInteractionStore.snapshot.activeScope, initialScope)
        XCTAssertGreaterThan(state.localMessageSessionGeneration, original.presentation.actionIdentity.sessionGeneration)
        if storageFailure {
            XCTAssertEqual(state.apiContext.authSessionFence, fixture.original.authSessionFence)
            XCTAssertNotNil(state.sessionReauthenticationError)
        } else {
            XCTAssertNotEqual(state.apiContext.sessionEpoch, original.presentation.actionIdentity.sessionEpoch)
            XCTAssertNotEqual(state.apiContext.authSessionFence.authoritySessionID, original.presentation.actionIdentity.authoritySessionID)
        }
        // No replacement root, .id, row/message mutation, directory update or manual refresh/rebind.
        for _ in 0..<20 {
            if latest?.presentation.actionIdentity.sessionGeneration == state.localMessageSessionGeneration,
               latest?.presentation.actionIdentity.sessionEpoch == state.apiContext.sessionEpoch,
               latest?.presentation.actionIdentity.authoritySessionID == state.apiContext.authSessionFence.authoritySessionID { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let current = try XCTUnwrap(latest)
        XCTAssertGreaterThan(captures, initialCaptures)
        XCTAssertEqual(current.presentation.actionIdentity.sessionGeneration, state.localMessageSessionGeneration)
        XCTAssertEqual(current.presentation.actionIdentity.sessionEpoch, state.apiContext.sessionEpoch)
        XCTAssertEqual(current.presentation.actionIdentity.authoritySessionID, state.apiContext.authSessionFence.authoritySessionID)
        XCTAssertEqual(current.presentation.actionIdentity.bindingGeneration, original.presentation.actionIdentity.bindingGeneration)
        XCTAssertEqual(ObjectIdentifier(host), hostIdentity); XCTAssertEqual(ObjectIdentifier(host.view), viewIdentity)
        XCTAssertEqual(row.message, message); XCTAssertEqual(globalUpdates, 0)
        f4Invoke(original, message: message)
        XCTAssertEqual(events, ["read", "sender", "menu", "attachment"])
        f4Invoke(current, message: message)
        XCTAssertEqual(events, ["read", "sender", "menu", "attachment", "read", "sender", "menu", "attachment"])
    }

    @MainActor
    private func f4BubbleMessage(state: AppState) -> ChatMessage {
        ChatMessage(id: "f4-mounted-row", senderId: state.apiContext.imUID ?? "", senderName: "Stable sender",
                    text: "Stable row", time: "", isOutgoing: true, status: .sent, kind: .image,
                    reactions: [], readBy: [], unreadBy: [], isPinned: false)
    }

    private func f4BubbleRow(_ message: ChatMessage) -> MessageRowModel {
        MessageRowModel(index: 0, message: message, showsSenderHeader: true, senderUser: nil,
                        displaySenderName: "Stable sender", timeSeparatorText: nil)
    }

    @MainActor
    private func f4BubbleSurface(state: AppState, row: MessageRowModel, event: @escaping (String) -> Void) -> some View {
        ChatTimelineRow(row: row, conversationID: "uid-1:uid-2", isGroupConversation: false,
                      onLongPress: { event("menu") }, onReadTap: { event("read") },
                      onSenderTap: { _ in event("sender") }, onAttachmentTap: { _ in event("attachment") })
            .appStateEnvironment(state)
    }

    @MainActor
    private func f4Invoke(_ probe: ChatBubbleAssemblyProbe, message: ChatMessage) {
        probe.onReadTap(); probe.onSenderTap(probe.presentation.currentUser); probe.onLongPress(); probe.onAttachmentTap(message)
    }
}
// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
