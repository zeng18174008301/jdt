@testable import IM4Domain
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testTextSendSecondUnauthorizedAfterSuccessfulRefreshKeepsSessionAndRetryableBubble() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"im_token":"fresh-im-token","expires_at":1800000000,"tenant":{"tenant_id":"tenant-1","name":"Tenant 1","status":"active"},"member":{"tenant_id":"tenant-1","account_id":"account-1","im_uid":"uid-1","status":"active","role":"member"},"auth_session":{"session_id":"sess_platform-tenant-1","refresh_token":"platform-tenant-refresh-2","expires_at":1800000000,"tenant_id":"tenant-1","app_id":"jianhuitong-ios","device_id":"device-1","client_type":"ios","token_type":"im"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeRefreshableMessageSendContext())
        state.authenticationPresentationStore.setInitialAuthentication(true)
        _ = try await state.loadCurrentAppPolicy(force: true)
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/platform/apps/current-policy"])

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status == .failed
        }

        XCTAssertEqual(transport.requests().filter { $0.url?.path != "/api/platform/apps/current-policy" }.map(\.url?.path), [
            "/api/im/messages",
            "/api/platform/tenants/tenant-1/session/refresh",
            "/api/im/messages"
        ])
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(IMAPIContext.load().hasIMSession)
        XCTAssertEqual(state.toast, "消息发送失败，可点击重发")
    }

    func testTextSendUnauthorizedWithNonterminalRefreshFailureKeepsSessionAndRetryableBubble() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"refresh_too_soon","message":"refresh_too_soon"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeRefreshableMessageSendContext())
        state.authenticationPresentationStore.setInitialAuthentication(true)
        _ = try await state.loadCurrentAppPolicy(force: true)
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/platform/apps/current-policy"])

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) {
            state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status == .failed
        }

        XCTAssertEqual(transport.requests().filter { $0.url?.path != "/api/platform/apps/current-policy" }.map(\.url?.path), [
            "/api/im/messages",
            "/api/platform/tenants/tenant-1/session/refresh"
        ])
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.text, "hello")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status, .failed)
        XCTAssertEqual(state.toast, "消息发送失败，可点击重发")
    }

    func testTextSendTenantRevocationClearsOnlyTenantAndReturnsToWorkspaceSelection() async throws {
        clearStoredAPIContext()
        defer { clearStoredAPIContext() }
        let transport = FakeHTTPTransport(results: [
            activeAppPolicyResult(),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"invalid_token","message":"invalid_token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"session_revoked","message":"session_revoked"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeRefreshableMessageSendContext())
        state.authenticationPresentationStore.setInitialAuthentication(true)
        _ = try await state.loadCurrentAppPolicy(force: true)
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        try await waitForCondition(iterations: 120) {
            transport.requests().contains { $0.url?.path == "/api/platform/apps/current-policy" }
        }
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/platform/apps/current-policy"])

        XCTAssertTrue(state.sendText("hello", conversationID: "uid-1:uid-2", quote: nil))
        try await waitForCondition(iterations: 120) { !state.isAuthenticated }

        let businessPaths = transport.requests()
            .filter { $0.url?.path != "/api/platform/apps/current-policy" }
            .compactMap(\.url?.path)
        XCTAssertEqual(
            Array(businessPaths.prefix(2)),
            ["/api/im/messages", "/api/platform/tenants/tenant-1/session/refresh"]
        )
        let stored = IMAPIContext.load()
        XCTAssertFalse(stored.hasIMSession)
        XCTAssertEqual(stored.platformToken, "platform-token")
        XCTAssertEqual(state.authScreen, .workspaceSelection)
    }

    func testVoiceMessagePayloadNormalizesDurationAndWaveform() {
        XCTAssertTrue(VoiceMessagePayload.isTooShort(durationMS: 999))
        XCTAssertFalse(VoiceMessagePayload.isTooShort(durationMS: 1_000))
        XCTAssertTrue(VoiceMessagePayload.isValidFinalDurationMS(1))
        XCTAssertFalse(VoiceMessagePayload.isValidFinalDurationMS(0))
        XCTAssertTrue(VoiceMessagePayload.isSendableDurationMS(1_000))
        XCTAssertFalse(VoiceMessagePayload.isSendableDurationMS(60_001))
        XCTAssertEqual(VoiceMessagePayload.normalizedDurationMS(65_000), 60_000)
        XCTAssertEqual(VoiceMessagePayload.durationSeconds(from: 1_001), 2)
        XCTAssertEqual(VoiceMessagePayload.playbackProgress(elapsedMS: 500, durationMS: 2_000), 0.25, accuracy: 0.001)
        XCTAssertEqual(VoiceMessagePayload.playbackProgress(elapsedMS: 3_000, durationMS: 2_000), 1, accuracy: 0.001)
        XCTAssertEqual(VoiceMessagePayload.remainingDurationMS(elapsedMS: 750, durationMS: 2_000), 1_250)
        XCTAssertEqual(VoiceMessagePayload.countdownLabel(elapsedMS: 1_001, durationMS: 2_000), "1秒")
        XCTAssertEqual(VoiceMessagePayload.normalizedWaveform([-20, 18, 120]), [0, 18, 100])
        XCTAssertEqual(VoiceMessagePayload.normalizedWaveform(Array(repeating: 50, count: 128)).count, 64)
    }

    func testVoicePlaybackUsesDecodedMediaDurationInsteadOfMetadataFallback() throws {
        let durationMS = try XCTUnwrap(VoiceMessagePayload.authoritativeDurationMS(
            metadataDurationMS: 10_000,
            decodedDurationSeconds: 6.18
        ))

        XCTAssertEqual(durationMS, 6_180)
        XCTAssertEqual(
            VoiceMessagePayload.playbackProgress(elapsedMS: 3_090, durationMS: durationMS),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VoiceMessagePayload.countdownLabel(elapsedMS: 3_090, durationMS: durationMS),
            "4秒"
        )
    }

    func testVoicePlaybackFailsClosedWhenDecodedDurationIsUnavailable() {
        XCTAssertNil(
            VoiceMessagePayload.authoritativeDurationMS(
                metadataDurationMS: 10_000,
                decodedDurationSeconds: nil
            )
        )
        XCTAssertNil(
            VoiceMessagePayload.authoritativeDurationMS(
                metadataDurationMS: 10_000,
                decodedDurationSeconds: .nan
            )
        )
        XCTAssertNil(VoiceMessagePayload.decodedDurationMS(0))
        XCTAssertNil(VoiceMessagePayload.decodedDurationMS(-1))
        XCTAssertNil(VoiceMessagePayload.decodedDurationMS(60.001))
    }

    // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_BEGIN
    func testVoicePlaybackUpdatesOnlyThePlayingMessageWithoutAppStateRefresh() {
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makeContext())
        let store = state.voiceMessagePlaybackStore
        var first: [VoiceMessagePlaybackStore.Snapshot] = []
        var second: [VoiceMessagePlaybackStore.Snapshot] = []
        var globalUpdates = 0
        let firstObserver = store.updates(for: "voice-first").sink { first.append($0) }
        let secondObserver = store.updates(for: "voice-second").sink { second.append($0) }
        let globalObserver = state.objectWillChange.sink { globalUpdates += 1 }
        defer {
            firstObserver.cancel()
            secondObserver.cancel()
            globalObserver.cancel()
        }

        store.playingMessageID = "voice-first"
        store.state = VoiceMessagePlaybackState(messageID: "voice-first", elapsedMS: 1_000, durationMS: 4_000, isPlaying: true)
        XCTAssertEqual(first.last?.isPlaying, true)
        XCTAssertEqual(first.last?.state?.remainingMS, 3_000)
        XCTAssertEqual(second.count, 1)

        store.playingMessageID = nil
        store.state = VoiceMessagePlaybackState(messageID: "voice-first", elapsedMS: 1_000, durationMS: 4_000)
        XCTAssertEqual(first.last?.isPlaying, false)
        XCTAssertEqual(first.last?.state?.remainingMS, 3_000)

        state.stopVoiceMessagePlayback()
        XCTAssertNil(first.last?.state)
        XCTAssertEqual(second.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110_END

    func testVoicePlaybackStateClampsMediaClockWithoutNegativeCountdown() {
        let active = VoiceMessagePlaybackState(
            messageID: "voice-active",
            elapsedMS: -250,
            durationMS: 1_500,
            isPlaying: true
        )
        XCTAssertEqual(active.elapsedMS, 0)
        XCTAssertEqual(active.remainingMS, 1_500)
        XCTAssertTrue(active.isPlaying)

        let completed = VoiceMessagePlaybackState(
            messageID: "voice-completed",
            elapsedMS: 9_000,
            durationMS: 1_500,
            isPlaying: true
        )
        XCTAssertEqual(completed.elapsedMS, 1_500)
        XCTAssertEqual(completed.progress, 1, accuracy: 0.001)
        XCTAssertEqual(completed.remainingMS, 0)
        XCTAssertFalse(completed.isPlaying)
    }

    func testSendVoiceUsesVoiceContentTypeAndPayloadForGroup() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message":{"message_id":"m-voice-1","channel_id":"g1","channel_type":"group","channel_seq":3,"from_uid":"uid-1","content_type":"voice","payload":{"file_id":"file-voice","duration_ms":60000,"waveform":[0,25,100]},"status":"sent","created_at":"2026-06-26T00:00:00Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        _ = try await client.sendVoice(
            context: makeContext(),
            conversation: makeGroupConversation(id: "g1"),
            channelID: "g1",
            file: makeVoiceRemoteFile(id: "file-voice", sizeBytes: 512),
            name: "voice.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 512,
            durationMS: 65_000,
            waveform: [-8, 25, 120],
            quote: nil,
            clientMessageID: "local-voice-1"
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://im.example.test/api/im/messages")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["content_type"] as? String, "voice")
        XCTAssertEqual(body["channel_type"] as? String, "group")
        XCTAssertEqual(body["client_msg_no"] as? String, "local-voice-1")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["file_id"] as? String, "file-voice")
        XCTAssertEqual(payload["attachment_id"] as? String, "file-voice")
        XCTAssertEqual(payload["media_id"] as? String, "file-voice")
        XCTAssertEqual(payload["media_category"] as? String, "voice")
        XCTAssertEqual(payload["kind"] as? String, "voice")
        XCTAssertEqual(payload["mime_type"] as? String, "audio/mp4")
        XCTAssertEqual(payload["duration_ms"] as? Int, 60_000)
        XCTAssertEqual(payload["duration_seconds"] as? Int, 60)
        XCTAssertEqual(payload["waveform"] as? [Int], [0, 25, 100])
        XCTAssertEqual(payload["fallback_text"] as? String, "[语音]")
        XCTAssertEqual(payload["download_endpoint"] as? String, "/api/tenant/files/file-voice/presign-download")
    }

    func testRemoteHistoryParsesVoiceAndLegacyAudioMessages() throws {
        let state = AppState(apiContextOverride: makeContext())
        let voice = try decodeRemoteMessage("""
        {
          "message_id": "msg-voice",
          "channel_id": "g1",
          "channel_type": "group",
          "channel_seq": 4,
          "from_uid": "uid-2",
          "content_type": "voice",
          "payload": {
            "file_id": "file-voice",
            "file_name": "voice.m4a",
            "mime_type": "audio/mp4",
            "media_category": "voice",
            "duration_ms": 1600,
            "waveform": [-3, 40, 120]
          },
          "status": "sent",
          "created_at": "2026-06-26T00:00:00Z"
        }
        """)
        let audio = try decodeRemoteMessage("""
        {
          "message_id": "msg-audio",
          "channel_id": "uid-1:uid-2",
          "channel_type": "direct",
          "channel_seq": 5,
          "from_uid": "uid-2",
          "content_type": "audio",
          "payload": {
            "file_id": "file-audio",
            "file_name": "legacy.m4a",
            "mime_type": "audio/mp4",
            "media_category": "audio",
            "duration_seconds": 3,
            "waveform": [12, 34, 56]
          },
          "status": "sent",
          "created_at": "2026-06-26T00:00:00Z"
        }
        """)

        let mappedVoice = state.debugChatMessageForTesting(voice)
        XCTAssertEqual(mappedVoice.kind, .voice)
        XCTAssertEqual(mappedVoice.contentType, "voice")
        XCTAssertEqual(mappedVoice.attachmentMediaCategory, "voice")
        XCTAssertEqual(mappedVoice.voiceWaveform, [0, 40, 100])
        XCTAssertEqual(mappedVoice.text, "2秒")
        XCTAssertEqual(try XCTUnwrap(mappedVoice.attachmentDurationSeconds), 1.6, accuracy: 0.01)

        let mappedAudio = state.debugChatMessageForTesting(audio)
        XCTAssertEqual(mappedAudio.kind, .voice)
        XCTAssertEqual(mappedAudio.contentType, "audio")
        XCTAssertEqual(mappedAudio.attachmentMediaCategory, "audio")
        XCTAssertEqual(mappedAudio.voiceWaveform, [12, 34, 56])
        XCTAssertEqual(mappedAudio.text, "3秒")
        XCTAssertEqual(try XCTUnwrap(mappedAudio.attachmentDurationSeconds), 3, accuracy: 0.01)
    }

    func testVoiceMessageUnderOneSecondDoesNotUpload() {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"max_bytes":10485760}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])

        XCTAssertFalse(state.sendVoiceMessage(
            data: Data([1, 2, 3]),
            name: "short.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 3,
            durationMS: 999,
            waveform: [10, 20],
            conversationID: "uid-1:uid-2",
            quote: nil
        ))

        XCTAssertEqual(state.toast, "说话时间太短")
        XCTAssertTrue(transport.requests().isEmpty)
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().first?.messages.isEmpty ?? false)
        XCTAssertTrue(state.files.isEmpty)
    }

    func testVoiceMessageInvalidFinalDurationAndNonAudioMIMERemainUncommitted() {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"max_bytes":10485760}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])

        XCTAssertFalse(state.sendVoiceMessage(
            data: Data([1, 2, 3]),
            name: "invalid.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 3,
            durationMS: 60_001,
            waveform: [10, 20],
            conversationID: "uid-1:uid-2",
            quote: nil
        ))
        XCTAssertEqual(state.toast, "语音时长无效，请重新录制")

        XCTAssertFalse(state.sendVoiceMessage(
            data: Data([1, 2, 3]),
            name: "not-voice.txt",
            mimeType: "text/plain",
            sizeBytes: 3,
            durationMS: 1_500,
            waveform: [10, 20],
            conversationID: "uid-1:uid-2",
            quote: nil
        ))
        XCTAssertEqual(state.toast, "语音格式无效，请重新录制")
        XCTAssertTrue(transport.requests().isEmpty)
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().first?.messages.isEmpty ?? false)
    }

    func testVoiceRetryReusesClientMessageIDAndUploadedFileIDWithoutReuploadingDirect() async throws {
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"max_bytes":10485760}}"#.utf8), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"file":{"file_id":"file-voice","file_name":"voice.m4a","mime_type":"audio/mp4","size_bytes":4,"status":"pending","upload_status":"pending","media_category":"voice","extension":"m4a"},"upload":{"url":"https://upload.example.test/voice","method":"PUT","headers":{"Content-Type":"audio/mp4"}}}}"#.utf8), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"file":{"file_id":"file-voice","file_name":"voice.m4a","mime_type":"audio/mp4","size_bytes":4,"status":"uploaded","upload_status":"uploaded","download_endpoint":"/api/tenant/files/file-voice/presign-download","detail_endpoint":"/api/tenant/files/file-voice","media_category":"voice","extension":"m4a","preview_kind":"voice","duration_seconds":1.5}}}"#.utf8), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"temporary_send_failure","message":"temporary failure"}}"#.utf8), isHTTPResponse: true, statusCode: 500),
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"max_bytes":10485760}}"#.utf8), isHTTPResponse: true, statusCode: 200),
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"message":{"message_id":"msg-voice-confirmed","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":7,"from_uid":"uid-1","content_type":"voice","payload":{"file_id":"file-voice","file_name":"voice.m4a","mime_type":"audio/mp4","media_category":"voice","duration_ms":1500,"waveform":[10,20,30],"attachment_status":"uploaded","upload_status":"uploaded"},"status":"sent","created_at":"2026-06-26T00:00:00Z"}}}"#.utf8), isHTTPResponse: true, statusCode: 200)
            ],
            uploadResults: [
                HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
            ]
        )
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])

        state.sendVoiceMessage(
            data: Data([1, 2, 3, 4]),
            name: "voice.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 4,
            durationMS: 1_500,
            waveform: [10, 20, 30],
            conversationID: "uid-1:uid-2",
            quote: nil
        )

        try await waitForCondition(iterations: 120) {
            transport.requests().count >= 4
                && state.conversationStore.conversationMessageSnapshots().first?.messages.first?.status == .failed
        }
        let failedVoice = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first?.messages.first)
        XCTAssertEqual(failedVoice.kind, .voice)
        XCTAssertEqual(failedVoice.contentType, "voice")
        XCTAssertEqual(failedVoice.attachmentMediaCategory, "voice")
        let localID = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.id)
        state.retryAttachmentUpload(messageID: localID, in: "uid-1:uid-2")
        try await waitForCondition(iterations: 120) {
            transport.requests().count >= 6
                && state.conversationStore.conversationMessageSnapshots().first?.messages.first?.id == "msg-voice-confirmed"
        }

        let paths = transport.requests().compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/file-voice/uploaded" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 2)
        XCTAssertEqual(transport.uploads().count, 1)
        let attachmentEvents = transport.events().filter {
            $0 == "request:POST:/api/tenant/files/presign-upload"
                || $0 == "upload:PUT:/voice"
                || $0 == "request:POST:/api/tenant/files/file-voice/uploaded"
                || $0 == "request:POST:/api/im/messages"
        }
        XCTAssertEqual(Array(attachmentEvents.prefix(4)), [
            "request:POST:/api/tenant/files/presign-upload",
            "upload:PUT:/voice",
            "request:POST:/api/tenant/files/file-voice/uploaded",
            "request:POST:/api/im/messages"
        ])

        let presignRequest = try XCTUnwrap(transport.requests().first { $0.url?.path == "/api/tenant/files/presign-upload" })
        let completeRequest = try XCTUnwrap(transport.requests().first { $0.url?.path == "/api/tenant/files/file-voice/uploaded" })
        let presignBody = try requestJSONObject(presignRequest)
        XCTAssertEqual(presignBody["app_id"] as? String, "jianhuitong-ios")
        XCTAssertEqual(presignBody["purpose"] as? String, "message_attachment")
        XCTAssertEqual(presignBody["channel_id"] as? String, "uid-1:uid-2")
        XCTAssertEqual(presignBody["channel_type"] as? String, "direct")
        XCTAssertEqual(presignBody["client_msg_no"] as? String, localID)
        XCTAssertEqual(presignBody["file_name"] as? String, "voice.m4a")
        XCTAssertEqual(presignBody["mime_type"] as? String, "audio/mp4")
        XCTAssertEqual(presignBody["size_bytes"] as? Int, 4)
        XCTAssertEqual(presignBody["media_category"] as? String, "voice")
        XCTAssertEqual(presignBody["kind"] as? String, "voice")
        XCTAssertEqual(presignBody["fallback_text"] as? String, VoiceMessagePayload.fallbackText)
        XCTAssertEqual(presignBody["duration_ms"] as? Int, 1_500)
        XCTAssertEqual(presignBody["duration_seconds"] as? Int, 2)
        XCTAssertEqual(presignBody["waveform"] as? [Int], [10, 20, 30])
        let presignMetadata = try XCTUnwrap(presignBody["metadata"] as? [String: Any])
        XCTAssertEqual(presignMetadata["purpose"] as? String, "message_attachment")

        let completeBody = try requestJSONObject(completeRequest)
        XCTAssertEqual(completeBody["purpose"] as? String, "message_attachment")
        XCTAssertEqual(completeBody["channel_id"] as? String, "uid-1:uid-2")
        XCTAssertEqual(completeBody["channel_type"] as? String, "direct")
        XCTAssertEqual(completeBody["client_msg_no"] as? String, localID)
        XCTAssertNil(completeBody["file_name"])
        XCTAssertNil(completeBody["duration_ms"])
        let completeMetadata = try XCTUnwrap(completeBody["metadata"] as? [String: Any])
        XCTAssertEqual(completeMetadata["purpose"] as? String, "message_attachment")
        XCTAssertEqual(completeMetadata["message_id"] as? String, localID)
        let sendBodies = try transport.requests()
            .filter { $0.url?.path == "/api/im/messages" }
            .map(requestJSONObject)
        XCTAssertEqual(sendBodies.count, 2)
        XCTAssertEqual(sendBodies[0]["client_msg_no"] as? String, localID)
        XCTAssertEqual(sendBodies[1]["client_msg_no"] as? String, localID)
        XCTAssertEqual((sendBodies[0]["payload"] as? [String: Any])?["file_id"] as? String, "file-voice")
        XCTAssertEqual((sendBodies[1]["payload"] as? [String: Any])?["file_id"] as? String, "file-voice")
        XCTAssertEqual(sendBodies[1]["channel_type"] as? String, "direct")
    }

    func testGIFAttachmentPreservesOriginalBytesMIMEAndFinalizeWithoutURL() async throws {
        let bytes = gifFixtureBytes()
        let signedURL = "https://object.example.test/original.gif?signature=redacted&expires=900"
        let transport = StrictAttachmentHTTPTransport(results: [
            attachmentConfigResult(),
            attachmentPresignResult(fileID: "file-gif", uploadURL: signedURL, mimeType: "image/gif", sizeBytes: bytes.count),
            attachmentUploadedResult(fileID: "file-gif", sizeBytes: bytes.count, mimeType: "image/gif"),
            attachmentMessageResult(messageID: "msg-gif", fileID: "file-gif", sizeBytes: bytes.count, mimeType: "image/gif")
        ], uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        var localID: String?
        XCTAssertTrue(state.sendAttachment(kind: .image, name: "图片消息.jpg", mimeType: "image/jpeg",
            sizeBytes: Int64(bytes.count), data: bytes, conversationID: "g1", quote: nil,
            onQueued: { localID = $0 }))
        let sent = try await awaitMessage(in: state, conversationID: "g1") { $0.id == "msg-gif" }
        XCTAssertEqual(sent.attachmentMimeType, "image/gif")
        let upload = try XCTUnwrap(transport.uploads().first)
        XCTAssertEqual(upload.body, bytes)
        XCTAssertEqual(upload.request.url?.absoluteString, signedURL)
        XCTAssertEqual(upload.request.httpMethod, "PUT")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "image/gif")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "X-Signed-Scope"), "object-put")
        XCTAssertNil(upload.request.value(forHTTPHeaderField: "Authorization"))
        let requests = transport.requests()
        let presign = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/presign-upload") == true }))
        XCTAssertEqual(presign["mime_type"] as? String, "image/gif")
        XCTAssertEqual((presign["size_bytes"] as? NSNumber)?.intValue, bytes.count)
        let finalize = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/uploaded") == true }))
        XCTAssertEqual(finalize["client_msg_no"] as? String, localID)
        let send = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path == "/api/im/messages" }))
        XCTAssertEqual(send["client_msg_no"] as? String, localID)
        XCTAssertEqual(send["channel_id"] as? String, "g1")
        XCTAssertEqual(send["content_type"] as? String, "image")
        let payload = try XCTUnwrap(send["payload"] as? [String: Any])
        XCTAssertEqual(payload["mime_type"] as? String, "image/gif")
        XCTAssertEqual(payload["media_category"] as? String, "image")
        XCTAssertEqual((payload["size_bytes"] as? NSNumber)?.intValue, bytes.count)
        XCTAssertEqual((payload["width"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((payload["height"] as? NSNumber)?.intValue, 1)
        XCTAssertNil(payload["download_url"])
        XCTAssertEqual(payload["download_endpoint"] as? String, "/api/tenant/files/file-gif/presign-download")
        XCTAssertEqual(transport.uploads().count, 1)
    }

    func testGIFAttachmentInclusiveCapLowerTenantLimitAndDeclaredForgery() throws {
        let transport = FakeHTTPTransport(results: [])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        let exactBytes = gifFixtureBytes(count: Int(GIFAttachmentUploadPolicy.maximumBytes))
        var queued: String?
        XCTAssertTrue(state.sendAttachment(kind: .image, name: "limit.gif", mimeType: "image/gif",
            sizeBytes: Int64(exactBytes.count), data: exactBytes, conversationID: "g1", quote: nil,
            automaticallyStartUpload: false, onQueued: { queued = $0 }))
        state.cancelAttachmentUpload(messageID: try XCTUnwrap(queued), in: "g1")
        var oversized = exactBytes
        oversized.append(0)
        XCTAssertFalse(state.sendAttachment(kind: .image, name: "too-large.gif", mimeType: "image/gif",
            sizeBytes: Int64(oversized.count), data: oversized, conversationID: "g1", quote: nil,
            automaticallyStartUpload: false))
        XCTAssertFalse(state.sendAttachment(kind: .image, name: "forged.gif", mimeType: "image/gif",
            sizeBytes: nil, data: pngFixtureBytes(count: 100), conversationID: "g1", quote: nil,
            automaticallyStartUpload: false))
        XCTAssertFalse(state.sendAttachment(kind: .image, name: "truncated.gif", mimeType: "image/gif",
            sizeBytes: nil, data: Data("GIF89a".utf8), conversationID: "g1", quote: nil,
            automaticallyStartUpload: false))
        let smallConfig = FileUploadConfig(maxBytes: 100, maxMB: 0, source: "tenant",
            messageRecallMaxMinutes: 120, voiceCallEnabled: true, videoCallEnabled: false,
            readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false)
        XCTAssertTrue(GIFAttachmentUploadPolicy.allowsUpload(sizeBytes: 100, config: smallConfig))
        XCTAssertFalse(GIFAttachmentUploadPolicy.allowsUpload(sizeBytes: 101, config: smallConfig))
        XCTAssertTrue(FileUploadConfig.defaultValue.allowsUpload(sizeBytes: 500 * 1024 * 1024))
        XCTAssertTrue(transport.requests().isEmpty)
    }

    func testGIFFileBackedOriginalBytesAndDeclaredForgeryAreNotTranscoded() async throws {
        let bytes = gifFixtureBytes()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gif-original-\(UUID().uuidString).gif")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let staged = try PendingAttachmentFileStore.stageFile(from: file, preferredName: file.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        XCTAssertTrue(try GIFAttachmentUploadPolicy.isGIF(data: nil, fileURL: staged.url, name: file.lastPathComponent, mimeType: "image/gif"))
        let transport = FakeHTTPTransport(results: [], uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)])
        let client = makeClient(transport: transport)
        try await client.uploadFileBinary(upload: makeUpload(url: "https://object.example.test/exact.gif", method: "POST", headers: ["X-Signed-Scope": "original"]),
            fileURL: staged.url, mimeType: "image/gif", sizeBytes: Int64(bytes.count), progress: { _ in })
        let upload = try XCTUnwrap(transport.fileUploads().first)
        XCTAssertEqual(try Data(contentsOf: upload.fileURL), bytes)
        XCTAssertEqual(upload.request.httpMethod, "POST")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "image/gif")
        XCTAssertEqual(upload.sizeBytes, Int64(bytes.count))
        XCTAssertTrue(transport.uploads().isEmpty)
        try pngFixtureBytes(count: 100).write(to: staged.url)
        XCTAssertThrowsError(try GIFAttachmentUploadPolicy.isGIF(data: nil, fileURL: staged.url, name: "forged.gif", mimeType: "image/gif"))
    }

    func testGIFFreshTenantCapRejectsBeforePresignUploadAndMessage() async throws {
        let transport = StrictAttachmentHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"max_bytes":20}}"#.utf8), isHTTPResponse: true, statusCode: 200
        )], uploadResults: [])
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        XCTAssertTrue(state.sendAttachment(kind: .image, name: "small.gif", mimeType: "image/gif",
            sizeBytes: nil, data: gifFixtureBytes(), conversationID: "g1", quote: nil))
        try await waitForCondition { state.conversationStore.conversationMessageSnapshots().first?.messages.isEmpty == true }
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().first?.messages.isEmpty == true)
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/presign-upload") == true || $0.url?.path == "/api/im/messages" })
        XCTAssertTrue(transport.uploads().isEmpty)
    }

    func testGIFOriginalURLRecoveryUsesDetailThenPresignNotThumbnail() async throws {
        let original = "https://object.example.test/original.gif?signature=redacted&expires=900"
        let transport = FakeHTTPTransport(results: [gifFileDetailResult(), gifFileDetailResult(downloadURL: original)])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        let message = gifRecoveryMessage()
        var conversation = makeGroupConversation(id: "g1")
        conversation.messages = [message]
        state.conversationStore.hydrateCachedConversations([conversation])

        let url = await state.refreshedGIFAttachmentOriginalURL(message, conversationID: "g1")

        XCTAssertEqual(url?.absoluteString, original)
        XCTAssertEqual(transport.requests().map { $0.httpMethod }, ["GET", "POST"])
        XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/file-gif", "/api/tenant/files/file-gif/presign-download"])
        XCTAssertTrue(transport.uploads().isEmpty)
        XCTAssertFalse(transport.requests().contains { $0.url?.host == "object.example.test" })
    }

    func testGIFUnknownMIMEOriginalURLRecoveryLoadsValidatedBytesFromDetailAndPresign() async throws {
        let original = "https://object.example.test/original.gif?signature=redacted"
        let expired = URL(string: "https://object.example.test/expired.gif")!
        let bytes = gifFixtureBytes()
        for requiresPresign in [false, true] {
            for missingPrimary in [false, true] {
                let detail = gifFileDetailResult(
                    downloadURL: requiresPresign ? "" : original,
                    mimeType: " Application/Octet-Stream ", fileExtension: ""
                )
                let transport = FakeHTTPTransport(results: requiresPresign
                    ? [detail, gifFileDetailResult(downloadURL: original, mimeType: "application/octet-stream")]
                    : [detail])
                let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
                var message = gifRecoveryMessage()
                message.attachmentMimeType = "application/octet-stream"
                var conversation = makeGroupConversation(id: "g1")
                conversation.messages = [message]
                state.conversationStore.hydrateCachedConversations([conversation])
                let loader = StickerGIFFrameLoader(dataSource: { url in
                    if url == expired { throw StickerGIFResourceError.unauthorized }
                    guard url.absoluteString == original else { throw StickerGIFResourceError.invalidTransport }
                    return bytes
                })

                await loader.load(url: missingPrimary ? nil : expired, cacheKey: "legacy-gif", maxPixelSize: 64,
                    requiresGIF: true, recoveryURL: {
                        await state.refreshedGIFAttachmentOriginalURL(message, conversationID: "g1")
                    })

                XCTAssertNotNil(loader.frame)
                XCTAssertEqual(loader.frameCount, 1)
                XCTAssertFalse(loader.failed)
                XCTAssertEqual(transport.requests().map { $0.httpMethod }, requiresPresign ? ["GET", "POST"] : ["GET"])
                XCTAssertEqual(transport.requests().map { $0.url?.path }, requiresPresign
                    ? ["/api/tenant/files/file-gif", "/api/tenant/files/file-gif/presign-download"]
                    : ["/api/tenant/files/file-gif"])
                XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.attachmentMimeType, " Application/Octet-Stream ")
                XCTAssertTrue(transport.uploads().isEmpty)
                loader.stop()
                XCTAssertNil(loader.frame)
            }
        }
    }

    func testGIFUnknownMIMERecoveryDoesNotTrustPNGPayloadOrTruncatedGIFBytes() async throws {
        let original = "https://object.example.test/original.gif"
        for bytes in [pngFixtureBytes(count: 100), Data(gifFixtureBytes().prefix(16))] {
            let transport = FakeHTTPTransport(results: [
                gifFileDetailResult(mimeType: "application/octet-stream"),
                gifFileDetailResult(downloadURL: original, mimeType: "application/octet-stream")
            ])
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
            var message = gifRecoveryMessage()
            message.attachmentMimeType = "application/octet-stream"
            var conversation = makeGroupConversation(id: "g1")
            conversation.messages = [message]
            state.conversationStore.hydrateCachedConversations([conversation])
            let loader = StickerGIFFrameLoader(dataSource: { url in
                guard url.absoluteString == original else { throw StickerGIFResourceError.invalidTransport }
                return bytes
            })

            await loader.load(url: nil, cacheKey: "untrusted-legacy-gif", maxPixelSize: 64,
                requiresGIF: true, recoveryURL: {
                    await state.refreshedGIFAttachmentOriginalURL(message, conversationID: "g1")
                })

            // Metadata permits fetching the original, never permits accepting
            // non-GIF or incomplete bytes as a successfully loaded animation.
            XCTAssertEqual(transport.requests().map { $0.httpMethod }, ["GET", "POST"])
            XCTAssertTrue(loader.failed)
            XCTAssertNil(loader.frame)
            XCTAssertEqual(loader.frameCount, 0)
            XCTAssertTrue(transport.uploads().isEmpty)
            loader.stop()
        }
        XCTAssertFalse(GIFAttachmentUploadPolicy.isGIFCandidate(mimeType: "image/png", name: "forged.gif", fileExtension: "gif"))
        XCTAssertFalse(GIFAttachmentUploadPolicy.isGIFCandidate(mimeType: "application/octet-stream", name: "unknown.bin", fileExtension: "bin"))
        XCTAssertTrue(GIFAttachmentUploadPolicy.isGIFCandidate(mimeType: "", name: "legacy.GIF", fileExtension: ""))
    }

    func testGIFOriginalURLRecoveryRejectsLateCancelledAndSessionABAResponses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gif-recovery-fences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for invalidation in ["cancel", "sessionABA", "recalled", "deleted"] {
            let transport = StrictAttachmentHTTPTransport(results: [gifFileDetailResult(downloadURL: "https://object.example.test/original.gif")], uploadResults: [], suspendedPath: "/api/tenant/files/file-gif")
            defer { transport.releaseSuspendedResponse() }
            let context = makeContext()
            // This case intentionally retires session generations. Do not poison
            // the shared persistence authority used by later upload tests.
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent(invalidation).appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent(invalidation).appendingPathComponent("caches")
            )
            let state = AppState(api: makeClient(transport: transport), messagePersistence: persistence, apiContextOverride: context)
            let message = gifRecoveryMessage()
            var conversation = makeGroupConversation(id: "g1")
            conversation.messages = [message]
            state.conversationStore.hydrateCachedConversations([conversation])
            let recovery = Task { await state.refreshedGIFAttachmentOriginalURL(message, conversationID: "g1") }
            try await waitForCondition { !transport.requests().isEmpty }
            XCTAssertEqual(transport.requests().count, 1)
            if invalidation == "cancel" {
                recovery.cancel()
            } else if invalidation == "sessionABA" {
                state.overrideAPIContextForTesting(makeContext(tenantID: "other-tenant", imUID: "other-uid"))
                state.overrideAPIContextForTesting(context)
                state.conversationStore.hydrateCachedConversations([conversation])
            } else if invalidation == "recalled" {
                state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].status = .recalled }
            } else {
                state.conversationStore.mutateStoredConversation(at: 0) { $0.messages[0].isDeletedLocally = true }
            }
            transport.releaseSuspendedResponse()
            let result = await recovery.value
            XCTAssertNil(result, "invalidation=\(invalidation)")
            XCTAssertEqual(transport.requests().count, 1)
            XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.first?.attachmentDownloadURL, "")
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
