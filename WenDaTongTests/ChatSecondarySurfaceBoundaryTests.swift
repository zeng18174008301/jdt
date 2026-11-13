@testable import IM4Features
@testable import IM4Domain
import XCTest
import SwiftUI
import UIKit
import Combine
@testable import WenDaTong

// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
extension IdentityPresentationTests {
    @MainActor func secondarySurfaceState(transport: any HTTPTransport = FakeAttachmentHTTPTransport(results: [])) throws -> AppState {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "secondary-surfaces-\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("secondary-surfaces-\(UUID())")
        let context = IMAPIContext(platformToken: "fixture", accountID: "account-1", tenantID: "secondary-tenant", imUID: "uid-1", imToken: "fixture",
            platformAuthSession: nil, tenantAuthSession: nil, appID: IMAPIContext.canonicalIOSAppID, deviceID: "secondary-device")
        let state = AppState(api: IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults)),
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(), rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        let user = makeRemarkContractUser(id: "uid-1", userID: "UID-1", name: "当前用户")
        state.setCurrentUser(user)
        state.setCurrentEnterprise(Enterprise(id: "secondary-tenant", name: "原企业", code: "", role: "admin", status: "", memberCount: 5, isDefault: false, accentHex: 0))
        state.groups = [GroupInfo(id: "secondary-chat", name: "原群聊", notice: "原公告正文", owner: "当前用户", members: [user], admins: [user], muted: false, allMuted: false)]
        state.conversationStore.commitConversationSnapshots([ChatSecondarySurfaceOriginalReference.conversation([
            ChatSecondarySurfaceOriginalReference.message(), ChatSecondarySurfaceOriginalReference.message(outgoing: false)
        ])])
        return state
    }
    @MainActor func testSecondarySurfaceOriginalReferenceMatrix() async throws {
        for name in ChatSecondarySurfaceOriginalReference.cases {
            let state = try secondarySurfaceState()
            let view = ChatSecondarySurfaceOriginalReference.surface(name, state: state)
                .appStateEnvironment(state).environment(\.colorScheme, .light).environment(\.sizeCategory, .medium)
                .environment(\.locale, Locale(identifier: "zh_CN"))
            let hosted = try secondarySurfaceHost(AnyView(view))
            let image = try await secondarySurfaceSnapshot(hosted)
            let attachment = XCTAttachment(image: image)
            attachment.name = "secondary-" + name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(image.size, CGSize(width: 390, height: 760))
            secondarySurfaceRetire(hosted)
        }
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

private final class SecondarySurfaceTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var pending: [(String, CheckedContinuation<HTTPTransportResult, Error>)] = []
    func count(_ suffix: String) -> Int { lock.withLock { requests.filter { $0.url?.path.hasSuffix(suffix) == true && $0.httpMethod != "GET" }.count } }
    func body(_ suffix: String) -> [String: Any]? {
        lock.withLock { requests.last(where: { $0.url?.path.hasSuffix(suffix) == true && $0.httpMethod != "GET" })?.httpBody }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock { requests.append(request) }
        if path.hasSuffix("/lookup") { return try response(["reported": false]) }
        if request.httpMethod != "GET", path.hasSuffix("/edit") || path.hasSuffix("/message-reports") || path.hasSuffix("/announcements/secondary-announcement") {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append((path, continuation)) }
            }
        }
        throw URLError(.resourceUnavailable)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult { throw URLError(.unsupportedURL) }
    func release(_ suffix: String, data: [String: Any]) throws {
        let result = try response(data)
        let continuations = lock.withLock { () -> [CheckedContinuation<HTTPTransportResult, Error>] in
            let matching = pending.filter { $0.0.hasSuffix(suffix) }; pending.removeAll { $0.0.hasSuffix(suffix) }; return matching.map { $0.1 }
        }
        for continuation in continuations { continuation.resume(returning: result) }
    }
    func cancelAll() {
        let values = lock.withLock { let values = pending; pending = []; return values }
        for value in values { value.1.resume(throwing: URLError(.cancelled)) }
    }
    private func response(_ data: [String: Any]) throws -> HTTPTransportResult {
        HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]), isHTTPResponse: true, statusCode: 200)
    }
}
@MainActor private final class SecondaryModalModel: ObservableObject { @Published var open = true }
private struct SecondaryModalHarness: View {
    @ObservedObject var model: SecondaryModalModel
    let content: () -> AnyView
    let onReturn: () -> Void
    var body: some View {
        Text("原返回目标").sheet(isPresented: $model.open, onDismiss: onReturn, content: content)
    }
}

