@testable import IM4Features
import XCTest
import SwiftUI
import UIKit
import Combine
@testable import WenDaTong

// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_BEGIN
@MainActor
private func hostComposerBoundaryForSimulatorUI<Content: View>(
    _ root: Content, size: CGSize
) throws -> HostedSimulatorUI<Content> {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let controller = UIHostingController(rootView: root)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: controller)
}

@MainActor
private func retireComposerBoundaryHost(
    _ hosted: HostedSimulatorUI<AnyView>, didDisappear: () -> Bool
) async throws {
    func editor(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(editor).first }
    let retiringEditor = editor(hosted.controller.view)
    hosted.controller.view.endEditing(true)
    hosted.controller.rootView = AnyView(EmptyView())
    for _ in 0..<160 {
        hosted.controller.view.layoutIfNeeded()
        if didDisappear(), retiringEditor?.isFirstResponder != true, retiringEditor?.window == nil { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(didDisappear(), "Own mounted graph must disappear before the next input fixture")
    XCTAssertFalse(retiringEditor?.isFirstResponder ?? false)
    XCTAssertNil(retiringEditor?.window)
    hosted.window.isHidden = true; hosted.window.rootViewController = nil
}

extension DomainStoreTests {
    @MainActor
    func testComposerBoundaryMountedInputSelectionMentionFailureAndBodyIsolation() async throws {
        let (state, transport, id) = try composerBoundaryFixture()
        let owner = ComposerState()
        var probe: ChatComposerInputProbe?
        var selectMention: ((IMUser) -> Void)?
        ChatComposerInputDiagnostics.capture = { if $0.conversationID == id { probe = $0 } }
        ChatComposerInputDiagnostics.mentionActions = { cid, select, _ in if cid == id { selectMention = select } }
        ChatTimelineRenderDiagnostics.reset(); ChatTimelineRenderDiagnostics.enabled = true
        var hostRetired = false
        let hosted = try hostComposerBoundaryForSimulatorUI(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: id) }
            .appStateEnvironment(state).onDisappear { hostRetired = true }), size: CGSize(width: 390, height: 850))
        defer {
            let retiringEditor = composerBoundaryEditor(hosted.controller.view)
            if let retiringEditor { composerBoundaryTrace("new-host-retire-before", editor: retiringEditor, owner: owner, host: hosted.controller) }
            hosted.controller.view.endEditing(true)
            hosted.controller.rootView = AnyView(EmptyView())
            hosted.window.isHidden = true; hosted.window.rootViewController = nil
            if let retiringEditor { composerBoundaryTrace("new-host-retire-after", editor: retiringEditor, owner: owner, host: hosted.controller) }
            composerBoundaryReset()
        }
        try await composerBoundaryWait { probe != nil && composerBoundaryEditor(hosted.controller.view) != nil }
        let editor = try XCTUnwrap(composerBoundaryEditor(hosted.controller.view))
        XCTAssertTrue(hosted.window.isKeyWindow); XCTAssertTrue(editor.window === hosted.window)
        let editorID = ObjectIdentifier(editor), hostID = ObjectIdentifier(hosted.controller)
        XCTAssertTrue(try XCTUnwrap(probe).owner === owner)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThan(ChatTimelineRenderDiagnostics.bubbleBodies, 0)
        let bubbles = ChatTimelineRenderDiagnostics.bubbleBodies, timelines = ChatTimelineRenderDiagnostics.timelineBodies
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 300_000_000)
        let inputBubbles = ChatTimelineRenderDiagnostics.bubbleBodies, inputTimelines = ChatTimelineRenderDiagnostics.timelineBodies
        for character in ["A", "😀", "B"] {
            composerBoundaryTrace("new-char-before", editor: editor, owner: owner, host: hosted.controller)
            editor.insertText(character); editor.delegate?.textViewDidChange?(editor)
            composerBoundaryTrace("new-char-after", editor: editor, owner: owner, host: hosted.controller)
            try await Task.sleep(nanoseconds: 90_000_000)
            XCTAssertEqual(ChatTimelineRenderDiagnostics.bubbleBodies, inputBubbles)
            XCTAssertEqual(ChatTimelineRenderDiagnostics.timelineBodies, inputTimelines)
        }
        XCTAssertEqual(owner.draft.input, "A😀B")
        XCTAssertTrue(probe?.input.canSend ?? false, "rendered send availability follows every draft change")
        editor.selectedRange = NSRange(location: 1, length: 2)
        editor.delegate?.textViewDidChangeSelection?(editor)
        XCTAssertEqual(owner.draft.selection, NSRange(location: 1, length: 2))
        composerBoundaryTrace("new-selection-before", editor: editor, owner: owner, host: hosted.controller)
        try XCTUnwrap(probe).insertEmoji("🚀")
        composerBoundaryTrace("new-selection-after", editor: editor, owner: owner, host: hosted.controller)
        try await composerBoundaryWait { editor.text == "A🚀B" }
        XCTAssertEqual(owner.draft.selection, NSRange(location: 3, length: 0))
        XCTAssertEqual(ObjectIdentifier(editor), editorID)
        editor.text = "Hi @"; editor.selectedRange = NSRange(location: 4, length: 0)
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertEqual(owner.draft.input, "Hi @")
        try await composerBoundaryWait { probe?.activeMentionQuery == "" }
        try await composerBoundaryWait { selectMention != nil }
        XCTAssertFalse(probe?.input.isDisabled ?? true, "mention render disabled: \(probe?.disabledReason ?? "unknown")")
        let peer = try XCTUnwrap(state.contacts.first)
        composerBoundaryTrace("new-mention-before", editor: editor, owner: owner, host: hosted.controller)
        try XCTUnwrap(selectMention)(peer)
        composerBoundaryTrace("new-mention-after", editor: editor, owner: owner, host: hosted.controller)
        try await composerBoundaryWait { editor.text == "Hi @Peer " }
        XCTAssertEqual(owner.draft.mentions.first?.imUID, peer.id)
        XCTAssertEqual(owner.draft.selection, NSRange(location: 9, length: 0))
        XCTAssertEqual(ChatTimelineRenderDiagnostics.bubbleBodies, inputBubbles)
        XCTAssertEqual(ChatTimelineRenderDiagnostics.timelineBodies, inputTimelines)
        composerBoundaryTrace("new-send-before", editor: editor, owner: owner, host: hosted.controller)
        try XCTUnwrap(probe).actions.send()
        composerBoundaryTrace("new-send-after", editor: editor, owner: owner, host: hosted.controller)
        XCTAssertEqual(owner.draft.input, "")
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.text = "next😀"; editor.selectedRange = NSRange(location: 6, length: 0)
        editor.delegate?.textViewDidChange?(editor)
        try await composerBoundaryWait { owner.draft.input == "Hi @Peer\nnext😀" && editor.text == owner.draft.input && editor.selectedRange == owner.draft.selection }
        composerBoundaryTrace("new-failure-restored", editor: editor, owner: owner, host: hosted.controller)
        XCTAssertEqual(editor.text, owner.draft.input)
        XCTAssertEqual(owner.draft.selection, NSRange(location: 15, length: 0))
        XCTAssertTrue(transport.requests().contains { $0.url?.path == "/api/im/messages" })
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(composerBoundaryEditor(hosted.controller.view))), editorID)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
        XCTAssertGreaterThanOrEqual(ChatTimelineRenderDiagnostics.bubbleBodies, bubbles)
        XCTAssertGreaterThanOrEqual(ChatTimelineRenderDiagnostics.timelineBodies, timelines)
        composerBoundaryTrace("new-host-disposal-before", editor: editor, owner: owner, host: hosted.controller)
        try await retireComposerBoundaryHost(hosted) { hostRetired }
        composerBoundaryTrace("new-host-disposal-after", editor: editor, owner: owner, host: hosted.controller)
    }

    @MainActor
    func testComposerBoundaryLiveGroupPolicyUpdatesSameEditorWithoutChangingDraft() async throws {
        let (state, _, id) = try composerBoundaryFixture()
        let owner = ComposerState()
        var probe: ChatComposerInputProbe?
        ChatComposerInputDiagnostics.capture = { if $0.conversationID == id { probe = $0 } }
        var hostRetired = false
        let hosted = try hostComposerBoundaryForSimulatorUI(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: id) }
            .appStateEnvironment(state).onDisappear { hostRetired = true }), size: CGSize(width: 390, height: 850))
        defer {
            let retiringEditor = composerBoundaryEditor(hosted.controller.view)
            if let retiringEditor { composerBoundaryTrace("new-host-retire-before", editor: retiringEditor, owner: owner, host: hosted.controller) }
            hosted.controller.view.endEditing(true)
            hosted.controller.rootView = AnyView(EmptyView())
            hosted.window.isHidden = true; hosted.window.rootViewController = nil
            if let retiringEditor { composerBoundaryTrace("new-host-retire-after", editor: retiringEditor, owner: owner, host: hosted.controller) }
            composerBoundaryReset()
        }
        try await composerBoundaryWait { probe != nil && composerBoundaryEditor(hosted.controller.view) != nil }
        let editor = try XCTUnwrap(composerBoundaryEditor(hosted.controller.view)); let editorID = ObjectIdentifier(editor)
        XCTAssertTrue(hosted.window.isKeyWindow); XCTAssertTrue(editor.window === hosted.window)
        editor.text = "policy 😀 draft"; editor.selectedRange = NSRange(location: 7, length: 2)
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertFalse(try XCTUnwrap(probe).input.isDisabled)
        let saved = owner.draft.input, selection = owner.draft.selection
        var group = try XCTUnwrap(state.groups.first)
        group.allMuted = true; group.allMuteMode = .always; group.allMuteActive = true
        state.groups = [group]
        try await composerBoundaryWait { probe?.input.isDisabled == true }
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(owner.draft.input, saved); XCTAssertEqual(owner.draft.selection, selection)
        group.allMuted = false; group.allMuteMode = .off; group.allMuteActive = false
        state.groups = [group]
        try await composerBoundaryWait { probe?.input.isDisabled == false }
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(composerBoundaryEditor(hosted.controller.view))), editorID)
        XCTAssertEqual(owner.draft.input, saved); XCTAssertEqual(owner.draft.selection, selection)
        try await retireComposerBoundaryHost(hosted) { hostRetired }
    }

    @MainActor
    func testComposerBoundaryTextEntryMatchesCurrentLegacyPixels() throws {
        for text in ["", "Input 😀"] {
            let before = hostForSimulatorUI(ComposerBoundaryPixelSurface(text: text, legacy: true), size: CGSize(width: 390, height: 100))
            let beforeImage = hostedSnapshotImage(before)
            before.window.isHidden = true; before.window.rootViewController = nil
            let after = hostForSimulatorUI(ComposerBoundaryPixelSurface(text: text, legacy: false), size: CGSize(width: 390, height: 100))
            let afterImage = hostedSnapshotImage(after)
            after.window.isHidden = true; after.window.rootViewController = nil
            let left = try composerBoundaryPixels(beforeImage), right = try composerBoundaryPixels(afterImage)
            XCTAssertEqual(left.count, right.count)
            let changed = stride(from: 0, to: min(left.count, right.count), by: 4).filter { left[$0..<$0 + 4] != right[$0..<$0 + 4] }.count
            let label = text.isEmpty ? "empty" : "typed"
            add(snapshotAttachment(beforeImage, name: "composer-input-\(label)-before"))
            add(snapshotAttachment(afterImage, name: "composer-input-\(label)-after"))
            let metric = XCTAttachment(string: "state=\(label); changed_pixels=\(changed)"); metric.name = "composer-input-\(label)-pixels"; metric.lifetime = .keepAlways; add(metric)
            XCTAssertEqual(changed, 0)
        }
    }


    @MainActor
    func testComposerBoundaryOrderedIMEThenNewInputThenIMEInSameProcess() async throws {
        let binary = Bundle(for: DomainStoreTests.self).executableURL?.path ?? "unknown"
        func step(_ name: String) {
            let attachment = XCTAttachment(string: "step=\(name); pid=\(ProcessInfo.processInfo.processIdentifier); binary=\(binary)")
            attachment.name = "composer-order-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        step("IME-before")
        try await testMountedChatComposerPreservesIMESelectionFailureDraftAndTimelineIsolation()
        step("new-input-before")
        try await testComposerBoundaryMountedInputSelectionMentionFailureAndBodyIsolation()
        step("IME-after")
        try await testMountedChatComposerPreservesIMESelectionFailureDraftAndTimelineIsolation()
        step("complete")
    }

    @MainActor
    func composerBoundaryTrace(_ stage: String, editor: UITextView, owner: ComposerState, host: UIViewController) {
        func find(_ root: UIView) -> UITextView? { (root as? UITextView) ?? root.subviews.lazy.compactMap(find).first }
        let data: [String: Any] = [
            "stage": stage, "pid": ProcessInfo.processInfo.processIdentifier, "uptime": ProcessInfo.processInfo.systemUptime,
            "host_id": String(describing: ObjectIdentifier(host)), "host_in_window": host.viewIfLoaded?.window != nil,
            "editor_id": String(describing: ObjectIdentifier(editor)), "current_editor_same": host.viewIfLoaded.flatMap(find) === editor,
            "editor_text": editor.text ?? "", "owner_text": owner.draft.input,
            "editor_selection": NSStringFromRange(editor.selectedRange), "owner_selection": NSStringFromRange(owner.draft.selection),
            "marked_text": editor.markedTextRange.flatMap { editor.text(in: $0) } ?? "",
            "has_marked_range": editor.markedTextRange != nil, "first_responder": editor.isFirstResponder,
            "editable": editor.isEditable, "editor_in_window": editor.window != nil,
            "key_window": editor.window?.isKeyWindow ?? false,
            "selected_text_range": editor.selectedTextRange.map { "\(editor.offset(from: editor.beginningOfDocument, to: $0.start)),\(editor.offset(from: editor.beginningOfDocument, to: $0.end))" } ?? "nil",
            "document_length": editor.offset(from: editor.beginningOfDocument, to: editor.endOfDocument),
            "storage_text": editor.textStorage.string, "storage_edited_range": NSStringFromRange(editor.textStorage.editedRange),
            "storage_change_length": editor.textStorage.changeInLength, "selectable": editor.isSelectable,
            "user_interaction": editor.isUserInteractionEnabled, "input_mode": editor.textInputMode?.primaryLanguage ?? "nil",
            "delegate": String(describing: editor.delegate),
            "owner_token": String(describing: owner.token)
        ]
        let attachment = XCTAttachment(string: String(data: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)!)
        attachment.name = "composer-edit-\(stage)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    // WDT_IOS1_CHAT_MOUNT_FIXTURE_ISOLATION_20261111_BEGIN
    private func composerBoundaryFixture(
        defaults injectedDefaults: UserDefaults? = nil,
        biometricAuthenticator: any LocalBiometricAuthenticating = SystemLocalBiometricAuthenticator()
    ) throws -> (AppState, ComposerBoundarySendTransport, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-boundary-\(UUID())")
        let defaults = try XCTUnwrap(injectedDefaults ?? UserDefaults(suiteName: "composer-boundary-\(UUID())"))
        let transport = ComposerBoundarySendTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)
        )
        let state = AppState(api: api,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults), realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: biometricAuthenticator, biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: makeAuthenticatedAPIContext(accountID: UUID().uuidString))
        let viewer = makeUser(id: "uid-1", name: "Viewer"), peer = makeUser(id: "uid-2", name: "Peer")
        state.replaceCurrentUserAndProject(viewer, persistIdentity: false)
        state.setAuthenticated(true)
        state.contacts = [peer]
        let id = "composer-boundary-group"
        var group = GroupInfo(id: id, name: "Boundary", notice: "", owner: "Other", members: [viewer, peer], admins: [], muted: false, allMuted: false)
        group.myRole = "member"; group.allMuteMode = .off; group.allMuteActive = false
        state.groups = [group]
        var conversation = makeConversation(id: id, kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.hasUnreadReaction = false; conversation.unreadReactionCount = 0
        conversation.participants = [viewer, peer]; conversation.messages = [makeMessage(id: "composer-boundary-row", senderId: "uid-2", seq: 1)]
        state.conversationStore.commitConversationSnapshots([conversation])
        return (state, transport, id)
    }
    // WDT_IOS1_CHAT_MOUNT_FIXTURE_ISOLATION_20261111_END

    @MainActor
    private func composerBoundaryWait(_ predicate: () -> Bool) async throws {
        for _ in 0..<160 { if predicate() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(predicate(), "Mounted composer condition did not arrive")
    }

    @MainActor
    private func composerBoundaryEditor(_ view: UIView) -> UITextView? {
        (view as? UITextView) ?? view.subviews.lazy.compactMap(composerBoundaryEditor).first
    }

    @MainActor
    private func composerBoundaryReset() {
        ChatComposerInputDiagnostics.capture = nil; ChatComposerInputDiagnostics.mentionActions = nil; ChatTimelineRenderDiagnostics.reset()
    }

    private func composerBoundaryPixels(_ image: UIImage) throws -> Data {
        let cg = try XCTUnwrap(image.cgImage); var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return data
    }
}

