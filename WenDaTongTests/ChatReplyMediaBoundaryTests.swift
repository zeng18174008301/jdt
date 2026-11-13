@testable import IM4Features
// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
import XCTest
import SwiftUI
import UIKit
import Combine
@testable import IM4Domain // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
@testable import WenDaTong

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
extension IdentityPresentationTests {
    private func boundaryMessage(_ id: String, kind: MessageKind = .text, outgoing: Bool = false) -> ChatMessage {
        ChatMessage(id: id, senderId: outgoing ? "viewer-ui" : "peer-ui", senderName: outgoing ? "当前成员" : "Peer",
                    text: "原消息", time: "", isOutgoing: outgoing, status: .sent, kind: kind,
                    reactions: [], readBy: [], unreadBy: [], isPinned: false)
    }

    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
    @MainActor
    func testMountedReplyBoundaryTracksSourcePolicyDirectoryRoleAndMessageOnlyChanges() async throws {
        let state = groupChatUIState(role: "member", active: false, repairRequired: false)
        state.storeCancellables.removeAll()
        let peer = makeRemarkContractUser(id: "peer-ui", userID: "PEER-UI", name: "Peer")
        state.contacts = [peer]; state.groups[0].members.append(peer)
        let store = state.conversationStore
        let conversationID = try XCTUnwrap(store.conversations.first?.id)
        let lookup = ChatReplySourceLookup()
        var source = boundaryMessage("source"); source.channelSeq = 42
        var reply = boundaryMessage("reply"); reply.text = "回复正文"
        reply.replyContext = MessageReplyContext(messageID: source.id, senderID: peer.id, senderName: "Peer", summary: "旧引用", channelSeq: 42)
        var initial = store.conversationMessageSnapshot(at: 0); initial.messages = [source, reply]
        store.commitConversationSnapshot(initial, at: 0)
        state.tenantInteractionStore.snapshot.policyScope = state.tenantInteractionStore.snapshot.activeScope ?? ""
        var rendered: [ReplyQuotePresentation] = []
        var visible: [Bool] = []
        var roles: [ChatSenderGroupRole?] = []
        ChatReplyAssemblyDiagnostics.capture = { rendered.append($0) }
        ChatReplyAssemblyDiagnostics.resolution = { if $0 == reply.id { visible.append($1) } }
        ChatBubbleAssemblyDiagnostics.capture = { if $0.messageID == reply.id { roles.append($0.presentation.senderGroupRole) } }
        defer { ChatReplyAssemblyDiagnostics.capture = nil; ChatReplyAssemblyDiagnostics.resolution = nil; ChatBubbleAssemblyDiagnostics.capture = nil }
        let surface = state.tenantInteractionStore.observe(\.showsProcessingNotices) { notices in
            ContactDirectoryPresentationView(store: state.contactStore) {
                store.observeConversationPresentation(id: conversationID) { current in
                    if let current, let latestReply = current.messages.first(where: { $0.id == reply.id }) {
                        ChatTimelineRow(
                            row: MessageRowModel(index: 0, message: latestReply, showsSenderHeader: true,
                                senderUser: peer, displaySenderName: "", timeSeparatorText: nil),
                            conversationID: conversationID, isGroupConversation: true, onLongPress: {}, onReadTap: {}
                        )
                            .chatTranscriptConversation(current, replyLookup: lookup)
                            .environment(\.chatShowsMessageProcessingNotices, notices)
                    }
                }
            }
        }.appStateEnvironment(state)
        try await withMountedConversationSurface(surface) { snapshot in
            _ = try await snapshot(); XCTAssertEqual(rendered.last?.summary, "原消息")
            do { var updated = store.conversationMessageSnapshot(at: 0); updated.messages[0].text = "编辑后的原消息"; store.commitConversationSnapshot(updated, at: 0) }
            _ = try await snapshot(); XCTAssertEqual(rendered.last?.summary, "编辑后的原消息")
            state.contactStore.remarks = [peer.userID: "私有备注"]
            _ = try await snapshot(); XCTAssertEqual(rendered.last?.sender, "私有备注")
            state.groups[0].admins = [peer]
            _ = try await snapshot(); XCTAssertEqual(roles.last ?? nil, .admin); XCTAssertEqual(rendered.last?.summary, "编辑后的原消息")
            do { var updated = store.conversationMessageSnapshot(at: 0); updated.messages[0].status = .recalled; store.commitConversationSnapshot(updated, at: 0) }
            _ = try await snapshot(); XCTAssertEqual(rendered.last?.summary, "原消息不可见/已删除"); XCTAssertEqual(visible.last, true)
            state.tenantInteractionStore.snapshot.rules.processingNoticeEnabled = false
            _ = try await snapshot(); XCTAssertEqual(visible.last, false)
            state.tenantInteractionStore.snapshot.rules.processingNoticeEnabled = true
            _ = try await snapshot(); XCTAssertEqual(visible.last, true)
            // Message-only context changes must not wait for a source-row mutation.
            do { var updated = store.conversationMessageSnapshot(at: 0); updated.messages[1].replyContext = MessageReplyContext(messageID: "missing", senderID: "missing-user", senderName: "仅消息更新的发送者", summary: "仅消息更新的引用"); store.commitConversationSnapshot(updated, at: 0) }
            _ = try await snapshot(); XCTAssertEqual(rendered.last?.summary, "仅消息更新的引用"); XCTAssertEqual(rendered.last?.sender, "仅消息更新的发送者")
            let count = rendered.count
            let other = ConversationMessageSnapshot(id: "other-conversation", title: "Other", subtitle: "", kind: .direct, lastMessage: "", time: "", unread: 0, isPinned: false, isMuted: false, memberCount: nil, accentHex: 0, participants: [], messages: [])
            store.commitConversationSnapshots(store.conversationMessageSnapshots() + [other])
            _ = try await snapshot(); XCTAssertEqual(rendered.count, count)
        }
    }
    // WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END