extension IdentityPresentationTests {
    @MainActor private func retireSecondaryProbes() {
        ChatSecondarySurfaceDiagnostics.menu = nil; ChatSecondaryRenderingDiagnostics.receipt = nil
        ChatSecondaryRenderingDiagnostics.edit = nil; ChatSecondaryRenderingDiagnostics.report = nil
        ChatSecondaryRenderingDiagnostics.announcement = nil; ChatSecondaryRenderingDiagnostics.announcementEditor = nil
        ChatSecondaryRenderingDiagnostics.forward = nil; ChatSecondaryRenderingDiagnostics.reaction = nil; ChatSecondaryRenderingDiagnostics.confirmation = nil
    }
    @MainActor private func advanceSecondaryEpoch(_ state: AppState) {
        let original = state.apiContext
        var context = original; context.sessionEpoch = UUID().uuidString
        state.sessionReauthenticationCommit = (old: original.authSessionFence, new: context.authSessionFence)
        state.apiContext = context
        state.sessionReauthenticationCommit = nil
    }
    @MainActor func testSecondaryActualMenuRejectsRetainedEntriesAcrossFourRetirementsOnSameHost() async throws {
        let state = try secondarySurfaceState()
        let presentation = ChatMessagePresentationState()
        let message = ChatSecondarySurfaceOriginalReference.message()
        presentation.actionMessage = message
        var probe: MessageActionOverlay?, renders = 0
        ChatSecondarySurfaceDiagnostics.menu = { probe = $0; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(ChatView(messagePresentation: presentation, conversationID: "secondary-chat").appStateEnvironment(state)))
        let hostID = ObjectIdentifier(host.controller), viewID = ObjectIdentifier(host.controller.view)
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("real App menu assembled") { probe != nil }
        for scenario in 0..<4 {
            let old = try XCTUnwrap(probe); let rendered = renders
            switch scenario {
            case 0: advanceSecondaryEpoch(state)
            case 1:
                let original = state.tenantInteractionStore.snapshot.activeScope
                state.tenantInteractionStore.snapshot.activeScope = "retired-scope"
                state.tenantInteractionStore.snapshot.activeScope = original
            case 2:
                let original = state.apiContext; var next = original; next.accountID = "other-account"
                state.apiContext = next; state.apiContext = original
            default:
                let original = state.apiContext; var next = original; next.tenantID = "other-tenant"
                state.apiContext = next; state.apiContext = original
            }
            UIPasteboard.general.string = "retained-entry-marker"
            old.onCopy()
            XCTAssertEqual(UIPasteboard.general.string, "retained-entry-marker")
            state.conversationStore.commitConversationSnapshots([ChatSecondarySurfaceOriginalReference.conversation([message])])
            presentation.actionMessage = message
            try await secondarySurfaceWait("current menu actions refreshed") { renders > rendered && probe != nil }
            let current = try XCTUnwrap(probe); current.onCopy()
            XCTAssertEqual(UIPasteboard.general.string, message.text)
            XCTAssertNil(presentation.actionMessage)
            XCTAssertEqual(ObjectIdentifier(host.controller), hostID)
            XCTAssertEqual(ObjectIdentifier(host.controller.view), viewID)
            presentation.actionMessage = message
            try await secondarySurfaceWait("same host menu reopened") { presentation.actionMessage != nil }
        }
    }
    @MainActor func testSecondaryReceiptKeepsDetailsCountsAndReactionPoliciesSeparateWithoutAppRelay() async throws {
        let state = try secondarySurfaceState()
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        func policy(_ count: Bool) -> RemoteTenantClientPolicy {
            RemoteTenantClientPolicy(clientFriendRequests: true, showGroupMemberCount: count,
                groupMemberCountPolicyGeneration: 1, groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true, groupMemberCountPolicyPresent: true)
        }
        state.tenantClientPolicyStore.snapshot = TenantClientPolicyPresentationStore.Snapshot(activeScope: scope,
            policyScope: scope, policy: policy(true), groupCountResolution: .authoritative(scope: scope, generation: 1))
        let message = ChatSecondarySurfaceOriginalReference.message()
        let conversation = ChatSecondarySurfaceOriginalReference.conversation([message])
        _ = state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        var input: ChatReceiptInput?
        ChatSecondaryRenderingDiagnostics.receipt = { input = $0 }
        let host = try secondarySurfaceHost(AnyView(ReadReceiptSheet(message: message, conversation: conversation, readReceiptsEnabled: true).appStateEnvironment(state)))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("receipt details input") { input != nil }
        XCTAssertTrue(try XCTUnwrap(input).canViewDetails)
        var broadUpdates = 0
        let subscription = state.objectWillChange.sink { broadUpdates += 1 }; defer { subscription.cancel() }
        state.tenantClientPolicyStore.snapshot.policy = policy(false)
        try await secondarySurfaceWait("count-only permission changed") { input?.showsGroupMemberCount == false }
        XCTAssertTrue(try XCTUnwrap(input).canViewDetails)
        _ = state.applyReadReceiptDetailAuthority(false, conversationID: conversation.id)
        try await secondarySurfaceWait("details permission changed") { input?.canViewDetails == false }
        XCTAssertEqual(broadUpdates, 0)
    }
    @MainActor func testSecondaryEditRealFeatureEntryRecoversRejectedBusyStateThenAdmitsOneAuthoritativeSave() async throws {
        let transport = SecondarySurfaceTransport(); defer { transport.cancelAll() }
        let state = try secondarySurfaceState(transport: transport)
        let message = ChatSecondarySurfaceOriginalReference.message()
        state.activeRealtimeConversationID = "secondary-chat"
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext)
        state.tenantInteractionStore.snapshot.actions.editEnabled = true
        var probe: ChatSecondaryEditProbe?, renders = 0, accepted = 0, returns = 0
        ChatSecondaryRenderingDiagnostics.edit = { probe = $0; renders += 1 }
        let model = SecondaryModalModel()
        let host = try secondarySurfaceHost(AnyView(SecondaryModalHarness(model: model, content: {
            AnyView(MessageEditSheet(message: message, conversationID: "secondary-chat", onAuthoritativeSuccess: { _ in accepted += 1; return true }).appStateEnvironment(state))
        }, onReturn: { returns += 1 })))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("actual Feature save entry") { probe != nil }
        let old = try XCTUnwrap(probe), rendered = renders
        advanceSecondaryEpoch(state); old.submit(); old.submit()
        try await secondarySurfaceWait("rejected Feature save releases busy") { renders > rendered && probe?.isSaving == false }
        XCTAssertEqual(transport.count("/edit"), 0)
        XCTAssertNotNil(state.conversationStore.conversationMessageSnapshot(id: "secondary-chat"))
        XCTAssertNil(state.messageEditUnavailableReason(message))
        let current = try XCTUnwrap(probe); current.submit(); current.submit()
        try await secondarySurfaceWait("current edit dispatched once") { transport.count("/edit") == 1 }
        advanceSecondaryEpoch(state)
        try transport.release("/edit", data: ["extra": ["tenant_id": "secondary-tenant", "message_id": message.id,
            "channel_id": "secondary-chat", "channel_type": "group", "channel_seq": 7, "version": 2,
            "operator_uid": "uid-1", "extra_type": "edit", "payload": ["text": message.text, "edit_revision": 2]]])
        try await secondarySurfaceWait("authoritative accepted save returns") { accepted == 1 && returns == 1 }
        XCTAssertEqual(transport.count("/edit"), 1)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshot(id: "secondary-chat")?.messages.first?.editRevision, 2)
    }
    @MainActor func testSecondaryReportRealFeatureEntryRecoversThenPreservesAlreadyReportedReadOnlyCompletion() async throws {
        let transport = SecondarySurfaceTransport(); defer { transport.cancelAll() }
        let state = try secondarySurfaceState(transport: transport)
        let message = ChatSecondarySurfaceOriginalReference.message(outgoing: false)
        var probe: ChatSecondaryReportProbe?, renders = 0
        ChatSecondaryRenderingDiagnostics.report = { probe = $0; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(MessageReportSheet(message: message, conversationID: "secondary-chat").appStateEnvironment(state)))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("report lookup completes") { probe?.isLookingUp == false }
        let old = try XCTUnwrap(probe)
        old.description.wrappedValue = "真实举报草稿"
        try await secondarySurfaceWait("description rerenders") { probe?.description.wrappedValue == "真实举报草稿" }
        let stale = try XCTUnwrap(probe), rendered = renders
        advanceSecondaryEpoch(state); stale.submit(); stale.submit()
        try await secondarySurfaceWait("report rejected busy resets") { renders > rendered && probe?.isSubmitting == false }
        XCTAssertEqual(transport.count("/message-reports"), 0)
        let current = try XCTUnwrap(probe); current.submit(); current.submit()
        try await secondarySurfaceWait("report single new operation") { transport.count("/message-reports") == 1 }
        advanceSecondaryEpoch(state)
        try transport.release("/message-reports", data: ["id": "secondary-report", "message_id": message.id,
            "reason": MessageReportCategory.illegalTrade.rawValue, "description": "真实举报草稿", "already_reported": true, "read_only": true])
        try await secondarySurfaceWait("admitted report becomes read-only") { probe?.readOnly == true && probe?.isSubmitting == false }
        try XCTUnwrap(probe).submit()
        XCTAssertEqual(transport.count("/message-reports"), 1)
        XCTAssertEqual(probe?.description.wrappedValue, "真实举报草稿")
    }
    @MainActor func testSecondaryAnnouncementExpectedRevisionRejectedRecoveryAndAdmittedCompletionKeepOriginalCloseACK() async throws {
        let transport = SecondarySurfaceTransport(); defer { transport.cancelAll() }
        let state = try secondarySurfaceState(transport: transport)
        let original = GroupAnnouncement(id: "secondary-announcement", groupID: "secondary-chat", title: "原标题", content: "原正文",
            summary: "原摘要", createdBy: "当前用户", status: "published", createdAt: "2026-11-10T09:00:00Z",
            updatedAt: "2026-11-10T09:00:00Z", publishedAt: "2026-11-10T09:00:00Z", unread: true, readAt: nil,
            displayPosition: "", readAction: "", readCount: nil, unreadCount: nil, recipientCount: nil, canViewReadCounts: false)
        state.contactStore.groupAnnouncements["secondary-chat"] = [original]
        var editor: ChatSecondaryAnnouncementEditorProbe?, showEditor: Binding<Bool>?, renders = 0, closed = 0
        ChatSecondaryRenderingDiagnostics.announcement = { showEditor = $0 }
        ChatSecondaryRenderingDiagnostics.announcementEditor = { editor = $0; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(GroupAnnouncementSheet(group: state.groups[0], announcementID: original.id, onClose: { closed += 1 }).appStateEnvironment(state)))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("original announcement host") { showEditor != nil }
        try XCTUnwrap(showEditor).wrappedValue = true
        try await secondarySurfaceWait("original editor presented") { editor != nil }
        let old = try XCTUnwrap(editor), rendered = renders
        advanceSecondaryEpoch(state); old.submit(); old.submit()
        try await secondarySurfaceWait("publish rejection releases one-shot busy") { renders > rendered && editor?.isPublishing == false }
        XCTAssertEqual(transport.count("/announcements/secondary-announcement"), 0)
        let current = try XCTUnwrap(editor); current.submit(); current.submit()
        try await secondarySurfaceWait("publish dispatch once") { transport.count("/announcements/secondary-announcement") == 1 }
        XCTAssertEqual(transport.body("/announcements/secondary-announcement")?["expected_updated_at"] as? String, original.updatedAt)
        advanceSecondaryEpoch(state)
        try transport.release("/announcements/secondary-announcement", data: ["id": original.id, "group_id": original.groupID,
            "title": original.title, "content": original.content, "summary": original.summary, "status": "published", "updated_at": "2026-11-10T09:01:00Z"])
        try await secondarySurfaceWait("admitted publish completes despite renewed entry") { showEditor?.wrappedValue == false }
        XCTAssertEqual(closed, 0)
        secondarySurfaceRetire(host)
        try await secondarySurfaceWait("original close ACK once") { closed == 1 }
        XCTAssertEqual(transport.count("/announcements/secondary-announcement"), 1)
    }
    @MainActor func testSecondaryForwardObservesSameDraftAndRejectsOldSearchEntryWithoutReplacingBatch() async throws {
        let state = try secondarySurfaceState()
        var draft = BatchForwardState(scope: BatchForwardScope(tenantID: "secondary-tenant", actorUID: "uid-1", sourceChannelID: "secondary-chat", sourceChannelType: "group"))
        draft.setTargetSearchQuery("原查询")
        state.batchForwardStore.begin(draft, sourceConversationID: "secondary-chat")
        var input: ChatForwardInput?, actions: ChatForwardActions?, renders = 0
        ChatSecondaryRenderingDiagnostics.forward = { input = $0; actions = $1; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(ForwardMessageTargetSheet(sourceConversationID: "secondary-chat").appStateEnvironment(state)))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("original batch draft consumed") { input?.draft?.targetSearchQuery == "原查询" }
        let old = try XCTUnwrap(actions), rendered = renders
        advanceSecondaryEpoch(state); old.search("旧请求")
        XCTAssertEqual(state.batchForwardStore.draft(for: "secondary-chat")?.state.targetSearchQuery, "原查询")
        try await secondarySurfaceWait("current target actions refreshed") { renders > rendered }
        try XCTUnwrap(actions).search("当前查询")
        try await secondarySurfaceWait("same Store draft update") { input?.draft?.targetSearchQuery == "当前查询" }
        XCTAssertEqual(state.batchForwardStore.draft(for: "secondary-chat")?.state.scope, draft.scope)
        XCTAssertEqual(state.batchForwardStore.draft(for: "secondary-chat")?.state.clientBatchID, draft.clientBatchID)
    }
}

