import XCTest
@testable import BlueStoneIM

final class SnapshotCacheTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCachedMessageRoundTripPreservesAttachmentUploadFailure() throws {
        var message = makeMessage(id: "failed-upload", text: "fixture.gif", status: .failed)
        message.attachmentUploadStatus = "put_failed"
        message.attachmentUploadFailure = AttachmentUploadFailure(
            code: .http,
            httpStatus: 503,
            serverCode: "tenant_storage_secret_unresolved"
        )
        let encoded = try JSONEncoder().encode(CachedMessage(message: message))
        let restored = try JSONDecoder().decode(CachedMessage.self, from: encoded).model

        XCTAssertEqual(restored.id, message.id)
        XCTAssertEqual(restored.status, .failed)
        XCTAssertEqual(restored.attachmentUploadStatus, "put_failed")
        XCTAssertEqual(restored.attachmentUploadFailure, message.attachmentUploadFailure)
    }

    func testLegacyCachedMessageWithoutAttachmentUploadFailureStillRestores() throws {
        var message = makeMessage(id: "legacy-upload", text: "fixture.gif", status: .failed)
        message.attachmentUploadStatus = "put_failed"
        message.attachmentUploadFailure = AttachmentUploadFailure(code: .timeout)
        let encoded = try JSONEncoder().encode(CachedMessage(message: message))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachmentUploadFailure")
        let restored = try JSONDecoder().decode(
            CachedMessage.self,
            from: JSONSerialization.data(withJSONObject: object)
        ).model

        XCTAssertEqual(restored.id, message.id)
        XCTAssertEqual(restored.status, .failed)
        XCTAssertEqual(restored.attachmentUploadStatus, "put_failed")
        XCTAssertNil(restored.attachmentUploadFailure)
    }

    func testWriteThenLoadRoundTrip() async throws {
        let cache = makeCache()
        let scope = "account|tenant|uid|ios-main|device"
        let conversation = makeConversation(id: "conversation-1", title: "Design")
        let snapshot = CachedRemoteSnapshot(
            schemaVersion: cache.schemaVersion,
            scope: scope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: conversation, messageLimit: 40)]
        )

        let didWrite = await cache.writeNow(snapshot, scope: scope)
        XCTAssertTrue(didWrite)

        let loaded = await cache.load(scope: scope)

        XCTAssertEqual(loaded?.conversations.count, 1)
        XCTAssertEqual(loaded?.conversations.first?.id, conversation.id)
        XCTAssertEqual(loaded?.conversations.first?.title, conversation.title)
    }

    func testGroupAvatarProjectionRoundTripsForColdHydration() async throws {
        let cache = makeCache()
        let scope = "account|tenant|member|ios-main|device"
        var conversation = makeConversation(id: "group-1", title: "Group", kind: .group)
        conversation.avatarURL = "/api/tenant/avatar/group-file"
        conversation.avatarVersion = "group-version"
        conversation.avatarUpdatedAt = "2026-08-13T00:00:00Z"
        let snapshot = CachedRemoteSnapshot(
            schemaVersion: cache.schemaVersion,
            scope: scope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: conversation, messageLimit: 40)]
        )

        let didWrite = await cache.writeNow(snapshot, scope: scope)
        XCTAssertTrue(didWrite)
        let loaded = await cache.load(scope: scope)
        let hydrated = try XCTUnwrap(loaded?.conversations.first)

        XCTAssertEqual(hydrated.avatarURL, conversation.avatarURL)
        XCTAssertEqual(hydrated.avatarVersion, conversation.avatarVersion)
        XCTAssertEqual(hydrated.avatarUpdatedAt, conversation.avatarUpdatedAt)
    }

    func testLoadWithWrongScopeReturnsNil() async throws {
        let cache = makeCache()
        let snapshot = CachedRemoteSnapshot(
            schemaVersion: cache.schemaVersion,
            scope: "account|tenant|uid|ios-main|device",
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(), messageLimit: 40)]
        )

        let didWrite = await cache.writeNow(snapshot, scope: snapshot.scope)
        XCTAssertTrue(didWrite)

        let loaded = await cache.load(scope: "other|tenant|uid|ios-main|device")

        XCTAssertNil(loaded)
    }

    func testScopeKeySeparatesIdentityPartsAndEncodesDelimiters() {
        let cache = makeCache()
        let base = makeContext(accountID: "a|b", tenantID: "tenant", imUID: "uid", appID: "ios|main", deviceID: "device")
        let ambiguousWithoutEncoding = makeContext(accountID: "a", tenantID: "b|tenant", imUID: "uid", appID: "ios|main", deviceID: "device")
        let differentTenant = makeContext(accountID: "a|b", tenantID: "other", imUID: "uid", appID: "ios|main", deviceID: "device")
        let differentIMUser = makeContext(accountID: "a|b", tenantID: "tenant", imUID: "other", appID: "ios|main", deviceID: "device")
        let differentApp = makeContext(accountID: "a|b", tenantID: "tenant", imUID: "uid", appID: "other", deviceID: "device")
        let differentDevice = makeContext(accountID: "a|b", tenantID: "tenant", imUID: "uid", appID: "ios|main", deviceID: "other")
        let missingAccount = makeContext(accountID: nil, tenantID: "tenant", imUID: "uid", appID: "ios-main", deviceID: "device")
        let dashAccount = makeContext(accountID: "-", tenantID: "tenant", imUID: "uid", appID: "ios-main", deviceID: "device")

        let scope = cache.scopeKey(for: base)

        XCTAssertTrue(scope.hasPrefix("v2|account="))
        XCTAssertFalse(scope.contains("a|b"))
        XCTAssertNotEqual(scope, cache.scopeKey(for: ambiguousWithoutEncoding))
        XCTAssertNotEqual(scope, cache.scopeKey(for: differentTenant))
        XCTAssertNotEqual(scope, cache.scopeKey(for: differentIMUser))
        XCTAssertNotEqual(scope, cache.scopeKey(for: differentApp))
        XCTAssertNotEqual(scope, cache.scopeKey(for: differentDevice))
        XCTAssertNotEqual(cache.scopeKey(for: missingAccount), cache.scopeKey(for: dashAccount))
    }

    func testScopeKeyTrimsWhitespaceAndNormalizesMissingComponents() {
        let cache = makeCache()
        let spaced = makeContext(
            accountID: " account-1 ",
            tenantID: "\ttenant-1",
            imUID: "user-1\n",
            appID: " ios-main ",
            deviceID: "\ndevice-1\t"
        )
        let normalized = makeContext(
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "user-1",
            appID: "ios-main",
            deviceID: "device-1"
        )
        let blankAccount = makeContext(
            accountID: " \n ",
            tenantID: "tenant-1",
            imUID: "user-1",
            appID: "ios-main",
            deviceID: "device-1"
        )
        let missingAccount = makeContext(
            accountID: nil,
            tenantID: "tenant-1",
            imUID: "user-1",
            appID: "ios-main",
            deviceID: "device-1"
        )

        XCTAssertEqual(cache.scopeKey(for: spaced), cache.scopeKey(for: normalized))
        XCTAssertEqual(cache.scopeKey(for: blankAccount), cache.scopeKey(for: missingAccount))
    }

    func testLongScopeWritesToShortFilesystemSafeFileName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let cache = SnapshotCache(schemaVersion: SnapshotCache.defaultSchemaVersion, directoryURL: directory)
        let scope = (0..<12)
            .map { index in "component-\(index)-\(String(repeating: "abcdef", count: 12))" }
            .joined(separator: "|")
        let snapshot = CachedRemoteSnapshot(
            schemaVersion: cache.schemaVersion,
            scope: scope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(), messageLimit: 40)]
        )

        let didWrite = await cache.writeNow(snapshot, scope: scope)
        let loaded = await cache.load(scope: scope)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        XCTAssertTrue(didWrite)
        XCTAssertEqual(loaded?.conversations.count, 1)
        XCTAssertEqual(files.count, 1)
        XCTAssertLessThanOrEqual(files[0].lastPathComponent.count, 80)
        XCTAssertFalse(files[0].lastPathComponent.contains("|"))
    }

    func testCachedConversationRoundTripPreservesMessageSenderAvatarSnapshot() {
        var conversation = makeConversation(id: "group-1", title: "全员公告群")
        var message = makeMessage(id: "m1", text: "的", status: .read)
        message.senderProvenance = .authoritativeStored
        message.senderAvatarURL = "https://avatar.example/mengyao.png"
        message.senderAvatarVersion = "v3"
        message.senderAvatarUpdatedAt = "2026-06-25T12:00:00Z"
        message.senderAvatarSeed = 0x7C6BFF
        conversation.messages = [message]
        conversation.lastMsgSeq = 43
        conversation.messageCoveredThroughSeq = 41
        conversation.messageCoverageRequiresRecovery = true

        let restoredConversation = CachedConversation(conversation: conversation, messageLimit: 40).model
        let restored = restoredConversation.messages.first

        XCTAssertEqual(restored?.senderProvenance, .authoritativeStored)
        XCTAssertEqual(restored?.senderAvatarURL, "https://avatar.example/mengyao.png")
        XCTAssertEqual(restored?.senderAvatarVersion, "v3")
        XCTAssertEqual(restored?.senderAvatarUpdatedAt, "2026-06-25T12:00:00Z")
        XCTAssertEqual(restored?.senderAvatarSeed, 0x7C6BFF)
        XCTAssertEqual(restoredConversation.lastMsgSeq, 43)
        XCTAssertEqual(restoredConversation.messageCoveredThroughSeq, 41)
        XCTAssertTrue(restoredConversation.messageCoverageRequiresRecovery)
    }

    func testLegacyCachedMessageWithoutSenderProvenanceFailsClosedAsUnknown() throws {
        var conversation = makeConversation(id: "group-legacy", title: "旧缓存群")
        var message = makeMessage(id: "legacy-message", text: "voice", status: .read)
        message.senderProvenance = .authoritativeStored
        conversation.messages = [message]
        let encoded = try JSONEncoder().encode(
            CachedConversation(conversation: conversation, messageLimit: 40)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        messages[0].removeValue(forKey: "senderProvenance")
        object["messages"] = messages

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder()
            .decode(CachedConversation.self, from: legacyData)
            .model
            .messages
            .first

        XCTAssertEqual(restored?.senderId, "u1")
        XCTAssertEqual(restored?.senderProvenance, .unknown)
    }

    func testDeletedMessageTombstoneRoundTripsThroughSnapshot() {
        var conversation = makeConversation()
        var message = makeMessage(id: "m1", text: "原消息已删除", status: .recalled)
        message.isDeletedLocally = true
        message.attachmentName = nil
        message.attachmentPreviewURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewAvailable = false
        message.attachmentDownloadAvailable = false
        conversation.messages = [message]

        let restored = CachedConversation(conversation: conversation, messageLimit: 40).model.messages.first

        XCTAssertEqual(restored?.id, "m1")
        XCTAssertEqual(restored?.status, .recalled)
        XCTAssertTrue(restored?.isDeletedLocally == true)
        XCTAssertEqual(restored?.text, "原消息已删除")
    }

    func testExpiredSnapshotReturnsNil() async throws {
        let cache = makeCache(maxAge: 1)
        let scope = "account|tenant|uid|ios-main|device"
        let snapshot = CachedRemoteSnapshot(
            schemaVersion: cache.schemaVersion,
            scope: scope,
            createdAt: Date().addingTimeInterval(-10).timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(), messageLimit: 40)]
        )

        let didWrite = await cache.writeNow(snapshot, scope: scope)
        XCTAssertTrue(didWrite)

        let loaded = await cache.load(scope: scope)

        XCTAssertNil(loaded)
    }

    func testMessageStoreRemoveDeletesOnlyRequestedScope() async throws {
        let store: any MessageStore = makeCache()
        let firstScope = "account-a|tenant|uid|ios-main|device"
        let secondScope = "account-b|tenant|uid|ios-main|device"
        let firstSnapshot = CachedRemoteSnapshot(
            schemaVersion: store.schemaVersion,
            scope: firstScope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(id: "conversation-a"), messageLimit: 40)]
        )
        let secondSnapshot = CachedRemoteSnapshot(
            schemaVersion: store.schemaVersion,
            scope: secondScope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(id: "conversation-b"), messageLimit: 40)]
        )

        let didWriteFirst = await store.writeNow(firstSnapshot, scope: firstScope)
        let didWriteSecond = await store.writeNow(secondSnapshot, scope: secondScope)
        XCTAssertTrue(didWriteFirst)
        XCTAssertTrue(didWriteSecond)

        store.remove(scope: firstScope)

        let removed = await store.load(scope: firstScope)
        let retained = await store.load(scope: secondScope)
        XCTAssertNil(removed)
        XCTAssertEqual(retained?.conversations.first?.id, "conversation-b")
    }

    func testMessageStoreRemoveAllDeletesEveryStoredScope() async throws {
        let store: any MessageStore = makeCache()
        let firstScope = "account-a|tenant|uid|ios-main|device"
        let secondScope = "account-b|tenant|uid|ios-main|device"
        let firstSnapshot = CachedRemoteSnapshot(
            schemaVersion: store.schemaVersion,
            scope: firstScope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(id: "conversation-a"), messageLimit: 40)]
        )
        let secondSnapshot = CachedRemoteSnapshot(
            schemaVersion: store.schemaVersion,
            scope: secondScope,
            createdAt: Date().timeIntervalSince1970,
            conversations: [CachedConversation(conversation: makeConversation(id: "conversation-b"), messageLimit: 40)]
        )

        let didWriteFirst = await store.writeNow(firstSnapshot, scope: firstScope)
        let didWriteSecond = await store.writeNow(secondSnapshot, scope: secondScope)
        XCTAssertTrue(didWriteFirst)
        XCTAssertTrue(didWriteSecond)

        store.removeAll()

        let firstLoaded = await store.load(scope: firstScope)
        let secondLoaded = await store.load(scope: secondScope)
        XCTAssertNil(firstLoaded)
        XCTAssertNil(secondLoaded)
    }

    @MainActor
    func testAppStateAcceptsInjectedMessageStore() {
        let state = AppState(messageStore: EmptyMessageStore())

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authScreen, .accountLogin)
    }

    @MainActor
    func testColdLaunchWithoutCachedOrRemoteSnapshotRetainsAuthenticatedSession() async {
        let context = makeRealtimeContext()
        let state = AppState(
            realtimeClient: RecordingRealtimeTransport(),
            messageStore: EmptyMessageStore(),
            apiContextOverride: context
        )
        state.isAuthenticated = true
        state.isRestoringSession = true
        state.hasLoadedRemoteSnapshot = false

        await state.completeColdLaunchSessionRestore(
            restoringContext: context,
            synced: false
        )

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.hasActiveIMSession)
        XCTAssertFalse(state.isRestoringSession)
        XCTAssertEqual(state.toast, "登录状态已保留，数据同步失败，请稍后重试")
    }

    @MainActor
    func testVerifiedTenantContextBindingMismatchClearsAuthenticatedSession() throws {
        let context = makeRealtimeContext()
        let state = AppState(messageStore: EmptyMessageStore(), apiContextOverride: context)
        state.isAuthenticated = true
        let response = try JSONDecoder().decode(
            RemoteTenantContext.self,
            from: Data(#"{"tenant_id":"tenant-other","im_uid":"uid-1","app_id":"com.bluestone.im.app1","device_id":"snapshot-cache-test-device","tenant":{"tenant_id":"tenant-other"},"user":{"im_uid":"uid-1","account_id":"account-1"}}"#.utf8)
        )

        XCTAssertFalse(state.applyTenantContext(response))
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.hasActiveIMSession)
        XCTAssertEqual(state.authScreen, .accountLogin)
    }

    func testSessionScopeLogTokenDoesNotExposeRawIdentityScope() {
        let rawScope = "tenant-1|uid-1|account-1|credential-token"
        let logToken = AppState.sessionScopeLogToken(rawScope)

        XCTAssertTrue(logToken.hasPrefix("scope:hash:"))
        XCTAssertFalse(logToken.contains(rawScope))
        XCTAssertFalse(logToken.contains("tenant-1"))
        XCTAssertFalse(logToken.contains("credential-token"))
    }

    @MainActor
    func testAppStateAcceptsInjectedRealtimeTransport() {
        let realtime = RecordingRealtimeTransport()
        let state = AppState(realtimeClient: realtime, messageStore: EmptyMessageStore())

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertTrue(realtime.hasConfiguredCallbacks)
    }

    @MainActor
    func testAppStateBackgroundDisablesRealtimeReconnectAndDoesNotDial() {
        let realtime = RecordingRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            messageStore: EmptyMessageStore(),
            apiContextOverride: makeRealtimeContext()
        )
        state.isAuthenticated = true

        state.appDidEnterBackground()

        XCTAssertEqual(realtime.startCount, 0)
        XCTAssertEqual(realtime.disconnectCount, 1)
        XCTAssertFalse(realtime.canReconnect?() ?? true)
    }

    @MainActor
    func testAppStateFirstSceneActivationStartsRestoredRealtimeExactlyOnce() {
        let realtime = RecordingRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            messageStore: EmptyMessageStore(),
            apiContextOverride: makeRealtimeContext()
        )
        state.isAuthenticated = true

        state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: false)
        XCTAssertEqual(realtime.startCount, 0)
        XCTAssertFalse(realtime.canReconnect?() ?? true)

        state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(realtime.startCount, 1)
        XCTAssertTrue(realtime.canReconnect?() ?? false)

        state.iosRiskTelemetrySceneDidBecomeAvailable(isActive: true)
        XCTAssertEqual(realtime.startCount, 1)

        state.appDidEnterBackground()
        XCTAssertEqual(realtime.startCount, 1)
        XCTAssertEqual(realtime.disconnectCount, 1)
        XCTAssertFalse(realtime.canReconnect?() ?? true)
    }

    @MainActor
    func testAppStateRealtimeReconnectNoticeIsSuppressedWhenConnectionRecoversWithinGracePeriod() async throws {
        let realtime = RecordingRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            messageStore: EmptyMessageStore(),
            realtimeReconnectNoticeDelayNanoseconds: 40_000_000,
            realtimeReconnectNoticeThrottleInterval: 60,
            apiContextOverride: makeRealtimeContext()
        )
        state.isAuthenticated = true

        realtime.onConnectionStateChanged?(false)
        realtime.onDisconnected?()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNil(state.toast)

        realtime.onConnectionStateChanged?(true)
        realtime.onConnected?()
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(state.toast)
    }

    @MainActor
    func testAppStateRealtimeReconnectNoticeShowsAfterGracePeriodAndThrottlesRepeats() async throws {
        let realtime = RecordingRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            messageStore: EmptyMessageStore(),
            realtimeReconnectNoticeDelayNanoseconds: 20_000_000,
            realtimeReconnectNoticeThrottleInterval: 60,
            apiContextOverride: makeRealtimeContext()
        )
        state.isAuthenticated = true

        realtime.onConnectionStateChanged?(false)
        realtime.onDisconnected?()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.toast, "实时连接中断，正在重连")

        state.toast = nil
        realtime.onDisconnected?()
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(state.toast)
    }

    @MainActor
    func testAppStateAcceptsInjectedConversationStore() {
        let store = ConversationStore()
        let state = AppState(conversationStore: store, messageStore: EmptyMessageStore())

        XCTAssertTrue(state.conversationStore === store)
        XCTAssertFalse(state.isAuthenticated)
    }

    private func makeCache(maxAge: TimeInterval = SnapshotCache.defaultMaxAge) -> SnapshotCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return SnapshotCache(schemaVersion: SnapshotCache.defaultSchemaVersion, maxAge: maxAge, directoryURL: directory)
    }

    private func makeRealtimeContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "im-token",
            imAPIBaseURL: "http://127.0.0.1:5174",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "snapshot-cache-test-device"
        )
    }

    private func makeContext(
        accountID: String?,
        tenantID: String,
        imUID: String,
        appID: String,
        deviceID: String
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: accountID,
            tenantID: tenantID,
            imUID: imUID,
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: appID,
            deviceID: deviceID
        )
    }

    private func makeConversation(
        id: String = "conversation-1",
        title: String = "Design",
        kind: ConversationKind = .direct
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            subtitle: "Alice",
            kind: kind,
            lastMessage: "hello",
            time: "09:00",
            unread: 1,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0x2266CC,
            participants: [
                IMUser(
                    id: "u1",
                    name: "Alice",
                    title: "Designer",
                    department: "Product",
                    phone: "",
                    email: "alice@example.test",
                    status: "online",
                    enterprise: "BlueStone",
                    avatarSeed: 1,
                    badges: []
                )
            ],
            messages: [],
            sortTimestamp: 1_777_000_000
        )
    }

    private func makeMessage(id: String, text: String, status: MessageDelivery) -> ChatMessage {
        ChatMessage(
            id: id,
            senderId: "u1",
            senderName: "Alice",
            text: text,
            time: "09:00",
            channelSeq: 1,
            isOutgoing: false,
            status: status,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
    }
}

private struct EmptyMessageStore: MessageStore {
    let schemaVersion = 99

    func scopeKey(for context: IMAPIContext) -> String {
        "test-scope|\(context.deviceID)"
    }

    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? {
        nil
    }

    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool {
        true
    }

    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool {
        true
    }

    func remove(scope: String) {}

    func removeAll() {}
}

@MainActor
private final class RecordingRealtimeTransport: RealtimeTransporting, @unchecked Sendable {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)?
    private(set) var isConnected = false
    private(set) var startCount = 0
    private(set) var disconnectCount = 0

    var hasConfiguredCallbacks: Bool {
        connectionRequestProvider != nil
            && canReconnect != nil
            && onConnectionUnavailable != nil
            && onConnectionStateChanged != nil
            && onConnected != nil
            && onDisconnected != nil
            && onReconnectAttempt != nil
            && onEnvelope != nil
    }

    func start(url: URL, token: String) {
        startCount += 1
    }

    func disconnect(shouldReconnect: Bool) {
        disconnectCount += 1
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {}
}