    @MainActor
    func testMountedVoiceBoundaryObservesOnlyMatchingPlaybackAndDownloadAndRunsCancelCleanup() async throws {
        let state = directChatUIState(nickname: "Peer", remark: nil)
        state.storeCancellables.removeAll()
        let a = boundaryMessage("voice-a", kind: .voice)
        let b = boundaryMessage("voice-b", kind: .voice)
        var probes: [String: ChatVoiceAssemblyProbe] = [:]
        var counts: [String: Int] = [:]
        ChatMediaAssemblyDiagnostics.voice = { probes[$0.messageID] = $0; counts[$0.messageID, default: 0] += 1 }
        defer { ChatMediaAssemblyDiagnostics.voice = nil }
        let surface = VStack {
            VoiceBubbleContent(message: a, outgoing: false, conversationID: "direct-ui-chat")
            VoiceBubbleContent(message: b, outgoing: false, conversationID: "direct-ui-chat")
        }.appStateEnvironment(state)
        try await withMountedConversationSurface(surface) { snapshot in
            _ = try await snapshot(); let bCount = counts[b.id]
            state.voiceMessagePlaybackStore.playingMessageID = a.id
            state.voiceMessagePlaybackStore.state = VoiceMessagePlaybackState(messageID: a.id, elapsedMS: 1_000, durationMS: 4_000, isPlaying: true)
            _ = try await snapshot(); XCTAssertEqual(probes[a.id]?.presentation.playbackState?.remainingMS, 3_000)
            XCTAssertTrue(try XCTUnwrap(probes[a.id]).presentation.isPlaying); XCTAssertEqual(counts[b.id], bCount)
            let key = state.attachmentProgressKey(for: a); let token = UUID()
            let task = Task<URL, Error> { try await Task.sleep(nanoseconds: 30_000_000_000); return URL(fileURLWithPath: "/never-used") }
            defer { task.cancel(); state.fileStore.cancelAttachmentDownloadTask(attachmentID: key) }
            state.fileStore.replaceAttachmentDownloadTask(attachmentID: key, with: task, token: token)
            state.fileStore.setAttachmentDownloadSnapshot(.init(receivedBytes: 250, totalBytes: 1_000), attachmentID: key, token: token)
            _ = try await snapshot(); XCTAssertEqual(probes[a.id]?.presentation.download?.receivedBytes, 250); XCTAssertEqual(counts[b.id], bCount)
            try XCTUnwrap(probes[a.id]).onCancelDownload()
            XCTAssertFalse(state.fileStore.hasAttachmentDownloadTask(attachmentID: key)); XCTAssertTrue(task.isCancelled)
            state.voiceMessagePlayerMessageID = a.id
            try XCTUnwrap(probes[a.id]).onDisappear()
            XCTAssertNil(state.voiceMessagePlaybackStore.playingMessageID); XCTAssertNil(state.voiceMessagePlaybackStore.state)
        }
    }