extension IdentityPresentationTests {
    @MainActor func testSecondaryReactionRealFeatureRejectsOldCommandThenClosesOriginalModalOnce() async throws {
        let state = try secondarySurfaceState()
        let model = SecondaryModalModel()
        var select: ((String) -> Void)?, renders = 0, returns = 0
        ChatSecondaryRenderingDiagnostics.reaction = { select = $0; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(SecondaryModalHarness(model: model, content: {
            AnyView(ReactionPickerView(message: ChatSecondarySurfaceOriginalReference.message(), conversationID: "secondary-chat", fullPicker: AnyView(Text("完整 Emoji"))).appStateEnvironment(state))
        }, onReturn: { returns += 1 })))
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("actual reaction Feature entry") { select != nil && host.controller.presentedViewController != nil }
        let presented = try XCTUnwrap(host.controller.presentedViewController)
        let hostID = ObjectIdentifier(host.controller), viewID = ObjectIdentifier(host.controller.view)
        let old = try XCTUnwrap(select), rendered = renders
        advanceSecondaryEpoch(state); old("👍")
        XCTAssertEqual(returns, 0)
        XCTAssertTrue(host.controller.presentedViewController === presented)
        try await secondarySurfaceWait("current reaction action") { renders > rendered }
        try XCTUnwrap(select)("👍")
        try await secondarySurfaceWait("original modal closes once") { returns == 1 && host.controller.presentedViewController == nil }
        XCTAssertEqual(ObjectIdentifier(host.controller), hostID)
        XCTAssertEqual(ObjectIdentifier(host.controller.view), viewID)
    }
    @MainActor func testSecondaryConfirmationSameHostRejectsOldSendAndRetainsOriginalManagedSelection() async throws {
        let state = try secondarySurfaceState()
        let selection = PendingAttachmentSelection(kind: .file, name: "原文件.pdf", mimeType: "application/pdf", sizeBytes: 20, data: Data([1]), previewImage: nil)
        let batch = selection.asBatch
        var send: (() -> Void)?, renders = 0, sent = 0, cancelled = 0
        ChatSecondaryRenderingDiagnostics.confirmation = { send = $0; renders += 1 }
        let host = try secondarySurfaceHost(AnyView(AttachmentSendConfirmationSheet(batch: batch, onCancel: { cancelled += 1 }, onSend: { sent += 1 }).appStateEnvironment(state)))
        let hostID = ObjectIdentifier(host.controller), viewID = ObjectIdentifier(host.controller.view)
        defer { secondarySurfaceRetire(host); retireSecondaryProbes() }
        try await secondarySurfaceWait("actual confirmation command") { send != nil }
        let old = try XCTUnwrap(send), rendered = renders
        advanceSecondaryEpoch(state); old()
        XCTAssertEqual(sent, 0); XCTAssertEqual(cancelled, 0)
        try await secondarySurfaceWait("current confirmation command") { renders > rendered }
        try XCTUnwrap(send)()
        XCTAssertEqual(sent, 1); XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(batch.selections.first?.id, selection.id)
        XCTAssertEqual(ObjectIdentifier(host.controller), hostID)
        XCTAssertEqual(ObjectIdentifier(host.controller.view), viewID)
    }
}

