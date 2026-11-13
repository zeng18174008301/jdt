@testable import IM4Features
import Combine
import XCTest
import SwiftUI
import UIKit
@testable import WenDaTong

private final class HeaderAnnouncementTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<HTTPTransportResult, Error>?
    private var paths: [String] = []
    var pendingDetail: Bool { lock.withLock { pending != nil } }
    var readCount: Int { lock.withLock { paths.filter { $0.hasSuffix("/announcements/header-announcement/read") }.count } }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock { paths.append(path) }
        if path.hasSuffix("/announcements/header-announcement"), request.httpMethod == "GET" {
            return try await withCheckedThrowingContinuation { continuation in lock.withLock { pending = continuation } }
        }
        if path.hasSuffix("/announcements/header-announcement/read") { return response(unread: false) }
        throw URLError(.resourceUnavailable)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult { throw URLError(.unsupportedURL) }
    func releaseDetail() {
        let value = lock.withLock { let value = pending; pending = nil; return value }
        value?.resume(returning: response(unread: true))
    }
    private func response(unread: Bool) -> HTTPTransportResult {
        let data = Data("{\"ok\":true,\"data\":{\"id\":\"header-announcement\",\"group_id\":\"header-group\",\"title\":\"原公告标题\",\"content\":\"原公告正文\",\"summary\":\"原公告摘要\",\"status\":\"published\",\"unread\":\(unread),\"updated_at\":\"2026-11-10T01:00:00Z\"}}".utf8)
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }
}

@MainActor private func headerStatusHost(_ content: AnyView, size: CGSize = CGSize(width: 390, height: 844)) throws -> HostedSimulatorUI<AnyView> {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let controller = UIHostingController(rootView: content)
    let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = controller; window.makeKeyAndVisible()
    controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
    return HostedSimulatorUI(window: window, controller: controller)
}
@MainActor private func headerStatusRetire(_ hosted: HostedSimulatorUI<AnyView>) {
    hosted.controller.view.endEditing(true); hosted.controller.rootView = AnyView(EmptyView())
    hosted.window.isHidden = true; hosted.window.rootViewController = nil
}
@MainActor private func headerStatusWait(_ label: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<160 { if predicate() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
    XCTAssertTrue(predicate(), "Header/status did not reach \(label)")
}
// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
private final class GlobalSearchPageTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[URLQueryItem]] = []
    var searches: [[URLQueryItem]] { lock.withLock { requests } }
    private let conversationHistoryCount: Int?
    private let acknowledgeLinkFilterOnFirstPageOnly: Bool // WDT_IOS1_SEARCH_LINK_FILTER_20261113
    private let denyHistoryContinuation: Bool
    private let holdHistoryContinuation: Bool
    private var continuationReleased = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    var isHistoryContinuationPending: Bool { lock.withLock { pendingContinuation != nil } }

    init(conversationHistoryCount: Int? = nil, acknowledgeLinkFilterOnFirstPageOnly: Bool = false,
         denyHistoryContinuation: Bool = false, holdHistoryContinuation: Bool = false) {
        self.conversationHistoryCount = conversationHistoryCount
        self.acknowledgeLinkFilterOnFirstPageOnly = acknowledgeLinkFilterOnFirstPageOnly // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        self.denyHistoryContinuation = denyHistoryContinuation
        self.holdHistoryContinuation = holdHistoryContinuation
    }

    func releaseHistoryContinuation() {
        let continuation = lock.withLock {
            continuationReleased = true
            let continuation = pendingContinuation
            pendingContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard let url = request.url, url.path == "/api/tenant/search" else {
            throw URLError(.resourceUnavailable)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        lock.withLock { requests.append(items) }
        if let conversationHistoryCount {
            let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            guard values["scope"] == "conversation", values["types"] == "messages",
                  values["cursor"] == nil, values["messages_cursor"] == nil,
                  let cursor = values["cursor_v2"], let channel = values["channel_id"] else {
                throw URLError(.badServerResponse)
            }
            let offset = cursor.isEmpty ? 0 : (Int(cursor.dropFirst("page-".count)) ?? 0)
            if offset > 0 && denyHistoryContinuation {
                let data = Data(#"{"ok":false,"error":{"code":"forbidden","message":"forbidden"}}"#.utf8)
                return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 403)
            }
            if offset > 0 && holdHistoryContinuation {
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock {
                        guard !continuationReleased else { return true }
                        pendingContinuation = continuation
                        return false
                    }
                    if resume { continuation.resume() }
                }
            }
            let end = min(offset + 20, conversationHistoryCount)
            let hits: [[String: Any]] = (offset..<end).map { index in
                let sequence = conversationHistoryCount - index
                return ["result_id": "message:history-\(sequence)", "type": "message", "title": "合同",
                    "jump_target": ["kind": "message", "channel_id": channel, "channel_type": "direct",
                        "channel_seq": sequence, "message_id": "history-\(sequence)"]]
            }
            var bucket: [String: Any] = ["items": hits, "has_more": end < conversationHistoryCount,
                "status": "ok", "total_is_exact": false, "authoritative": true]
            if end < conversationHistoryCount { bucket["next_cursor_v2"] = "page-\(end)" }
            var response: [String: Any] = [
                "query": "合同", "scope": "conversation", "types": ["messages"], "results_by_type": ["messages": bucket]
            ]
            // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
            if acknowledgeLinkFilterOnFirstPageOnly, values["has_link"] == "true" {
                response["search_capabilities"] = ["message_links": true]
                if offset == 0 { response["applied_filters"] = ["has_link": true] }
            }
            // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
            // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
            if values["message_content"] == "attachment" {
                guard values["from_uid"] == "uid-2" else { throw URLError(.badServerResponse) }
                response["search_capabilities"] = ["attachment_messages": true]
                response["applied_filters"] = ["message_content": "attachment"]
            }
            // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": response])
            return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
        }
        let data = Data("""
        {"ok":true,"data":{"query":"知","degraded":true,"results_by_type":{
          "contacts":{"items":[],"status":"ok","count":0,"total_is_exact":true},
          "groups":{"items":[],"status":"ok","count":0,"total_is_exact":true},
          "conversations":{"items":[],"status":"ok","count":0,"total_is_exact":true},
          "messages":{"items":[],"status":"unavailable","error":{"code":"query_too_short","message":"too short","retryable":false}},
          "files":{"items":[],"status":"ok","count":0,"total_is_exact":true}
        }}}
        """.utf8)
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }
}
// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
private final class HeldTenantSearchTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<HTTPTransportResult, Error>?
    var isWaiting: Bool { lock.withLock { pending != nil } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        guard request.url?.path == "/api/tenant/search" else { throw URLError(.resourceUnavailable) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending = continuation }
        }
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }

    func release() {
        let continuation = lock.withLock {
            let value = pending
            pending = nil
            return value
        }
        let payload = Data(#"{"ok":true,"data":{"query":"旧搜索","scope":"global","results_by_type":{"contacts":{"items":[{"result_id":"old-account-hit","type":"contact","title":"旧账号结果"}]}}}}"#.utf8)
        continuation?.resume(returning: HTTPTransportResult(data: payload, isHTTPResponse: true, statusCode: 200))
    }
}
// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
@MainActor private final class HeaderNavigationModel: ObservableObject { @Published var open = true }
private struct HeaderNavigationHarness: View {
    @ObservedObject var model: HeaderNavigationModel
    let owner: ComposerState
    var body: some View {
        NavigationStackCompat {
            NavigationLink(isActive: $model.open) {
                ChatView(composerState: owner, conversationID: "header-chat")
            } label: { Text("返回目标") }
        }
    }
}

// WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_BEGIN
private enum HeaderTopSlot: Hashable {
    case announcement, pinned, search, timeline
}

private struct HeaderTopFrames: PreferenceKey {
    static let defaultValue: [HeaderTopSlot: CGRect] = [:]

    static func reduce(value: inout [HeaderTopSlot: CGRect], nextValue: () -> [HeaderTopSlot: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct HeaderTopLayoutHarness: View {
    enum Content {
        case empty, withoutPinned, full
    }

    let content: Content
    let framesChanged: ([HeaderTopSlot: CGRect]) -> Void
    @State private var searchFocused = false // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113

    init(content: Content, framesChanged: @escaping ([HeaderTopSlot: CGRect]) -> Void) {
        self.content = content
        self.framesChanged = framesChanged
    }

    var body: some View {
        ChatScreenColumn(top: {
            chatTopContextContent(hasPinnedMessages: content == .full, announcement: {
                if content != .empty {
                    ChatGroupAnnouncementView(title: "原公告标题", preview: "原公告摘要", isBusy: false, open: {}, close: {})
                        .background(frame(of: .announcement))
                }
            }, pinned: {
                ChatPinnedContextView(input: ChatPinnedContextInput(text: "原置顶消息"), open: {})
                    .background(frame(of: .pinned))
            }, search: {
                if content != .empty {
                    ChatHistorySearchPanel(keyword: .constant(""), dateText: .constant(""), results: [], visibleResults: [],
                        total: 0, hitChannelSeqs: [], isSearching: false, isLoadingMore: false, hasMore: false,
                        searchFocus: $searchFocused, onSearch: {}, onDateSearch: {}, onPrevious: {}, onNext: {},
                        onLoadMore: {}, onClose: {}, onSelect: { _ in }, onQueryChange: {})
                        .background(frame(of: .search))
                }
            })
        }, timeline: {
            Color.clear.frame(height: 1).background(frame(of: .timeline))
        }, mute: { EmptyView() }, composer: { EmptyView() })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "header-top-layout")
        .onPreferenceChange(HeaderTopFrames.self, perform: framesChanged)
    }

    private func frame(of slot: HeaderTopSlot) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: HeaderTopFrames.self, value: [slot: proxy.frame(in: .named("header-top-layout"))])
        }
    }
}
// WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_END

// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_BEGIN
extension AttachmentDownloadTests {
    // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_BEGIN
    @MainActor private func headerStatusState(
        transport: any HTTPTransport = FakeAttachmentHTTPTransport(results: []),
        defaults fixtureDefaults: UserDefaults? = nil,
        history: TenantSearchHistoryStore? = nil // WDT_IOS1_SEARCH_HISTORY_20261113
    ) throws -> AppState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("header-status-\(UUID())")
        let defaults = try fixtureDefaults ?? XCTUnwrap(UserDefaults(suiteName: "header-status-\(UUID())"))
        let context = attachmentContext(tenantID: "header-\(UUID())")
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"), imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            startupContext: context)
        let state = AppState(api: api,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            tenantSearchHistory: history, // WDT_IOS1_SEARCH_HISTORY_20261113
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        let viewer = IMUser(id: "uid-1", name: "Viewer", title: "", department: "", phone: "", email: "", status: "在线", enterprise: "", avatarSeed: 0, badges: [])
        state.replaceCurrentUserAndProject(viewer, persistIdentity: false)
        state.setAuthenticated(true)
        let peer = IMUser(id: "uid-2", name: "原联系人", title: "", department: "", phone: "", email: "", status: "在线", enterprise: "", avatarSeed: 0, badges: [])
        state.contacts = [peer]
        return state
    }
    // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_END
    @MainActor private func headerStatusConversation(_ state: AppState, group: Bool = false, title: String = "原会话") -> ConversationMessageSnapshot {
        var value = ConversationMessageSnapshot(id: group ? "header-group" : "header-chat", title: title, subtitle: "", kind: group ? .group : .direct,
            lastMessage: "", time: "", unread: 2, isPinned: false, isMuted: false, memberCount: group ? 12 : nil,
            accentHex: 0, participants: [state.currentUser] + state.contacts, messages: [])
        value.messages = [ChatMessage(id: "header-message", senderId: "uid-2", senderName: "原联系人", text: "原消息", time: "",
            isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: [], unreadBy: [], isPinned: false)]
        state.conversationStore.commitConversationSnapshots([value])
        var policy = state.tenantInteractionStore.snapshot
        policy.policyScope = policy.activeScope ?? ""; policy.actions.forwardEnabled = true
        state.tenantInteractionStore.snapshot = policy
        return value
    }
    @MainActor private func headerStatusGroup(_ state: AppState) -> GroupInfo {
        GroupInfo(id: "header-group", name: "原群标题", notice: "原群公告", owner: "uid-9", members: [state.currentUser] + state.contacts,
            admins: [], muted: false, allMuted: true, allMuteStart: nil, allMuteEnd: nil, memberCount: 12)
    }
    private func headerStatusAnnouncement() -> GroupAnnouncement {
        GroupAnnouncement(id: "header-announcement", groupID: "header-group", title: " 原公告标题 ", content: "原公告正文", summary: " 原公告摘要 ",
            createdBy: "uid-9", status: "published", createdAt: "", updatedAt: "2026-11-10T01:00:00Z", publishedAt: "", unread: true,
            readAt: nil, displayPosition: "above_pinned_messages", readAction: "", readCount: 0, unreadCount: 0, recipientCount: 0, canViewReadCounts: false)
    }
    @MainActor
    func testHeaderActualFactoryObservesUnreadRemarkAndOriginalActionsWithoutReplacingOwner() async throws {
        let state = try headerStatusState(), owner = ComposerState()
        let conversation = headerStatusConversation(state)
        var latest: ChatHeaderProbe?
        ChatHeaderStatusDiagnostics.header = { latest = $0 }
        let hosted = try headerStatusHost(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: conversation.id) }.appStateEnvironment(state)))
        defer { headerStatusRetire(hosted); ChatHeaderStatusDiagnostics.header = nil }
        try await headerStatusWait("direct title") { latest?.input.title == "原联系人" }
        let hostID = ObjectIdentifier(hosted.controller), viewID = ObjectIdentifier(hosted.controller.view)
        let first = try XCTUnwrap(latest)
        XCTAssertTrue(first.owner.composerState === owner)
        let other = ConversationMessageSnapshot(id: "header-other", title: "其他会话", subtitle: "", kind: .direct, lastMessage: "", time: "", unread: 7, isPinned: false, isMuted: false, memberCount: nil, accentHex: 0, participants: [], messages: [])
        state.conversationStore.commitConversationSnapshots([conversation, other])
        try await headerStatusWait("unread") { latest?.input.backUnreadCount == state.conversationStore.alertingUnreadTotal - max(0, state.conversationStore.conversation(id: conversation.id)?.unread ?? 0) }
        XCTAssertGreaterThan(try XCTUnwrap(latest).input.backUnreadCount, 0)
        state.contactRemarks = ["uid-2": "  真实备注  "]
        try await headerStatusWait("remark producer") { latest?.input.title == "真实备注" }
        latest?.actions.search()
        try await headerStatusWait("search open") { latest?.owner.showSearch == true }
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        func containsSearchInput(_ view: UIView) -> Bool {
            if let input = view as? UITextField, input.placeholder == "搜索历史聊天记录" { return true }
            return view.subviews.contains(where: containsSearchInput)
        }
        try await headerStatusWait("full-screen history search input") {
            hosted.controller.presentedViewController.map { containsSearchInput($0.view) } == true
        }
        XCTAssertFalse(containsSearchInput(hosted.controller.view))
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        latest?.actions.search()
        try await headerStatusWait("search close") { latest?.owner.showSearch == false }
        state.beginBatchForward(conversationID: conversation.id, initialMessageID: "header-message")
        try await headerStatusWait("batch selected") { latest?.input.isBatchSelecting == true }
        XCTAssertEqual(latest?.input.selectedSourceCount, 1)
        latest?.actions.back()
        try await headerStatusWait("original batch cancel") { latest?.input.isBatchSelecting == false }
        XCTAssertNil(state.batchForwardState)
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID); XCTAssertEqual(ObjectIdentifier(hosted.controller.view), viewID)
        XCTAssertTrue(try XCTUnwrap(latest).owner.composerState === owner)
        // Existing call policy remains owned by AppState; a missing license never reaches media permission/IO.
        let hint = try XCTUnwrap(latest).owner.voiceCallAccessibilityHint
        XCTAssertEqual(hint, state.callLicenseUnavailableMessage(for: .voice))
        latest?.owner.startVoiceCallFromConversation()
        XCTAssertEqual(state.rtcCapabilityAlertStore.message, hint)
        latest?.actions.more()
        try await headerStatusWait("direct profile") { latest?.owner.selectedUserProfile?.id == "uid-2" }
    }

    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    @MainActor
    func testSearchHistoryRejectsRetiredOwnerAndClearsOnlyRemovedConversation() throws {
        let state = try headerStatusState(history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let conversation = headerStatusConversation(state)
        let owner = state.chatBubbleSessionIdentity
        let originalContext = state.apiContext
        state.recordTenantSearch("企业关键词", conversationID: nil, owner: owner)
        state.recordTenantSearch("会话关键词", conversationID: conversation.id, owner: owner)
        XCTAssertEqual(state.recentTenantSearches(conversationID: nil, owner: owner), ["企业关键词"])
        XCTAssertEqual(state.recentTenantSearches(conversationID: conversation.id, owner: owner), ["会话关键词"])
        var switched = originalContext
        switched.tenantID = "other-\(UUID())"
        switched.sessionEpoch = UUID().uuidString
        state.apiContext = switched
        state.recordTenantSearch("迟到的关键词", conversationID: nil, owner: owner)
        XCTAssertTrue(state.recentTenantSearches(conversationID: nil, owner: owner).isEmpty)
        var returned = originalContext
        returned.sessionEpoch = UUID().uuidString
        state.apiContext = returned
        let current = state.chatBubbleSessionIdentity
        XCTAssertNotEqual(owner, current)
        defer {
            state.clearTenantSearchHistory(conversationID: nil, owner: current)
            state.clearTenantSearchHistory(conversationID: conversation.id, owner: current)
        }
        XCTAssertEqual(state.recentTenantSearches(conversationID: nil, owner: current), ["企业关键词"])
        state.applySearchInvalidation(SearchInvalidationEvent(tenantID: returned.tenantID ?? "",
            invalidationKey: UUID().uuidString, eventType: "removed_conversation",
            channelID: state.remoteChannelID(for: conversation), channelType: "direct", clientAction: "remove_conversation"))
        XCTAssertEqual(state.recentTenantSearches(conversationID: nil, owner: current), ["企业关键词"])
        XCTAssertTrue(state.recentTenantSearches(conversationID: conversation.id, owner: current).isEmpty)
    }

    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    @MainActor
    func testLateTenantSearchResponseIsRetiredAfterSameAccountAndTenantReturn() async throws {
        let transport = HeldTenantSearchTransport()
        let state = try headerStatusState(transport: transport)
        let original = state.apiContext
        let request = Task { @MainActor in
            await state.tenantSearch(query: "旧搜索", scope: "global", types: ["contacts"], limit: 10)
        }
        defer { request.cancel(); transport.release() }
        try await headerStatusWait("old tenant search enters transport") { transport.isWaiting }
        var switched = original
        switched.tenantID = "separate-workspace"
        switched.sessionEpoch = UUID().uuidString
        state.apiContext = switched
        var returned = original
        returned.sessionEpoch = UUID().uuidString
        state.apiContext = returned
        transport.release()
        guard case .retired = await request.value else {
            return XCTFail("A response from before the session change became visible")
        }
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    func testChatHistorySearchDateFilterUsesLocalDayAcrossDSTAndKeepsAnchorSeparate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let bounds = try XCTUnwrap(ChatHistorySearchCriteria.dayBounds(day, calendar: calendar))
        XCTAssertEqual(bounds.0, "2026-03-08T08:00:00Z")
        XCTAssertEqual(bounds.1, "2026-03-09T06:59:59.999999999Z")

        let text = ChatHistorySearchCriteria(keyword: "你好", range: .messages, sender: "u-1", day: nil)
        let textRequest = text.request(cursorV2: "")
        XCTAssertEqual(textRequest.types, ["messages"])
        XCTAssertEqual(textRequest.sender, "u-1")
        XCTAssertEqual(textRequest.cursorV2, "")
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        XCTAssertNil(textRequest.startAt)
        XCTAssertNil(textRequest.endAt)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END

        let files = ChatHistorySearchCriteria(keyword: "你好", range: .videos, sender: "u-1", day: nil)
        let fileRequest = files.request(legacy: ["files": "20"])
        XCTAssertEqual(fileRequest.types, ["files"])
        XCTAssertEqual(fileRequest.fileType, "video")
        XCTAssertNil(fileRequest.sender)
        XCTAssertNil(fileRequest.cursorV2)
    }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END

    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
    @MainActor
    func testMountedGlobalSearchSubmitsSingleRuneMixedQueryOnceAndRemembersIt() async throws {
        let transport = GlobalSearchPageTransport()
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let owner = state.chatBubbleSessionIdentity
        let presentation = TenantGlobalSearchPresentation(owner: owner, deployment: state.apiContext.tenantAPIBaseURL,
            returnToken: state.conversationListPresentationStore.snapshot.returnToken)
        let hosted = try headerStatusHost(AnyView(TenantGlobalSearchPage(presentation: presentation).appStateEnvironment(state)))
        defer { headerStatusRetire(hosted) }
        func editor(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(editor).first
        }
        try await headerStatusWait("global search input mounted") { editor(hosted.controller.view) != nil }
        let input = try XCTUnwrap(editor(hosted.controller.view))
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
        input.text = "44"
        input.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(transport.searches.isEmpty)
        input.text = "知"
        input.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(transport.searches.isEmpty)
        XCTAssertTrue(state.recentTenantSearches(conversationID: nil, owner: owner).isEmpty)
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
        XCTAssertEqual(input.delegate?.textFieldShouldReturn?(input), false)
        try await headerStatusWait("global mixed search reaches tenant transport") { transport.searches.count == 1 }
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(transport.searches.count, 1)
        let query = try XCTUnwrap(transport.searches.first)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "知")
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "global")
        XCTAssertEqual(query.first { $0.name == "types" }?.value, "contacts,groups,conversations,messages,files")
        XCTAssertEqual(state.recentTenantSearches(conversationID: nil, owner: owner), ["知"])
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
        input.text = "新草稿"
        input.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(transport.searches.count, 1)
        XCTAssertEqual(state.recentTenantSearches(conversationID: nil, owner: owner), ["知"])
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
    }

    @MainActor
    func testGlobalSearchInputDoesNotReproject1050ConversationList() async throws {
        let state = try headerStatusState(history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        state.conversationStore.commitConversationSnapshots((0..<1050).map { index in
            ConversationMessageSnapshot(id: "list-search-\(index)", title: "会话 \(index)", subtitle: "",
                kind: .direct, lastMessage: "", time: "", unread: 0, isPinned: false,
                isMuted: false, memberCount: nil, accentHex: 0, participants: [], messages: [])
        })
        let projection = ConversationListMountedProjectionProbe(binding: state.conversationStore.messageMemoryStore.bindingID)
        var list: ConversationListView?
        ChatTimelineRenderDiagnostics.conversationListBody = { list = $0 }
        defer { ChatTimelineRenderDiagnostics.conversationListBody = nil; projection.stop() }
        let hosted = try headerStatusHost(AnyView(NavigationStackCompat { ConversationListView() }.appStateEnvironment(state)))
        defer { headerStatusRetire(hosted) }
        func table(_ view: UIView) -> UITableView? {
            (view as? UITableView) ?? view.subviews.lazy.compactMap(table).first
        }
        func editor(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(editor).first
        }
        try await headerStatusWait("large conversation list settled") {
            (table(hosted.controller.view)?.numberOfRows(inSection: 0) ?? 0) >= 1050 && list != nil
        }
        let listTable = try XCTUnwrap(table(hosted.controller.view))
        let anchor = IndexPath(row: 800, section: 0)
        listTable.scrollToRow(at: anchor, at: .middle, animated: false)
        listTable.layoutIfNeeded()
        try await headerStatusWait("large list scroll anchor visible") {
            listTable.indexPathsForVisibleRows?.contains(anchor) == true
        }
        try XCTUnwrap(list).openGlobalSearch()
        try await headerStatusWait("global search presented from list") {
            hosted.controller.presentedViewController.flatMap { editor($0.view) } != nil
        }
        let modal = try XCTUnwrap(hosted.controller.presentedViewController)
        let input = try XCTUnwrap(editor(modal.view))
        try await Task.sleep(nanoseconds: 200_000_000)
        projection.projected.removeAll()
        for term in ["知", "知识", "知识库", ""] {
            input.text = term
            input.sendActions(for: .editingChanged)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(projection.projected.filter { $0 == nil }.count, 0)
        modal.dismiss(animated: false)
        try await headerStatusWait("large list visible again") {
            hosted.controller.presentedViewController == nil && listTable.indexPathsForVisibleRows?.contains(anchor) == true
        }
        XCTAssertTrue(table(hosted.controller.view) === listTable)
    }
    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    @MainActor
    func testChatHistoryDenialRetiresEarlierRowsAndJump() async throws {
        let transport = GlobalSearchPageTransport(conversationHistoryCount: 21, denyHistoryContinuation: true)
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let conversation = headerStatusConversation(state)
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context)
        defer { session.close(context) }
        session.range = .messages
        session.keyword = "合同"
        session.update(immediate: true, context: context)
        try await headerStatusWait("initial history page") { session.rows.count == 20 }
        let id = "message:message:history-21"
        let jump = try XCTUnwrap(session.select(id, context: context))
        session.finish(jump)
        XCTAssertTrue(session.canComplete(jump, context: context))
        session.loadMore(context)
        try await headerStatusWait("authoritative permission denial") { session.failure == .access }
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.hasMore)
        XCTAssertNil(session.focusedID)
        XCTAssertNil(session.select(id, context: context))
        XCTAssertNil(session.adjacent(1, context: context))
        XCTAssertFalse(session.canComplete(jump, context: context))
    }

    @MainActor
    func testChatHistoryDropsRecalledHitsAndRejectsStaleContinuationWithNoticesEnabled() async throws {
        let transport = GlobalSearchPageTransport(conversationHistoryCount: 22, holdHistoryContinuation: true)
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        var conversation = headerStatusConversation(state)
        let affectedSequences: [Int64] = [22, 1]
        conversation.messages = affectedSequences.map { sequence in
            var message = ChatMessage(id: "history-\(sequence)", senderId: "uid-2", senderName: "Peer", text: "合同", time: "",
                isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: [], unreadBy: [])
            message.channelSeq = sequence
            return message
        }
        state.conversationStore.commitConversationSnapshots([conversation])
        XCTAssertTrue(state.shouldShowMessageProcessingNotices)
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context, currentMessages: conversation.messages)
        let changes = state.conversationStore.memoryCommits.sink { commit in
            guard commit.bindingID == state.conversationStore.messageMemoryStore.bindingID,
                  let change = commit.messageChanges[context.conversationID] else { return }
            session.observeLocalMessageWindow(change.current, previous: change.previous, context: context)
        }
        defer {
            changes.cancel()
            session.close(context)
            transport.releaseHistoryContinuation()
        }
        session.range = .messages
        session.keyword = "合同"
        session.update(immediate: true, context: context)
        try await headerStatusWait("initial history page") { session.rows.count == 20 }
        let jump = try XCTUnwrap(session.select("message:message:history-22", context: context))
        session.finish(jump)
        session.loadMore(context)
        try await headerStatusWait("continuation requested") { transport.isHistoryContinuationPending }
        XCTAssertTrue(state.applyAdminDeletedMessage(messageID: "history-22", conversationID: conversation.id))
        XCTAssertTrue(state.conversationStore.applyRecall(messageID: "history-1", conversationID: conversation.id))
        XCTAssertNil(session.focusedID)
        XCTAssertFalse(session.canComplete(jump, context: context))
        let revokedTarget = await state.prepareSearchJumpTarget(jump.target, conversationID: conversation.id)
        XCTAssertNil(revokedTarget)
        conversation.messages = []
        state.conversationStore.commitConversationSnapshots([conversation])
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshot(id: conversation.id)?.messages.isEmpty == true)
        transport.releaseHistoryContinuation()
        try await headerStatusWait("stale continuation finished") { !session.paging && !session.hasMore }
        XCTAssertEqual(session.rows.count, 20)
        XCTAssertFalse(session.rows.contains { ["message:history-1", "message:history-22"].contains($0.resultID) })
        let unaffected = try XCTUnwrap(session.select("message:message:history-2", context: context))
        XCTAssertEqual(unaffected.target.channelSeq, 2)
        let other = headerStatusConversation(state, group: true)
        let otherContext = ChatHistorySearchPageContext(actions: .bind(state), conversationID: other.id,
            conversationChannel: state.remoteChannelID(for: other), currentOwner: { state.chatBubbleSessionIdentity })
        session.open(otherContext, currentMessages: other.messages)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.canComplete(unaffected, context: otherContext))
    }

    @MainActor
    func testChatHistoryPageCrossesLegacyLimitAndKeepsOldestExactTarget() async throws {
        let hitCount = 1045
        let transport = GlobalSearchPageTransport(conversationHistoryCount: hitCount)
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let conversation = headerStatusConversation(state)
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context)
        defer { session.close(context) }
        session.range = .messages
        session.keyword = "合同"
        session.update(immediate: true, context: context)
        try await headerStatusWait("history first page") { session.rows.count == 20 && !session.busy }
        for expected in stride(from: 40, through: 1060, by: 20) {
            let targetCount = min(expected, hitCount)
            session.loadMore(context)
            try await headerStatusWait("history page through \(targetCount)") {
                session.rows.count == targetCount && !session.paging
            }
            guard session.rows.count == targetCount else { return }
        }
        XCTAssertEqual(Set(session.rows.map(\.resultID)).count, hitCount)
        XCTAssertFalse(session.hasMore)
        XCTAssertNil(session.exactTotal)
        XCTAssertEqual(transport.searches.count, 53)
        let jump = try XCTUnwrap(session.select("message:message:history-1", context: context))
        XCTAssertEqual(jump.target.messageID, "history-1")
        XCTAssertEqual(jump.target.channelSeq, 1)
        XCTAssertFalse(conversation.messages.contains(where: { $0.id == "history-1" }))
    }

    // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
    @MainActor
    func testChatHistoryLinkSearchRejectsPageWithoutFilterAcknowledgement() async throws {
        let transport = GlobalSearchPageTransport(conversationHistoryCount: 21, acknowledgeLinkFilterOnFirstPageOnly: true)
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let conversation = headerStatusConversation(state)
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context)
        defer { session.close(context) }
        session.keyword = "合同"
        session.range = .links
        session.update(immediate: true, context: context)
        try await headerStatusWait("acknowledged links page visible") { session.rows.count == 20 && session.supportsLinks }
        session.loadMore(context)
        try await headerStatusWait("unacknowledged links page rejected") { session.pageFailure == .unavailable }
        XCTAssertEqual(session.rows.count, 20)
        XCTAssertTrue(session.hasMore)
        XCTAssertEqual(transport.searches.count, 2)
        XCTAssertTrue(transport.searches.allSatisfy { $0.contains(URLQueryItem(name: "has_link", value: "true")) })
        XCTAssertFalse(session.rows.contains { $0.resultID == "message:history-1" })
    }
    // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END

    // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
    @MainActor
    func testChatHistoryAttachmentSearchKeepsExactSenderAcrossPages() async throws {
        let transport = GlobalSearchPageTransport(conversationHistoryCount: 21)
        let state = try headerStatusState(transport: transport,
            history: TenantSearchHistoryStore(secretStore: SearchHistorySecrets()))
        let conversation = headerStatusConversation(state)
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context)
        defer { session.close(context) }
        session.keyword = "合同"
        session.range = .attachments
        session.sender = "uid-2"
        session.update(immediate: true, context: context)
        try await headerStatusWait("attachment sender search started") {
            session.rows.count == 20 && session.supportsAttachmentMessages
        }
        session.loadMore(context)
        try await headerStatusWait("attachment sender search finished") { session.rows.count == 21 && !session.hasMore }
        XCTAssertTrue(session.rows.allSatisfy { $0.displayKind == "附件消息" })
        XCTAssertEqual(transport.searches.count, 2)
        for query in transport.searches {
            XCTAssertTrue(query.contains(URLQueryItem(name: "from_uid", value: "uid-2")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "message_content", value: "attachment")))
            XCTAssertFalse(query.contains { $0.name == "file_type" || $0.name == "has_link" })
        }
        XCTAssertEqual(session.select("message:message:history-1", context: context)?.target.messageID, "history-1")
    }
    // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    @MainActor
    func testChatDateCalendarOnlyOffersVisibleDaysAndJumpsToThatDay() async throws {
        let state = try headerStatusState()
        var conversation = headerStatusConversation(state)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let month = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let days = try (0..<4).map { try XCTUnwrap(calendar.date(byAdding: .day, value: $0, to: month)) }
        conversation.messages = days.enumerated().map { index, date in
            var message = LocalMessageTestFixture.message(id: "calendar-\(index)", sequence: Int64(index + 1),
                status: index == 1 ? .recalled : .sent)
            message.createdAt = date
            message.isDeletedLocally = index == 2
            message.isPinnedContextOnly = index == 3
            return message
        }
        state.conversationStore.commitConversationSnapshots([conversation])
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context, currentMessages: conversation.messages)
        let available = await session.availableDates(in: month, calendar: calendar, context: context)
        XCTAssertEqual(available, [month])
        var jump: ChatHistorySearchJump?
        session.anchorDate = "2026-11-02"
        session.jumpToDate(context) { jump = $0 }
        XCTAssertNil(jump)
        session.anchorDate = "2026-11-01"
        session.jumpToDate(context) { jump = $0 }
        XCTAssertEqual(jump?.target.messageID, "calendar-0")
    }

    @MainActor
    func testChatDateCalendarKeepsDayAfterOnlyMessageIsEdited() async throws {
        let state = try headerStatusState()
        var conversation = headerStatusConversation(state)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        var message = LocalMessageTestFixture.message(id: "calendar-edited", sequence: 21)
        message.createdAt = day
        conversation.messages = [message]
        state.conversationStore.commitConversationSnapshots([conversation])
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), conversationChannelType: "direct",
            currentOwner: { state.chatBubbleSessionIdentity })
        let session = ChatHistorySearchSession()
        session.open(context, currentMessages: conversation.messages)
        session.apply(.init(tenantID: state.apiContext.tenantID ?? "", eventType: "message_updated",
            channelID: context.conversationChannel, channelType: "direct", channelSeq: message.channelSeq,
            messageID: message.id, clientAction: "upsert_message_search_cache"), context: context)
        let days = await session.availableDates(in: day, calendar: calendar, context: context)
        XCTAssertEqual(days, [day])
        session.anchorDate = "2026-10-15"
        var jump: ChatHistorySearchJump?
        session.jumpToDate(context) { jump = $0 }
        XCTAssertEqual(jump?.target.messageID, message.id)
    }

    @MainActor
    func testChatDateCalendarSkipsRecalledFirstCachedAnchorOnSameDay() async throws {
        let state = try headerStatusState()
        var conversation = headerStatusConversation(state)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15)))
        let context = ChatHistorySearchPageContext(actions: .bind(state), conversationID: conversation.id,
            conversationChannel: state.remoteChannelID(for: conversation), conversationChannelType: "direct",
            currentOwner: { state.chatBubbleSessionIdentity })
        var first = LocalMessageTestFixture.message(id: "calendar-old-first", sequence: 31)
        first.createdAt = day.addingTimeInterval(60)
        var second = LocalMessageTestFixture.message(id: "calendar-old-next", sequence: 32)
        second.createdAt = day.addingTimeInterval(120)
        conversation.messages = [first, second]
        let ticket = try await state.messagePersistence.ensureTicket(context: state.apiContext,
            sessionGeneration: state.localMessageSessionGeneration)
        state.localMessageTicket = ticket
        _ = try await state.messagePersistence.persist(ticket: ticket, snapshots: [
            LocalMessageConversationSnapshot(conversation: conversation, channelID: context.conversationChannel,
                channelType: "direct", currentActorID: state.apiContext.imUID ?? "")
        ], source: .history, revision: 1)
        conversation.messages = []
        state.conversationStore.commitConversationSnapshots([conversation])
        let session = ChatHistorySearchSession()
        session.open(context, currentMessages: conversation.messages)
        session.anchorDate = "2026-09-15"
        let initial = await session.availableDates(in: day, calendar: calendar, context: context)
        XCTAssertEqual(initial, [day])
        var jump: ChatHistorySearchJump?
        session.jumpToDate(context) { jump = $0 }
        XCTAssertEqual(jump?.target.messageID, first.id)

        session.apply(.init(tenantID: state.apiContext.tenantID ?? "", eventType: "message_recalled",
            channelID: context.conversationChannel, channelType: "direct", channelSeq: first.channelSeq,
            messageID: first.id), context: context)
        session.apply(.init(tenantID: state.apiContext.tenantID ?? "", eventType: "message_deleted_for_all",
            channelID: "another-channel", channelType: "direct", channelSeq: second.channelSeq), context: context)
        let remaining = await session.availableDates(in: day, calendar: calendar, context: context)
        XCTAssertEqual(remaining, [day])
        jump = nil
        session.jumpToDate(context) { jump = $0 }
        XCTAssertEqual(jump?.target.messageID, second.id)
        XCTAssertEqual(jump?.target.channelSeq, second.channelSeq)
    }
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    @MainActor
    func testChatHistoryInputDoesNotRecomputeMountedTimeline() async throws {
        let state = try headerStatusState()
        let conversation = headerStatusConversation(state)
        var header: ChatHeaderProbe?
        ChatTimelineRenderDiagnostics.reset()
        ChatTimelineRenderDiagnostics.enabled = true
        ChatHeaderStatusDiagnostics.header = { header = $0 }
        defer { ChatHeaderStatusDiagnostics.header = nil; ChatTimelineRenderDiagnostics.reset() }
        let hosted = try headerStatusHost(AnyView(NavigationStackCompat {
            ChatView(composerState: ComposerState(), conversationID: conversation.id)
        }.appStateEnvironment(state)))
        defer { headerStatusRetire(hosted) }
        func editor(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(editor).first
        }
        try await headerStatusWait("chat timeline rendered") { ChatTimelineRenderDiagnostics.timelineBodies > 0 && header != nil }
        try XCTUnwrap(header).actions.search()
        try await headerStatusWait("chat history search input presented") {
            hosted.controller.presentedViewController.flatMap { editor($0.view) } != nil
        }
        let modal = try XCTUnwrap(hosted.controller.presentedViewController)
        let input = try XCTUnwrap(editor(modal.view))
        try await Task.sleep(nanoseconds: 200_000_000)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
        XCTAssertLessThan(input.convert(input.bounds, to: modal.view).minY, 160)
        let baseline = ChatTimelineRenderDiagnostics.timelineBodies
        for term in ["合", "合同", "合同文件", ""] {
            input.text = term
            input.sendActions(for: .editingChanged)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(ChatTimelineRenderDiagnostics.timelineBodies, baseline)
    }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    @MainActor
    func testHeaderRetainedNewActionsRetireOnScopeRoundTripAndSameScopeEpoch() async throws {
        let state = try headerStatusState(), owner = ComposerState()
        let conversation = headerStatusConversation(state)
        var latest: ChatHeaderProbe?
        ChatHeaderStatusDiagnostics.header = { latest = $0 }
        let hosted = try headerStatusHost(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: conversation.id) }.appStateEnvironment(state)))
        defer { headerStatusRetire(hosted); ChatHeaderStatusDiagnostics.header = nil }
        try await headerStatusWait("initial action") { latest != nil }
        let initial = try XCTUnwrap(latest), hostID = ObjectIdentifier(hosted.controller)
        let context = state.apiContext
        var next = context; next.tenantID = "header-other-tenant"; state.apiContext = next; state.apiContext = context
        state.conversationStore.commitConversationSnapshots([conversation])
        try await headerStatusWait("round trip") { latest?.origin == state.chatBubbleSessionIdentity }
        initial.actions.search(); initial.actions.more(); initial.actions.back()
        XCTAssertFalse(initial.owner.showSearch); XCTAssertNil(initial.owner.selectedUserProfile)
        XCTAssertEqual(initial.owner.chatBackDismissAttemptID, 0)
        let roundTrip = try XCTUnwrap(latest)
        next = state.apiContext; next.sessionEpoch = UUID().uuidString; state.apiContext = next
        try await headerStatusWait("epoch refreshed") { latest?.origin == state.chatBubbleSessionIdentity && latest?.origin != roundTrip.origin }
        roundTrip.actions.search(); roundTrip.actions.more(); roundTrip.actions.back()
        XCTAssertFalse(roundTrip.owner.showSearch); XCTAssertNil(roundTrip.owner.selectedUserProfile)
        XCTAssertEqual(roundTrip.owner.chatBackDismissAttemptID, 0)
        latest?.actions.search()
        try await headerStatusWait("current search") { latest?.owner.showSearch == true }
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
        XCTAssertTrue(try XCTUnwrap(latest).owner.composerState === owner)
    }
    @MainActor
    func testHeaderCurrentBackUsesOriginalNavigationDismiss() async throws {
        let state = try headerStatusState(), owner = ComposerState(), model = HeaderNavigationModel()
        _ = headerStatusConversation(state)
        var latest: ChatHeaderProbe?
        ChatHeaderStatusDiagnostics.header = { latest = $0 }
        let hosted = try headerStatusHost(AnyView(HeaderNavigationHarness(model: model, owner: owner).appStateEnvironment(state)))
        defer { headerStatusRetire(hosted); ChatHeaderStatusDiagnostics.header = nil }
        try await headerStatusWait("navigation pushed") { latest != nil }
        let current = try XCTUnwrap(latest), hostID = ObjectIdentifier(hosted.controller)
        current.actions.back()
        try await headerStatusWait("navigation returned") { !model.open }
        XCTAssertEqual(ObjectIdentifier(hosted.controller), hostID)
        XCTAssertTrue(current.owner.composerState === owner)
    }
    @MainActor
    func testHeaderGroupStatusAndAdmittedAnnouncementKeepOriginalCallbackAndACKContract() async throws {
        // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_BEGIN
        try await assertMountedHeaderTopLayout()
        let suite = "header-announcement-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = HeaderAnnouncementTransport()
        let state = try headerStatusState(transport: transport, defaults: defaults)
        let owner = ComposerState()
        // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_END
        let conversation = headerStatusConversation(state, group: true)
        state.groups = [headerStatusGroup(state)]
        state.currentGroupAnnouncements = [conversation.id: headerStatusAnnouncement()]
        var header: ChatHeaderProbe?, announcement: ChatAnnouncementProbe?
        var announcementCaptures = 0
        ChatHeaderStatusDiagnostics.header = { header = $0 }; ChatHeaderStatusDiagnostics.announcement = { announcement = $0; announcementCaptures += 1 }
        let hosted = try headerStatusHost(AnyView(NavigationStackCompat { ChatView(composerState: owner, conversationID: conversation.id) }.appStateEnvironment(state)))
        defer { transport.releaseDetail(); headerStatusRetire(hosted); ChatHeaderStatusDiagnostics.header = nil; ChatHeaderStatusDiagnostics.announcement = nil }
        try await headerStatusWait("group status") { header != nil && announcement != nil }
        // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_BEGIN
        try await assertMountedHeaderTopInputs(state: state, conversation: conversation, header: { header })
        // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_END
        let current = try XCTUnwrap(header), first = try XCTUnwrap(announcement)
        XCTAssertTrue(current.input.isGroup); XCTAssertNil(current.input.groupMemberSubtitle)
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        state.tenantClientPolicyStore.snapshot = TenantClientPolicyPresentationStore.Snapshot(
            activeScope: scope, policyScope: scope,
            policy: RemoteTenantClientPolicy(showGroupMemberCount: true, groupMemberCountPolicyGeneration: 1,
                groupMemberCountContractVersion: 1, groupMemberCountPolicyAuthoritative: true, groupMemberCountPolicyPresent: true),
            groupCountResolution: .authoritative(scope: scope, generation: 1))
        try await headerStatusWait("authoritative visible group count") { header?.input.groupMemberSubtitle == "12 人" }
        XCTAssertTrue(current.owner.composerIsDisabled); XCTAssertNotNil(current.owner.disabledBannerDecision.groupMuteBanner)
        XCTAssertEqual(first.title, "原公告标题"); XCTAssertEqual(first.preview, "原公告摘要")
        let beforeRenewalCaptures = announcementCaptures
        var next = state.apiContext; next.sessionEpoch = UUID().uuidString; state.apiContext = next
        try await headerStatusWait("fresh announcement closure") { header?.origin == state.chatBubbleSessionIdentity && announcementCaptures > beforeRenewalCaptures }
        first.open(); first.close()
        XCTAssertFalse(transport.pendingDetail); XCTAssertEqual(transport.readCount, 0)
        let fresh = try XCTUnwrap(announcement)
        fresh.open()
        try await headerStatusWait("admitted detail request") { transport.pendingDetail }
        next = state.apiContext; next.sessionEpoch = UUID().uuidString; state.apiContext = next
        transport.releaseDetail()
        try await headerStatusWait("original callback and read ACK") { fresh.owner.showGroupAnnouncementDetail && transport.readCount > 0 }
        XCTAssertEqual(fresh.owner.openedGroupAnnouncementID, "header-announcement")
        XCTAssertFalse(fresh.owner.isOpeningGroupAnnouncementDetail)
        XCTAssertTrue(fresh.owner.composerState === owner)
    }
    // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_BEGIN
    @MainActor private func assertMountedHeaderTopInputs(
        state: AppState,
        conversation: ConversationMessageSnapshot,
        header: () -> ChatHeaderProbe?
    ) async throws {
        var pinned = conversation
        var message = try XCTUnwrap(pinned.messages.first)
        message.isPinned = true
        pinned.messages = [message]
        state.conversationStore.commitConversationSnapshots([pinned])
        try await headerStatusWait("pinned input on the mounted chat") {
            chatPinnedMessagesForRendering(header()?.owner.conversation.messages ?? []).map(\.id) == [message.id]
        }

        try XCTUnwrap(header()).actions.search()
        try await headerStatusWait("search shown on the mounted chat") { header()?.owner.showSearch == true }
        try XCTUnwrap(header()).actions.search()
        state.conversationStore.commitConversationSnapshots([conversation])
        try await headerStatusWait("pinned input and search cleared on the mounted chat") {
            guard let owner = header()?.owner else { return false }
            return !owner.showSearch && chatPinnedMessagesForRendering(owner.conversation.messages).isEmpty
        }
    }

    @MainActor private func assertMountedHeaderTopLayout() async throws {
        var frames: [HeaderTopSlot: CGRect] = [:]
        func layout(_ content: HeaderTopLayoutHarness.Content) -> AnyView {
            AnyView(HeaderTopLayoutHarness(content: content) { frames = $0 })
        }
        let hosted = try headerStatusHost(layout(.empty))
        defer { headerStatusRetire(hosted) }
        try await headerStatusWait("empty top context") { Set(frames.keys) == [.timeline] }
        let emptyTimeline = try XCTUnwrap(frames[.timeline])
        XCTAssertFalse(emptyTimeline.isEmpty)
        XCTAssertEqual(emptyTimeline.minY, 0, accuracy: 1)

        hosted.controller.rootView = layout(.full)
        try await headerStatusWait("announcement, pinned context and search") {
            Set(frames.keys) == [.announcement, .pinned, .search, .timeline]
        }
        let order: [HeaderTopSlot] = [.announcement, .pinned, .search, .timeline]
        let full = try order.map { try XCTUnwrap(frames[$0], "Missing frame for \($0)") }
        XCTAssertEqual(full[0].minY, emptyTimeline.minY, accuracy: 1)
        for (upper, lower) in zip(full, full.dropFirst()) {
            XCTAssertFalse(upper.isEmpty)
            XCTAssertEqual(upper.maxY, lower.minY, accuracy: 1)
        }

        hosted.controller.rootView = layout(.withoutPinned)
        try await headerStatusWait("visible top context with no pinned message") {
            Set(frames.keys) == [.announcement, .search, .timeline]
        }
        let announcement = try XCTUnwrap(frames[.announcement])
        let search = try XCTUnwrap(frames[.search])
        XCTAssertEqual(announcement.maxY, search.minY, accuracy: 1)

        hosted.controller.rootView = layout(.empty)
        try await headerStatusWait("empty top context after removal") { Set(frames.keys) == [.timeline] }
        XCTAssertEqual(try XCTUnwrap(frames[.timeline]).minY, emptyTimeline.minY, accuracy: 1)
    }
    // WDT_IOS1_CHAT_TOP_CONTEXT_FIXTURE_ISOLATION_20261111_END
    @MainActor
    func testHeaderAndStatusFrozen9BE69PixelMatrix() async throws {
        let state = try headerStatusState()
        let direct = headerStatusConversation(state)
        var latest: ChatHeaderProbe?
        ChatHeaderStatusDiagnostics.header = { latest = $0 }
        let actual = try headerStatusHost(AnyView(NavigationStackCompat { ChatView(conversationID: direct.id) }.appStateEnvironment(state)))
        try await headerStatusWait("pixel factory input") { latest != nil }
        let factory = try XCTUnwrap(latest).input
        headerStatusRetire(actual); ChatHeaderStatusDiagnostics.header = nil
        let inputs: [(String, ChatHeaderInput)] = [
            ("direct", factory),
            ("group-long", ChatHeaderInput(title: "这是很长的原群标题😀还有很长的一段文字", isGroup: true, groupMemberSubtitle: "128 人", isBatchSelecting: false, selectedSourceCount: 0, isReadOnlySystem: false, backUnreadCount: 128)),
            ("batch", ChatHeaderInput(title: "原群标题", isGroup: true, groupMemberSubtitle: "12 人", isBatchSelecting: true, selectedSourceCount: 12, isReadOnlySystem: false, backUnreadCount: 0)),
            ("system", ChatHeaderInput(title: "系统消息", isGroup: false, groupMemberSubtitle: nil, isBatchSelecting: false, selectedSourceCount: 0, isReadOnlySystem: true, backUnreadCount: 1))]
        for (name, input) in inputs {
            try headerStatusPixels(name, before: AnyView(ChatHeader9BE69Reference(input: input)),
                after: AnyView(ChatConversationHeaderView(input: input, actions: ChatHeaderActions(back: {}, search: {}, more: {}))), size: CGSize(width: 390, height: 80))
        }
        for repair in [false, true] {
            let banner = GroupMuteBannerDecision(title: repair ? "禁言状态需要管理员修复" : "全员禁言中", detail: "群主和管理员可继续发言。", isRepairRequired: repair)
            let name = repair ? "repair" : "mute"
            try headerStatusPixels(name, before: AnyView(ChatMute9BE69Reference(muteBanner: banner, detail: banner.detail)),
                after: AnyView(ChatGroupMuteStatusView(muteBanner: banner, detail: banner.detail)), size: CGSize(width: 390, height: 110))
        }
        try headerStatusPixels("announcement", before: AnyView(ChatAnnouncement9BE69Reference(title: "原公告标题", preview: "原公告摘要", isBusy: false)),
            after: AnyView(ChatGroupAnnouncementView(title: "原公告标题", preview: "原公告摘要", isBusy: false, open: {}, close: {})), size: CGSize(width: 390, height: 80))
    }
    @MainActor private func headerStatusPixels(_ name: String, before: AnyView, after: AnyView, size: CGSize) throws {
        func canvas(_ content: AnyView) -> AnyView {
            AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(uiColor: .systemBackground)).ignoresSafeArea().environment(\.colorScheme, .light))
        }
        let old = try headerStatusHost(canvas(before), size: size)
        let oldImage = hostedSnapshotImage(old); headerStatusRetire(old)
        let new = try headerStatusHost(canvas(after), size: size)
        let newImage = hostedSnapshotImage(new); headerStatusRetire(new)
        add(snapshotAttachment(oldImage, name: "header-status-\(name)-9be69")); add(snapshotAttachment(newImage, name: "header-status-\(name)-candidate"))
        let a = try headerStatusRGBA(oldImage), b = try headerStatusRGBA(newImage)
        XCTAssertEqual(a.count, b.count)
        let changed = stride(from: 0, to: min(a.count, b.count), by: 4).filter { Array(a[$0..<$0+4]) != Array(b[$0..<$0+4]) }.count
        let metrics = XCTAttachment(string: "pair=\(name) changedPixels=\(changed) width=\(Int(size.width)) height=\(Int(size.height))")
        metrics.name = "header-status-\(name)-pixel-metrics"; metrics.lifetime = .keepAlways; add(metrics)
        XCTAssertEqual(changed, 0, name)
    }
    private func headerStatusRGBA(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); return bytes
    }
}
// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_END