extension HTTPTransportTests {
    @MainActor
    func testComposerBoundarySameHostReauthenticationRetiresOnlyOldActions() async throws {
        let transport = ComposerBoundaryLoginTransport(login: try sessionReauthenticationLoginResult())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-boundary-reauth-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "composer-boundary-reauth-\(UUID())"))
        let context = makeRefreshableMessageSendContext(), protected = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(defaults: defaults, sessionStore: protected).isCommitted)
        let state = AppState(api: makeClient(transport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults), realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricDefaults: defaults, rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults), protectedSessionStore: protected, apiContextOverride: context)
        state.setAuthenticated(true)
        let id = "uid-1:uid-2", owner = ComposerState()
        state.conversationStore.commitConversationSnapshots([makeDirectConversation(id: id)])
        var latest: ChatComposerInputProbe?
        ChatComposerInputDiagnostics.capture = { if $0.conversationID == id { latest = $0 } }
        var hostRetired = false
        let hosted = try hostComposerBoundaryForSimulatorUI(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: id) }.appStateEnvironment(state).onDisappear { hostRetired = true }), size: CGSize(width: 390, height: 850))
        defer { hosted.controller.view.endEditing(true); hosted.controller.rootView = AnyView(EmptyView()); hosted.window.isHidden = true; hosted.window.rootViewController = nil; ChatComposerInputDiagnostics.capture = nil }
        for _ in 0..<120 { if latest != nil { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        owner.draft.input = "current draft"
        try await Task.sleep(nanoseconds: 150_000_000)
        let original = try XCTUnwrap(latest), hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        state.beginSessionReauthentication()
        let succeeded = await state.reauthenticateCurrentSession(identifier: "member1", password: "SyntheticPass123!", enterpriseCode: "")
        XCTAssertTrue(succeeded)
        for _ in 0..<120 { if latest?.origin == state.chatBubbleSessionIdentity { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let current = try XCTUnwrap(latest)
        XCTAssertNotEqual(current.origin, original.origin)
        XCTAssertTrue(current.owner === owner)
        XCTAssertEqual(owner.draft.input, "current draft")
        original.actions.toggleTools(); original.actions.toggleEmoji(); original.actions.send()
        XCTAssertFalse(owner.draft.showTools); XCTAssertFalse(owner.draft.showEmoji)
        XCTAssertEqual(owner.draft.input, "current draft"); XCTAssertEqual(transport.sendCount, 0)
        current.actions.toggleTools(); XCTAssertTrue(owner.draft.showTools)
        current.actions.toggleTools(); XCTAssertFalse(owner.draft.showTools)
        current.actions.send()
        for _ in 0..<120 { if transport.sendCount == 1 { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(transport.sendCount, 1)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        try await retireComposerBoundaryHost(hosted) { hostRetired }
    }
}


private final class ComposerBoundarySendTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    func requests() -> [URLRequest] { lock.withLock { recorded } }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock { recorded.append(request) }
        if request.url?.path == "/api/im/messages" {
            try await Task.sleep(nanoseconds: 350_000_000)
            return HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"group_muted","message":"全员禁言"}}"#.utf8), isHTTPResponse: true, statusCode: 403)
        }
        return HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"service_unavailable","message":"isolated fixture"}}"#.utf8), isHTTPResponse: true, statusCode: 503)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        try await self.data(for: request)
    }
}