// WDT_IOS1_SECONDARY_RECEIPT_ROW_SNAPSHOT_20261111_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testSecondaryReceiptSameUIDRecordSnapshotsKeepNamesAndLiveViewerRemarks() async throws {
        try await verifySecondaryRecordSnapshotRows(reaction: false)
    }

    @MainActor
    func testSecondaryReactionSameUIDReceiptAndReactionKeepNamesAndLiveViewerRemarks() async throws {
        try await verifySecondaryRecordSnapshotRows(reaction: true)
    }

    @MainActor
    private func verifySecondaryRecordSnapshotRows(reaction: Bool) async throws {
        let state = try secondarySurfaceState()
        let a = makeRemarkContractUser(id: "same-im-uid", userID: "SNAPSHOT-A", username: "alias-a", name: "资料快照甲")
        let b = makeRemarkContractUser(id: "same-im-uid", userID: "SNAPSHOT-B", username: "alias-b", name: "资料快照乙")
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.userID, b.userID)
        XCTAssertEqual(state.remarkPreferredDisplayName(for: a, fallback: "未知用户"), "资料快照甲")
        XCTAssertEqual(state.remarkPreferredDisplayName(for: b, fallback: "未知用户"), "资料快照乙")
        var message = ChatSecondarySurfaceOriginalReference.message()
        message.readBy = [ReadReceipt(id: "record-a", user: a, device: "phone-a", time: "09:00")]
        message.unreadBy = []
        if reaction {
            message.reactionDetails = [ReactionDetail(id: "record-b", emoji: "👍", user: b, time: "09:01")]
        } else {
            message.readBy.append(ReadReceipt(id: "record-b", user: b, device: "phone-b", time: "09:01"))
            message.reactionDetails = []
        }
        let conversation = ChatSecondarySurfaceOriginalReference.conversation([message])
        state.conversationStore.commitConversationSnapshots([conversation])
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let policy = RemoteTenantClientPolicy(clientFriendRequests: true, showGroupMemberCount: true,
            groupMemberCountPolicyGeneration: 1, groupMemberCountContractVersion: 1,
            groupMemberCountPolicyAuthoritative: true, groupMemberCountPolicyPresent: true)
        state.tenantClientPolicyStore.snapshot = TenantClientPolicyPresentationStore.Snapshot(activeScope: scope,
            policyScope: scope, policy: policy, groupCountResolution: .authoritative(scope: scope, generation: 1))
        _ = state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        XCTAssertTrue(state.canViewMessageReadDetails(message, in: conversation))
        var rows: [String: ChatReceiptRowRender] = [:]
        var renderCount = 0
        ChatReceiptRowDiagnostics.render = { row in
            rows[row.kind.rawValue + ":" + row.recordID] = row
            renderCount += 1
        }
        let host = try secondarySurfaceHost(AnyView(ReadReceiptSheet(message: message, conversation: conversation,
            readReceiptsEnabled: true).appStateEnvironment(state)))
        let hostID = ObjectIdentifier(host.controller), viewID = ObjectIdentifier(host.controller.view)
        defer { secondarySurfaceRetire(host); ChatReceiptRowDiagnostics.render = nil }
        let keyA = "read:record-a", keyB = (reaction ? "reaction:" : "read:") + "record-b"
        try await secondarySurfaceWait("actual production receipt/reaction row bodies mounted") {
            rows[keyA] != nil && rows[keyB] != nil
        }
        XCTAssertEqual(rows.count, 2, "Every original record renders; same UID must not collapse rows")
        XCTAssertEqual(rows[keyA]?.user, a)
        XCTAssertEqual(rows[keyB]?.user, b)
        XCTAssertEqual(rows[keyA]?.displayName, "资料快照甲")
        XCTAssertEqual(rows[keyB]?.displayName, "资料快照乙")
        let prefix = reaction ? "reaction-sameUID" : "receipt-sameUID"
        let original = XCTAttachment(image: try await secondarySurfaceSnapshot(host))
        original.name = prefix + "-original-record-snapshots"; original.lifetime = .keepAlways; add(original)
        var rendered = renderCount
        state.contactStore.remarks = [a.userID: "当前查看者备注甲", b.userID: "当前查看者备注乙"]
        XCTAssertEqual(state.remarkPreferredDisplayName(for: a, fallback: "未知用户"), "当前查看者备注甲")
        XCTAssertEqual(state.remarkPreferredDisplayName(for: b, fallback: "未知用户"), "当前查看者备注乙")
        try await secondarySurfaceWait("same mounted rows observe current viewer remarks") {
            renderCount > rendered && rows[keyA]?.displayName == "当前查看者备注甲"
        }
        XCTAssertEqual(rows[keyA]?.displayName, "当前查看者备注甲")
        XCTAssertEqual(rows[keyB]?.displayName, "当前查看者备注乙")
        let remarked = XCTAttachment(image: try await secondarySurfaceSnapshot(host))
        remarked.name = prefix + "-live-viewer-remarks"; remarked.lifetime = .keepAlways; add(remarked)
        rendered = renderCount
        state.contactStore.remarks = [:]
        try await secondarySurfaceWait("per-record fallback restores without replacing host") {
            renderCount > rendered && rows[keyA]?.displayName == "资料快照甲"
        }
        XCTAssertEqual(rows[keyB]?.displayName, "资料快照乙")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(ObjectIdentifier(host.controller), hostID)
        XCTAssertEqual(ObjectIdentifier(host.controller.view), viewID)
    }
}
// WDT_IOS1_SECONDARY_RECEIPT_ROW_SNAPSHOT_20261111_END

