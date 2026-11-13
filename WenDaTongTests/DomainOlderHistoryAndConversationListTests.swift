@testable import IM4Features
@testable import IM4Stores // WDT_IOS1_STICKER_STATE_FAMILY_20261110
import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func assertManualOlderRTCHistoryPage(
        malformedField: String?, authorityInOtherConversation: Bool = false
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-rtc-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorityChannel = "friend-1:uid-1"
        let targetChannel = authorityInOtherConversation ? "friend-2:uid-1" : authorityChannel
        var authoritativeObject = historicalRTCMessageObject(outer: "2026-08-24T00:01:45Z")
        authoritativeObject["message_id"] = "m100"
        authoritativeObject["channel_seq"] = 100
        var authoritativePayload = try XCTUnwrap(authoritativeObject["payload"] as? [String: Any])
        authoritativePayload["call_id"] = "callA"
        authoritativeObject["payload"] = authoritativePayload
        var olderObject = authoritativeObject
        olderObject["message_id"] = "m99"
        olderObject["channel_seq"] = 99
        olderObject["channel_id"] = targetChannel
        if let malformedField {
            var malformedPayload = authoritativePayload
            if malformedField == "schema_version" {
                malformedPayload[malformedField] = 2
            } else {
                malformedPayload[malformedField] = "2026-08-23T23:58:00Z"
            }
            olderObject["payload"] = malformedPayload
        } else {
            olderObject["content_type"] = "text"
            olderObject["payload"] = ["text": "普通旧消息"]
        }
        let pageData = try JSONSerialization.data(withJSONObject: [
            "ok": true, "data": ["items": [olderObject], "has_more_before": true, "total": 1]
        ])
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: pageData, isHTTPResponse: true, statusCode: 200)
        ])
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let syncEngine = DefaultSyncEngine()
        _ = syncEngine.beginRemoteSnapshotRefresh()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: NoopVideoMediaClient(), messagePersistence: persistence,
            remoteSyncEngine: syncEngine, apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let authoritativeRemote = try JSONDecoder().decode(
            RemoteMessage.self, from: JSONSerialization.data(withJSONObject: authoritativeObject)
        )
        let authoritativeMessage = state.debugChatMessageForTesting(authoritativeRemote)
        XCTAssertEqual(authoritativeMessage.rtcCallRecord?.callID, "callA")
        let originalAuthority = try XCTUnwrap(RTCCallRecordMessageDeduplicator.authority(for: authoritativeMessage))
        var target = makeConversation(id: targetChannel, unread: 0, lastMsgSeq: 100, lastReadSeq: 98)
        target.messages = [authorityInOtherConversation
            ? makeMessage(id: "target-m100", seq: 100, text: "目标会话原消息")
            : authoritativeMessage]
        target.messageCoveredThroughSeq = 100
        target.messageCoverageRequiresRecovery = false
        var initial = [target]
        if authorityInOtherConversation {
            var owner = makeConversation(id: authorityChannel, unread: 0, lastMsgSeq: 100, lastReadSeq: 100)
            owner.messages = [authoritativeMessage]
            owner.messageCoveredThroughSeq = 100
            initial.append(owner)
        }
        state.conversationStore.commitConversationSnapshots(initial)

        XCTAssertTrue(state.loadOlderMessagesIfAvailable(targetChannel))
        for _ in 0..<200 {
            if !state.conversationStore.isHistoryLoading(conversationID: targetChannel) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(state.conversationStore.isHistoryLoading(conversationID: targetChannel))
        let syncRequest = try XCTUnwrap(transport.requests().first { $0.url?.path == "/api/im/sync" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(syncRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["before_seq"] as? Int, 100)
        XCTAssertEqual(body["after_seq"] as? Int, 0)
        XCTAssertEqual(body["channel_id"] as? String, targetChannel)
        XCTAssertEqual(body["channel_type"] as? String, "direct")
        let result = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first { $0.id == targetChannel })
        let retainedOwner = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first { $0.id == authorityChannel })
        let retained = try XCTUnwrap(retainedOwner.messages.first { $0.id == "m100" })
        XCTAssertEqual(RTCCallRecordMessageDeduplicator.authority(for: retained), originalAuthority)
        XCTAssertEqual(result.unread, 0, "Manual history is not an incoming realtime unread event")
        XCTAssertEqual(result.lastMsgSeq, 100)
        if malformedField != nil {
            XCTAssertEqual(result.messages.map(\.id), target.messages.map(\.id))
            XCTAssertFalse(result.messages.contains { $0.id == "m99" }, "Do not retain a malformed RTC fallback row")
            XCTAssertEqual(result.messageCoveredThroughSeq, 98)
            XCTAssertTrue(result.messageCoverageRequiresRecovery)
            XCTAssertEqual(state.conversationStore.latestReadableSequence(in: result), 98)
        } else {
            XCTAssertEqual(result.messages.map(\.id), ["m99", "m100"])
            XCTAssertEqual(result.messages.first?.text, "普通旧消息")
            XCTAssertEqual(result.messageCoveredThroughSeq, 100)
            XCTAssertFalse(result.messageCoverageRequiresRecovery)
            XCTAssertEqual(state.conversationStore.latestReadableSequence(in: result), 100)
        }
        if authorityInOtherConversation {
            XCTAssertEqual(retainedOwner.messageCoveredThroughSeq, 100)
            XCTAssertFalse(retainedOwner.messageCoverageRequiresRecovery)
        }
    }

    func testHighSensitivityMediaPolicyDecodesToOfflineDeny() throws {
        let nested = try JSONDecoder().decode(
            RemoteTenantClientPolicy.self,
            from: Data(#"{"media_cache":{"offline_policy":"high_sensitivity"}}"#.utf8)
        )
        XCTAssertTrue(nested.mediaOfflinePolicyPresent)
        XCTAssertEqual(nested.mediaOfflinePolicy, "high_sensitivity")
        XCTAssertEqual(AppState.mediaOfflinePolicy(for: nested), .deny)

        let defaultPolicy = try JSONDecoder().decode(
            RemoteTenantClientPolicy.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertFalse(defaultPolicy.mediaOfflinePolicyPresent)
        XCTAssertEqual(AppState.mediaOfflinePolicy(for: defaultPolicy), .bounded)
    }

    func testStickerStoreCachesByScopeAndMovesWithoutPersistingSignedURLs() throws {
        let suiteName = "BlueStoneIMTests.stickers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = StickerLibraryItem(
            id: "us-1",
            stickerID: "st-1",
            fileID: "file-1",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 96,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-1",
            version: "v1",
            thumbnailURL: "https://cdn.example.test/thumb.gif?token=secret",
            variants: [
                StickerAssetVariant(
                    kind: "thumb",
                    fileID: "thumb-1",
                    mimeType: "image/png",
                    assetURL: "//cdn.example.test/sticker.gif?SIG=fixture", // WDT_IOS1_STICKER_MANIFEST_R2_20261111
                    sizeBytes: 256,
                    width: 64,
                    height: 64,
                    durationMS: nil,
                    frameCount: nil,
                    thumbnailURL: "/api/tenant/files/thumb-1/thumbnail",
                    cacheKey: "thumb-cache"
                )
            ],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )
        let second = StickerLibraryItem(
            id: "us-2",
            stickerID: "st-2",
            fileID: "file-2",
            packID: "",
            source: .mine,
            status: "queued",
            processingStatus: "processing",
            sort: 2,
            mimeType: "image/gif",
            sizeBytes: 2048,
            width: 128,
            height: 128,
            durationMS: 700,
            frameCount: 9,
            cacheKey: "cache-2",
            version: "v2",
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
            thumbnailURL: "/media/sticker.gif?s%69g=fixture",
            variants: [StickerAssetVariant(kind: "preview", fileID: "file-2", mimeType: "image/gif",
                assetURL: "media/preview.gif?size=128", sizeBytes: nil, width: nil, height: nil,
                durationMS: nil, frameCount: nil, thumbnailURL: "media/preview.gif?Signature=fixture", cacheKey: "")],
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
            createdAt: "2026-06-26T01:01:00Z",
            updatedAt: "2026-06-26T01:01:00Z"
        )
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        let key = "im2.ios.stickerManifest.2d15268f17844393"
        let legacy = CachedStickerManifest(schemaVersion: 1, scope: "tenant-a|uid-a", updatedAt: 100,
            myStickers: [first.persistentCacheCopy])
        let oldBytes = try JSONEncoder().encode(legacy)
        defaults.set(oldBytes, forKey: key)
        let store = StickerStore(defaults: defaults)
        let binding = store.activate(scope: TestMessageMemoryScope.value, legacyKey: "tenant-a|uid-a") // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        XCTAssertEqual(store.myStickers, legacy.myStickers)
        XCTAssertEqual(defaults.data(forKey: key), oldBytes)
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END

        store.replaceMyStickers([second, first], binding: binding)
        XCTAssertEqual(store.myStickers.map(\.id), ["us-1", "us-2"])
        XCTAssertTrue(store.myStickers[1].isProcessing)
        XCTAssertEqual(store.myStickers[1].thumbnailURL, "/media/sticker.gif?s%69g=fixture") // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        XCTAssertEqual(store.myStickers[0].variants.first?.assetURL, "//cdn.example.test/sticker.gif?SIG=fixture") // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        XCTAssertEqual(store.moveUserSticker(id: "us-2", direction: -1, binding: binding), ["us-2", "us-1"])

        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        let stored = try XCTUnwrap(defaults.data(forKey: key))
        let storedRecord = try JSONDecoder().decode(CachedStickerManifest.self, from: stored)
        XCTAssertEqual(storedRecord.schemaVersion, 1)
        XCTAssertEqual(storedRecord.scope, "tenant-a|uid-a")
        let reloadedSameScope = StickerStore(defaults: defaults)
        var renderedIDs = Set<String>()
        let panel = ChatExpressionPanel(
            stickerStore: reloadedSameScope, selectedTab: .constant(.stickers), emojis: [],
            insertEmoji: { _ in }, addStickerPhoto: {}, sendSticker: { _ in },
            prepareStickers: { reloadedSameScope.activate(scope: TestMessageMemoryScope.value, legacyKey: "tenant-a|uid-a") }, refreshStickers: {},
            stickerThumbnailURL: { item in renderedIDs.insert(item.id); return "" },
            retrySticker: { _ in }, deleteSticker: { _ in }, moveSticker: { _, _ in }
        )
        let hosted = hostForSimulatorUI(panel, size: CGSize(width: 390, height: 360))
        defer { hosted.window.isHidden = true }
        XCTAssertEqual(renderedIDs, Set(["us-1", "us-2"]))
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END
        XCTAssertEqual(reloadedSameScope.myStickers.map(\.id), ["us-2", "us-1"])
        XCTAssertEqual(reloadedSameScope.myStickers.first(where: { $0.id == "us-1" })?.thumbnailURL, "")
        XCTAssertEqual(reloadedSameScope.myStickers.first(where: { $0.id == "us-1" })?.variants.first?.thumbnailURL, "/api/tenant/files/thumb-1/thumbnail")
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        XCTAssertEqual(reloadedSameScope.myStickers.first(where: { $0.id == "us-1" })?.variants.first?.assetURL, "")
        let secondCached = try XCTUnwrap(reloadedSameScope.myStickers.first(where: { $0.id == "us-2" }))
        XCTAssertEqual(secondCached.thumbnailURL, "")
        XCTAssertEqual(secondCached.variants.first?.thumbnailURL, "")
        XCTAssertEqual(secondCached.variants.first?.assetURL, "media/preview.gif?size=128")
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("=fixture"))
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END

        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        let otherKey = "im2.ios.stickerManifest.5dfdb83a2ad1b333"
        defaults.set(oldBytes, forKey: otherKey) // Its envelope still belongs to scope A.
        let reloadedOtherScope = StickerStore(defaults: defaults)
        reloadedOtherScope.activate(scope: TestMessageMemoryScope.value, legacyKey: "tenant-b|uid-b")
        XCTAssertTrue(reloadedOtherScope.myStickers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), stored)
        XCTAssertEqual(defaults.data(forKey: otherKey), oldBytes)
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END
    }

    // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
    @MainActor
    func testStickerPanelRendersStoreChangesWithoutPublishingAppState() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let scope = "sticker-panel-\(UUID().uuidString)"
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        var preparationCount = 0
        var renderedUploadTitles: [String] = []
        let root = ChatExpressionPanel(
            stickerStore: state.stickerStore,
            selectedTab: .constant(.stickers),
            emojis: [],
            insertEmoji: { _ in },
            addStickerPhoto: {},
            sendSticker: { _ in },
            prepareStickers: { preparationCount += 1 },
            refreshStickers: {},
            stickerThumbnailURL: { item in
                if let title = item.uploadTileTitle {
                    renderedUploadTitles.append(title)
                }
                return ""
            },
            retrySticker: { _ in },
            deleteSticker: { _ in },
            moveSticker: { _, _ in }
        )
        let hosted = hostForSimulatorUI(root, size: CGSize(width: 390, height: 360))
        defer { hosted.window.isHidden = true }
        XCTAssertEqual(preparationCount, 1)
        XCTAssertTrue(renderedUploadTitles.isEmpty)

        var appStateChanges = 0
        let observation = state.objectWillChange.sink { appStateChanges += 1 }
        defer { observation.cancel() }

        let binding = state.stickerStore.activate(scope: TestMessageMemoryScope.value, legacyKey: scope) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        state.stickerStore.beginLocalUpload(
            id: uploadID, name: "wave.png", mimeType: "image/png", sizeBytes: 1,
            data: Data([0]), conversationID: "conversation-1", binding: binding
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosted.controller.view.layoutIfNeeded()
        XCTAssertEqual(renderedUploadTitles.last, "2%")

        state.stickerStore.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.36, binding: binding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosted.controller.view.layoutIfNeeded()
        XCTAssertEqual(renderedUploadTitles.last, "36%")

        state.stickerStore.resetRuntime()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(appStateChanges, 0)
        XCTAssertEqual(preparationCount, 1)
    }
    // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END

    func testStickerThumbnailURLDoesNotExposeTenantFileEndpointToImageView() {
        let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
        let endpointOnly = StickerLibraryItem(
            id: "us-endpoint",
            stickerID: "st-endpoint",
            fileID: "file-endpoint",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 128,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-endpoint",
            version: "v1",
            thumbnailURL: "/api/tenant/files/file-endpoint/thumbnail",
            variants: [
                StickerAssetVariant(
                    kind: "original",
                    fileID: "file-endpoint",
                    mimeType: "image/gif",
                    assetURL: "/api/tenant/files/file-endpoint/presign-download",
                    sizeBytes: 1024,
                    width: 128,
                    height: 128,
                    durationMS: 600,
                    frameCount: 8,
                    thumbnailURL: "/api/tenant/files/file-endpoint/thumbnail",
                    cacheKey: "cache-endpoint"
                )
            ],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )
        let signed = StickerLibraryItem(
            id: "us-signed",
            stickerID: "st-signed",
            fileID: "file-signed",
            packID: "",
            source: .mine,
            status: "active",
            processingStatus: "active",
            sort: 1,
            mimeType: "image/gif",
            sizeBytes: 1024,
            width: 128,
            height: 128,
            durationMS: 600,
            frameCount: 8,
            cacheKey: "cache-signed",
            version: "v1",
            thumbnailURL: "https://cdn.example.test/sticker.gif?signature=safe-for-render",
            variants: [],
            createdAt: "2026-06-26T01:00:00Z",
            updatedAt: "2026-06-26T01:00:00Z"
        )

        XCTAssertEqual(state.stickerThumbnailURL(for: endpointOnly), "")
        XCTAssertEqual(state.stickerThumbnailURL(for: signed), "https://cdn.example.test/sticker.gif?signature=safe-for-render")
    }

    // WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111: Sticker manifest tests and private fixtures moved to DomainStickerManifestTests.swift.

    func testStickerStoreLocalUploadTileTracksProgressAndStaysOutOfCache() throws {
        let suiteName = "BlueStoneIMTests.stickerUploadTile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = StickerStore(defaults: defaults)
        let scope = "tenant-a|uid-a"
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let binding = store.activate(scope: TestMessageMemoryScope.value, legacyKey: scope) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        store.beginLocalUpload(
            id: uploadID,
            name: "wave.png",
            mimeType: "image/png",
            sizeBytes: imageData.count,
            data: imageData,
            conversationID: "conversation-1",
            binding: binding
        )

        XCTAssertEqual(store.myStickers.map(\.id), [uploadID])
        XCTAssertTrue(store.myStickers[0].isLocalUploadPlaceholder)
        XCTAssertEqual(store.myStickers[0].uploadTileTitle, "2%")
        XCTAssertEqual(store.myStickers[0].uploadSubtitle, "上传中")
        XCTAssertTrue(store.isUploading)

        store.updateLocalUpload(id: uploadID, phase: .uploading, progress: 0.36, binding: binding)
        XCTAssertEqual(store.myStickers[0].uploadTileTitle, "36%")
        XCTAssertEqual(store.localUploadDraft(id: uploadID)?.conversationID, "conversation-1")

        store.failLocalUpload(id: uploadID, binding: binding)
        XCTAssertFalse(store.isUploading)
        XCTAssertTrue(store.myStickers[0].isFailed)
        XCTAssertEqual(store.myStickers[0].statusTitle, "失败")
        XCTAssertNotNil(store.localUploadDraft(id: uploadID))

        let reloaded = StickerStore(defaults: defaults)
        reloaded.activate(scope: TestMessageMemoryScope.value, legacyKey: scope)
        XCTAssertTrue(reloaded.myStickers.isEmpty)

        store.removeLocalUpload(id: uploadID, binding: binding)
        XCTAssertTrue(store.myStickers.isEmpty)
        XCTAssertNil(store.localUploadDraft(id: uploadID))
    }

    // WDT_CONVERSATION_LIST_SORT_20261021_BEGIN
    func testConversationListMessageTimeAfterDeleteDoesNotMutateBusinessState() throws {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "sort-delete", unread: 2, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1)
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m2", seq: 2)
        latest.createdAt = Date(timeIntervalSince1970: 200)
        conversation.messages = [older, latest]
        conversation.sortTimestamp = 200
        conversation.isPinned = true
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyAdminDeletedMessage(messageID: "m2", channelIDForConversation: { $0.id }))
        let afterDelete = try XCTUnwrap(store.conversationMessageSnapshots().first)
        XCTAssertEqual(afterDelete.sortTimestamp, 200)
        XCTAssertEqual(afterDelete.lastMessage, "m1")
        XCTAssertEqual(afterDelete.lastMsgSeq, 2)
        XCTAssertEqual(afterDelete.unread, 2)
        XCTAssertTrue(afterDelete.isPinned)
        XCTAssertEqual(conversationListMessageTimestamp(afterDelete), 100)
        XCTAssertEqual(store.conversationMessageSnapshots().first, afterDelete)
    }

    func testConversationListRecallKeepsOriginalMessageTime() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "sort-recall", unread: 2, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1)
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m2", seq: 2)
        latest.createdAt = Date(timeIntervalSince1970: 200)
        conversation.messages = [older, latest]
        conversation.sortTimestamp = 900
        store.commitConversationSnapshots([conversation])

        XCTAssertTrue(store.applyRecall(messageID: "m1"))
        XCTAssertEqual(conversationListMessageTimestamp(store.conversationMessageSnapshots()[0]), 200)
        XCTAssertTrue(store.applyRecall(messageID: "m2"))
        XCTAssertEqual(conversationListMessageTimestamp(store.conversationMessageSnapshots()[0]), 200)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].messages[1].status, .recalled)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 900)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMsgSeq, 2)
    }

    func testConversationListRemovingFailedOutgoingRestoresRemainingMessageTime() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "sort-failed", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        var sent = makeMessage(id: "m1", seq: 1)
        sent.createdAt = Date(timeIntervalSince1970: 100)
        var pending = makeMessage(id: "local_failed", seq: 0, status: .failed, isOutgoing: true)
        pending.createdAt = Date(timeIntervalSince1970: 200)
        conversation.messages = [sent, pending]
        conversation.sortTimestamp = 200
        store.commitConversationSnapshots([conversation])

        XCTAssertNil(conversationListMessageTimestamp(store.conversationMessageSnapshots()[0]))
        XCTAssertTrue(store.removeMessage(messageID: pending.id, conversationID: conversation.id))
        XCTAssertEqual(conversationListMessageTimestamp(store.conversationMessageSnapshots()[0]), 100)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].sortTimestamp, 200)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastMsgSeq, 1)
    }

    func testConversationListMessageTimestampProtectsIncompleteHistoryAndPendingMessages() {
        var conversation = makeConversation(id: "sort-guards", unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1)
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m3", seq: 3)
        latest.createdAt = Date(timeIntervalSince1970: 300)
        conversation.sortTimestamp = 900

        conversation.messages = []
        XCTAssertNil(conversationListMessageTimestamp(conversation))
        conversation.messages = [older]
        XCTAssertNil(conversationListMessageTimestamp(conversation))
        latest.isDeletedLocally = true
        conversation.messages = [older, latest]
        XCTAssertNil(conversationListMessageTimestamp(conversation), "Sequence 2 is unknown, not necessarily deleted")
        conversation.messages = [latest]
        XCTAssertNil(conversationListMessageTimestamp(conversation), "An all-deleted page is not an empty conversation")
        latest.isDeletedLocally = false
        latest.createdAt = nil
        conversation.messages = [older, latest]
        XCTAssertNil(conversationListMessageTimestamp(conversation), "Do not use an older date when the latest date is missing")
        latest.createdAt = Date(timeIntervalSince1970: 300)
        for status in [MessageDelivery.sending, .failed] {
            conversation.messages = [older, latest, makeMessage(id: "local", seq: 0, status: status, isOutgoing: true)]
            XCTAssertNil(conversationListMessageTimestamp(conversation))
        }
    }

    func testConversationListMessageTimestampIgnoresPinnedContextAndOlderDeletion() {
        var conversation = makeConversation(id: "sort-existing", unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1, isDeletedLocally: true)
        older.createdAt = Date(timeIntervalSince1970: 100)
        var latest = makeMessage(id: "m2", seq: 2)
        latest.createdAt = Date(timeIntervalSince1970: 200)
        var context = makeMessage(id: "pin", seq: 4, isPinned: true)
        context.createdAt = Date(timeIntervalSince1970: 400)
        context.isPinnedContextOnly = true
        conversation.messages = [older, latest, context]
        conversation.sortTimestamp = 900

        XCTAssertEqual(conversationListMessageTimestamp(conversation), 200)
        conversation.isPinned = true
        XCTAssertEqual(conversationListMessageTimestamp(conversation), 200)
        var incoming = makeMessage(id: "m3", seq: 3)
        incoming.createdAt = Date(timeIntervalSince1970: 300)
        conversation.messages.append(incoming)
        conversation.lastMsgSeq = 3
        XCTAssertEqual(conversationListMessageTimestamp(conversation), 300)
    }

    func testConversationListAllDeletedMessagesUseZeroOnlyThroughKnownHistoryBoundary() {
        var conversation = makeConversation(id: "sort-empty", unread: 0, lastMsgSeq: 3, lastReadSeq: 0)
        conversation.messages = [
            makeMessage(id: "m1", seq: 1, isDeletedLocally: true),
            makeMessage(id: "m2", seq: 2, isDeletedLocally: true),
            makeMessage(id: "m3", seq: 3, isDeletedLocally: true)
        ]
        conversation.time = "昨天 10:00"
        conversation.sortTimestamp = 900
        XCTAssertEqual(conversationListMessageTimestamp(conversation), 0)
        XCTAssertEqual(conversationListDisplayTime(for: conversation), "")

        conversation.messages.removeFirst()
        XCTAssertNil(conversationListMessageTimestamp(conversation))
        conversation.historyVisibleFromSeq = 2
        conversation.historyBoundaryConfirmed = true
        XCTAssertEqual(conversationListMessageTimestamp(conversation), 0)
    }

    func testConversationListDisplayTimeMatchesRemainingMessageSortDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10)))
        let yesterday = now.addingTimeInterval(-86400)
        var conversation = makeConversation(id: "sort-time", unread: 0, lastMsgSeq: 2, lastReadSeq: 0)
        var older = makeMessage(id: "m1", seq: 1)
        older.createdAt = yesterday
        conversation.messages = [older, makeMessage(id: "m2", seq: 2, isDeletedLocally: true)]
        conversation.sortTimestamp = now.timeIntervalSince1970
        conversation.time = "10:00"

        XCTAssertEqual(conversationListMessageTimestamp(conversation), yesterday.timeIntervalSince1970)
        XCTAssertEqual(conversationListDisplayTime(for: conversation, now: now, calendar: calendar), "昨天 10:00")
        XCTAssertEqual(conversation.sortTimestamp, now.timeIntervalSince1970)
        XCTAssertEqual(conversation.time, "10:00")
    }

    func testConversationListMessageTimestampLeavesSystemConversationUnchanged() {
        var conversation = makeConversation(id: "system_notification", kind: .system, unread: 0, lastMsgSeq: 1, lastReadSeq: 0)
        var message = makeMessage(id: "notice", seq: 1)
        message.createdAt = Date(timeIntervalSince1970: 100)
        conversation.messages = [message]
        conversation.sortTimestamp = 900
        XCTAssertNil(conversationListMessageTimestamp(conversation))
    }
    // WDT_CONVERSATION_LIST_SORT_20261021_END

    func testConversationListTimeOnlyAfterMidnightFallsBackToYesterday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))

        let timestamp = try XCTUnwrap(conversationListDisplayTimestamp("03:44", now: now, calendar: calendar))

        XCTAssertEqual(timestamp, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testConversationListDisplayTimeUsesYesterdayForStoredTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))
        var conversation = makeConversation(id: "conversation_time_test", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        conversation.time = "03:44"
        conversation.sortTimestamp = yesterday.timeIntervalSince1970

        XCTAssertEqual(conversationListDisplayTime(for: conversation, now: now, calendar: calendar), "昨天 03:44")
    }

    func testConversationListMutableActionsExcludeOnlyProtectedSystemRows() {
        let system = makeConversation(
            id: "system_notification",
            kind: .system,
            unread: 2,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        var direct = makeConversation(
            id: "direct-system-topic",
            kind: .direct,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        direct.title = "系统升级讨论"
        var group = makeConversation(
            id: "group-system-topic",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 1
        )
        group.title = "系统维护群"

        XCTAssertFalse(conversationListSupportsMutableActions(system.conversation))
        XCTAssertTrue(conversationListSupportsMutableActions(direct.conversation))
        XCTAssertTrue(conversationListSupportsMutableActions(group.conversation))
    }

    func testAppStateRejectsProtectedSystemConversationMutableActions() {
        let transport = SystemInboxReadHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let system = makeConversation(
            id: "system_notification",
            kind: .system,
            unread: 2,
            lastMsgSeq: 2,
            lastReadSeq: 0
        )
        state.conversationStore.commitConversationSnapshots([system])

        state.togglePinned(system.id)
        state.toggleMuted(system.id)
        state.deleteConversation(system.id)

        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().map(\.id), [system.id])
        XCTAssertFalse(state.conversationStore.conversationMessageSnapshots()[0].isPinned)
        XCTAssertFalse(state.conversationStore.conversationMessageSnapshots()[0].isMuted)
        XCTAssertTrue(transport.requestPaths().isEmpty)
    }

    func testConversationMetadataRefreshPreservesKnownMessageOrder() throws {
        var previous = makeConversation(id: "group-a", kind: .group, unread: 0, lastMsgSeq: 42, lastReadSeq: 42)
        previous.sortTimestamp = 1_700_000_000
        let unchanged = try decodeRemoteConversation(#"{"channel_id":"group-a","channel_type":"group","last_msg_seq":42,"updated_at":"2026-11-05T08:00:00Z"}"#)
        let advanced = try decodeRemoteConversation(#"{"channel_id":"group-a","channel_type":"group","last_msg_seq":43,"last_message_at":"2026-11-05T08:00:00Z"}"#)
        XCTAssertEqual(RemoteConversationTimelineMapper.sortTimestamp(remote: unchanged, previous: previous), previous.sortTimestamp)
        XCTAssertGreaterThan(RemoteConversationTimelineMapper.sortTimestamp(remote: advanced, previous: previous), previous.sortTimestamp)
    }

    func testConversationListNormalizesFutureTimeOnlySortTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0, minute: 4)))
        let staleToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 3, minute: 44)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 3, minute: 44)))

        let timestamp = conversationListNormalizedTimestamp(staleToday.timeIntervalSince1970, now: now, calendar: calendar)

        XCTAssertEqual(timestamp, expected.timeIntervalSince1970, accuracy: 0.5)
    }

    func testConversationUnreadStateKeepsReactionUnreadAfterLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 1,
            remoteUnreadReactionCount: 1,
            remoteHasReactionUnread: true,
            locallyReadThrough: true
        )

        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertTrue(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 1)
        XCTAssertFalse(state.hasUnreadMessages)
    }

    func testConversationUnreadStateClearsOnlyNormalUnreadAfterLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 3,
            remoteUnreadReactionCount: 0,
            remoteHasReactionUnread: false,
            locallyReadThrough: true
        )

        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertFalse(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 0)
        XCTAssertFalse(state.hasUnreadMessages)
    }

    func testConversationUnreadStatePreservesMixedUnreadWithoutLocalReadThrough() {
        let state = resolvedConversationUnreadState(
            remoteUnreadCount: 5,
            remoteUnreadReactionCount: 2,
            remoteHasReactionUnread: true,
            locallyReadThrough: false
        )

        XCTAssertEqual(state.unreadCount, 5)
        XCTAssertTrue(state.hasUnreadReaction)
        XCTAssertEqual(state.unreadReactionCount, 2)
        XCTAssertTrue(state.hasUnreadMessages)
    }

    func testChatInitialScrollAnchorUsesBottomForUnreadEntry() throws {
        let messages = [
            makeMessage(id: "m40", seq: 40),
            makeMessage(id: "m41", seq: 41),
            makeMessage(id: "m42", seq: 42, isOutgoing: true, text: "last read full content"),
            makeMessage(id: "m43", seq: 43)
        ]

        let anchor = try XCTUnwrap(chatInitialScrollAnchor(
            messages: messages,
            unreadCount: 1,
            lastReadSeq: 42,
            firstUnreadMessageID: "m43",
            firstUnreadSeq: 43,
            firstUnreadMarkerID: "first-unread-marker",
            bottomAnchorID: "chat-bottom-anchor"
        ))

        XCTAssertEqual(anchor.id, "chat-bottom-anchor")
        XCTAssertEqual(anchor.placement, .bottom)
        XCTAssertFalse(anchor.anchorsLastReadMessage)
        XCTAssertNil(anchor.lastReadMessageID)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
