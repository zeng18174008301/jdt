import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testRTC503EnvelopesPreserveStableCodesForVoiceVideoCreateAndAccept() async throws {
        func failure(_ code: String) -> HTTPTransportResult {
            HTTPTransportResult(
                data: Data("{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"redacted\"}}".utf8),
                isHTTPResponse: true,
                statusCode: 503
            )
        }
        let transport = FakeHTTPTransport(results: [
            failure("rtc_license_capabilities_unavailable"),
            failure("rtc_license_capabilities_unavailable"),
            failure("rtc_ice_config_missing"),
            failure("rtc_turn_config_missing"),
        ])
        let client = makeClient(transport: transport)
        let context = makeContext()
        let videoCapabilities = RTCDeviceCapabilities(audio: true, video: true, cameraAvailable: true)

        func assertStable(_ error: Error, code expectedCode: String, media: RTCCapabilityMedia, message: String) {
            guard let apiError = error as? IMAPIError,
                  case .conflict(let code, _) = apiError else {
                return XCTFail("Expected stable RTC conflict, got \(error)")
            }
            XCTAssertEqual(code, expectedCode)
            XCTAssertEqual(rtcCapabilityFailureMessage(code: code, media: media), message)
        }

        do {
            _ = try await client.createRTCCall(
                context: context,
                calleeUID: "peer-voice",
                callType: "audio",
                channelID: "direct-voice"
            )
            XCTFail("Expected voice create to fail")
        } catch {
            assertStable(
                error,
                code: "rtc_license_capabilities_unavailable",
                media: .voice,
                message: "暂时无法确认语音通话权限，请稍后重试"
            )
        }

        do {
            _ = try await client.createRTCVideoCall(
                context: context,
                calleeUID: "peer-video",
                channelID: "direct-video",
                capabilities: videoCapabilities
            )
            XCTFail("Expected video create to fail")
        } catch {
            assertStable(
                error,
                code: "rtc_license_capabilities_unavailable",
                media: .video,
                message: "暂时无法确认视频通话权限，请稍后重试"
            )
        }

        do {
            _ = try await client.acceptRTCCall(context: context, callID: "voice-call")
            XCTFail("Expected voice accept to fail")
        } catch {
            assertStable(
                error,
                code: "rtc_ice_config_missing",
                media: .voice,
                message: "语音通话媒体服务配置缺失，请联系管理员"
            )
        }

        do {
            _ = try await client.acceptRTCCall(
                context: context,
                callID: "video-call",
                mode: "video",
                capabilities: videoCapabilities
            )
            XCTFail("Expected video accept to fail")
        } catch {
            assertStable(
                error,
                code: "rtc_turn_config_missing",
                media: .video,
                message: "视频通话媒体服务配置缺失，请联系管理员"
            )
        }
    }

    func testRTCVideoCreateHTTP201WithOmittedCapabilityVersionRemainsSuccessfulRinging() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"call":{"call_id":"video-created-201","status":"ringing","call_type":"video","requested_media_mode":"video","caller_capabilities":{"video":true}},"rtc_token":"video-token"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.createRTCVideoCall(
            context: makeContext(),
            calleeUID: "peer-video",
            channelID: "direct-video",
            capabilities: RTCDeviceCapabilities(audio: true, video: true, cameraAvailable: true)
        )

        XCTAssertEqual(result.call.id, "video-created-201")
        XCTAssertEqual(result.call.status, "ringing")
        XCTAssertEqual(result.call.callerCapabilities?.version, "")
        XCTAssertEqual(result.call.callerCapabilities?.video, true)
        XCTAssertEqual(result.call.callerCapabilities?.audio, false)
        XCTAssertEqual(result.rtcToken, "video-token")
    }

    func testEndingOutgoingRingingCallUsesCancelOnceAndWaitsForServerSuccess() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = makeVideoCallEndingState(
            transport: transport,
            statusText: "等待对方接听",
            mediaState: .preparing,
            connectedAt: nil
        )

        recordCallsAcceptanceDiagnostic(self, state: state, stage: "ending-cancel-entry", counts: ["total": transport.requests().count])
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "ending-cancel-exit", counts: ["total": transport.requests().count]) }
        state.endActiveVoiceCall()
        state.endActiveVoiceCall()

        XCTAssertTrue(state.isEndingActiveCall)
        try await waitForCondition { state.activeVoiceCall == nil }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.activeCallEndError)
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/rtc/calls/call-ending-1/cancel")
    }

    func testEndingAcceptedConnectingCallUsesHangup() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = makeVideoCallEndingState(
            transport: transport,
            statusText: "连接中",
            mediaState: .connecting,
            connectedAt: nil
        )

        state.endActiveVoiceCall()
        try await waitForCondition { state.activeVoiceCall == nil }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/calls/call-ending-1/hangup")
    }

    func testEndingCallFailureKeepsCallVisibleAndAllowsRetry() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"code":"rtc_state_conflict","message":"状态已变化"}"#.utf8),
                isHTTPResponse: true,
                statusCode: 409
            ),
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = makeVideoCallEndingState(
            transport: transport,
            statusText: "等待对方接听",
            mediaState: .preparing,
            connectedAt: nil
        )

        recordCallsAcceptanceDiagnostic(self, state: state, stage: "ending-retry-entry", counts: ["total": transport.requests().count])
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "ending-retry-exit", counts: ["total": transport.requests().count]) }
        state.endActiveVoiceCall()
        try await waitForCondition {
            !state.isEndingActiveCall && state.activeCallEndError != nil
        }

        XCTAssertNotNil(state.activeVoiceCall)
        XCTAssertEqual(state.activeCallEndError, "未能结束通话，请检查网络后重试")
        XCTAssertEqual(transport.requests().count, 1)

        state.endActiveVoiceCall()
        try await waitForCondition { state.activeVoiceCall == nil }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requests().count, 2)
    }

    func testCallerAcceptedEventWithoutRTCTokenPreservesCreateStageToken() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(
                    #"""
                    {
                      "ok": true,
                      "data": {
                        "room_id": "room-accepted-token",
                        "rtc_token": "create-stage-token",
                        "media": {"ice_servers": []},
                        "self_participant": {
                          "uid": "uid-1",
                          "device_id": "device-1",
                          "device_type": "ios",
                          "role": "caller"
                        },
                        "peer_participant": {
                          "uid": "uid-2",
                          "device_id": "web-loser-device",
                          "device_type": "web",
                          "role": "callee"
                        },
                        "participants": [
                          {
                            "uid": "uid-1",
                            "device_id": "device-1",
                            "device_type": "ios",
                            "role": "caller"
                          },
                          {
                            "uid": "uid-2",
                            "device_id": "web-loser-device",
                            "device_type": "web",
                            "role": "callee"
                          },
                          {
                            "uid": "uid-2",
                            "device_id": "web-winner-device",
                            "device_type": "web",
                            "role": "callee"
                          }
                        ]
                      }
                    }
                    """#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let preparation = CallsAcceptancePhasedHTTPTransport.providerPreparation()
        let phasedTransport = CallsAcceptancePhasedHTTPTransport(preparation: preparation, operation: transport)
        let api = makeClient(transport: phasedTransport)
        let videoMediaClient = PeerWaitVideoMediaClient()
        let state = AppState(
            api: api,
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Caller")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.activeVoiceCall = VoiceCallSession(
            id: "local-accepted-token",
            callID: "call-accepted-token",
            roomID: "room-accepted-token",
            rtcToken: "create-stage-token",
            peer: makeUser(id: "uid-2", name: "Callee"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方接听",
            mediaState: .preparing,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true
        )

        _ = try await api.rtcProvider(context: state.apiContext)
        XCTAssertEqual(preparation.requests().map(\.url?.path), ["/api/rtc/provider"])
        phasedTransport.beginOperation()
        state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(
            type: "rtc.call.accepted",
            requestID: "accepted-without-token",
            payload: [
                "call_id": .string("call-accepted-token"),
                "room_id": .string("room-accepted-token"),
                "caller_uid": .string("uid-1"),
                "callee_uid": .string("uid-2"),
                "call": .object([
                    "id": .string("call-accepted-token"),
                    "room_id": .string("room-accepted-token"),
                    "status": .string("accepted"),
                    "caller_uid": .string("uid-1"),
                    "callee_uid": .string("uid-2"),
                    "call_type": .string("video"),
                    "requested_media_mode": .string("video"),
                    "media_mode": .string("video"),
                    "caller_device": .object([
                        "uid": .string("uid-1"),
                        "device_id": .string("device-1"),
                        "device_type": .string("ios")
                    ]),
                    "accepted_device": .object([
                        "uid": .string("uid-2"),
                        "device_id": .string("web-winner-device"),
                        "device_type": .string("web")
                    ])
                ])
            ]
        ))

        try await waitForCondition {
            transport.requests().count == 1
                && videoMediaClient.startContexts.count == 1
        }

        let joinRequest = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(joinRequest.httpMethod, "POST")
        XCTAssertEqual(joinRequest.url?.path, "/api/rtc/rooms/room-accepted-token/join")
        XCTAssertEqual(
            joinRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer create-stage-token"
        )
        let joinBodyData = try XCTUnwrap(joinRequest.httpBody)
        let joinBody = try XCTUnwrap(JSONSerialization.jsonObject(with: joinBodyData) as? [String: Any])
        XCTAssertEqual(joinBody["rtc_token"] as? String, "create-stage-token")

        let mediaContext = try XCTUnwrap(videoMediaClient.startContexts.first)
        XCTAssertEqual(mediaContext.roomID, "room-accepted-token")
        XCTAssertEqual(mediaContext.rtcToken, "create-stage-token")
        XCTAssertTrue(mediaContext.isCaller)
        XCTAssertEqual(mediaContext.peerUID, "uid-2")
        XCTAssertEqual(mediaContext.peerDeviceID, "web-winner-device")
        XCTAssertNotEqual(mediaContext.peerDeviceID, mediaContext.localDeviceID)
        XCTAssertEqual(state.activeVoiceCall?.rtcToken, "create-stage-token")
        XCTAssertNotEqual(state.activeVoiceCall?.statusText, "通话连接失败")
    }

    func testAcceptedCallReconcilePreservesAuthoritativeWinningDeviceForVideoStart() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(
                    #"""
                    {
                      "ok": true,
                      "data": {
                        "room_id": "room-reconcile-winner",
                        "rtc_token": "token-reconcile-winner",
                        "media": {"ice_servers": []},
                        "self_participant": {
                          "uid": "uid-1",
                          "device_id": "device-1",
                          "device_type": "ios",
                          "role": "caller"
                        },
                        "peer_participant": {
                          "uid": "uid-2",
                          "device_id": "web-loser-device",
                          "device_type": "web",
                          "role": "callee"
                        },
                        "participants": [
                          {"uid":"uid-1","device_id":"device-1","device_type":"ios","role":"caller"},
                          {"uid":"uid-2","device_id":"web-loser-device","device_type":"web","role":"callee"},
                          {"uid":"uid-2","device_id":"web-winner-device","device_type":"web","role":"callee"}
                        ]
                      }
                    }
                    """#.utf8
                ),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let preparation = CallsAcceptancePhasedHTTPTransport.providerPreparation()
        let phasedTransport = CallsAcceptancePhasedHTTPTransport(preparation: preparation, operation: transport)
        let api = makeClient(transport: phasedTransport)
        let videoMediaClient = PeerWaitVideoMediaClient()
        let state = AppState(
            api: api,
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Caller")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.activeVoiceCall = VoiceCallSession(
            id: "local-reconcile-winner",
            callID: "call-reconcile-winner",
            roomID: "room-reconcile-winner",
            rtcToken: "token-reconcile-winner",
            peer: makeUser(id: "uid-2", name: "Web callee"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方接听",
            mediaState: .preparing,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true
        )
        let remoteCall = RemoteRTCCall(
            id: "call-reconcile-winner",
            status: "accepted",
            roomID: "room-reconcile-winner",
            rtcToken: "token-reconcile-winner",
            callerUID: "uid-1",
            calleeUID: "uid-2",
            callType: "video",
            requestedMediaMode: "video",
            mediaMode: "video",
            callerDevice: RemoteRTCDevice(uid: "uid-1", deviceID: "device-1", deviceType: "ios"),
            calleeDevice: RemoteRTCDevice(uid: "uid-2", deviceID: "web-winner-device", deviceType: "web"),
            acceptedDevice: RemoteRTCDevice(uid: "uid-2", deviceID: "web-winner-device", deviceType: "web")
        )

        _ = try await api.rtcProvider(context: state.apiContext)
        XCTAssertEqual(preparation.requests().map(\.url?.path), ["/api/rtc/provider"])
        phasedTransport.beginOperation()
        state.reconcileRTCCallsForTesting([remoteCall])

        try await waitForCondition {
            transport.requests().count == 1
                && videoMediaClient.startContexts.count == 1
        }
        let context = try XCTUnwrap(videoMediaClient.startContexts.first)
        XCTAssertTrue(context.isCaller)
        XCTAssertEqual(context.peerUID, "uid-2")
        XCTAssertEqual(context.peerDeviceID, "web-winner-device")
        XCTAssertNotEqual(context.peerDeviceID, context.localDeviceID)
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/rooms/room-reconcile-winner/join")
    }

    func testRTCPeerParticipantWaitIgnoresAcceptedDeviceUntilJoinedParticipantAppears() async throws {
        let transport = FakeHTTPTransport(results: [
            rtcParticipantsResponse([]),
            rtcParticipantsResponse([
                RemoteRTCRoomParticipant(
                    uid: "uid-2",
                    deviceID: "peer-joined-device",
                    deviceType: "android",
                    role: "callee"
                )
            ])
        ])
        let fixture = makeRTCPeerWaitFixture(transport: transport)

        let readyRoom = try await fixture.state.waitForRTCPeerParticipantForTesting(
            call: fixture.call,
            joinedRoom: fixture.joinedRoom,
            policy: RTCPeerParticipantWaitPolicy(
                maximumAttempts: 3,
                pollIntervalNanoseconds: 1_000_000
            )
        )

        XCTAssertEqual(readyRoom.peerParticipant?.deviceID, "peer-joined-device")
        XCTAssertEqual(fixture.state.activeVoiceCall?.statusText, "等待对方连接")
        XCTAssertEqual(transport.requests().count, 2)
        XCTAssertTrue(transport.requests().allSatisfy {
            $0.httpMethod == "GET" && $0.url?.path == "/api/rtc/rooms/room-peer-wait/participants"
        })
        XCTAssertTrue(transport.requests().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer rtc-token-peer-wait"
        })
        XCTAssertFalse(transport.requests().contains {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer im-token"
        })
    }

    func testRTCPeerParticipantWaitSelectsAcceptedWinnerAmongSameUIDDevices() async throws {
        let transport = FakeHTTPTransport(results: [
            rtcParticipantsResponse([
                RemoteRTCRoomParticipant(
                    uid: "uid-2",
                    deviceID: "stale-joined-device",
                    deviceType: "web",
                    role: "callee"
                ),
                RemoteRTCRoomParticipant(
                    uid: "uid-2",
                    deviceID: "peer-joined-device",
                    deviceType: "android",
                    role: "callee"
                )
            ])
        ])
        let fixture = makeRTCPeerWaitFixture(transport: transport)

        let readyRoom = try await fixture.state.waitForRTCPeerParticipantForTesting(
            call: fixture.call,
            joinedRoom: fixture.joinedRoom,
            policy: RTCPeerParticipantWaitPolicy(
                maximumAttempts: 1,
                pollIntervalNanoseconds: 1_000_000
            )
        )

        XCTAssertEqual(readyRoom.peerParticipant?.uid, "uid-2")
        XCTAssertEqual(readyRoom.peerParticipant?.deviceID, "peer-joined-device")
    }

    func testRTCRoomParticipantRequestUsesRoomCredentialAndUnauthorizedDoesNotClearIMSession() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"rtc_token_invalid","message":"RTC credential rejected"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 401
            )
        ])
        let context = makeContext()
        let client = makeClient(transport: transport)
        var credentialError: RTCCredentialError?

        do {
            _ = try await client.listRTCRoomParticipants(
                context: context,
                roomID: "room-token-contract",
                rtcToken: "room-rtc-token"
            )
            XCTFail("Expected room RTC credential rejection")
        } catch let error as RTCCredentialError {
            XCTAssertEqual(error, .unauthorized("RTC credential rejected"))
            credentialError = error
        }

        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.path, "/api/rtc/rooms/room-token-contract/participants")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer room-rtc-token")
        XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer im-token")

        let state = AppState(apiContextOverride: context)
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setAuthScreen(.workspaceSelection) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        state.debugHandleRemoteErrorForTesting(
            try XCTUnwrap(credentialError),
            fallback: "接听视频通话失败"
        )
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.debugHasIMSessionForTesting())
        XCTAssertEqual(state.authScreen, .workspaceSelection)
        XCTAssertNotEqual(state.toast, "登录已失效，请重新登录")
    }

    func testRTCPeerParticipantWaitTimesOutWithoutSendingSignalToEmptyDevice() async throws {
        let transport = FakeHTTPTransport(results: [
            rtcParticipantsResponse([]),
            successfulEmptyResponse(),
            rtcParticipantsResponse([])
        ])
        let videoMediaClient = PeerWaitVideoMediaClient()
        let fixture = makeRTCPeerWaitFixture(
            transport: transport,
            videoMediaClient: videoMediaClient
        )

        do {
            _ = try await fixture.state.waitForRTCPeerParticipantForTesting(
                call: fixture.call,
                joinedRoom: fixture.joinedRoom,
                policy: RTCPeerParticipantWaitPolicy(
                    maximumAttempts: 1,
                    pollIntervalNanoseconds: 1_000_000
                )
            )
            XCTFail("Expected peer participant wait timeout")
        } catch {
            // The concrete error is intentionally private; the stable UI state is the contract.
        }
        do {
            _ = try await fixture.state.waitForRTCPeerParticipantForTesting(
                call: fixture.call,
                joinedRoom: fixture.joinedRoom,
                policy: RTCPeerParticipantWaitPolicy(
                    maximumAttempts: 1,
                    pollIntervalNanoseconds: 1_000_000
                )
            )
            XCTFail("Expected repeated peer participant wait timeout")
        } catch {
            // A repeated timeout may re-check participants, but must not end the same call twice.
        }

        XCTAssertEqual(fixture.state.activeVoiceCall?.statusText, "连接失败")
        XCTAssertEqual(fixture.state.activeVoiceCall?.mediaState, .failed)
        XCTAssertEqual(fixture.state.toast, "连接失败，请结束后重试")
        XCTAssertEqual(transport.requests().count, 3)
        XCTAssertEqual(transport.requests()[0].url?.path, "/api/rtc/rooms/room-peer-wait/participants")
        XCTAssertEqual(transport.requests()[1].url?.path, "/api/rtc/calls/call-peer-wait/hangup")
        XCTAssertEqual(transport.requests()[1].httpMethod, "POST")
        let endBodyData = try XCTUnwrap(transport.requests()[1].httpBody)
        let endBody = try XCTUnwrap(JSONSerialization.jsonObject(with: endBodyData) as? [String: Any])
        XCTAssertEqual(endBody["reason"] as? String, "peer_participant_timeout")
        XCTAssertTrue((endBody["idempotency_key"] as? String)?.hasPrefix("ios-") == true)
        XCTAssertEqual(transport.requests()[2].url?.path, "/api/rtc/rooms/room-peer-wait/participants")
        XCTAssertEqual(
            transport.requests().filter { $0.url?.path == "/api/rtc/calls/call-peer-wait/hangup" }.count,
            1
        )
        XCTAssertFalse(transport.requests().contains { $0.url?.path.contains("/signals") == true })
        try await waitForCondition {
            videoMediaClient.stopReasons == ["peer_participant_timeout"]
        }
    }

    func testRTCPeerParticipantWaitStopsAfterActiveCallTerminates() async throws {
        let transport = FakeHTTPTransport(results: [
            rtcParticipantsResponse([]),
            rtcParticipantsResponse([
                RemoteRTCRoomParticipant(uid: "uid-2", deviceID: "must-not-be-read", deviceType: "web")
            ])
        ])
        let fixture = makeRTCPeerWaitFixture(transport: transport)
        let waitTask = Task { @MainActor in
            try await fixture.state.waitForRTCPeerParticipantForTesting(
                call: fixture.call,
                joinedRoom: fixture.joinedRoom,
                policy: RTCPeerParticipantWaitPolicy(
                    maximumAttempts: 3,
                    pollIntervalNanoseconds: 100_000_000
                )
            )
        }
        try await waitForCondition {
            transport.requests().count == 1
                && fixture.state.activeVoiceCall?.statusText == "等待对方连接"
        }

        fixture.state.activeVoiceCall = nil
        do {
            _ = try await waitTask.value
            XCTFail("Expected participant wait cancellation")
        } catch {
            // Ending the authoritative active call must cancel the pending peer wait.
        }

        XCTAssertEqual(transport.requests().count, 1)
    }

    func testRTCPeerParticipantWaitStopsWhenAppEntersBackground() async throws {
        let transport = FakeHTTPTransport(results: [
            rtcParticipantsResponse([]),
            rtcParticipantsResponse([
                RemoteRTCRoomParticipant(uid: "uid-2", deviceID: "must-not-be-read", deviceType: "web")
            ])
        ])
        let fixture = makeRTCPeerWaitFixture(transport: transport)
        let waitTask = Task { @MainActor in
            try await fixture.state.waitForRTCPeerParticipantForTesting(
                call: fixture.call,
                joinedRoom: fixture.joinedRoom,
                policy: RTCPeerParticipantWaitPolicy(
                    maximumAttempts: 3,
                    pollIntervalNanoseconds: 100_000_000
                )
            )
        }
        try await waitForCondition {
            transport.requests().count == 1
                && fixture.state.activeVoiceCall?.statusText == "等待对方连接"
        }

        fixture.state.appDidEnterBackground()
        do {
            _ = try await waitTask.value
            XCTFail("Expected participant wait cancellation in background")
        } catch {
            // Foreground reconciliation can resume the accepted call; background must not signal.
        }

        XCTAssertEqual(transport.requests().count, 1)
        XCTAssertEqual(fixture.state.activeVoiceCall?.statusText, "等待对方连接")
        XCTAssertFalse(transport.requests().contains { $0.url?.path.contains("/signals") == true })
    }

    func testRTCPeerWaitProductionWindowAndVideoBackgroundCapturePolicy() {
        XCTAssertGreaterThanOrEqual(
            RTCPeerParticipantWaitPolicy.production.maximumScheduledWaitNanoseconds,
            10_000_000_000
        )
        XCTAssertLessThanOrEqual(
            RTCPeerParticipantWaitPolicy.production.maximumScheduledWaitNanoseconds,
            15_000_000_000
        )
        XCTAssertTrue(
            RTCVideoCapturePolicy.shouldCapture(
                cameraEnabledIntent: true,
                isApplicationBackgrounded: false
            )
        )
        XCTAssertFalse(
            RTCVideoCapturePolicy.shouldCapture(
                cameraEnabledIntent: true,
                isApplicationBackgrounded: true
            )
        )
    }
}