// WDT_IOS1_SECONDARY_SOURCE_CONTRACT_ENTRIES_20261111_BEGIN
// Same runtime method; relocated whole case to keep both Swift files below800 lines.
extension IdentityPresentationTests {
    func testRemarkPresentationSurfacesUseLiveViewerResolver() throws {
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110: directory remark changes are covered by the mounted directory test.
        let department = try sourceText(relativePath: "../WenDaTong/Features/Contacts/DepartmentManagementSheets.swift")
        let rows = try sourceText(relativePath: "../Sources/IM4Features/Contacts/ContactRowContent.swift")
        let directoryRow = try sourceSection(rows, startingAt: "public struct ContactDirectoryRowContent")
        let members = try sourceText(relativePath: "../WenDaTong/Features/Contacts/GroupMemberManagementViews.swift")
        let muteList = try sourceText(relativePath: "../WenDaTong/Features/Contacts/GroupMuteListViews.swift")
        let profile = try sourceText(relativePath: "../WenDaTong/Features/Contacts/ContactUserProfile.swift")
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        let messageActions = try sourceText(relativePath: "../WenDaTong/App/ChatMessageInteractionAssembly.swift")
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END

        // Follow the actual value producers instead of requiring every pure row to call AppState.
        func actualFunction(_ source: String, _ signature: String) throws -> Substring {
            let start = try XCTUnwrap(source.range(of: signature)?.lowerBound)
            let lineStart = source[..<start].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
            let indent = source[lineStart..<start]
            let tail = source[start...]
            let end = try XCTUnwrap(tail.range(of: "\n\(indent)}\n")?.upperBound)
            return tail[..<end]
        }
        let directoryAssembly = try sourceText(relativePath: "../WenDaTong/ContactsViews.swift")
        let directoryNames = try sourceText(relativePath: "../WenDaTong/Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift")
        let directoryFactory = try actualFunction(directoryAssembly, "func contactDirectoryRowPresentation(")
        let directoryName = try actualFunction(directoryNames, "func contactDirectoryDisplayName(for user:")
        XCTAssertTrue(directoryRow.contains("row.displayName"))
        XCTAssertTrue(directoryFactory.contains("displayName ?? state.contactDirectoryDisplayName(for: user)"))
        XCTAssertTrue(directoryName.contains("[user.id, user.userID, user.username]"))
        XCTAssertTrue(directoryName.contains("!normalizedIdentifiers.contains(where: { isCurrentUserIdentity($0) })"))
        XCTAssertTrue(directoryName.contains("contactRemarks[identifier]"))
        XCTAssertTrue(directoryName.contains("candidates: [user.name, user.username, user.userID]"))
        let groupProjection = try sourceText(relativePath: "../WenDaTong/Core/AppSupport/GroupFileMapping/AppState+GroupDetailProjection.swift")
        let groupUser = try actualFunction(groupProjection, "func groupMemberUser(from member:")
        XCTAssertTrue(groupUser.contains("let identifiers = [resolvedID, resolvedUserID, resolvedUsername]"))
        XCTAssertTrue(groupUser.contains("isCurrentUser ? nil : contactRemarkValue(matching: identifiers)"))
        XCTAssertTrue(groupUser.contains("GroupMemberDisplayNameResolver.resolve("))
        XCTAssertTrue(groupUser.contains("viewerRemarks: [member.remark, localRemark]"))
        XCTAssertTrue(groupUser.contains("name: displayName"))
        for symbol in ["struct GroupMemberManagementView", "private struct GroupMemberRoleRow", "private struct GroupMemberActionSheet"] {
            XCTAssertTrue(try sourceSection(members, startingAt: symbol).contains("GroupMemberDisplayNameResolver.projectedName(for: user)"),
                "\(symbol) must consume the viewer-aware group projection without reapplying a different row rule")
        }
        let muteName = try actualFunction(muteList, "private func displayName(for item:")
        XCTAssertTrue(muteName.contains("state.remarkPreferredDisplayName("))
        XCTAssertTrue(muteName.contains("[item.targetUID, item.targetUserID, item.targetUsername]"))
        let muteListContent = try sourceText(relativePath: "../Sources/IM4Features/Contacts/GroupMuteListContent.swift")
        XCTAssertTrue(try sourceSection(muteListContent, startingAt: "public struct GroupMuteListRowContent").contains("Text(displayName)"))
        XCTAssertTrue(muteList.contains("displayName: displayName(for: item)"))
        for (source, symbol) in [
            (department, "private struct DepartmentMemberInviteSheet"),
            (members, "private struct GroupInviteMembersSheet")
        ] {
            XCTAssertTrue(try sourceSection(source, startingAt: symbol).contains("remarkPreferredDisplayName"),
                "\(symbol) must resolve the current viewer's live remark")
        }
        let profileView = try sourceSection(
            profile,
            startingAt: "struct UserProfileView"
        )
        XCTAssertTrue(profileView.contains("state.liveProfileUser"))
        XCTAssertTrue(profileView.contains("state.userProfileDisplayName"))
        XCTAssertTrue(profileView.contains("liveUser.displayAvatarURL"))
        XCTAssertFalse(profileView.contains("state.visibleLastLoginText(for: liveUser)"))

        // WDT_IOS1_REFACTOR_CHAT_SHEETS_20261109_BEGIN
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let composerPanels = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerPanels.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerContactCardAssembly.swift")
        let composerActions = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatComposerActions.swift") + sourceText(relativePath: "../WenDaTong/App/ChatComposerActionAssembly.swift")
        let contactPickerStart = try XCTUnwrap(composerPanels.range(of: "\nstruct ContactCardPickerSheet: View")?.lowerBound)
        let mentionPanelSource = String(composerPanels[..<contactPickerStart])
        let receipts = try sourceText(relativePath: "../WenDaTong/App/ChatReceiptAssembly.swift")
        for (source, symbol) in [
            // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
            (messageActions, "struct UserQuickActionOverlay"),
            // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
            (composerPanels, "struct ContactCardPickerSheet")
        ] {
            XCTAssertTrue(
                try sourceSection(source, startingAt: symbol).contains("remarkPreferredDisplayName"),
                "\(symbol) must resolve the current viewer's live remark"
            )
        }
        let mention = try sourceSection(mentionPanelSource, startingAt: "struct MentionSuggestionPanel")
        XCTAssertTrue(mention.contains("chatProjectedMemberName(user)"))
        // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_BEGIN
        let receiptSheet = try sourceSection(receipts, startingAt: "struct ReadReceiptSheet")
        for user in ["receipt.user", "reaction.user"] {
            XCTAssertTrue(receiptSheet.contains("state.remarkPreferredDisplayName(for: \(user),"))
        }
        // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_SHEETS_20261109_END

        // WDT_IOS1_REFACTOR_CONVERSATION_VIEWS_20261109_BEGIN
        let searchViews = try sourceText(relativePath: "../WenDaTong/Features/Conversations/ConversationListSearch.swift")
        let quickAddViews = try sourceText(relativePath: "../WenDaTong/Features/Conversations/QuickAddViews.swift")
        let rowViews = try sourceText(relativePath: "../Sources/IM4Features/Conversations/ConversationRowContent.swift")
        let searchRow = try sourceSection(searchViews, startingAt: "private struct TenantSearchResultRow")
        XCTAssertTrue(searchRow.contains("contactDisplayName"))
        XCTAssertTrue(searchRow.contains("remarkPreferredDisplayName"))
        for symbol in ["struct CreateGroupSheet", "private struct StartDirectChatSheet"] {
            let section = try sourceSection(quickAddViews, startingAt: symbol)
            XCTAssertTrue(section.contains("remarkPreferredDisplayName"))
            XCTAssertTrue(section.contains("withName"))
        }
        XCTAssertTrue(rowViews.contains("\"会话 \\(rowModel.displayTitle)\""))
        // WDT_IOS1_REFACTOR_CONVERSATION_VIEWS_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        XCTAssertTrue(composerActions.contains("let replacement = \"@\\(mentionVisibleDisplayName(for: user)) \""))
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }
}
// WDT_IOS1_SECONDARY_SOURCE_CONTRACT_ENTRIES_20261111_END

