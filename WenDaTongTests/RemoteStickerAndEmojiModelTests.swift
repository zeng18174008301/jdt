@testable import IM4Domain
import XCTest
import UIKit
import SwiftUI
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRemoteUserStickerManifestDecodesProcessingFieldsAndVariants() throws {
        let list = try JSONDecoder().decode(RemoteList<RemoteUserSticker>.self, from: Data("""
        {
          "items": [
            {
              "id": "us-1",
              "sticker_id": "st-1",
              "file_id": "file-1",
              "status": "active",
              "processing_status": "active",
              "sort": "7",
              "mime_type": "image/gif",
              "size_bytes": "12345",
              "width": "240",
              "height": 180,
              "duration_ms": "900",
              "frame_count": "12",
              "cache_key": "cache-1",
              "version": "v3",
              "thumbnail_url": "/api/tenant/files/file-1/thumbnail",
              "variants": [
                {
                  "kind": "thumb",
                  "file_id": "thumb-1",
                  "mime_type": "image/png",
                  "url": "/api/tenant/files/thumb-1/presigned-preview",
                  "size_bytes": "512",
                  "width": "96",
                  "height": "96",
                  "cache_key": "thumb-cache"
                }
              ],
              "created_at": "2026-06-26T01:00:00Z",
              "updated_at": "2026-06-26T01:02:00Z"
            }
          ],
          "total": 1
        }
        """.utf8))

        let sticker = try XCTUnwrap(list.items.first)
        XCTAssertEqual(sticker.id, "us-1")
        XCTAssertEqual(sticker.stickerID, "st-1")
        XCTAssertEqual(sticker.sizeBytes, 12_345)
        XCTAssertEqual(sticker.width, 240)
        XCTAssertEqual(sticker.durationMS, 900)
        XCTAssertEqual(sticker.frameCount, 12)
        XCTAssertEqual(sticker.variants.first?.kind, "thumb")
        XCTAssertEqual(sticker.variants.first?.url, "/api/tenant/files/thumb-1/presigned-preview")
        XCTAssertEqual(sticker.variants.first?.sizeBytes, 512)
    }

    func testRemoteStickerMessageDecodesContentTypeAndSnapshotPayload() throws {
        let message = try JSONDecoder().decode(RemoteMessage.self, from: Data("""
        {
          "message_id": "msg-sticker-1",
          "channel_id": "g1",
          "channel_type": "group",
          "channel_seq": 88,
          "from_uid": "uid-2",
          "content_type": "sticker",
          "payload": {
            "type": "sticker",
            "sticker_id": "st-1",
            "pack_id": "pack-1",
            "file_id": "file-1",
            "mime_type": "image/gif",
            "width": 240,
            "height": 180,
            "duration_ms": 900,
            "frame_count": 12,
            "thumbnail_url": "/assets/sticker-thumb.png",
            "fallback_text": "[GIF表情]",
            "variants": [
              {
                "kind": "original",
                "file_id": "file-1",
                "mime_type": "image/gif",
                "cache_key": "gif-v1",
                "thumbnail_url": "/assets/sticker.gif"
              }
            ]
          },
          "status": "sent",
          "created_at": "2026-06-26T02:00:00Z"
        }
        """.utf8))

        XCTAssertEqual(message.contentType, "sticker")
        XCTAssertEqual(message.payload["type"]?.stringValue, "sticker")
        XCTAssertEqual(message.payload["sticker_id"]?.stringValue, "st-1")
        XCTAssertEqual(message.payload["fallback_text"]?.stringValue, StickerMessageSnapshot.fallbackText)
        guard case .array(let variants)? = message.payload["variants"],
              case .object(let first)? = variants.first else {
            return XCTFail("Expected sticker variants")
        }
        XCTAssertEqual(first["kind"]?.stringValue, "original")
        XCTAssertEqual(first["cache_key"]?.stringValue, "gif-v1")
    }

    func testStickerGIFRendererUsesImageIOWithoutWebViewOrUIImageDataPlayback() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/StickerGIFRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import ImageIO"))
        XCTAssertTrue(source.contains("CGImageSourceCreateWithData"))
        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        XCTAssertFalse(source.contains("WKWebView"))
        XCTAssertFalse(source.contains("UIImage(data:"))
    }

	    func testStickerMessageViewResolvesTenantFilePayloadsBeforeRendering() throws {
	        let testFile = URL(fileURLWithPath: #filePath)
	        let appSourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WenDaTong")
        let appStateSource = try String(contentsOf: appSourceRoot.appendingPathComponent("Core/AppSupport/AppState+StickerLibrary.swift"), encoding: .utf8)
        let payloadMapping = try String(contentsOf: appSourceRoot.appendingPathComponent("Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift"), encoding: .utf8)
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
        // WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
        let mediaBubbles = try String(contentsOf: appSourceRoot.appendingPathComponent("../Sources/IM4Features/Chat/ChatMediaBubbleViews.swift"), encoding: .utf8)
            + String(contentsOf: appSourceRoot.appendingPathComponent("App/ChatMediaBubbleAssembly.swift"), encoding: .utf8)
        // WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END
        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END

        XCTAssertTrue(appStateSource.contains("func resolveStickerMessageAssetsIfNeeded(for snapshot: StickerMessageSnapshot?)"))
        XCTAssertTrue(appStateSource.contains("api.getTenantFile(context: context, fileID: fileID, coalescingScope: generation.uuidString)"))
        XCTAssertTrue(appStateSource.contains("stickerMessageFileURL(for: snapshot, preferThumbnail: false, files: files)"))
        XCTAssertTrue(appStateSource.contains("guard isCurrentStickerMessageAssetRequest(context: context, generation: generation) else { return }"))
        XCTAssertTrue(appStateSource.contains("downloadStickerMessageAssetToLocalFile"))
        XCTAssertTrue(appStateSource.contains("file.localDownloadURL"))
        XCTAssertTrue(payloadMapping.contains("let thumbnailFileID = attachmentPayloadString(message.payload, [\"thumbnail_file_id\", \"thumb_file_id\", \"preview_file_id\"])"))
	        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_BEGIN
	        XCTAssertTrue(mediaBubbles.contains("state.resolveStickerMessageAssetsIfNeeded(for: snapshot)"))
	        // WDT_IOS1_REFACTOR_CHAT_BUBBLES_20261109_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let panels = try String(contentsOf: appSourceRoot.appendingPathComponent("../Sources/IM4Features/Chat/ChatComposerPanels.swift"), encoding: .utf8)
        XCTAssertTrue(panels.contains(".task(id: selectedTab)"))
        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_STICKER_COMPOSER_PREPARE_CONTRACT_20261112_BEGIN
        let sections = try String(contentsOf: appSourceRoot.appendingPathComponent("App/ChatComposerSections.swift"), encoding: .utf8)
        let composition = try String(contentsOf: appSourceRoot.appendingPathComponent("App/ChatComposerComposition.swift"), encoding: .utf8)
        XCTAssertTrue(panels.contains("await prepareStickers()"))

        let expressionStart = try XCTUnwrap(sections.range(of: "func expressionContent("))
        let expressionEnd = try XCTUnwrap(sections.range(of: "func toolsContent(", range: expressionStart.upperBound..<sections.endIndex))
        let expression = sections[expressionStart.upperBound..<expressionEnd.lowerBound]
        XCTAssertTrue(expression.contains("ChatExpressionPanel("))
        XCTAssertTrue(expression.contains("prepareStickers: { if inputActionIsCurrent(origin) { await services.stickers.prepare() } }"))
        XCTAssertTrue(sections.contains("unicodePicker: unicodePicker, prepareStickers: prepareStickers"))

        let servicesStart = try XCTUnwrap(composition.range(of: "struct ChatComposerServices {"))
        let stickersStart = try XCTUnwrap(composition.range(of: "struct ChatComposerStickerActions {", range: servicesStart.upperBound..<composition.endIndex))
        let catalogStart = try XCTUnwrap(composition.range(of: "struct ChatComposerCatalogActions {", range: stickersStart.upperBound..<composition.endIndex))
        XCTAssertTrue(composition[servicesStart.upperBound..<stickersStart.lowerBound].contains("stickers: .bind(app)"))
        XCTAssertTrue(composition[stickersStart.upperBound..<catalogStart.lowerBound].contains("prepare: { await app.prepareStickerExpressionPanel() }"))
        // WDT_IOS1_STICKER_COMPOSER_PREPARE_CONTRACT_20261112_END
        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
	    }

    // WDT_IOS1_D583_UI_SOURCE_CONTRACTS_20261112_BEGIN
    func testTranscriptTapDismissesExpressionPanel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func section(_ source: String, from start: String, to end: String) throws -> Substring {
            let first = try XCTUnwrap(source.range(of: start))
            let next = try XCTUnwrap(source.range(of: end, range: first.upperBound..<source.endIndex))
            return source[first.upperBound..<next.lowerBound]
        }

        let timeline = try source("WenDaTong/App/ChatTimelineAssembly.swift")
        let mounted = try section(timeline, from: "private func observedMessageTimeline(", to: "private func messageScrollView(")
        XCTAssertTrue(mounted.contains("messageScrollView("))
        XCTAssertTrue(mounted.contains(".simultaneousGesture(messageTranscriptTapGesture)"))
        let tap = try section(timeline, from: "private var messageTranscriptTapGesture:", to: "private var messageTranscriptDragGesture:")
        XCTAssertTrue(tap.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains(
            "TapGesture() .onEnded { dismissChatKeyboardFromTranscript(trigger: .tap) dismissExpressionPanelFromTranscriptTap() }"
        ))

        let navigation = try source("WenDaTong/App/ChatNavigationActions.swift")
        let dismiss = try section(navigation, from: "func dismissExpressionPanelFromTranscriptTap()", to: "func dismissChatKeyboardFromTranscript(")
        XCTAssertTrue(dismiss.contains("guard showEmoji || showTools else { return }"))
        XCTAssertTrue(dismiss.contains("showEmoji = false"))
        XCTAssertTrue(dismiss.contains("showTools = false"))

        let chat = try source("WenDaTong/ChatViews.swift")
        let composition = try source("WenDaTong/App/ChatComposerComposition.swift")
        for field in ["showEmoji", "showTools"] {
            let property = try section(chat, from: "var \(field): Bool {", to: "\n    }")
            XCTAssertTrue(property.contains("nonmutating set { composerState.draft.\(field) = newValue }"))
            XCTAssertTrue(composition.contains(
                "\(field): composerState.binding(\\.\(field), conversationID: conversationID, scope: chatComposerScope)"
            ))
        }

        // Closing the panel must not prepare stickers for a closed or retired composer.
        let composer = try source("WenDaTong/App/ChatComposerAssembly.swift")
        let prepare = try section(composer, from: ".task(id: draft.showEmoji)", to: ".task(id: emojiPickerTaskKey(")
        XCTAssertTrue(prepare.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains(
            "let showEmoji = draft.showEmoji guard showEmoji, services.currentIdentity() == actionIdentity else { return } await services.stickers.prepare()"
        ))
    }
    // WDT_IOS1_D583_UI_SOURCE_CONTRACTS_20261112_END

	    func testIOSComposerEmojiCatalogKeepsWebFallbackCoverage() throws {
	        let testFile = URL(fileURLWithPath: #filePath)
	        let chatViewsURL = testFile
	            .deletingLastPathComponent()
	            .deletingLastPathComponent()
	            // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
	            .appendingPathComponent("Sources/IM4Features/Chat/ChatComposer.swift")
	            // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
	        let source = try String(contentsOf: chatViewsURL, encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatComposerAssembly.swift"), encoding: .utf8)
	        let requiredFallbackEmojis = [
	            "👎", "🤣", "😃", "😁", "😆", "😅", "😉", "🤩",
	            "🥳", "😢", "😡", "😱", "👋", "✌️", "🤞", "🤙",
	            "👈", "👉", "☝️", "✊", "🤝", "🧡", "💛", "💚",
	            "💙", "💜", "🖤", "🤍", "💔", "❤️‍🔥", "💕", "💯",
	            "💬", "📎", "📝", "📅", "⏰", "🔒", "🔔", "📣",
	            "📈", "⚠️", "❗", "❓", "🔍"
	        ]

	        for emoji in requiredFallbackEmojis {
	            XCTAssertTrue(source.contains("\"\(emoji)\""), "Missing composer emoji fallback: \(emoji)")
	        }
	    }

    func testEmojiCatalogRuntimeBacksOffRepeatedPanelReopensUntilRetryBoundary() throws {
        let scope = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "user-a"
        )
        let baseURL = try XCTUnwrap(URL(string: "https://example.test"))
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var runtime = EmojiPickerCatalogRuntimeState()

        XCTAssertEqual(
            runtime.begin(scope: scope, baseURL: baseURL, now: startedAt),
            .attempt
        )
        XCTAssertTrue(runtime.recordFailure(scope: scope, baseURL: baseURL, now: startedAt))
        XCTAssertEqual(
            runtime.begin(scope: scope, baseURL: baseURL, now: startedAt.addingTimeInterval(1)),
            .useFallback
        )
        XCTAssertEqual(
            runtime.begin(
                scope: scope,
                baseURL: baseURL,
                now: startedAt.addingTimeInterval(EmojiPickerCatalogRuntimeState.initialRetryDelay)
            ),
            .attempt
        )
        runtime.cancelAttempt(scope: scope, baseURL: baseURL)
        XCTAssertEqual(
            runtime.begin(
                scope: scope,
                baseURL: baseURL,
                now: startedAt.addingTimeInterval(EmojiPickerCatalogRuntimeState.initialRetryDelay)
            ),
            .attempt
        )
    }

    func testEmojiCatalogRuntimeReusesSuccessOnlyForMatchingIdentityAndRoute() throws {
        let scopeA = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "user-a"
        )
        let scopeB = try EmojiPickerScope(
            product: "ios",
            appID: "app-a",
            accountID: "account-b",
            tenantID: "tenant-a",
            imUID: "user-b"
        )
        let baseA = try XCTUnwrap(URL(string: "https://example.test"))
        let baseB = try XCTUnwrap(URL(string: "https://backup.example.test"))
        let now = Date(timeIntervalSince1970: 2_000)
        let catalog = EmojiCatalog(
            schema: emojiCatalogProjectionSchema,
            catalogSchema: unicodeEmojiCatalogSchema,
            catalogVersion: frozenEmojiCatalogVersion,
            catalogHash: frozenEmojiCatalogHash,
            emojiVersion: "17.0",
            cldrVersion: "48",
            items: []
        )
        var runtime = EmojiPickerCatalogRuntimeState()

        XCTAssertEqual(runtime.begin(scope: scopeA, baseURL: baseA, now: now), .attempt)
        XCTAssertTrue(runtime.recordSuccess(catalog, scope: scopeA, baseURL: baseA))
        XCTAssertEqual(runtime.begin(scope: scopeA, baseURL: baseA, now: now), .useCatalog(catalog))
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseA, now: now), .attempt)

        XCTAssertTrue(runtime.recordFailure(scope: scopeB, baseURL: baseA, now: now))
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseA, now: now), .useFallback)
        XCTAssertEqual(runtime.begin(scope: scopeB, baseURL: baseB, now: now), .attempt)
    }

    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_BEGIN
    func testIOSComposerWiresCatalogBackoffWithoutMergingStickerPackRefresh() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_BEGIN
        let chatSourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/IM4Features/Chat")
        let source = try String(contentsOf: chatSourceRoot.appendingPathComponent("ChatComposerActions.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatComposerActionAssembly.swift"), encoding: .utf8)
        let panels = try String(contentsOf: chatSourceRoot.appendingPathComponent("ChatComposerPanels.swift"), encoding: .utf8)

        let assemblyURL = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WenDaTong/App/ChatComposerComposition.swift")
        let assembly = try String(contentsOf: assemblyURL, encoding: .utf8)
        XCTAssertTrue(source.contains("services.catalog.begin(runtime)"))
        XCTAssertTrue(assembly.contains("app.emojiPickerCatalogRuntime.begin("))
        XCTAssertTrue(source.contains("services.catalog.recordSuccess("))
        XCTAssertTrue(assembly.contains("app.emojiPickerCatalogRuntime.recordSuccess("))
        XCTAssertTrue(source.contains("services.catalog.recordFailure("))
        XCTAssertTrue(assembly.contains("app.emojiPickerCatalogRuntime.recordFailure("))
        XCTAssertTrue(source.contains("case .useFallback:"))
        XCTAssertTrue(source.contains("表情目录暂不可用，已使用本地 Emoji"))
        XCTAssertFalse(source.contains("表情目录加载失败，可重试"))
        XCTAssertTrue(panels.contains("case .stickers: return \"表情包\""))
        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_BEGIN
        let composer = try String(contentsOf: chatSourceRoot.appendingPathComponent("ChatComposer.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatComposerAssembly.swift"), encoding: .utf8) + String(contentsOf: testFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WenDaTong/App/ChatComposerSections.swift"), encoding: .utf8)
        XCTAssertTrue(panels.contains("refreshStickers()"))
        XCTAssertTrue(composer.contains("refreshStickers: { performInputAction(origin: origin, services.stickers.refresh) }"))
        XCTAssertTrue(assembly.contains("refresh: app.refreshStickerExpressionPanel"))
        // WDT_IOS1_REFACTOR_STICKER_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_CHAT_COMPOSER_20261109_END
    }
    // WDT_IOS1_CHAT_COMPOSER_APP_LEAF_20261111_END

	    func testCachedRemoteSnapshotRoundTrip() throws {
	        let snapshot = CachedRemoteSnapshot(
            schemaVersion: 1,
            scope: "account|tenant",
            createdAt: 1_777_000_000,
            conversations: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CachedRemoteSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(decoded.scope, snapshot.scope)
        XCTAssertEqual(decoded.createdAt, snapshot.createdAt)
        XCTAssertTrue(decoded.conversations.isEmpty)
    }

    func testCaptchaUserMessageMapsKnownCodesAndSanitizesBackendReason() {
        XCTAssertEqual(
            captchaUserMessage(code: "captcha_config_missing", reason: nil, fallback: "fallback"),
            "验证码配置缺失，请联系管理员"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "captcha_channel_unavailable", reason: "captcha resource is not ready", fallback: "fallback"),
            "当前验证码通道不可用"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "rate_limited", reason: "请 30 秒后再试", fallback: "fallback"),
            "请 30 秒后再试"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "rate_limit_unavailable", reason: "rate limit state is temporarily unavailable", fallback: "fallback"),
            "服务繁忙，请稍后重试"
        )
        XCTAssertEqual(
            captchaUserMessage(code: "unknown", reason: "internal server error: token leak", fallback: "验证码服务暂不可用"),
            "验证码服务暂不可用"
        )
    }
}


