import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func attachmentPresignResult(
        fileID: String,
        uploadURL: String,
        reused: Bool = false,
        mimeType: String = "image/png",
        sizeBytes: Int = 600_562
    ) -> HTTPTransportResult {
        let data = try! JSONSerialization.data(withJSONObject: [
            "ok": true,
            "data": [
                "file": [
                    "file_id": fileID,
                    "file_name": mimeType == "image/gif" ? "图片消息.gif" : "图片消息.png",
                    "mime_type": mimeType,
                    "size_bytes": sizeBytes,
                    "status": "prepared",
                    "upload_status": "prepared",
                    "media_category": "image",
                    "extension": mimeType == "image/gif" ? "gif" : "png"
                ],
                "upload": [
                    "url": uploadURL,
                    "method": "PUT",
                    "headers": [
                        "Content-Type": mimeType,
                        "X-Signed-Scope": "object-put"
                    ]
                ],
                "reused": reused
            ]
        ])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: reused ? 200 : 201)
    }

    func attachmentUploadedResult(fileID: String, sizeBytes: Int, mimeType: String = "image/png") -> HTTPTransportResult {
        let data = try! JSONSerialization.data(withJSONObject: [
            "ok": true,
            "data": [
                "file": [
                    "file_id": fileID,
                    "file_name": mimeType == "image/gif" ? "图片消息.gif" : "图片消息.png",
                    "mime_type": mimeType,
                    "size_bytes": sizeBytes,
                    "status": "uploaded",
                    "upload_status": "uploaded",
                    "download_endpoint": "/api/tenant/files/\(fileID)/presign-download",
                    "detail_endpoint": "/api/tenant/files/\(fileID)",
                    "media_category": "image",
                    "extension": mimeType == "image/gif" ? "gif" : "png",
                    "preview_kind": "image",
                    "width": 1,
                    "height": 1
                ]
            ]
        ])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func attachmentMessageResult(messageID: String, fileID: String, sizeBytes: Int, mimeType: String = "image/png") -> HTTPTransportResult {
        let data = try! JSONSerialization.data(withJSONObject: [
            "ok": true,
            "data": [
                "message": [
                    "message_id": messageID,
                    "channel_id": "g1",
                    "channel_type": "group",
                    "channel_seq": 7,
                    "from_uid": "uid-1",
                    "content_type": "image",
                    "payload": [
                        "file_id": fileID,
                        "file_name": mimeType == "image/gif" ? "图片消息.gif" : "图片消息.png",
                        "mime_type": mimeType,
                        "size_bytes": sizeBytes,
                        "media_category": "image",
                        "attachment_status": "uploaded",
                        "upload_status": "uploaded"
                    ],
                    "status": "sent",
                    "created_at": "2026-08-13T00:00:00Z"
                ]
            ]
        ])
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func seedDurableAttachmentCheckpoint(
        root: URL,
        context: IMAPIContext,
        phase: String,
        fileID: String,
        clientMessageID: String,
        isVideo: Bool = false
    ) async throws -> Int {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = pngFixtureBytes(count: 600_562)
        let ext = isVideo ? "mp4" : "png"
        let mime = isVideo ? "video/mp4" : "image/png"
        let name = isVideo ? "视频消息.mp4" : "图片消息.png"
        let sourceURL = root.appendingPathComponent("source-\(clientMessageID).\(ext)")
        try bytes.write(to: sourceURL)
        var message = ChatMessage(
            id: clientMessageID,
            senderId: "uid-1",
            senderName: "我",
            text: name,
            time: "09:00",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            channelSeq: 0,
            isOutgoing: true,
            status: .sending,
            kind: isVideo ? .file : .image,
            reactions: [],
            readBy: [],
            unreadBy: [],
            attachmentName: name,
            attachmentSizeBytes: Int64(bytes.count),
            attachmentPreviewURL: sourceURL.absoluteString,
            attachmentDownloadURL: sourceURL.absoluteString,
            attachmentPreviewAvailable: true,
            attachmentDownloadAvailable: true
        )
        message.contentType = isVideo ? "file" : "image"
        message.attachmentMimeType = mime
        message.attachmentMediaCategory = isVideo ? "video" : "image"
        message.attachmentExtension = ext
        var conversation = makeGroupConversation(id: "g1")
        conversation.messages = [message]
        let scope = try LocalMessageScope(context: context)
        let paths = try MessageDatabasePaths(
            scope: scope,
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let repository = try await SQLiteMessageRepository.open(scope: scope, paths: paths)
        _ = try await repository.enqueueOutgoing(
            LocalMessageOutgoingIntent(
                conversation: LocalMessageConversationSnapshot(
                    conversation: conversation,
                    channelID: "g1",
                    channelType: "group",
                    currentActorID: "uid-1"
                ),
                message: CachedMessage(message: message),
                operationKind: "send_attachment",
                attachment: LocalMessageAttachmentIntent(
                    fileURL: sourceURL,
                    fileName: name,
                    mimeType: mime,
                    sizeBytes: Int64(bytes.count)
                )
            ),
            revision: 1
        )
        try await repository.updateOutboxState(
            clientMessageID: clientMessageID,
            state: phase == "message_send" ? .awaitingAcknowledgement : .sending,
            fileID: fileID,
            attachmentPhase: phase,
            now: Date(timeIntervalSinceNow: -600)
        )
        return bytes.count
    }

    func testColdConversationSyncProjectsStableGroupAvatarBeforeSecondaryGroupHydration() throws {
        let state = AppState(
            messageStore: AvatarProjectionEmptyMessageStore(),
            apiContextOverride: makeContext()
        )
        let remote = try JSONDecoder().decode(RemoteConversation.self, from: Data("""
        {
          "channel_id": "group-cold",
          "channel_type": "group",
          "display_name": "Cold Group",
          "avatar": "/api/tenant/avatar/group-file-cold",
          "avatar_version": "version-cold",
          "avatar_updated_at": "2026-08-13T00:00:00Z"
        }
        """.utf8))

        state.debugApplyRemoteConversationsForTesting([remote])

        let conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first)
        XCTAssertEqual(conversation.id, "group-cold")
        XCTAssertEqual(conversation.avatarURL, "/api/tenant/avatar/group-file-cold")
        XCTAssertEqual(conversation.avatarVersion, "version-cold")
        XCTAssertEqual(conversation.avatarUpdatedAt, "2026-08-13T00:00:00Z")
    }

    func testGroupAvatarProjectionFencesStaleRevisionAndAuthoritativeCleanupPreservesRowState() async throws {
        let messageStore = RecordingAvatarProjectionMessageStore()
        let state = AppState(
            messageStore: messageStore,
            apiContextOverride: makeContext()
        )
        let current = try decodeRemoteUserGroup("""
        {
          "group_id": "group-avatar",
          "group_revision": 8,
          "name": "Current Group",
          "avatar": "/api/tenant/avatar/group-file-v2",
          "avatar_source": "uploaded",
          "avatar_version": "version-2",
          "avatar_updated_at": "2026-08-13T02:00:00Z"
        }
        """)
        let stale = try decodeRemoteUserGroup("""
        {
          "group_id": "group-avatar",
          "group_revision": 7,
          "name": "Stale Group",
          "avatar": "/api/tenant/avatar/group-file-v1",
          "avatar_source": "uploaded",
          "avatar_version": "version-1",
          "avatar_updated_at": "2026-08-13T01:00:00Z"
        }
        """)
        let cleanup = try decodeRemoteUserGroup("""
        {
          "group_id": "group-avatar",
          "group_revision": 9,
          "name": "Current Group",
          "avatar": "/api/tenant/avatar/group-default-avatar.svg",
          "avatar_source": "group_default",
          "avatar_version": "",
          "avatar_updated_at": ""
        }
        """)

        state.debugApplyRemoteGroupsForTesting([current])
        try await waitForCondition { messageStore.writeCount() > 0 }
        state.conversationStore.mutateStoredConversation(at: 0) { $0.unread = 4 }
        state.conversationStore.mutateStoredConversation(at: 0) { $0.isPinned = true }
        let stableSortTimestamp = state.conversationStore.conversationMessageSnapshots()[0].sortTimestamp
        state.debugApplyRemoteGroupsForTesting([stale])

        XCTAssertEqual(state.groups.first?.groupRevision, 8)
        XCTAssertEqual(state.groups.first?.name, "Current Group")
        XCTAssertEqual(state.groups.first?.avatarURL, "/api/tenant/avatar/group-file-v2")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.avatarVersion, "version-2")

        state.debugApplyRemoteGroupsForTesting([cleanup])

        XCTAssertEqual(state.groups.first?.groupRevision, 9)
        XCTAssertEqual(state.groups.first?.avatarURL, "")
        XCTAssertEqual(state.groups.first?.avatarVersion, "")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.avatarURL, "")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.avatarVersion, "")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.unread, 4)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.isPinned, true)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.sortTimestamp, stableSortTimestamp)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().map(\.id), ["group-avatar"])
    }

    func testGroupAvatarAuthorityRejectsSignedAndCrossTenantAbsolutePersistence() throws {
        let state = AppState(
            messageStore: AvatarProjectionEmptyMessageStore(),
            apiContextOverride: makeContext()
        )
        let signed = try decodeRemoteUserGroup("""
        {
          "group_id": "group-signed",
          "group_revision": 1,
          "name": "Signed Group",
          "avatar": "https://foreign.example.test/api/tenant/avatar/file?signature=redacted",
          "avatar_source": "uploaded",
          "avatar_version": "version-1"
        }
        """)

        state.debugApplyRemoteGroupsForTesting([signed])

        XCTAssertEqual(state.groups.first?.avatarURL, "")
        XCTAssertEqual(state.groups.first?.avatarVersion, "")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.avatarURL, "")
    }

    func testGroupAvatarRealtimeVersionUpdateConvergesThroughAuthoritativeSummary() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"group-live","group_revision":2,"name":"Live Group","avatar":"/api/tenant/avatar/group-file-v2","avatar_source":"uploaded","avatar_version":"version-2","avatar_updated_at":"2026-08-13T02:00:00Z"},"member_preview":[{"im_uid":"owner-1","nickname":"Owner","role":"owner","is_owner":true}],"current_announcement":{"id":"notice-1","group_id":"group-live","content":"notice","unread":true},"settings":{"group_revision":2}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(
            api: makeClient(transport: transport),
            messageStore: AvatarProjectionEmptyMessageStore(),
            apiContextOverride: makeContext()
        )
        let initial = try decodeRemoteUserGroup("""
        {
          "group_id": "group-live",
          "group_revision": 1,
          "name": "Live Group",
          "avatar": "/api/tenant/avatar/group-file-v1",
          "avatar_source": "uploaded",
          "avatar_version": "version-1"
        }
        """)
        let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data("""
        {
          "type": "group.settings.updated",
          "payload": {
            "group_id": "group-live",
            "group_revision": 2,
            "changed": ["avatar"],
            "settings": {"group_revision": 2}
          }
        }
        """.utf8))
        state.debugApplyRemoteGroupsForTesting([initial])

        state.debugHandleRealtimeEnvelopeForTesting(envelope)
        try await waitForCondition {
            state.groups.first?.avatarVersion == "version-2"
                && state.conversationStore.conversationMessageSnapshots().first?.avatarVersion == "version-2"
        }

        XCTAssertEqual(state.groups.first?.groupRevision, 2)
        XCTAssertEqual(state.groups.first?.avatarURL, "/api/tenant/avatar/group-file-v2")
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.avatarURL, "/api/tenant/avatar/group-file-v2")
        XCTAssertEqual(
            transport.requests().first?.url?.path,
            "/api/tenant/groups/group-live/summary"
        )
    }

    private func decodeRemoteUserGroup(_ json: String) throws -> RemoteUserGroup {
        try JSONDecoder().decode(RemoteUserGroup.self, from: Data(json.utf8))
    }

    func assertRegistrationAppIDIsolationPendingState(
        _ state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.registrationResolutionState, .pending, file: file, line: line)
        XCTAssertEqual(state.toast, RegistrationConfirmationPolicy.pendingMessage, file: file, line: line)
        XCTAssertTrue(state.isRegistrationSubmissionBlocked, file: file, line: line)
        XCTAssertEqual(state.authScreen, .accountRegister, file: file, line: line)
        XCTAssertFalse(state.isAuthenticated, file: file, line: line)
        XCTAssertFalse(state.enterprises.contains { $0.name == "QA Tenant" || $0.code == "WXT999999" }, file: file, line: line)
        XCTAssertNotEqual(state.currentEnterprise.name, "QA Tenant", file: file, line: line)
        XCTAssertFalse(IMAPIContext.load().hasRefreshSession, file: file, line: line)
        XCTAssertFalse(IMAPIContext.load().hasIMSession, file: file, line: line)
    }

    func inviteCodeResponse(code: String, tenantID: String, imUID: String) -> HTTPTransportResult {
        let payload: [String: Any] = [
            "ok": true,
            "data": [
                "enabled": true,
                "item": [
                    "tenant_id": tenantID,
                    "im_uid": imUID,
                    "member_invite_code": code,
                    "status": "active",
                    "sync_status": "synced"
                ]
            ]
        ]
        return HTTPTransportResult(
            data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func favoriteAssetsResult(
        items: [[String: Any]],
        nextCursor: String = "",
        hasMore: Bool = false
    ) -> HTTPTransportResult {
        let payload: [String: Any] = [
            "ok": true,
            "data": [
                "items": items,
                "next_cursor": nextCursor,
                "has_more": hasMore
            ]
        ]
        return HTTPTransportResult(
            data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func favoriteAssetJSON(
        messageID: String,
        category: String,
        favoriteVersion: Int64 = 1
    ) -> [String: Any] {
        [
            "tenant_id": "tenant-1",
            "message_id": messageID,
            "channel_id": "group-1",
            "channel_type": "group",
            "channel_seq": favoriteVersion,
            "from_uid": "uid-1",
            "content_type": "file",
            "payload": [
                "file_id": "file-\(messageID)",
                "file_name": "\(messageID).dat",
                "mime_type": category == "image" ? "image/png" : "application/pdf",
                "size_bytes": 1_024,
                "media_category": category
            ],
            "status": "sent",
            "created_at": "2026-08-17T10:00:00Z",
            "favorited_at": "2026-08-17T10:01:00Z",
            "favorite_version": favoriteVersion,
            "category": category,
            "display_text": messageID,
            "cursor": "cursor-\(favoriteVersion)"
        ]
    }

    func makeContext(
        tenantID: String = "tenant-1",
        imUID: String = "uid-1",
        imToken: String = "im-token"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: tenantID,
            imUID: imUID,
            imToken: imToken,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "ios-main",
            deviceID: "device-1"
        )
    }

    // WDT_IOS1_NETWORK_PARENT_SCOPE_FIXTURE_20261111_BEGIN
    func makeRefreshableMessageSendContext(deviceID: String = "device-1") -> IMAPIContext {
        IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-1",
            tenantID: "tenant-1",
            imUID: "uid-1",
            imToken: "stale-im-token",
            platformAuthSession: nil,
            tenantAuthSession: IMStoredAuthSession(
                sessionID: "sess_platform-tenant-1",
                refreshToken: "platform-tenant-refresh-1",
                tokenType: "im",
                tenantID: "tenant-1",
                accountID: "account-1",
                appID: "jianhuitong-ios",
                deviceID: deviceID,
                clientType: "ios"
            ),
            appID: "jianhuitong-ios",
            deviceID: deviceID
        )
    }
    // WDT_IOS1_NETWORK_PARENT_SCOPE_FIXTURE_20261111_END

    func activeAppPolicyResult() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func messageSendSuccessResult(messageID: String) -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(
                """
                {"ok":true,"data":{"message":{"message_id":"\(messageID)","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":7,"from_uid":"uid-1","content_type":"text","payload":{"text":"hello"},"status":"sent","created_at":"2026-08-17T11:02:18Z"}}}
                """.utf8
            ),
            isHTTPResponse: true,
            statusCode: 201
        )
    }

    func makeMessageSendState(transport: HTTPTransport) -> AppState {
        let state = makeIsolatedAuthenticatedHTTPState( // WDT_IOS1_CORE23_ISOLATED_AUTH_FIXTURE_20261111
            transport: transport, context: makeRefreshableMessageSendContext()
        )
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        return state
    }

    func makePreloginContext(
        appID: String = "ios-main",
        deviceID: String = "device-1"
    ) -> IMAPIContext {
        IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: appID,
            deviceID: deviceID
        )
    }

    func makeUser(id: String, name: String) -> IMUser {
        IMUser(
            id: id,
            name: name,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: "",
            avatarSeed: 0,
            badges: []
        )
    }

    func makeVerificationAuthorityUser(
        id: String,
        phoneVerified: Bool,
        realNameVerified: Bool
    ) -> IMUser {
        IMUser(
            id: id,
            userID: id,
            username: "backend-created-user",
            name: "后台创建用户",
            title: "",
            department: "",
            phone: "138****1001",
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameVerified ? "approved" : "unsubmitted",
            email: "",
            status: "在线",
            enterprise: "测试企业",
            avatarSeed: 1,
            badges: []
        )
    }

    func makeGroupInfo(id: String) -> GroupInfo {
        GroupInfo(
            id: id,
            name: "测试群",
            notice: "",
            owner: "",
            members: [],
            admins: [],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil
        )
    }

    func clearStoredAPIContext() {
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true)
        IMAppBootstrapLastGoodStore.clearAll()
        IMAppPolicyLastGoodStore.clearAll()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "im2.ios.appID")
        defaults.removeObject(forKey: "im2.ios.deviceID")
        defaults.removeObject(forKey: PendingRegistrationReceiptStore.storageKey)
        defaults.synchronize()
    }

    func resetSharedAccessDiagnosticsForPolicyTests() {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        AccessDiagnostics.shared.forceDisable()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func registerFiveSharedAccessDiagnosticsLogoTaps(
        scope: AccessDiagnosticsActivationScope,
        baseNanoseconds: UInt64 = 1_000_000_000
    ) {
        for index in 0..<5 {
            AccessDiagnostics.shared.registerLogoTap(
                entry: .loggedOutLoginLogo,
                scope: scope,
                nowNanoseconds: baseNanoseconds + UInt64(index) * 120_000_000
            )
        }
    }

    func registerFiveStateAccessDiagnosticsLogoTaps(_ state: AppState) {
        for _ in 0..<5 {
            state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
        }
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    func makeGroupConversation(id: String) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(
            id: id,
            title: "测试群",
            subtitle: "",
            kind: .group,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0x6677FF,
            participants: [],
            messages: []
        )
    }

    func makeDirectConversation(id: String) -> ConversationMessageSnapshot {
        ConversationMessageSnapshot(
            id: id,
            title: "单聊",
            subtitle: "",
            kind: .direct,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: 0x6677FF,
            participants: [makeUser(id: "uid-2", name: "对方")],
            messages: []
        )
    }

    func makeVoiceRemoteFile(id: String, sizeBytes: Int) -> RemoteAvatarFile {
        RemoteAvatarFile(
            id: id,
            fileName: "voice.m4a",
            mimeType: "audio/mp4",
            sizeBytes: sizeBytes,
            status: "uploaded",
            uploadStatus: "uploaded",
            previewAvailable: false,
            downloadAvailable: true,
            previewURL: "",
            downloadURL: "",
            downloadEndpoint: "",
            detailEndpoint: "",
            cacheKey: "",
            version: "",
            checksum: "",
            mediaCategory: "voice",
            fileExtension: "m4a",
            thumbnailURL: "",
            posterURL: "",
            coverURL: "",
            previewKind: "voice",
            contentDisposition: "attachment",
            width: nil,
            height: nil,
            durationSeconds: 1.5
        )
    }

    func makeUpload(url: String, method: String, headers: [String: String]) throws -> RemoteSignedUpload {
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url,
            "method": method,
            "headers": headers
        ])
        return try JSONDecoder().decode(RemoteSignedUpload.self, from: data)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
