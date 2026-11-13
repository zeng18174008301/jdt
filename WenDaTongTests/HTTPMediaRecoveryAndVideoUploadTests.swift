import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testGIFOriginalURLRecoveryRejectsOversizedStaticOrUnavailableMetadata() async throws {
        for response in [
            gifFileDetailResult(downloadURL: "https://object.example.test/large.gif", sizeBytes: Int(GIFAttachmentUploadPolicy.maximumBytes) + 1),
            gifFileDetailResult(downloadURL: "https://object.example.test/static.png", mimeType: "image/png"),
            gifFileDetailResult(downloadURL: "https://object.example.test/denied.gif", downloadAllowed: false, previewAllowed: false),
            gifFileDetailResult(downloadURL: "https://object.example.test/denied.gif", downloadAllowed: false),
            gifFileDetailResult(downloadURL: "https://object.example.test/pending.gif", status: "prepared")
        ] {
            let transport = FakeHTTPTransport(results: [response])
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
            let message = gifRecoveryMessage()
            var conversation = makeGroupConversation(id: "g1")
            conversation.messages = [message]
            state.conversationStore.hydrateCachedConversations([conversation])
            let result = await state.refreshedGIFAttachmentOriginalURL(message, conversationID: "g1")
            XCTAssertNil(result)
            XCTAssertEqual(transport.requests().count, 1)
        }
    }

    func testGIFCancellationDuringFinalizeDoesNotSendMessage() async throws {
        let bytes = gifFixtureBytes()
        let transport = StrictAttachmentHTTPTransport(results: [
            attachmentConfigResult(),
            attachmentPresignResult(fileID: "file-gif", uploadURL: "https://object.example.test/cancel.gif", mimeType: "image/gif", sizeBytes: bytes.count),
            attachmentUploadedResult(fileID: "file-gif", sizeBytes: bytes.count, mimeType: "image/gif")
        ], uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)], suspendedPath: "/api/tenant/files/file-gif/uploaded")
        defer { transport.releaseSuspendedResponse() }
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        var localID: String?
        XCTAssertTrue(state.sendAttachment(kind: .image, name: "cancel.gif", mimeType: "image/gif", sizeBytes: nil,
            data: bytes, conversationID: "g1", quote: nil, onQueued: { localID = $0 }))
        try await waitForCondition { transport.requests().contains { $0.url?.path.hasSuffix("/uploaded") == true } }
        XCTAssertTrue(transport.requests().contains { $0.url?.path.hasSuffix("/uploaded") == true })
        state.cancelAttachmentUpload(messageID: try XCTUnwrap(localID), in: "g1")
        transport.releaseSuspendedResponse()
        try await waitForCondition { transport.didReturnSuspendedResponse() }
        // Let the resumed MainActor continuation cross the final send fence.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.didReturnSuspendedResponse())
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/im/messages" })
        XCTAssertTrue(state.conversationStore.conversationMessageSnapshots().first?.messages.isEmpty == true)
        XCTAssertEqual(transport.uploads().count, 1)
        XCTAssertNil(state.fileStore.attachmentUploadCheckpoint(messageID: try XCTUnwrap(localID)))
    }

    func testImageAttachmentPutFailureKeepsPhaseAndExplicitRetryRecoversGroupSend() async throws {
        let imageBytes = pngFixtureBytes(count: 600_562)
        let signedURL = "https://object.example.test/private/image.png?signature=redacted&expires=900"
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                attachmentPresignResult(fileID: "file-image", uploadURL: signedURL),
                attachmentConfigResult(),
                attachmentPresignResult(fileID: "file-image", uploadURL: signedURL, reused: true),
                attachmentUploadedResult(fileID: "file-image", sizeBytes: imageBytes.count),
                attachmentMessageResult(messageID: "msg-image", fileID: "file-image", sizeBytes: imageBytes.count)
            ],
            uploadResults: [
                HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 503),
                HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
            ]
        )
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])

        XCTAssertTrue(state.sendAttachment(
            kind: .image,
            name: "图片消息.png",
            mimeType: "image/png",
            sizeBytes: Int64(imageBytes.count),
            data: imageBytes,
            conversationID: "g1",
            quote: nil
        ))

        let failed = try await awaitMessage(in: state, conversationID: "g1") {
            $0.status == .failed && $0.attachmentUploadStatus == AttachmentUploadPhase.put.failedStatus && $0.attachmentUploadFailure != nil // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        }
        let localID = failed.id
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
        XCTAssertEqual(state.attachmentUploadFailureMessage(for: failed), "图片内容上传失败，请重试\nHTTP · HTTP 503")
        XCTAssertEqual(failed.attachmentUploadFailure, AttachmentUploadFailure(code: .http, httpStatus: 503))
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
        XCTAssertTrue(state.canRetryAttachmentUpload(failed))
        XCTAssertEqual(transport.uploads().count, 1)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/im/messages" })
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/tenant/files/file-image/uploaded" })

        state.retryAttachmentUpload(messageID: localID, in: "g1")
        let confirmed = try await awaitMessage(in: state, conversationID: "g1") { $0.id == "msg-image" }
        XCTAssertEqual(confirmed.attachmentFileID, "file-image")
        XCTAssertFalse(state.canRetryAttachmentUpload(confirmed))
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().first?.messages.map(\.id), ["msg-image"])

        let requests = transport.requests()
        let paths = requests.compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/config" }.count, 2)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 2)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/file-image/uploaded" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 1)
        XCTAssertEqual(transport.uploads().count, 2)
        XCTAssertTrue(transport.isExhausted)

        let presignBodies = try requests
            .filter { $0.url?.path == "/api/tenant/files/presign-upload" }
            .map(requestJSONObject)
        XCTAssertEqual(presignBodies.count, 2)
        for body in presignBodies {
            XCTAssertEqual(body["client_msg_no"] as? String, localID)
            XCTAssertEqual(body["purpose"] as? String, "message_attachment")
            XCTAssertEqual(body["channel_id"] as? String, "g1")
            XCTAssertEqual(body["channel_type"] as? String, "group")
            let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
            XCTAssertEqual(metadata["message_id"] as? String, localID)
            XCTAssertEqual(metadata["purpose"] as? String, "message_attachment")
            XCTAssertEqual(metadata["group_id"] as? String, "g1")
        }
        let finalizeBody = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path == "/api/tenant/files/file-image/uploaded" }))
        XCTAssertEqual(finalizeBody["client_msg_no"] as? String, localID)
        XCTAssertEqual(finalizeBody["channel_id"] as? String, "g1")
        XCTAssertEqual(finalizeBody["channel_type"] as? String, "group")
        XCTAssertEqual(finalizeBody["group_id"] as? String, "g1")
        let sendBody = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path == "/api/im/messages" }))
        XCTAssertEqual(sendBody["client_msg_no"] as? String, localID)
        XCTAssertEqual(sendBody["content_type"] as? String, "image")
        XCTAssertEqual((sendBody["payload"] as? [String: Any])?["file_id"] as? String, "file-image")

        for upload in transport.uploads() {
            XCTAssertEqual(upload.request.url?.absoluteString, signedURL)
            XCTAssertEqual(upload.request.httpMethod, "PUT")
            XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "image/png")
            XCTAssertEqual(upload.request.value(forHTTPHeaderField: "X-Signed-Scope"), "object-put")
            XCTAssertNil(upload.request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(upload.body, imageBytes)
        }
    }

    func testVideoUploadFallsBackOnceWithTheSameStagedBytesAndIdentities() async throws {
        let bytes = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let context = makeContext(tenantID: "video-route-\(UUID().uuidString)")
        let fileID = "video-upload"
        let acceleratedURL = "https://fast.example.test/object?sig=fast"
        let standardURL = "https://storage.example.test/object?sig=standard"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        // Retain only this UUID fixture root; original upload/source cleanup and recovery tasks stay intact.
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END
        let sourceURL = root.appendingPathComponent("clip.mp4")
        try bytes.write(to: sourceURL)
        let managed = try PendingAttachmentFileStore.stageFile(from: sourceURL, preferredName: "clip.mp4")
        defer { PendingAttachmentFileStore.removeManagedFile(at: managed.url) }
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                videoPresignFixture(fileID: fileID, url: acceleratedURL, transport: "accelerated", size: bytes.count),
                videoUploadFixture(404, ["ok": false]),
                videoUploadFixture(409, ["ok": false, "error": ["code": "object_not_found"]]),
                videoPresignFixture(fileID: fileID, url: standardURL, transport: "standard", size: bytes.count),
                videoUploadFixture(404, ["ok": false]),
                attachmentUploadedResult(fileID: fileID, sizeBytes: bytes.count, mimeType: "video/mp4"),
                attachmentMessageResult(messageID: "sent-video", fileID: fileID, sizeBytes: bytes.count, mimeType: "video/mp4")
            ],
            uploadResults: [videoUploadFixture(200, [:]), videoUploadFixture(200, [:])]
        )
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let state = AppState(api: makeClient(transport: transport), messagePersistence: persistence, apiContextOverride: context)
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        XCTAssertTrue(state.sendAttachment(
            kind: .file, name: "clip.mp4", mimeType: "video/mp4", sizeBytes: Int64(bytes.count),
            fileURL: managed.url, removeFileWhenFinished: true, conversationID: "g1", quote: nil
        ))
        let outcome = try await awaitMessage(in: state, conversationID: "g1") {
            $0.id == "sent-video" || $0.attachmentUploadStatus.hasPrefix("failed_")
        }
        XCTAssertEqual(outcome.id, "sent-video", "phase=\(outcome.attachmentUploadStatus) requests=\(transport.requests().compactMap { $0.url?.path })")
        let requests = transport.requests()
        let presigns = try requests.filter { $0.url?.path == "/api/tenant/files/presign-upload" }.map(requestJSONObject)
        guard presigns.count == 2 else { return XCTFail("Expected two signatures, got \(presigns.count)") }
        XCTAssertEqual(presigns.map { $0["upload_transport"] as? String }, ["auto", "standard"])
        XCTAssertEqual(presigns.map { $0["checksum"] as? String }, Array(repeating: AttachmentTransferRepository.sha256Hex(bytes), count: 2))
        XCTAssertEqual(presigns[1]["expected_file_id"] as? String, fileID)
        XCTAssertEqual(presigns[0]["client_msg_no"] as? String, presigns[1]["client_msg_no"] as? String)
        let sent = try requests.filter { $0.url?.path == "/api/im/messages" }.map(requestJSONObject)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["client_msg_no"] as? String, presigns[0]["client_msg_no"] as? String)
        XCTAssertEqual((sent.first?["payload"] as? [String: Any])?["file_id"] as? String, fileID)
        XCTAssertEqual(transport.uploads().map { $0.request.url?.absoluteString }, [acceleratedURL, standardURL])
        XCTAssertEqual(transport.uploads().map(\.body), [bytes, bytes])
        XCTAssertTrue(transport.isExhausted)
    }

    func testVideoUploadRejectsMismatchedFallbackObjectWithoutSecondPut() async throws {
        let bytes = Data([0, 1, 2, 3])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mismatch-video-\(UUID().uuidString)", isDirectory: true)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        // Retain only this UUID fixture root; original upload/source cleanup and recovery tasks stay intact.
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                videoPresignFixture(fileID: "original", url: "https://fast.example.test/object", transport: "accelerated", size: bytes.count),
                videoUploadFixture(404, ["ok": false]),
                videoUploadFixture(409, ["ok": false, "error": ["code": "object_not_found"]]),
                videoPresignFixture(fileID: "different", url: "https://storage.example.test/object", transport: "standard", size: bytes.count)
            ],
            uploadResults: [videoUploadFixture(200, [:])]
        )
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let state = AppState(
            api: makeClient(transport: transport), messagePersistence: persistence,
            apiContextOverride: makeContext(tenantID: "video-mismatch-\(UUID().uuidString)")
        )
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])
        XCTAssertTrue(state.sendAttachment(
            kind: .file, name: "clip.mp4", mimeType: "video/mp4", sizeBytes: Int64(bytes.count),
            data: bytes, conversationID: "g1", quote: nil
        ))
        let outcome = try await awaitMessage(in: state, conversationID: "g1") {
            $0.attachmentUploadStatus.hasPrefix("failed_")
        }
        XCTAssertEqual(transport.uploads().count, 1, "phase=\(outcome.attachmentUploadStatus) requests=\(transport.requests().compactMap { $0.url?.path })")
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/im/messages" })
        XCTAssertTrue(transport.isExhausted)
    }

    func testVideoUploadConfirmationRequiresVerifiedBinding() async throws {
        let context = makeContext()
        let checksum = String(repeating: "a", count: 64)
        let file: [String: Any] = [
            "file_id": "video", "app_id": context.appID, "channel_id": "g1", "channel_type": "group",
            "client_msg_no": "local-video", "size_bytes": 8, "mime_type": "video/mp4",
            "status": "uploaded", "completion_state": "uploaded", "verified": true, "checksum_sha256": checksum
        ]
        for matching in [true, false] {
            let payload = matching ? file : file.merging(["client_msg_no": "another-message"]) { _, new in new }
            let transport = StrictAttachmentHTTPTransport(
                results: [videoUploadFixture(200, ["ok": true, "data": payload])], uploadResults: []
            )
            let api = makeClient(transport: transport)
            do {
                let confirmed = try await api.confirmRoutedVideoAttachmentUpload(
                    context: context, conversation: makeGroupConversation(id: "g1"), channelID: "g1",
                    clientMessageID: "local-video", fileID: "video", sizeBytes: 8, mimeType: "video/mp4",
                    checksum: checksum, preparedFile: nil
                )
                XCTAssertTrue(matching, "a different message cannot confirm this upload")
                XCTAssertEqual(confirmed.id, "video")
                XCTAssertEqual(confirmed.checksum, checksum)
            } catch {
                XCTAssertFalse(matching, "matching verified upload failed: \(error)")
            }
            XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/video/upload-status"])
            XCTAssertTrue(transport.isExhausted)
        }
    }

    func testVideoUploadAcceptedCompletionStillReadsAuthoritativeStatus() async throws {
        let context = makeContext()
        let checksum = String(repeating: "b", count: 64)
        let identity: [String: Any] = [
            "file_id": "video", "app_id": context.appID, "channel_id": "g1", "channel_type": "group",
            "client_msg_no": "local-video", "size_bytes": 8, "mime_type": "video/mp4"
        ]
        let prepared = identity.merging(["status": "prepared", "completion_state": "prepared",
                                         "verified": false, "checksum_sha256": ""]) { _, new in new }
        let verified = identity.merging(["status": "uploaded", "completion_state": "uploaded",
                                         "verified": true, "checksum_sha256": checksum]) { _, new in new }
        let transport = StrictAttachmentHTTPTransport(results: [
            videoUploadFixture(200, ["ok": true, "data": prepared]),
            videoUploadFixture(202, ["ok": true, "data": ["file_id": "video", "status": "uploaded"]]),
            videoUploadFixture(200, ["ok": true, "data": verified])
        ], uploadResults: [])
        var selectedVerification = false
        let confirmed = try await makeClient(transport: transport).confirmRoutedVideoAttachmentUpload(
            context: context, conversation: makeGroupConversation(id: "g1"), channelID: "g1",
            clientMessageID: "local-video", fileID: "video", sizeBytes: 8, mimeType: "video/mp4",
            checksum: checksum, preparedFile: nil
        ) {
            selectedVerification = true
        }
        XCTAssertTrue(selectedVerification)
        XCTAssertEqual(confirmed.checksum, checksum)
        XCTAssertEqual(transport.requests().map { $0.url?.lastPathComponent }, ["upload-status", "uploaded", "upload-status"])
        XCTAssertEqual(transport.requests().first { $0.httpMethod == "POST" }?.value(forHTTPHeaderField: "Prefer"), "respond-async")
        XCTAssertTrue(transport.isExhausted)
    }

    func testColdRestartDoesNotSpendVideoFallbackTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-video-\(UUID().uuidString)", isDirectory: true)
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
        // Retain only this UUID fixture root; original upload/source cleanup and recovery tasks stay intact.
        // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END
        let context = makeContext(tenantID: "cold-video-\(UUID().uuidString)")
        let messageID = "local-cold-video"
        let fileID = "cold-video-file"
        _ = try await seedDurableAttachmentCheckpoint(
            root: root, context: context, phase: "video_standard_fallback", fileID: fileID,
            clientMessageID: messageID, isVideo: true
        )
        let transport = StrictAttachmentHTTPTransport(results: [
            attachmentConfigResult(),
            videoUploadFixture(404, ["ok": false]),
            videoUploadFixture(409, ["ok": false, "error": ["code": "object_not_found"]])
        ], uploadResults: [])
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let state = AppState(api: makeClient(transport: transport), messagePersistence: persistence, apiContextOverride: context)
        let restored = await state.recoverCachedDurableOutboxForTesting()
        XCTAssertTrue(restored)
        _ = try await awaitMessage(in: state, conversationID: "g1") { $0.id == messageID && $0.status == .failed }
        XCTAssertEqual(transport.requests().map { $0.url?.lastPathComponent }, ["config", "upload-status", "uploaded"])
        XCTAssertTrue(transport.uploads().isEmpty)
        XCTAssertTrue(transport.isExhausted)
    }

    func testImageAttachmentFinalizeFailureRetriesSameFileWithoutSecondPut() async throws {
        let imageBytes = pngFixtureBytes(count: 600_562)
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                attachmentPresignResult(fileID: "file-finalize", uploadURL: "https://object.example.test/finalize.png?signature=redacted"),
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"tenant_storage_temporarily_unavailable","message":"storage unavailable"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 502
                ),
                attachmentConfigResult(),
                attachmentUploadedResult(fileID: "file-finalize", sizeBytes: imageBytes.count),
                attachmentMessageResult(messageID: "msg-finalize", fileID: "file-finalize", sizeBytes: imageBytes.count)
            ],
            uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 200)]
        )
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])

        XCTAssertTrue(state.sendAttachment(
            kind: .image,
            name: "图片消息.png",
            mimeType: "image/png",
            sizeBytes: Int64(imageBytes.count),
            data: imageBytes,
            conversationID: "g1",
            quote: nil
        ))
        let failed = try await awaitMessage(in: state, conversationID: "g1") {
            $0.status == .failed && $0.attachmentUploadStatus == AttachmentUploadPhase.finalize.failedStatus
        }
        XCTAssertEqual(state.attachmentUploadFailureMessage(for: failed), "图片上传确认失败，请重试\nHTTP · HTTP 502 · unrecognized_server_code")
        XCTAssertEqual(failed.attachmentUploadFailure, AttachmentUploadFailure(code: .http, httpStatus: 502, serverCode: "unrecognized_server_code"))
        XCTAssertEqual(transport.uploads().count, 1)
        XCTAssertEqual(transport.requests().filter { $0.url?.path == "/api/tenant/files/presign-upload" }.count, 1)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/im/messages" })

        state.retryAttachmentUpload(messageID: failed.id, in: "g1")
        _ = try await awaitMessage(in: state, conversationID: "g1") { $0.id == "msg-finalize" }

        let paths = transport.requests().compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/file-finalize/uploaded" }.count, 2)
        XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 1)
        XCTAssertEqual(transport.uploads().count, 1)
        XCTAssertTrue(transport.isExhausted)
    }

    func testImageAttachmentMessageSendFailureRetriesOnlyIdempotentSend() async throws {
        let imageBytes = pngFixtureBytes(count: 600_562)
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                attachmentPresignResult(fileID: "file-send", uploadURL: "https://object.example.test/send.png?signature=redacted"),
                attachmentUploadedResult(fileID: "file-send", sizeBytes: imageBytes.count),
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"file_context_mismatch","message":"context mismatch"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 403
                ),
                attachmentConfigResult(),
                attachmentMessageResult(messageID: "msg-send", fileID: "file-send", sizeBytes: imageBytes.count)
            ],
            uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)]
        )
        let state = makeIsolatedOutgoingState(transport: transport, context: makeContext())
        state.conversationStore.hydrateCachedConversations([makeGroupConversation(id: "g1")])

        XCTAssertTrue(state.sendAttachment(
            kind: .image,
            name: "图片消息.png",
            mimeType: "image/png",
            sizeBytes: Int64(imageBytes.count),
            data: imageBytes,
            conversationID: "g1",
            quote: nil
        ))
        let failed = try await awaitMessage(in: state, conversationID: "g1") {
            $0.status == .failed && $0.attachmentUploadStatus == AttachmentUploadPhase.send.failedStatus && $0.attachmentUploadFailure != nil // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        }
        XCTAssertEqual(failed.attachmentFileID, "file-send")
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
        XCTAssertEqual(state.attachmentUploadFailureMessage(for: failed), "图片已上传，消息提交失败，请重试\nHTTP · HTTP 403 · unrecognized_server_code")
        XCTAssertEqual(failed.attachmentUploadFailure, AttachmentUploadFailure(code: .http, httpStatus: 403, serverCode: "unrecognized_server_code"))
        // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END

        state.retryAttachmentUpload(messageID: failed.id, in: "g1")
        _ = try await awaitMessage(in: state, conversationID: "g1") { $0.id == "msg-send" }

        let requests = transport.requests()
        let paths = requests.compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/file-send/uploaded" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 2)
        XCTAssertEqual(transport.uploads().count, 1)
        let sends = try requests.filter { $0.url?.path == "/api/im/messages" }.map(requestJSONObject)
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[0]["client_msg_no"] as? String, failed.id)
        XCTAssertEqual(sends[1]["client_msg_no"] as? String, failed.id)
        XCTAssertEqual((sends[0]["payload"] as? [String: Any])?["file_id"] as? String, "file-send")
        XCTAssertEqual((sends[1]["payload"] as? [String: Any])?["file_id"] as? String, "file-send")
        XCTAssertTrue(transport.isExhausted)
    }

    func testColdRestartFromUploadedCheckpointSkipsPresignAndPut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-cold-uploaded-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        let context = makeContext(tenantID: "tenant-cold-uploaded-\(UUID().uuidString)")
        let sizeBytes = try await seedDurableAttachmentCheckpoint(
            root: root,
            context: context,
            phase: "uploaded",
            fileID: "file-cold-uploaded",
            clientMessageID: "local-cold-uploaded"
        )
        let transport = StrictAttachmentHTTPTransport(
            results: [
                attachmentConfigResult(),
                attachmentUploadedResult(fileID: "file-cold-uploaded", sizeBytes: sizeBytes),
                attachmentMessageResult(messageID: "msg-cold-uploaded", fileID: "file-cold-uploaded", sizeBytes: sizeBytes)
            ],
            uploadResults: []
        )
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let loaded = try await persistence.activateAndLoad(
            context: context,
            sessionGeneration: 1
        )
        let pending = loaded.pendingOutbox
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attachmentPhase, "uploaded")
        XCTAssertEqual(pending.first?.attachmentFileID, "file-cold-uploaded")
        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.id), ["local-cold-uploaded"])
        let state = AppState(
            api: makeClient(transport: transport),
            messagePersistence: persistence,
            apiContextOverride: context
        )
        addTeardownBlock { @MainActor in
            await persistence.detach(ticket: state.localMessageTicket)
        }

        let restored = await state.recoverCachedDurableOutboxForTesting()
        XCTAssertTrue(restored)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().map(\.id), ["g1"])
        try await waitForCondition(iterations: 120) {
            !state.fileStore.hasAttachmentUploadTask(messageID: "local-cold-uploaded")
                && (transport.isExhausted
                    || state.conversationStore.conversationMessageSnapshot(id: "g1")?.messages.contains(where: {
                        $0.id == "local-cold-uploaded" && $0.status == .failed
                    }) == true)
        }

        let requests = transport.requests()
        let paths = requests.compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/config" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 0)
        XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/file-cold-uploaded/uploaded" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 1)
        XCTAssertTrue(transport.uploads().isEmpty)
        let sendBody = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path == "/api/im/messages" }))
        XCTAssertEqual(sendBody["client_msg_no"] as? String, "local-cold-uploaded")
        XCTAssertEqual((sendBody["payload"] as? [String: Any])?["file_id"] as? String, "file-cold-uploaded")
        XCTAssertNotNil(
            state.conversationStore.conversationMessageSnapshot(id: "g1")?.messages.first(where: {
                $0.id == "msg-cold-uploaded"
            })
        )
        XCTAssertTrue(transport.isExhausted)
    }

    func testColdRestartFromFinalizedAndMessageSendCheckpointsRetriesOnlySameMessageIdentity() async throws {
        for phase in ["finalized", "message_send"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios1-cold-\(phase)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let context = makeContext(tenantID: "tenant-cold-\(phase)-\(UUID().uuidString)")
            let clientMessageID = "local-cold-\(phase)"
            let fileID = "file-cold-\(phase)"
            let serverMessageID = "msg-cold-\(phase)"
            let sizeBytes = try await seedDurableAttachmentCheckpoint(
                root: root,
                context: context,
                phase: phase,
                fileID: fileID,
                clientMessageID: clientMessageID
            )
            let transport = StrictAttachmentHTTPTransport(
                results: [
                    attachmentConfigResult(),
                    attachmentMessageResult(
                        messageID: serverMessageID,
                        fileID: fileID,
                        sizeBytes: sizeBytes
                    )
                ],
                uploadResults: []
            )
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")
            )
            let loaded = try await persistence.activateAndLoad(
                context: context,
                sessionGeneration: 1
            )
            let pending = loaded.pendingOutbox
            XCTAssertEqual(pending.count, 1, phase)
            XCTAssertEqual(pending.first?.attachmentPhase, phase, phase)
            XCTAssertEqual(pending.first?.attachmentFileID, fileID, phase)
            XCTAssertEqual(loaded.conversations.count, 1, phase)
            XCTAssertEqual(loaded.conversations.first?.messages.map(\.id), [clientMessageID], phase)
            let state = AppState(
                api: makeClient(transport: transport),
                messagePersistence: persistence,
                apiContextOverride: context
            )

            let restored = await state.recoverCachedDurableOutboxForTesting()
            XCTAssertTrue(restored, phase)
            XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().map(\.id), ["g1"], phase)
            try await waitForCondition(iterations: 120) {
                transport.isExhausted
                    || state.conversationStore.conversationMessageSnapshot(id: "g1")?.messages.contains(where: {
                        $0.id == clientMessageID && $0.status == .failed
                    }) == true
            }

            let requests = transport.requests()
            let paths = requests.compactMap(\.url?.path)
            XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/config" }.count, 1, phase)
            XCTAssertEqual(paths.filter { $0 == "/api/tenant/files/presign-upload" }.count, 0, phase)
            XCTAssertEqual(paths.filter { $0.contains("/api/tenant/files/") && $0.hasSuffix("/uploaded") }.count, 0, phase)
            XCTAssertEqual(paths.filter { $0 == "/api/im/messages" }.count, 1, phase)
            XCTAssertTrue(transport.uploads().isEmpty, phase)
            let sendBody = try requestJSONObject(try XCTUnwrap(requests.first { $0.url?.path == "/api/im/messages" }))
            XCTAssertEqual(sendBody["client_msg_no"] as? String, clientMessageID, phase)
            XCTAssertEqual((sendBody["payload"] as? [String: Any])?["file_id"] as? String, fileID, phase)
            XCTAssertNotNil(
                state.conversationStore.conversationMessageSnapshot(id: "g1")?.messages.first(where: {
                    $0.id == serverMessageID
                }),
                phase
            )
            XCTAssertTrue(transport.isExhausted, phase)
        }
    }

    func testSendStickerUsesMessageEndpointWithCompleteSnapshotPayload() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message":{"message_id":"m-sticker-1","channel_id":"g1","channel_type":"group","channel_seq":2,"from_uid":"uid-1","content_type":"sticker","payload":{"type":"sticker","sticker_id":"st-1","file_id":"file-1","fallback_text":"[GIF表情]"},"status":"sent","created_at":"2026-06-26T00:00:00Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let sticker = StickerMessageSnapshot(
            stickerID: "st-1",
            packID: "pack-1",
            fileID: "file-1",
            mimeType: "image/gif",
            width: 240,
            height: 180,
            durationMS: 900,
            frameCount: 12,
            thumbnailURL: "/assets/sticker-thumb.png",
            variants: [
                StickerMessageVariantSnapshot(
                    kind: "original",
                    fileID: "file-1",
                    mimeType: "image/gif",
                    assetURL: "/assets/sticker.gif",
                    sizeBytes: 12_345,
                    width: 240,
                    height: 180,
                    durationMS: 900,
                    frameCount: 12,
                    thumbnailURL: "/assets/sticker.gif",
                    cacheKey: "gif-v1"
                )
            ]
        )

        _ = try await client.sendSticker(
            context: makeContext(),
            conversation: makeGroupConversation(id: "g1"),
            channelID: "g1",
            sticker: sticker,
            quote: nil,
            clientMessageID: "local-sticker-1"
        )

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://im.example.test/api/im/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["content_type"] as? String, "sticker")
        XCTAssertEqual(body["client_msg_no"] as? String, "local-sticker-1")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "sticker")
        XCTAssertEqual(payload["sticker_id"] as? String, "st-1")
        XCTAssertEqual(payload["pack_id"] as? String, "pack-1")
        XCTAssertEqual(payload["file_id"] as? String, "file-1")
        XCTAssertEqual(payload["mime_type"] as? String, "image/gif")
        XCTAssertEqual(payload["width"] as? Int, 240)
        XCTAssertEqual(payload["height"] as? Int, 180)
        XCTAssertEqual(payload["duration_ms"] as? Int, 900)
        XCTAssertEqual(payload["frame_count"] as? Int, 12)
        XCTAssertEqual(payload["thumbnail_url"] as? String, "/assets/sticker-thumb.png")
        XCTAssertEqual(payload["fallback_text"] as? String, StickerMessageSnapshot.fallbackText)
        let variants = try XCTUnwrap(payload["variants"] as? [[String: Any]])
        XCTAssertEqual(variants.first?["kind"] as? String, "original")
        XCTAssertNil(variants.first?["url"])
        XCTAssertEqual(variants.first?["cache_key"] as? String, "gif-v1")
    }

    func testSendStickerOmitsExternalVariantURLFromMessagePayload() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message":{"message_id":"m-sticker-1","channel_id":"g1","channel_type":"group","channel_seq":2,"from_uid":"uid-1","content_type":"sticker","payload":{"type":"sticker","sticker_id":"st-1","file_id":"file-1","fallback_text":"[GIF表情]"},"status":"sent","created_at":"2026-06-26T00:00:00Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let sticker = StickerMessageSnapshot(
            stickerID: "st-1",
            fileID: "file-1",
            mimeType: "image/gif",
            thumbnailURL: "http://127.0.0.1:8082/api/tenant/dev-objects/thumb.gif",
            variants: [
                StickerMessageVariantSnapshot(
                    kind: "original",
                    fileID: "file-1",
                    mimeType: "image/gif",
                    assetURL: "http://127.0.0.1:8082/api/tenant/dev-objects/sticker.gif?signature=secret",
                    thumbnailURL: "http://127.0.0.1:8082/api/tenant/dev-objects/thumb.gif",
                    cacheKey: "gif-v1"
                )
            ]
        )

        _ = try await client.sendSticker(
            context: makeContext(),
            conversation: makeGroupConversation(id: "g1"),
            channelID: "g1",
            sticker: sticker,
            quote: nil,
            clientMessageID: "local-sticker-1"
        )

        let request = try XCTUnwrap(transport.requests().first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        let variants = try XCTUnwrap(payload["variants"] as? [[String: Any]])
        XCTAssertEqual(payload["file_id"] as? String, "file-1")
        XCTAssertNil(payload["url"])
        XCTAssertNil(payload["download_url"])
        XCTAssertNil(variants.first?["url"])
        XCTAssertNil(variants.first?["download_url"])
        XCTAssertEqual(variants.first?["file_id"] as? String, "file-1")
        XCTAssertEqual(variants.first?["cache_key"] as? String, "gif-v1")
    }

    func testHTTPTransportResultHeaderLookupNormalizesDuplicateCaseAndWhitespace() throws {
        let normalizedResult = HTTPTransportResult(
            data: Data(),
            isHTTPResponse: true,
            statusCode: 200,
            headers: [
                " Retry-After ": "12",
                "": "ignored"
            ]
        )

        XCTAssertEqual(normalizedResult.value(forHTTPHeaderField: "retry-after"), "12")
        XCTAssertEqual(normalizedResult.value(forHTTPHeaderField: "  RETRY-AFTER "), "12")
        XCTAssertNil(normalizedResult.value(forHTTPHeaderField: ""))

        let duplicateResult = HTTPTransportResult(
            data: Data(),
            isHTTPResponse: true,
            statusCode: 200,
            headers: [
                " Retry-After ": "12",
                "retry-after": "15"
            ]
        )

        let duplicateValue = try XCTUnwrap(duplicateResult.value(forHTTPHeaderField: "retry-after"))
        XCTAssertTrue(["12", "15"].contains(duplicateValue))
        XCTAssertEqual(duplicateResult.value(forHTTPHeaderField: "  RETRY-AFTER "), duplicateValue)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END


// WDT_IOS1_CORE_OUTGOING_FIXTURE_PERSISTENCE_20261111_BEGIN
extension HTTPTransportTests {
    func makeIsolatedOutgoingState(transport: HTTPTransport, context: IMAPIContext) -> AppState {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios1-core-outgoing-\(UUID().uuidString)", isDirectory: true)
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        // The original asynchronous producers may still own their stores after a case returns.
        return AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: persistence,
            apiContextOverride: context
        )
    }
}
// WDT_IOS1_CORE_OUTGOING_FIXTURE_PERSISTENCE_20261111_END