extension RemoteAPIModelsTests {
    @MainActor
    func testEmojiPickerFeatureOwnerUpdatesRealQueryAndModeWithoutReplacingEditor() async throws {
        let item = EmojiCatalogItem(id: "1f600", emoji: "😀", category: "smileys_and_emotion",
            subgroup: "face_smiling", order: 0, name: "笑脸", nameEn: "grinning face", nameZhHans: "笑脸",
            shortcode: "grinning", canonicalShortcode: ":grinning:", keywordsEn: ["happy"],
            keywordsZhHans: ["开心"], baseID: nil, variantIDs: [])
        let catalog = EmojiCatalog(schema: emojiCatalogProjectionSchema, catalogSchema: unicodeEmojiCatalogSchema,
            catalogVersion: frozenEmojiCatalogVersion, catalogHash: frozenEmojiCatalogHash,
            emojiVersion: "17.0", cldrVersion: "48", items: [item])
        let suite = "im4-chat-emoji-owner-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = try EmojiPickerScope(product: "ios", appID: "emoji-app", accountID: "emoji-account",
            tenantID: "emoji-tenant", imUID: "emoji-user")
        let store = try EmojiPickerStoreAdapter(catalog: catalog, scope: scope, mode: .composer,
            preferenceStore: UserDefaultsEmojiPickerPreferenceStore(defaults: defaults))
        let owner = store.presentationState
        let host = try input100HostUsingOriginalComposerBoundary(EmojiPickerView(store: store, onSelect: { _ in }),
            size: CGSize(width: 320, height: 420))
        defer { host.window.isHidden = true; host.window.rootViewController = nil }
        func field(in view: UIView) -> UITextField? {
            if let value = view as? UITextField { return value }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        func image(_ name: String) throws -> Data {
            host.controller.view.setNeedsLayout()
            host.controller.view.layoutIfNeeded()
            host.window.layoutIfNeeded()
            var drewHierarchy = false
            let rendered = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
                drewHierarchy = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drewHierarchy)
            add(snapshotAttachment(rendered, name: name))
            return try XCTUnwrap(rendered.pngData())
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(owner.session.isOpen)
        let editor = try XCTUnwrap(field(in: host.controller.view))
        let editorID = ObjectIdentifier(editor)
        editor.text = "grinning"
        editor.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(store.session.query, "grinning")
        XCTAssertEqual(store.visibleItems.map(\.id), [item.id])
        XCTAssertTrue(store.presentationState === owner)
        let composerImage = try image("Emoji-composer-after-query")
        // open(mode:) changes only the single Feature UI owner, not the App catalog result.
        store.open(mode: .reaction)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(owner.session.mode, .reaction)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(field(in: host.controller.view))), editorID)
        XCTAssertNotEqual(try image("Emoji-reaction-same-owner"), composerImage)
        store.close()
        XCTAssertFalse(owner.session.isOpen)
        XCTAssertEqual(owner.session.focusedItemID, "")
    }
}