extension IdentityPresentationTests {
    @MainActor
    func testReturnToBottomControlGrowsForAccessibilityContentSize() throws {
        var heights: [CGFloat] = []
        for (name, category) in [("standard", ContentSizeCategory.large), ("accessibility", .accessibilityExtraExtraExtraLarge)] {
            var measuredHeight: CGFloat = 0
            let root = VStack {
                ReturnToBottomBar(count: 123) {}
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { measuredHeight = proxy.size.height }
                    })
                Spacer()
            }.padding(12).environment(\.sizeCategory, category)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: 320, height: 400))
            defer { hosted.window.isHidden = true }
            XCTAssertGreaterThanOrEqual(measuredHeight, 44)
            heights.append(measuredHeight)
            add(snapshotAttachment(hostedSnapshotImage(hosted), name: "return-to-bottom-\(name)"))
        }
        XCTAssertEqual(heights.count, 2)
        XCTAssertGreaterThan(heights[1], heights[0] + 8, "The mounted button must grow with accessibility text instead of retaining a fixed 14-point font")
        let dimensions = XCTAttachment(string: "standard=\(heights[0]); accessibility=\(heights[1])")
        dimensions.name = "return-to-bottom-mounted-heights"; dimensions.lifetime = .keepAlways; add(dimensions)
    }
}