private final class ComposerBoundaryLoginTransport: HTTPTransport, @unchecked Sendable {
    private let login: RememberedLoginGateHTTPTransport
    private let lock = NSLock(); private var sends = 0
    var sendCount: Int { lock.withLock { sends } }
    init(login result: HTTPTransportResult) { login = RememberedLoginGateHTTPTransport(loginResult: result); login.releaseLoginResponse() }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path == "/api/im/messages" {
            lock.withLock { sends += 1 }
            return HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"group_muted","message":"全员禁言"}}"#.utf8), isHTTPResponse: true, statusCode: 403)
        }
        return try await login.data(for: request)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        try await login.upload(for: request, from: data, delegate: delegate)
    }
}

private struct ComposerBoundaryPixelSurface: View {
    @State var text: String
    let legacy: Bool
    @State private var height: CGFloat = 42
    @State private var selection = NSRange(location: 0, length: 0)
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(IMColor.brand).frame(width: 38, height: 38)
            if legacy {
                legacyChildren
            } else {
                ChatComposerTextEntry(input: .init(isDisabled: false, canSend: containsSendableMessageContent(text)), text: $text, dynamicHeight: $height, selection: $selection,
                    actions: .init(toggleEmoji: {}, toggleTools: {}, send: {}, onBeginEditing: {}, onEditingChanged: { _ in }))
            }
        }.padding(.horizontal, 14).background(Color.white)
    }
    @ViewBuilder private var legacyChildren: some View {
        Button {} label: { Image(systemName: "face.smiling").font(.system(size: 20, weight: .semibold)).foregroundStyle(IMColor.brand).frame(width: 38, height: 38) }.accessibilityIdentifier("chat_emoji_toggle_button")
        ComposerInputBox(text: $text, dynamicHeight: $height, selection: $selection, isDisabled: false, onBeginEditing: {}, onEditingChanged: { _ in }).disabled(false).accessibilityIdentifier("chat_message_input")
        Button {} label: { Image(systemName: "plus.circle.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(IMColor.brand).frame(width: 38, height: 38) }.accessibilityIdentifier("chat_tools_toggle_button")
        Button {} label: { Image(systemName: "paperplane.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 38, height: 38).background(Circle().fill(!containsSendableMessageContent(text) ? Color(hex: 0xB9C0D6) : IMColor.brand)) }.disabled(!containsSendableMessageContent(text)).accessibilityIdentifier("chat_send_button")
    }
}
// WDT_IOS1_COMPOSER_INPUT_BOUNDARY_20261110_END

// WDT_IOS1_VOICE_PREVIEW_ACTUAL_FACTORY_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testComposerVoicePreviewUsesOriginalOwnerAndLiveValueInputThroughActualFactory() async throws {
        let (state, _, id) = try composerBoundaryFixture()
        var composer: ChatComposerInputProbe?
        var rendered: VoiceRecordingPreviewProbe?
        var disappeared = false
        let oldInputProbe = ChatComposerInputDiagnostics.capture
        let oldPreviewProbe = VoiceRecordingPreviewDiagnostics.render
        ChatComposerInputDiagnostics.capture = { if $0.conversationID == id { composer = $0 } }
        VoiceRecordingPreviewDiagnostics.render = { rendered = $0 }
        defer {
            ChatComposerInputDiagnostics.capture = oldInputProbe
            VoiceRecordingPreviewDiagnostics.render = oldPreviewProbe
        }
        let root = AnyView(NavigationStackCompat { ChatView(conversationID: id) }
            .appStateEnvironment(state).onDisappear { disappeared = true })
        let hosted = try hostComposerBoundaryForSimulatorUI(root, size: CGSize(width: 390, height: 760))
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        try await composerBoundaryWait { composer != nil }
        let initial = try XCTUnwrap(composer)
        XCTAssertFalse(initial.input.isDisabled)
        let previewOwner = initial.composer.voicePreview
        let recorderOwner = initial.composer.voiceRecorder
        initial.composer.toggleVoiceInputMode()
        previewOwner.setRecording(voiceBoundaryRecording(seconds: 2))
        try await composerBoundaryWait { rendered?.input.durationMS == 2_000 }
        let first = try XCTUnwrap(rendered)
        XCTAssertEqual(first.input.waveform, [0, 2, 4, 2, 0])
        XCTAssertFalse(first.input.isPlaying)
        XCTAssertEqual(first.input.progress, 0)
        XCTAssertEqual(first.input.remainingLabel, previewOwner.playbackState?.remainingLabel)
        XCTAssertTrue(composer?.composer.voicePreview === previewOwner)
        XCTAssertTrue(composer?.composer.voiceRecorder === recorderOwner)
        hosted.controller.view.layoutIfNeeded()
        let firstImage = hostedSnapshotImage(hosted)
        add(snapshotAttachment(firstImage, name: "voice-preview-original-owner-two-seconds"))
        previewOwner.setRecording(voiceBoundaryRecording(seconds: 4))
        try await composerBoundaryWait { rendered?.input.durationMS == 4_000 }
        hosted.controller.view.layoutIfNeeded()
        let updatedImage = hostedSnapshotImage(hosted)
        add(snapshotAttachment(updatedImage, name: "voice-preview-same-owner-four-seconds"))
        XCTAssertNotEqual(firstImage.pngData(), updatedImage.pngData())
        XCTAssertTrue(composer?.composer.voicePreview === previewOwner)
        try XCTUnwrap(rendered).cancel()
        try await composerBoundaryWait { previewOwner.recording == nil }
        XCTAssertTrue(composer?.composer.voiceRecorder === recorderOwner)
        try await retireComposerBoundaryHost(hosted, didDisappear: { disappeared })
    }

    private func voiceBoundaryRecording(seconds: Int) -> VoiceMessageRecording {
        let byteCount = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func appendLE(_ value: Int, width: Int) {
            for shift in stride(from: 0, to: width * 8, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        appendLE(byteCount + 36, width: 4); data.append(Data("WAVEfmt ".utf8))
        appendLE(16, width: 4); appendLE(1, width: 2); appendLE(1, width: 2)
        appendLE(8_000, width: 4); appendLE(16_000, width: 4)
        appendLE(2, width: 2); appendLE(16, width: 2)
        data.append(Data("data".utf8)); appendLE(byteCount, width: 4)
        data.append(Data(repeating: 0, count: byteCount))
        return VoiceMessageRecording(data: data, name: "preview-fixture.wav", mimeType: "audio/wav",
            sizeBytes: Int64(data.count), durationMS: seconds * 1_000, waveform: [0, 2, 4, 2, 0])
    }
}
// WDT_IOS1_VOICE_PREVIEW_ACTUAL_FACTORY_20261111_END

// WDT_IOS1_INPUT100_REUSE_ORIGINAL_SCENE_HOST_20261111_BEGIN
@MainActor
func input100HostUsingOriginalComposerBoundary<Content: View>(
    _ root: Content, size: CGSize
) throws -> HostedSimulatorUI<Content> {
    try hostComposerBoundaryForSimulatorUI(root, size: size)
}
// WDT_IOS1_INPUT100_REUSE_ORIGINAL_SCENE_HOST_20261111_END


extension DomainStoreTests {
    @MainActor
    func testComposerKeyboardAvoidanceKeepsLatestFocusDuringRapidResponderChanges() async throws {
        try input100CaptureActualLoadedImages(self, phase: "keyboard-lifecycle-event-publication")
        let (state, _, id) = try composerBoundaryFixture()
        var captured: ChatView?
        ChatTimelineRenderDiagnostics.chatBody = { if $0.conversationID == id { captured = $0 } }
        let hosted = try hostComposerBoundaryForSimulatorUI(AnyView(ChatView(conversationID: id)
            .appStateEnvironment(state)), size: CGSize(width: 390, height: 850))
        defer {
            hosted.controller.view.endEditing(true)
            hosted.window.isHidden = true; hosted.window.rootViewController = nil
            ChatTimelineRenderDiagnostics.reset()
        }
        try await composerBoundaryWait { captured != nil && composerBoundaryEditor(hosted.controller.view) != nil }
        let current = try XCTUnwrap(captured), owner = current.presentation
        let editor = try XCTUnwrap(composerBoundaryEditor(hosted.controller.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        try await composerBoundaryWait { owner.isComposerEditing }
        var insideResponderChange = false, inlineFlagPublications = 0
        let observation = owner.$isComposerEditing.dropFirst().sink { _ in
            if insideResponderChange { inlineFlagPublications += 1 }
        }
        defer { observation.cancel() }
        insideResponderChange = true
        XCTAssertTrue(editor.resignFirstResponder())
        XCTAssertTrue(editor.becomeFirstResponder())
        insideResponderChange = false
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(inlineFlagPublications, 0)
        XCTAssertTrue(owner.isComposerEditing)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(try XCTUnwrap(captured).presentation === owner)
        XCTAssertTrue(composerBoundaryEditor(hosted.controller.view) === editor)
        XCTAssertTrue(editor.resignFirstResponder())
        try await composerBoundaryWait { !owner.isComposerEditing }
        XCTAssertFalse(owner.isComposerEditing)
    }
}


// WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testActualChatRouteMountsComposerOnlyWhileAuthorized() async throws {
        let suite = "chat-protected-route-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authenticator = RecordingBiometricAuthenticator()
        let (state, _, id) = try composerBoundaryFixture(defaults: defaults, biometricAuthenticator: authenticator)
        let locked = BiometricProtectionSettings(enabled: true, unlockChats: true, previewFiles: false)
        state.biometricAccessStore.replaceSettings(locked)
        let hosted = try hostComposerBoundaryForSimulatorUI(
            NavigationStackCompat { AppFeatureComposition.chatRouting().makeChat(id) }
                .appStateEnvironment(state),
            size: CGSize(width: 390, height: 760)
        )
        defer {
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(composerBoundaryEditor(hosted.controller.view))

        let authorized = await state.authorizeProtectedAccess(.chat)
        XCTAssertTrue(authorized)
        XCTAssertEqual(authenticator.requestCount, 1)
        try await composerBoundaryWait { self.composerBoundaryEditor(hosted.controller.view) != nil }

        state.biometricAccessStore.revokeGrants()
        try await composerBoundaryWait { self.composerBoundaryEditor(hosted.controller.view) == nil }
    }
}
// WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_END


// WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testActualChatDeletionConfirmationsCancelAndRejectRetiredActions() async throws {
        let suite = "chat-deletion-route-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (state, transport, id) = try composerBoundaryFixture(defaults: defaults)
        state.groups[0].myRole = "admin"
        state.applyFileUploadConfig(FileUploadConfig(
            maxBytes: 20 * 1024 * 1024, maxMB: 20, source: "test", messageRecallMaxMinutes: 120,
            voiceCallEnabled: false, videoCallEnabled: false, readReceiptsEnabled: true,
            groupAdminDeleteMessageEnabled: true
        ))
        var conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshot(id: id))
        let sent = try XCTUnwrap(conversation.messages.first)
        let failed = makeMessage(id: "failed-current", senderId: "uid-1", seq: 0, status: .failed, isOutgoing: true)
        let retainedFailed = makeMessage(id: "failed-retired", senderId: "uid-1", seq: 0, status: .failed, isOutgoing: true)
        conversation.messages += [failed, retainedFailed]
        state.conversationStore.commitConversationSnapshots([conversation])
        XCTAssertTrue(state.canAdminDeleteMessage(sent, in: id))
        XCTAssertTrue(state.isCurrentMessageSender(failed.senderId))
        let adminPath = "/api/im/groups/\(state.remoteChannelID(for: conversation))/messages/\(sent.id)/admin-delete"
        func adminRequests() -> Int {
            transport.requests().filter { $0.httpMethod == "POST" && $0.url?.path == adminPath }.count
        }
        func contains(_ message: ChatMessage) -> Bool {
            state.conversationStore.conversationMessageSnapshot(id: id)?.messages.contains { $0.id == message.id } == true
        }

        var mounted: ChatView?
        let oldProbe = ChatTimelineRenderDiagnostics.chatBody
        ChatTimelineRenderDiagnostics.chatBody = { if $0.conversationID == id { mounted = $0 } }
        defer { ChatTimelineRenderDiagnostics.chatBody = oldProbe }
        let hosted = try hostComposerBoundaryForSimulatorUI(
            NavigationStackCompat { AppFeatureComposition.chatRouting().makeChat(id) }
                .appStateEnvironment(state), size: CGSize(width: 390, height: 760)
        )
        defer {
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
        }
        try await composerBoundaryWait { mounted != nil && self.composerBoundaryEditor(hosted.controller.view) != nil }
        let chat = try XCTUnwrap(mounted)

        chat.adminDeleteCandidate = sent
        chat.chatDeletionAlerts.cancelAdminDeletion()
        XCTAssertNil(chat.adminDeleteCandidate)
        XCTAssertEqual(adminRequests(), 0)
        chat.failedDeleteCandidate = failed
        chat.chatDeletionAlerts.cancelFailedDeletion()
        XCTAssertNil(chat.failedDeleteCandidate)
        XCTAssertTrue(contains(failed))

        chat.adminDeleteCandidate = sent
        chat.chatDeletionAlerts.confirmAdminDeletion()
        XCTAssertNil(chat.adminDeleteCandidate)
        try await composerBoundaryWait { adminRequests() == 1 }
        chat.failedDeleteCandidate = failed
        chat.chatDeletionAlerts.confirmFailedDeletion(failed)
        XCTAssertNil(chat.failedDeleteCandidate)
        try await composerBoundaryWait { !contains(failed) }

        let retired = chat.chatDeletionAlerts
        let originalIdentity = state.chatBubbleSessionIdentity
        state.localMessageSessionGeneration &+= 1
        XCTAssertNotEqual(state.chatBubbleSessionIdentity, originalIdentity)
        chat.adminDeleteCandidate = sent
        retired.confirmAdminDeletion()
        chat.failedDeleteCandidate = retainedFailed
        retired.confirmFailedDeletion(retainedFailed)
        XCTAssertNil(chat.adminDeleteCandidate)
        XCTAssertNil(chat.failedDeleteCandidate)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(adminRequests(), 1)
        XCTAssertTrue(contains(retainedFailed))
    }
}
// WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_END

// WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_BEGIN
extension DomainStoreTests {
    @MainActor
    func testMountedChatContactCardKeepsReferencePixelsAndLiveDirectory() async throws {
        let suite = "chat-contact-card-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (state, _, _) = try composerBoundaryFixture(defaults: defaults)
        let peer = try XCTUnwrap(state.contacts.first)
        var message = makeMessage(id: "contact-card-render", seq: 1, text: "个人名片：Fallback", kind: .contactCard)
        message.attachmentMeta = peer.userID

        func host<Content: View>(_ content: Content) throws -> HostedSimulatorUI<AnyView> {
            let root = ContactDirectoryPresentationView(store: state.contactStore) { content }
                .appStateEnvironment(state)
                .frame(width: 300, height: 100)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            return try hostComposerBoundaryForSimulatorUI(AnyView(root), size: CGSize(width: 320, height: 120))
        }
        func pixels(_ hosted: HostedSimulatorUI<AnyView>) async throws -> Data {
            try await Task.sleep(nanoseconds: 150_000_000)
            hosted.controller.view.layoutIfNeeded()
            return try XCTUnwrap(hostedSnapshotImage(hosted).pngData())
        }

        let reference = try host(ContactCardPresentationContent(
            contact: peer, displayContact: peer, contactID: peer.userID, outgoing: false, onOpen: { _ in }
        ))
        defer { reference.window.isHidden = true; reference.window.rootViewController = nil }
        let expected = try await pixels(reference)
        reference.window.isHidden = true
        reference.window.rootViewController = nil

        let actual = try host(ContactCardBubbleContent(message: message, outgoing: false) { _ in })
        defer { actual.window.isHidden = true; actual.window.rootViewController = nil }
        let initial = try await pixels(actual)
        XCTAssertEqual(initial, expected)
        state.contactStore.contacts = [peer.withName("Updated contact")]
        let updated = try await pixels(actual)
        XCTAssertNotEqual(updated, initial)
        state.contactStore.contacts = [peer]
        let restored = try await pixels(actual)
        XCTAssertEqual(restored, initial)
    }
}
// WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_END
