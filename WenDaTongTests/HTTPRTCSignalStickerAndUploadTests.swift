import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func makeVideoCallEndingState(
        transport: FakeHTTPTransport,
        statusText: String,
        mediaState: RTCVoiceMediaState,
        connectedAt: Date?
    ) -> AppState {
        let state = makeIsolatedAuthenticatedHTTPState( // WDT_IOS1_CORE23_ISOLATED_AUTH_FIXTURE_20261111
            transport: transport, context: makeContext(), videoMediaClient: NoopVideoMediaClient()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "local-ending-1",
            callID: "call-ending-1",
            roomID: "room-ending-1",
            rtcToken: "rtc-token",
            peer: IMUser(
                id: "peer-ending-1",
                name: "视频接听方",
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "online",
                enterprise: "",
                avatarSeed: 0x3366FF,
                badges: []
            ),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: statusText,
            mediaState: mediaState,
            isMuted: false,
            speakerOn: true,
            connectedAt: connectedAt,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: false
        )
        return state
    }

    func makeRTCPeerWaitFixture(
        transport: FakeHTTPTransport,
        videoMediaClient: any VideoMediaClient = NoopVideoMediaClient()
    ) -> (state: AppState, call: RemoteRTCCall, joinedRoom: RemoteRTCRoomJoinData) {
        let state = AppState(
            api: makeClient(transport: transport),
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeContext()
        )
        let peer = makeUser(id: "uid-2", name: "Peer")
        let call = RemoteRTCCall(
            id: "call-peer-wait",
            status: "accepted",
            roomID: "room-peer-wait",
            rtcToken: "rtc-token-peer-wait",
            callerUID: "uid-1",
            calleeUID: "uid-2",
            channelType: "direct",
            callType: "video",
            requestedMediaMode: "video",
            mediaMode: "video",
            acceptedDevice: RemoteRTCDevice(
                uid: "uid-2",
                deviceID: "peer-joined-device",
                deviceType: "android"
            )
        )
        let selfParticipant = RemoteRTCRoomParticipant(
            uid: "uid-1",
            deviceID: "device-1",
            deviceType: "ios",
            role: "caller"
        )
        let joinedRoom = RemoteRTCRoomJoinData(
            roomID: call.roomID,
            rtcToken: call.rtcToken,
            selfParticipant: selfParticipant,
            participants: [selfParticipant]
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.activeVoiceCall = VoiceCallSession(
            id: "local-peer-wait",
            callID: call.id,
            roomID: call.roomID,
            rtcToken: call.rtcToken,
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true
        )
        return (state, call, joinedRoom)
    }

    func rtcParticipantsResponse(
        _ participants: [RemoteRTCRoomParticipant]
    ) -> HTTPTransportResult {
        let data = (try? JSONEncoder().encode(["items": participants]))
            .flatMap { itemsData -> Data? in
                guard let itemsObject = try? JSONSerialization.jsonObject(with: itemsData),
                      let envelope = try? JSONSerialization.data(
                        withJSONObject: ["ok": true, "data": itemsObject]
                      ) else {
                    return nil
                }
                return envelope
            }
            ?? Data(#"{"ok":true,"data":{"items":[]}}"#.utf8)
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
    }

    func successfulEmptyResponse() -> HTTPTransportResult {
        HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
    }

    func testPostRTCSignalKeepsBackendCodeAndMessageOnFailure() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"rtc_participant_not_found","message":"信令接收方未加入当前房间"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 404,
                headers: ["X-Request-ID": "req-signal-2"]
            )
        ])
        let client = makeClient(transport: transport)
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "peer-uid",
            toDevice: "peer-device",
            kind: .offer,
            data: ["type": .string("offer")]
        )

        do {
            try await client.postRTCSignal(
                context: makeContext(),
                roomID: "room-1",
                rtcToken: "rtc-token-1",
                envelope: envelope
            )
            XCTFail("Expected signal post to fail")
        } catch IMAPIError.server(let message) {
            XCTAssertEqual(message, "信令接收方未加入当前房间")
        }
    }

    func testRTCSignalV2AndIceRefreshUseSuppliedReboundTokenAndFrozenPaths() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"message_id":"message-1","server_cursor":"cursor-1"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[],"next_cursor":"cursor-2","has_more":false}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(
                    """
                    {"ok":true,"data":{
                      "ice_servers":[{"urls":["turn:relay.example.test"]}],
                      "rtc_token":"token-generation-3",
                      "ice_credential_expires_at":"2026-07-25T12:40:00Z",
                      "ice_credential_refresh_after":"2026-07-25T12:28:00Z"
                    }}
                    """.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)
        let context = makeContext()
        let envelope = RemoteRTCSignalEnvelope(
            protocolVersion: "video-call-v1",
            messageID: "message-1",
            seq: 1,
            negotiationID: "negotiation-1",
            callID: "call-1",
            toUID: "peer",
            toDevice: "peer-device",
            kind: .candidate
        )

        _ = try await client.postRTCSignalV2(
            context: context,
            roomID: "room-1",
            rtcToken: "token-generation-1",
            envelope: envelope
        )
        _ = try await client.pollRTCSignalsV2(
            context: context,
            roomID: "room-1",
            rtcToken: "token-generation-2",
            cursor: "cursor-1",
            limit: 100,
            waitMS: 25_000
        )
        try await client.ackRTCSignals(
            context: context,
            roomID: "room-1",
            rtcToken: "token-generation-2",
            cursor: "cursor-2"
        )
        let refreshed = try await client.refreshRTCIceCredentials(
            context: context,
            roomID: "room-1",
            rtcToken: "token-generation-2"
        )

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-generation-1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token-generation-2")
        XCTAssertEqual(requests[1].timeoutInterval, 30)
        XCTAssertEqual(
            URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "wait_ms" })?
                .value,
            "25000"
        )
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer token-generation-2")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer token-generation-2")
        XCTAssertEqual(requests[3].url?.path, "/api/rtc/rooms/room-1/ice-credentials")
        XCTAssertEqual(requests[3].httpMethod, "POST")
        XCTAssertEqual(requests[3].cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(requests[3].timeoutInterval, 3)
        let refreshBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[3].httpBody)) as? [String: Any]
        )
        XCTAssertTrue(refreshBody.isEmpty)
        XCTAssertEqual(refreshed.rtcToken, "token-generation-3")
    }

    func testRTCMediaStateUpdateUsesFrozenPathStrictBodyAndPreservesLeaseConflict() async throws {
        let successTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(
                    """
                    {"ok":true,"data":{"call":{
                      "id":"call-heartbeat",
                      "status":"accepted",
                      "state_version":9
                    }}}
                    """.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: successTransport)
        let updated = try await client.updateRTCMediaState(
            context: makeContext(),
            callID: "call-heartbeat",
            mediaState: " Reconnecting ",
            expectedStateVersion: 8,
            idempotencyKey: "heartbeat-idempotency"
        )

        let request = try XCTUnwrap(successTransport.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/rtc/calls/call-heartbeat/media-state")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(body.keys), Set(["idempotency_key", "media_state", "expected_state_version"]))
        XCTAssertEqual(body["idempotency_key"] as? String, "heartbeat-idempotency")
        XCTAssertEqual(body["media_state"] as? String, "reconnecting")
        XCTAssertEqual(body["expected_state_version"] as? Int, 8)
        XCTAssertEqual(updated.id, "call-heartbeat")
        XCTAssertEqual(updated.stateVersion, 9)

        let conflictTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(
                    #"{"ok":false,"error":{"code":"rtc_participant_lease_expired","message":"participant lease expired"}}"#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 409
            )
        ])
        do {
            _ = try await makeClient(transport: conflictTransport).updateRTCMediaState(
                context: makeContext(),
                callID: "call-heartbeat",
                mediaState: "connected",
                expectedStateVersion: nil,
                idempotencyKey: "heartbeat-conflict"
            )
            XCTFail("Expected participant lease conflict")
        } catch let error as RTCVideoSignalHTTPError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "rtc_participant_lease_expired")
            XCTAssertTrue(RTCMediaStateHeartbeatFailurePolicy.needsParticipantRejoin(error))
        }
    }

    func testRTCSignalV2PreservesExactTerminalHTTPPairsWithoutClassifyingOtherFailures() async throws {
        func postFailure(statusCode: Int, code: String) async -> Error? {
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data(
                        #"{"ok":false,"error":{"code":"\#(code)","message":"signal failed"}}"#.utf8
                    ),
                    isHTTPResponse: true,
                    statusCode: statusCode
                )
            ])
            let client = makeClient(transport: transport)
            do {
                _ = try await client.postRTCSignalV2(
                    context: makeContext(),
                    roomID: "room-terminal",
                    rtcToken: "rtc-token-terminal",
                    envelope: RemoteRTCSignalEnvelope(
                        messageID: "message-terminal",
                        callID: "call-terminal",
                        toUID: "peer",
                        toDevice: "peer-device",
                        kind: .candidate
                    )
                )
                return nil
            } catch {
                return error
            }
        }

        let inactiveResult = await postFailure(statusCode: 409, code: "rtc_call_not_active")
        let inactive = try XCTUnwrap(inactiveResult)
        let inactiveHTTPError = try XCTUnwrap(inactive as? RTCVideoSignalHTTPError)
        XCTAssertEqual(inactiveHTTPError.statusCode, 409)
        XCTAssertEqual(inactiveHTTPError.code, "rtc_call_not_active")
        XCTAssertFalse(inactiveHTTPError.message.isEmpty)
        XCTAssertTrue(RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(inactive))

        let missingResult = await postFailure(statusCode: 404, code: "rtc_call_not_found")
        let missing = try XCTUnwrap(missingResult)
        XCTAssertTrue(RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(missing))

        let genericConflictResult = await postFailure(statusCode: 409, code: "duplicate_signal")
        let genericConflict = try XCTUnwrap(genericConflictResult)
        XCTAssertFalse(RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(genericConflict))

        let genericNotFoundResult = await postFailure(statusCode: 404, code: "route_not_found")
        let genericNotFound = try XCTUnwrap(genericNotFoundResult)
        XCTAssertFalse(RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(genericNotFound))

        let invalidMediaStateResult = await postFailure(
            statusCode: 422,
            code: "rtc_signal_payload_invalid"
        )
        let invalidMediaState = try XCTUnwrap(invalidMediaStateResult)
        let invalidMediaStateHTTPError = try XCTUnwrap(
            invalidMediaState as? RTCVideoSignalHTTPError
        )
        XCTAssertEqual(invalidMediaStateHTTPError.statusCode, 422)
        XCTAssertEqual(invalidMediaStateHTTPError.code, "rtc_signal_payload_invalid")
        XCTAssertTrue(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .mediaState,
                after: invalidMediaStateHTTPError
            )
        )
        XCTAssertFalse(
            RTCVideoSignalFailurePolicy.shouldDropBestEffort(
                kind: .answer,
                after: invalidMediaStateHTTPError
            )
        )

        let unavailableResult = await postFailure(statusCode: 503, code: "provider_unavailable")
        let unavailable = try XCTUnwrap(unavailableResult)
        XCTAssertFalse(RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(unavailable))
    }

    func testHTTPTransportUploadUsesInjectedTransportAndPreservesRequest() async throws {
        let transport = FakeHTTPTransport(
            results: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 200)],
            uploadResults: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)]
        )
        let client = makeClient(transport: transport)
        let upload = try makeUpload(
            url: "https://upload.example.test/object",
            method: "POST",
            headers: [
                "X-Signature": "sig-1",
                "X-Upload-Token": "token-1"
            ]
        )
        let body = Data("binary-avatar".utf8)

        try await client.uploadAvatarBinary(upload: upload, data: body, mimeType: "image/png")

        XCTAssertTrue(transport.requests().isEmpty)
        let captured = try XCTUnwrap(transport.uploads().first)
        XCTAssertEqual(captured.request.url?.absoluteString, "https://upload.example.test/object")
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.timeoutInterval, 20)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "X-Signature"), "sig-1")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "X-Upload-Token"), "token-1")
        XCTAssertEqual(captured.body, body)
    }

    func testHTTPTransportUploadFailureUsesInjectedTransportStatusAndBody() async throws {
        let transport = FakeHTTPTransport(
            results: [HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 200)],
            uploadResults: [
                HTTPTransportResult(
                    data: Data("storage down".utf8),
                    isHTTPResponse: true,
                    statusCode: 503
                )
            ]
        )
        let client = makeClient(transport: transport)
        let upload = try makeUpload(url: "https://upload.example.test/object", method: "PUT", headers: [:])

        let diagnostic = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
        do {
            try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
                try await client.uploadAvatarBinary(upload: upload, data: Data("avatar".utf8), mimeType: "image/jpeg")
            }
            XCTFail("Expected upload failure")
        } catch IMAPIError.server(let message) {
            XCTAssertTrue(message.contains("头像图片上传失败"))
            XCTAssertTrue(message.contains("HTTP 503"))
            XCTAssertFalse(message.contains("storage down"))
            let failure = try XCTUnwrap(diagnostic.uploadFailure)
            XCTAssertEqual(failure.code, .http)
            XCTAssertEqual(failure.httpStatus, 503)
            XCTAssertTrue(failure.detail.contains("HTTP 503"))
            XCTAssertFalse(failure.detail.contains("storage down"))
        }

        XCTAssertEqual(transport.uploads().count, 1)
    }

	func testAvatarUploadStructuredResultKeepsEachAttemptStageAndRedactsTransportDetails() async throws {
		let presignSuccess = HTTPTransportResult(
			data: Data(#"{"ok":true,"data":{"file":{"id":"file-1"},"upload":{"url":"https://upload.example.test/object?signature=do-not-return","method":"PUT","headers":{"X-Upload-Token":"do-not-return"}}}}"#.utf8),
			isHTTPResponse: true,
			statusCode: 200
		)
		let presignFailure = HTTPTransportResult(
			data: Data(#"{"ok":false,"error":{"code":"avatar_presign_rejected","message":"internal object key and token must stay hidden"}}"#.utf8),
			isHTTPResponse: true,
			statusCode: 422
		)
		let putFailure = HTTPTransportResult(
			data: Data("private storage response with query and token".utf8),
			isHTTPResponse: true,
			statusCode: 503
		)
		let commitFailure = HTTPTransportResult(
			data: Data(#"{"ok":false,"error":{"code":"avatar_commit_conflict","message":"internal key must stay hidden"}}"#.utf8),
			isHTTPResponse: true,
			statusCode: 409
		)
		let putSuccess = HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204)
		let transport = FakeHTTPTransport(
			results: [presignSuccess, presignFailure, presignSuccess, commitFailure],
			uploadResults: [putFailure, putSuccess]
		)
		let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
		let originalAvatarURL = state.currentUser.avatarURL
		let originalAvatarVersion = state.currentUser.avatarVersion

		let first = await state.uploadCurrentUserAvatarResult(
			imageData: Data("avatar-one".utf8), mimeType: "image/jpeg", width: 64, height: 64
		)
		let second = await state.uploadCurrentUserAvatarResult(
			imageData: Data("avatar-two".utf8), mimeType: "image/jpeg", width: 64, height: 64
		)
		let third = await state.uploadCurrentUserAvatarResult(
			imageData: Data("avatar-three".utf8), mimeType: "image/jpeg", width: 64, height: 64
		)

		XCTAssertEqual(first, .failed(.put, safeCode: "server_error", status: 503))
		XCTAssertEqual(second, .failed(.presign, safeCode: "http_status", status: 422))
		XCTAssertEqual(third, .failed(.commit, safeCode: "avatar_commit_conflict"))
		XCTAssertEqual(state.currentUser.avatarURL, originalAvatarURL)
		XCTAssertEqual(state.currentUser.avatarVersion, originalAvatarVersion)
		let exposed = String(reflecting: [first, second, third]).lowercased()
		XCTAssertFalse(exposed.contains("upload.example"))
		XCTAssertFalse(exposed.contains("signature="))
		XCTAssertFalse(exposed.contains("do-not-return"))
		XCTAssertFalse(exposed.contains("object key"))
	}

    @MainActor
    func testAvatarCommitWinsOverCachedOldRealtimeProjectionAndPropagatesExactCommitValues() async throws {
        let context = makeContext()
        let policyResponse = HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: [
            "ok": true, "data": ["app_id": IMAPIContext.normalizedIOSAppID(context.appID),
                                   "platform": "ios", "status": "active", "cache_ttl_seconds": 60]
        ]), isHTTPResponse: true, statusCode: 200)
        let presign = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"file":{"id":"file-new"},"upload":{"url":"https://upload.example.test/new","method":"PUT","headers":{}}}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let commit = HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"profile":{"avatar":"/api/tenant/avatar/new","avatar_version":"commit-v2","avatar_updated_at":"2026-08-24T00:00:00Z"},"avatar_url":"/api/tenant/avatar/new","avatar_version":"commit-v2","avatar_updated_at":"2026-08-24T00:00:00Z"}}"#.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [policyResponse, presign, commit])
        let state = AppState(
            api: makeClient(transport: transport),
            apiContextOverride: context
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        let resolved = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(resolved)
        XCTAssertTrue(state.currentAppPolicy?.isUsable == true)
        XCTAssertTrue(state.hasResolvedCurrentAppPolicyForAuthUI)
        state.setCurrentUser(makeUser(id: "uid-1", name: "Current User")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [makeUser(id: "uid-1", name: "Current User")]
        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "notification",
                requestID: nil,
                payload: [
                    "event": .string("avatar_updated"),
                    "event_id": .string("evt-old"),
                    "event_type": .string("identity.summary.updated"),
                    "tenant_id": .string("tenant-1"),
                    "subject_type": .string("user"),
                    "subject_id": .string("uid-1"),
                    "revision": .int(7),
                    "generation_family": .string("identity"),
                    "generation": .int(9),
                    "changed": .array([.string("avatar")]),
                    "occurred_at": .string("2026-08-23T23:59:00Z"),
                    "uid": .string("uid-1"),
                    "url": .string("/api/tenant/avatar/old"),
                    "version": .int(7),
                    "updated_at": .string("2026-08-23T23:59:00Z")
                ]
            )
        )
        XCTAssertTrue(state.currentUser.avatarURL.contains("/old"))

        let result = await state.uploadCurrentUserAvatarResult(
            imageData: Data("new-avatar".utf8),
            mimeType: "image/jpeg",
            width: 64,
            height: 64
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertTrue(state.currentUser.avatarURL.contains("/api/tenant/avatar/new"))
        XCTAssertEqual(state.currentUser.avatarVersion, "commit-v2")
        XCTAssertEqual(state.currentUser.avatarUpdatedAt, "2026-08-24T00:00:00Z")
        XCTAssertTrue(state.contacts.first?.avatarURL.contains("/api/tenant/avatar/new") == true)
        XCTAssertEqual(state.contacts.first?.avatarVersion, "commit-v2")
        XCTAssertEqual(state.contacts.first?.avatarUpdatedAt, "2026-08-24T00:00:00Z")
        for (label, url) in [("Core61-Avatar-actual-App", Bundle.main.executableURL),
                             ("Core61-Avatar-actual-XCTest", Bundle(for: HTTPTransportTests.self).executableURL)] {
            let executable = try XCTUnwrap(url)
            let attachment = XCTAttachment(contentsOfFile: executable)
            attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testIMAPIClientUserStickerEndpointsUseTenantIMBearerAndFrozenBodies() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"us-1","sticker_id":"st-1","file_id":"file-1","status":"active","processing_status":"active","sort":1,"created_at":"2026-06-26T01:00:00Z","updated_at":"2026-06-26T01:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"us-2","sticker_id":"st-2","file_id":"file-2","status":"active","processing_status":"active","sort":1,"created_at":"2026-06-26T01:01:00Z","updated_at":"2026-06-26T01:01:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"sticker":{"id":"st-3","file_id":"file-3","status":"queued","processing_status":"queued","sort":3,"created_at":"2026-06-26T01:02:00Z"},"task":{"id":"task-3","sticker_id":"st-3","file_id":"file-3","status":"queued","created_at":"2026-06-26T01:02:00Z","updated_at":"2026-06-26T01:02:00Z"}}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 202
            )
        ])
        let client = makeClient(transport: transport)
        let context = makeContext()

        let list = try await client.listUserStickers(context: context, status: " active ", since: "2026-06-26T00:00:00Z", limit: 500)
        let ordered = try await client.orderUserStickers(context: context, ids: [" us-2 ", "us-1", " "])
        let commit = try await client.commitUserSticker(context: context, fileID: " file-3 ", name: " hello.gif ", packID: nil)

        XCTAssertEqual(list.first?.id, "us-1")
        XCTAssertEqual(ordered.first?.id, "us-2")
        XCTAssertEqual(commit.sticker.id, "st-3")
        let requests = transport.requests()
        XCTAssertEqual(requests[0].url?.scheme, "https")
        XCTAssertEqual(requests[0].url?.host, "tenant.example.test")
        XCTAssertEqual(requests[0].url?.path, "/api/tenant/user-stickers")
        let listQueryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems)
        let listQuery = Dictionary(uniqueKeysWithValues: listQueryItems.map { ($0.name, $0.value) })
        XCTAssertEqual(listQuery["status"] ?? nil, "active")
        XCTAssertEqual(listQuery["since"] ?? nil, "2026-06-26T00:00:00Z")
        XCTAssertEqual(listQuery["limit"] ?? nil, "200")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/user-stickers/order")
        XCTAssertEqual(requests[1].httpMethod, "PATCH")
        let orderBodyData = try XCTUnwrap(requests[1].httpBody)
        let orderBody = try XCTUnwrap(JSONSerialization.jsonObject(with: orderBodyData) as? [String: Any])
        XCTAssertEqual(orderBody["ids"] as? [String], ["us-2", "us-1"])
        XCTAssertEqual(requests[2].url?.absoluteString, "https://tenant.example.test/api/tenant/user-stickers/commit")
        XCTAssertEqual(requests[2].httpMethod, "POST")
        let commitBodyData = try XCTUnwrap(requests[2].httpBody)
        let commitBody = try XCTUnwrap(JSONSerialization.jsonObject(with: commitBodyData) as? [String: Any])
        XCTAssertEqual(commitBody["file_id"] as? String, "file-3")
        XCTAssertEqual(commitBody["name"] as? String, "hello.gif")
        XCTAssertNil(commitBody["pack_id"])
    }

    func testIMAPIClientOfficialStickerPackEndpointsUseClientTenantRoutes() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"pack-1","name":"官方包","cover_url":"/cover.png","sort":1,"status":"online","created_at":"2026-06-26T01:00:00Z","updated_at":"2026-06-26T01:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"id":"st-1","pack_id":"pack-1","image_url":"/sticker.gif","file_id":"file-1","status":"active","processing_status":"active","sort":1,"created_at":"2026-06-26T01:00:00Z"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let packs = try await client.listStickerPacks(context: makeContext())
        let stickers = try await client.listStickerPackStickers(context: makeContext(), packID: "pack-1")

        XCTAssertEqual(packs.first?.id, "pack-1")
        XCTAssertEqual(stickers.first?.id, "st-1")
        let requests = transport.requests()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://tenant.example.test/api/tenant/sticker-packs")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/sticker-packs/pack-1/stickers")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer im-token")
    }

    func testDisabledPhoneAuthPolicyHidesEntriesAndNormalizesPhoneScreens() async throws {
        clearStoredAPIContext()
        IMAppPolicyLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppPolicyLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":true,"phone_auth_enabled":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let context = makePreloginContext()
        let scope = RememberedLoginCredentialScope(context: context)
        let credentialStore = RecordingRememberedLoginCredentialStore()
        let preferenceStore = RecordingRememberedLoginPreferenceStore()
        XCTAssertTrue(
            credentialStore.save(
                RememberedLoginCredentials(
                    mode: .phone,
                    identifier: "13800000000",
                    password: "SyntheticPass123!"
                ),
                scope: scope
            )
        )
        let state = AppState(
            api: makeClient(transport: transport),
            rememberedLoginCredentialStore: credentialStore,
            rememberedLoginPreferenceStore: preferenceStore,
            apiContextOverride: context
        )

        XCTAssertFalse(state.isPhoneAuthEnabledForAuthUI)
        XCTAssertNotNil(credentialStore.load(scope: scope))
        let loaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(loaded)
        XCTAssertFalse(state.isPhoneAuthEnabledForAuthUI)
        XCTAssertNil(credentialStore.load(scope: scope))
        XCTAssertTrue(state.rememberLoginCredentialsEnabledForAuthUI)
        state.setAuthScreen(.phoneLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        XCTAssertEqual(state.authScreen, .accountLogin)
        state.setAuthScreen(.phoneRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        XCTAssertEqual(state.authScreen, .accountRegister)
        state.setAuthScreen(.forgotPassword) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        XCTAssertEqual(state.authScreen, .forgotPassword)
    }
}