extension IdentityPresentationTests {
    @MainActor
    func testReturnToBottomControlIsAdaptiveAccessibleAndDoesNotResizeTimeline() throws {
        try input100CaptureActualLoadedImages(self, phase: "normal-and-AX-font-contract")
        let layout = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatViewLayout.swift")
        let shell = try sourceSection(layout, startingAt: "struct ChatReturnToBottomOverlay")
        XCTAssertTrue(shell.contains("ZStack(alignment: .bottomTrailing)"))
        XCTAssertTrue(shell.contains("ReturnToBottomBar(count: pendingUnreadCount, action: returnToBottom)"))
        XCTAssertTrue(shell.contains("if showsControl"))
        XCTAssertFalse(shell.contains("safeAreaInset"))
        let assembly = try sourceSection(sourceText(relativePath: "../WenDaTong/App/ChatTranscriptLayoutAssembly.swift"), startingAt: "func chatTimelineContainer(")
        XCTAssertTrue(assembly.contains("ChatReturnToBottomOverlay(showsControl: chatShouldShowReturnToBottom("))
        XCTAssertTrue(assembly.contains("pendingUnreadCount: boundedPendingUnreadCount"))
        XCTAssertTrue(assembly.contains("setScrollTarget(plan.targetID, source: plan.source, anchor: plan.anchor)"))
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_BEGIN
        let historyViews = try sourceText(relativePath: "../Sources/IM4Features/Chat/ChatHistorySupportViews.swift")
        let control = try sourceSection(historyViews, startingAt: "struct ReturnToBottomBar")
        // WDT_IOS1_REFACTOR_CHAT_SCROLL_SUPPORT_20261109_END
        try testReturnToBottomControlGrowsForAccessibilityContentSize()
        XCTAssertTrue(control.contains("minHeight: 44"))
        XCTAssertTrue(control.contains("lineLimit(2)") && control.contains("sizeCategory.isAccessibilityCategory"))
        XCTAssertTrue(control.contains("chat_return_to_bottom_button"))
        XCTAssertTrue(control.contains("accessibilityLabel(accessibilityTitle)"))
        XCTAssertTrue(control.contains("accessibilityHint"))
        // WDT_IOS1_REFACTOR_CHAT_VIEW_CORE_20261109_END
    }

}