    @MainActor
    func testVoiceBoundaryRetainedCleanupPreservesNormalRotationAndRejectsRetiredLoginBinding() async throws {
        for transition in ["normal-token", "same-scope-reauth", "tenant", "logout-login", "A-B-A"] {
            let state = directChatUIState(nickname: "Peer", remark: nil)
            let message = boundaryMessage("retained-voice", kind: .voice)
            var probe: ChatVoiceAssemblyProbe?
            ChatMediaAssemblyDiagnostics.voice = { if $0.messageID == message.id { probe = $0 } }
            defer { ChatMediaAssemblyDiagnostics.voice = nil }
            try await withMountedConversationSurface(VoiceBubbleContent(message: message, outgoing: false, conversationID: "direct-ui-chat").appStateEnvironment(state)) { snapshot in
                _ = try await snapshot(); let original = try XCTUnwrap(probe)
                let previous = state.apiContext; var next = previous
                switch transition {
                case "normal-token": next.imToken = "rotated-synthetic-token"; state.apiContext = next
                case "same-scope-reauth": next.sessionEpoch = UUID().uuidString; state.apiContext = next
                case "tenant": next.tenantID = "other-tenant"; state.apiContext = next
                case "logout-login": next.imToken = nil; state.apiContext = next; state.apiContext = previous
                default: next.tenantID = "other-tenant"; state.apiContext = next; state.apiContext = previous
                }
                state.voiceMessagePlayerMessageID = message.id
                state.voiceMessagePlaybackStore.playingMessageID = message.id
                state.voiceMessagePlaybackStore.state = .init(messageID: message.id, elapsedMS: 100, durationMS: 1_000, isPlaying: true)
                original.onDisappear()
                if transition == "normal-token" || transition == "same-scope-reauth" {
                    XCTAssertNil(state.voiceMessagePlaybackStore.playingMessageID, transition)
                } else {
                    XCTAssertEqual(state.voiceMessagePlaybackStore.playingMessageID, message.id, transition)
                }
                state.stopVoiceMessagePlayback()
            }
        }
    }