// WDT_IOS1_RETURN_BOTTOM_AX_ACTION_20261111_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testReturnToBottomScaledBaselineKeepsReadableAXAndOriginalBoundAction() async throws {
        try input100CaptureActualLoadedImages(self, phase: "AX-original-bound-button-action")
        var activations = 0
        var mountedAction: (() -> Void)?
        let previous = ReturnToBottomBar.captureBoundAction
        ReturnToBottomBar.captureBoundAction = { count, action in
            if count == 123 { mountedAction = action }
        }
        defer { ReturnToBottomBar.captureBoundAction = previous }
        let root = VStack {
            ReturnToBottomBar(count: 123) { activations += 1 }
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(12).environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        let hosted = try input100HostUsingOriginalComposerBoundary(root, size: CGSize(width: 320, height: 400))
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(activations, 0)
        try XCTUnwrap(mountedAction, "Capture the same action handed to Button by its actual mounted body")()
        XCTAssertEqual(activations, 1)
        add(snapshotAttachment(hostedSnapshotImage(hosted), name: "return-to-bottom-readable-AX-original-bound-action"))
        let scope = XCTAttachment(string: "Same original action captured from the actual mounted Button factory through existing ChatTimelineRenderDiagnostics. The SDK unit-test AX tree was empty; no physical tap/VoiceOver activation is claimed. Button(action: action), overlay and original App scroll action remain unchanged.")
        scope.name = "return-bottom-action-validation-scope"; scope.lifetime = .keepAlways; add(scope)
    }
}
// WDT_IOS1_RETURN_BOTTOM_AX_ACTION_20261111_END