    @MainActor
    func testMountedGIFAssemblyKeepsLocalOriginalPriorityAndRejectsMessageOnlyRecall() async throws {
        // WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111_BEGIN
        let suite = "mounted-gif-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (state, scope, media) = try mountedGIFState(suite: suite, root: root, defaults: defaults)
        let file = root.appendingPathComponent("original.gif")
        // WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111_END
        var message = boundaryMessage("gif", kind: .image)
        message.attachmentMimeType = "image/gif"; message.attachmentName = "original.gif"; message.attachmentSizeBytes = 43
        message.attachmentDownloadAvailable = true; message.attachmentPreviewAvailable = true
        try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")).write(to: file)
        var presentations: [AttachmentGIFRenderPresentation] = []
        ChatMediaAssemblyDiagnostics.gif = { if $0 == message.id { presentations.append($1) } }
        defer { ChatMediaAssemblyDiagnostics.gif = nil }
        func surface(_ value: ChatMessage) -> some View {
            AttachmentGIFImage(message: value, conversationID: "direct-ui-chat", localURL: file) { Text("GIF占位") }
                .frame(width: 100, height: 100).appStateEnvironment(state)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let host = UIHostingController(rootView: surface(message)); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(presentations.last?.url, file); XCTAssertEqual(presentations.last?.canPlay, true)
        XCTAssertTrue(try XCTUnwrap(presentations.last).cacheKey.contains("|original-gif|gif|"))
        // WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111_BEGIN
        XCTAssertEqual(presentations.last?.cacheKey,
            "\(scope.scopeHash)|\(media.sessionGeneration)|original-gif|\(message.id)|\(message.attachmentVersion)|\(message.attachmentChecksum)")
        XCTAssertEqual(presentations.last?.playbackPriority, true)
        // WDT_IOS1_CHAT_GIF_MOUNT_FIXTURE_ISOLATION_20261111_END
        message.status = .recalled; host.rootView = surface(message)
        try await Task.sleep(nanoseconds: 150_000_000); XCTAssertEqual(presentations.last?.canPlay, false); XCTAssertNil(presentations.last?.url)
    }

    // WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111_BEGIN
    @MainActor
    func testMountedGIFActionAndFullscreenPreviewKeepLocalURLAndRejectRecall() async throws {
        let suite = "mounted-gif-entries-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (state, _, _) = try mountedGIFState(suite: suite, root: root, defaults: defaults)
        let file = root.appendingPathComponent("original.gif")
        let fallback = root.appendingPathComponent("fallback.gif")
        let bytes = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try bytes.write(to: file)
        try bytes.write(to: fallback)
        var message = boundaryMessage("gif-preview-entries", kind: .image)
        message.attachmentMimeType = "image/gif"
        message.attachmentName = "original.gif"
        message.attachmentSizeBytes = Int64(bytes.count)
        message.attachmentDownloadAvailable = true
        message.attachmentPreviewAvailable = true
        message.attachmentDownloadURL = file.absoluteString
        message.attachmentPreviewURL = fallback.absoluteString
        let messageID = message.id
        var gif: AttachmentGIFRenderPresentation?
        ChatMediaAssemblyDiagnostics.gif = { if $0 == messageID { gif = $1 } }
        defer { ChatMediaAssemblyDiagnostics.gif = nil }

        func actionPreview(_ input: ChatMessage) -> AnyView {
            AnyView(ChatMessageActionPreview(message: input, conversationID: "detail-chat").appStateEnvironment(state))
        }
        XCTAssertEqual(state.resolvedAttachmentDownloadURL(for: message), file)
        XCTAssertEqual(state.resolvedAttachmentPreviewURL(for: message), fallback)
        do {
            let hosted = try attachmentBoundaryHost(actionPreview(message))
            defer { attachmentBoundaryRetire(hosted) }
            try await attachmentBoundaryWait("action preview selects playable local download") {
                gif?.canPlay == true && gif?.url == file
            }
            XCTAssertEqual(gif?.playbackPriority, false)
            var recalled = message
            recalled.status = .recalled
            gif = nil
            hosted.controller.rootView = actionPreview(recalled)
            try await attachmentBoundaryWait("action preview rejects recalled GIF") {
                gif?.canPlay == false && gif?.url == nil
            }
            XCTAssertTrue(hosted.controller.view.window === hosted.window)
        }

        message.attachmentDownloadURL = fallback.absoluteString
        XCTAssertEqual(state.resolvedAttachmentDownloadURL(for: message), fallback)
        var image: AttachmentImagePreviewProbe?
        ChatAttachmentDetailDiagnostics.image = { image = $0 }
        defer { ChatAttachmentDetailDiagnostics.image = nil }
        for status in [MessageDelivery.sent, .recalled] {
            message.status = status
            let playable = status == .sent
            let expectedURL: URL? = playable ? file : nil
            gif = nil
            image = nil
            var returns = 0
            let hosted = try attachmentBoundaryHost(AnyView(AttachmentBoundaryModalHarness(
                message: message, localURL: file, onReturn: { returns += 1 }).appStateEnvironment(state)))
            defer { attachmentBoundaryRetire(hosted) }
            try await attachmentBoundaryWait("actual fullscreen GIF cover, \(status)") {
                hosted.controller.presentedViewController != nil && image?.imageURL == file
                    && gif?.canPlay == playable && gif?.url == expectedURL
            }
            XCTAssertEqual(gif?.playbackPriority, true)
            XCTAssertTrue(try XCTUnwrap(image).actions.dismiss())
            try await attachmentBoundaryWait("fullscreen GIF cover dismissed") {
                hosted.controller.presentedViewController == nil && returns == 1
            }
        }
    }

    @MainActor private func mountedGIFState(
        suite: String, root: URL, defaults: UserDefaults
    ) throws -> (AppState, LocalMessageScope, IOSMediaCacheScopeContext) {
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        let context = remarkContractContext(tenantID: suite, imUID: "viewer-ui")
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: FakeAttachmentHTTPTransport(results: []),
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context
        )
        let state = AppState(api: api,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: support, cachesBase: caches),
            biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        let viewer = makeRemarkContractUser(id: "viewer-ui", userID: "VIEWER-UI", name: "查看者")
        state.replaceCurrentUserAndProject(viewer, persistIdentity: false)
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(scope: scope, applicationSupportBase: support, cachesBase: caches)
        let media = IOSMediaCacheScopeContext(scopeHash: scope.scopeHash,
            sessionGeneration: state.localMessageSessionGeneration, rootDirectory: paths.mediaScopeDirectory)
        state.resolvedMediaCacheScope = (scope, media)
        return (state, scope, media)
    }
    // WDT_IOS1_CHAT_GIF_ENTRY_MOUNT_20261111_END
}
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END

// WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END
