import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRTCCallPayloadDecodesDeviceFields() throws {
        let json = """
        {
          "call": {
            "call_id": "call-123",
            "status": "accepted",
            "room_id": "room-123",
            "rtc_token": "call-token",
            "call_type": "audio",
            "channel_type": "direct",
            "channel_id": "direct-a-b",
            "caller_uid": "uid-a",
            "callee_uid": "uid-b",
            "created_at": "2026-06-26T01:59:00Z",
            "started_at": "2026-06-26T02:00:10Z",
            "accepted_at": "2026-06-26T02:00:20Z",
            "ended_at": "2026-06-26T02:03:20Z",
            "updated_at": "2026-06-26T02:03:21Z",
            "caller_profile": {
              "uid": "uid-a",
              "display_name": "Alice",
              "avatar": "/avatars/alice.png",
              "avatar_version": "caller-v1",
              "avatar_updated_at": "2026-06-26T02:00:00Z"
            },
            "callee_avatar_url": "/avatars/bob.png",
            "callee_avatar_version": "callee-v2",
            "callee_avatar_updated_at": "2026-06-26T02:05:00Z",
            "caller_device": {
              "device_id": "web-123",
              "device_type": "web"
            },
            "callee_device": {
              "device_id": "ios-456",
              "device_type": "ios"
            },
            "accepted_device": {
              "uid": "uid-b",
              "device_id": "ios-456",
              "device_type": "ios"
            }
          },
          "rtc_token": "response-token"
        }
        """

        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.rtcToken, "response-token")
        XCTAssertEqual(response.call.id, "call-123")
        XCTAssertEqual(response.call.rtcToken, "call-token")
        XCTAssertEqual(response.call.callerProfile?.displayName, "Alice")
        XCTAssertEqual(response.call.callerAvatarURL, "/avatars/alice.png")
        XCTAssertEqual(response.call.callerAvatarVersion, "caller-v1")
        XCTAssertEqual(response.call.callerAvatarUpdatedAt, "2026-06-26T02:00:00Z")
        XCTAssertEqual(response.call.calleeAvatarURL, "/avatars/bob.png")
        XCTAssertEqual(response.call.calleeAvatarVersion, "callee-v2")
        XCTAssertEqual(response.call.calleeAvatarUpdatedAt, "2026-06-26T02:05:00Z")
        XCTAssertEqual(response.call.callerDevice?.deviceID, "web-123")
        XCTAssertEqual(response.call.calleeDevice?.deviceType, "ios")
        XCTAssertEqual(response.call.acceptedDevice?.uid, "uid-b")
        XCTAssertEqual(response.call.acceptedDevice?.deviceID, "ios-456")
        XCTAssertEqual(response.call.createdAt, "2026-06-26T01:59:00Z")
        XCTAssertEqual(response.call.startedAt, "2026-06-26T02:00:10Z")
        XCTAssertEqual(response.call.acceptedAt, "2026-06-26T02:00:20Z")
        XCTAssertEqual(response.call.endedAt, "2026-06-26T02:03:20Z")
        XCTAssertEqual(response.call.updatedAt, "2026-06-26T02:03:21Z")
    }

    func testRTCVideoProviderFailsClosedAndDecodesFrozenCapabilitiesContract() throws {
        let legacy = try JSONDecoder().decode(RemoteRTCProvider.self, from: Data("""
        {
          "call_types": ["audio", "video"],
          "video_supported": true,
          "media_plane_configured": true,
          "ice_servers_configured": true
        }
        """.utf8))
        XCTAssertFalse(legacy.supportsVideo)

        let current = try JSONDecoder().decode(RemoteRTCProvider.self, from: Data("""
        {
          "call_types": ["audio", "video"],
          "video_supported": true,
          "voice_call_enabled": true,
          "video_call_enabled": true,
          "capabilities_version": "video-call-v1",
          "media_plane_configured": true,
          "ice_servers_configured": true
        }
        """.utf8))
        XCTAssertTrue(current.supportsAudio)
        XCTAssertTrue(current.supportsVideo)
        XCTAssertEqual(current.capabilitiesVersion, RTCDeviceCapabilities.protocolVersion)
    }

    func testRTCVideoCallDecodesMediaModesAndPeerCapability() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-video-1",
            "status": "accepted",
            "call_type": "video",
            "requested_media_mode": "video",
            "media_mode": "audio",
            "peer_capability_status": "supported",
            "caller_capabilities": {
              "version": "video-call-v1",
              "audio": true,
              "video": true,
              "camera_available": false
            }
          },
          "rtc_token": "short-lived-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.callType, "video")
        XCTAssertEqual(response.call.requestedMediaMode, "video")
        XCTAssertEqual(response.call.mediaMode, "audio")
        XCTAssertEqual(response.call.peerCapabilityStatus, "supported")
        XCTAssertEqual(response.call.callerCapabilities?.cameraAvailable, false)
    }

    func testRTCVoiceCreateResponseDecodesOmittedCapabilityVersionInsteadOfSurfacingHTTP201Phrase() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-audio-201",
            "status": "ringing",
            "call_type": "audio",
            "caller_capabilities": {
              "audio": false,
              "video": false,
              "camera_available": false
            }
          },
          "rtc_token": "voice-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.id, "call-audio-201")
        XCTAssertEqual(response.call.status, "ringing")
        XCTAssertEqual(response.call.callerCapabilities?.version, "")
        XCTAssertEqual(response.call.callerCapabilities?.audio, false)
        XCTAssertEqual(response.rtcToken, "voice-token")
    }

    func testRTCVideoCreateResponseDecodesOmittedCapabilityFieldsAsSafeFalseDefaults() throws {
        let response = try JSONDecoder().decode(RemoteRTCCallResponse.self, from: Data("""
        {
          "call": {
            "call_id": "call-video-201",
            "status": "ringing",
            "call_type": "video",
            "requested_media_mode": "video",
            "caller_capabilities": {}
          },
          "rtc_token": "video-token"
        }
        """.utf8))

        XCTAssertEqual(response.call.id, "call-video-201")
        XCTAssertEqual(response.call.status, "ringing")
        XCTAssertEqual(response.call.requestedMediaMode, "video")
        XCTAssertEqual(response.call.callerCapabilities?.version, "")
        XCTAssertEqual(response.call.callerCapabilities?.audio, false)
        XCTAssertEqual(response.call.callerCapabilities?.video, false)
        XCTAssertEqual(response.call.callerCapabilities?.cameraAvailable, false)
        XCTAssertEqual(response.rtcToken, "video-token")
    }

    func testRTCIceCredentialContractsDecodeServerScheduleAndReboundToken() throws {
        let join = try JSONDecoder().decode(
            RemoteRTCRoomJoinData.self,
            from: Data(
                """
                {
                  "room_id": "room-1",
                  "media": {
                    "ice_servers": [{"urls": ["turn:relay.example.test"]}],
                    "ice_credential_expires_at": "2026-07-25T12:20:00Z",
                    "ice_credential_refresh_after": "2026-07-25T12:08:00Z"
                  }
                }
                """.utf8
            )
        )
        XCTAssertEqual(join.media.iceCredentialExpiresAt, "2026-07-25T12:20:00Z")
        XCTAssertEqual(join.media.iceCredentialRefreshAfter, "2026-07-25T12:08:00Z")

        let refresh = try JSONDecoder().decode(
            RemoteRTCIceCredentials.self,
            from: Data(
                """
                {
                  "ice_servers": [{"urls": ["turn:relay-2.example.test"]}],
                  "rtc_token": "rebound-token",
                  "ice_credential_expires_at": "2026-07-25T12:40:00Z",
                  "ice_credential_refresh_after": "2026-07-25T12:28:00Z"
                }
                """.utf8
            )
        )
        XCTAssertEqual(refresh.rtcToken, "rebound-token")
        XCTAssertEqual(refresh.iceCredentialExpiresAt, "2026-07-25T12:40:00Z")
        XCTAssertEqual(refresh.iceCredentialRefreshAfter, "2026-07-25T12:28:00Z")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteRTCIceCredentials.self,
                from: Data(#"{"ice_servers":[]}"#.utf8)
            )
        )
    }

    func testRTCVoiceIceMatrixAcceptsBothOrEitherTurnNodeAndRejectsZeroTurnNodes() throws {
        func decode(_ json: String) throws -> [RemoteRTCIceServer] {
            try JSONDecoder().decode([RemoteRTCIceServer].self, from: Data(json.utf8))
        }

        let both = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turn:turn-a.example.test:3478","turns:turn-a.example.test:5349"],"username":"a","credential":"secret-a"},{"urls":["turn:turn-b.example.test:3478","turns:turn-b.example.test:5349"],"username":"b","credential":"secret-b"}]"#
        )
        let onlyA = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turn:turn-a.example.test:3478"],"username":"a","credential":"secret-a"}]"#
        )
        let onlyB = try decode(
            #"[{"urls":["stun:stun.example.test"]},{"urls":["turns:turn-b.example.test:5349"],"username":"b","credential":"secret-b"}]"#
        )
        let zero = try decode(#"[{"urls":["stun:stun.example.test"]}]"#)

        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(both), 2)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(onlyA), 1)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(onlyB), 1)
        XCTAssertEqual(RTCVoiceIceServerSet.relayCount(zero), 0)
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(both))
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(onlyA))
        XCTAssertTrue(RTCVoiceIceServerSet.hasUsableTurnRelay(onlyB))
        XCTAssertFalse(RTCVoiceIceServerSet.hasUsableTurnRelay(zero))
    }

    func testRTCVoiceRecoveryBudgetIsTwoRoundsWithinFifteenSeconds() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var budget = RTCVoiceRecoveryBudget()

        budget.startWindowIfNeeded(now: startedAt)
        XCTAssertEqual(budget.claimAttempt(now: startedAt), 1)
        XCTAssertEqual(budget.claimAttempt(now: startedAt.addingTimeInterval(6)), 2)
        XCTAssertNil(budget.claimAttempt(now: startedAt.addingTimeInterval(7)))
        XCTAssertEqual(budget.remainingWindow(now: startedAt.addingTimeInterval(15)), 0)

        var expiredBudget = RTCVoiceRecoveryBudget()
        XCTAssertEqual(expiredBudget.claimAttempt(now: startedAt), 1)
        XCTAssertNil(expiredBudget.claimAttempt(now: startedAt.addingTimeInterval(15)))
        expiredBudget.reset()
        XCTAssertEqual(expiredBudget.claimAttempt(now: startedAt.addingTimeInterval(60)), 1)
        XCTAssertEqual(expiredBudget.attempts, 1)
    }

    @MainActor
    func testRTCVoiceRecoveryDeadlineTerminatesHungAsyncOperation() async {
        let startedAt = Date()
        var hungOperationCancelled = false

        do {
            try await RTCVoiceRecoveryDeadline.run(timeout: 0.02) {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    hungOperationCancelled = true
                    throw CancellationError()
                }
            }
            XCTFail("Expected the recovery deadline to terminate the hung operation")
        } catch {
            XCTAssertEqual(error as? RTCVoiceRecoveryDeadlineError, .exceeded)
        }
        for _ in 0..<20 where !hungOperationCancelled {
            await Task.yield()
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertTrue(hungOperationCancelled)
    }

    func testRTCVoiceRefreshSnapshotRejectsLateSessionAndTokenResults() {
        let snapshot = RTCVoiceCredentialRefreshSnapshot(
            sessionEpoch: 3,
            recoveryGeneration: 7,
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "token-generation-1"
        )

        XCTAssertTrue(
            snapshot.matches(
                sessionEpoch: 3,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-1"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 4,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-1"
            )
        )
        XCTAssertFalse(
            snapshot.matches(
                sessionEpoch: 3,
                recoveryGeneration: 7,
                callID: "call-1",
                roomID: "room-1",
                rtcToken: "token-generation-2"
            )
        )
    }

    func testRTCVoIPPushPayloadParsesRingingContractAndStableUUID() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "type": "rtc_call",
            "event": "ringing",
            "call_id": "call-voice-1",
            "room_id": "room-voice-1",
            "tenant_id": "tenant-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "/avatars/mengyao.png",
            "caller_avatar_version": "voice-v1",
            "caller_avatar_updated_at": "2026-06-26T03:00:00Z",
            "call_type": "audio",
            "provider": "self_hosted_webrtc",
            "issued_at": "2026-06-26T01:02:03Z",
            "expires_at": "2026-06-26T01:03:03Z"
        ]))

        XCTAssertTrue(payload.isRinging)
        XCTAssertFalse(payload.isTerminal)
        XCTAssertEqual(payload.kind, "rtc_call")
        XCTAssertEqual(payload.callID, "call-voice-1")
        XCTAssertEqual(payload.roomID, "room-voice-1")
        XCTAssertEqual(payload.callerUID, "WXT00000003")
        XCTAssertEqual(payload.calleeUID, "WXT00000002")
        XCTAssertEqual(payload.callerName, "孟瑶")
        XCTAssertEqual(payload.callerAvatarURL, "/avatars/mengyao.png")
        XCTAssertEqual(payload.callerAvatarVersion, "voice-v1")
        XCTAssertEqual(payload.callerAvatarUpdatedAt, "2026-06-26T03:00:00Z")
        XCTAssertEqual(payload.callType, "audio")
        XCTAssertEqual(payload.provider, "self_hosted_webrtc")
        XCTAssertTrue(payload.isPushKitEligibleRinging)
        XCTAssertEqual(
            payload.deliveryFreshness(now: ISO8601DateFormatter().date(from: "2026-06-26T01:02:30Z")!),
            .fresh
        )
        XCTAssertEqual(
            payload.deliveryFreshness(now: ISO8601DateFormatter().date(from: "2026-06-26T01:03:04Z")!),
            .expired
        )
        XCTAssertEqual(payload.deterministicUUID, RTCVoIPPushPayload.deterministicUUIDForCallKit("call-voice-1"))
    }

    func testRTCVoIPPushPayloadParsesAPNsNestedRTCCallPayload() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "aps": [
                "alert": [
                    "title": "语音来电",
                    "body": "来自孟瑶"
                ],
                "sound": "default"
            ],
            "rtc_call": [
                "type": "rtc_call",
                "event": "ringing",
                "call_id": "call-voice-nested",
                "room_id": "room-voice-nested",
                "tenant_id": "tenant-1",
                "caller_uid": "WXT00000003",
                "callee_uid": "WXT00000002",
                "caller_name": "孟瑶",
                "caller_profile": [
                    "uid": "WXT00000003",
                    "nickname": "孟瑶",
                    "avatar_url": "/avatars/mengyao-profile.png",
                    "avatar_version": "voice-v2",
                    "avatar_updated_at": "2026-06-26T03:05:00Z"
                ] as [String: Any],
                "call_type": "audio",
                "provider": "self_hosted_webrtc"
            ]
        ]))

        XCTAssertTrue(payload.isRinging)
        XCTAssertEqual(payload.callID, "call-voice-nested")
        XCTAssertEqual(payload.roomID, "room-voice-nested")
        XCTAssertEqual(payload.callerName, "孟瑶")
        XCTAssertEqual(payload.callerProfile?.uid, "WXT00000003")
        XCTAssertEqual(payload.callerAvatarURL, "/avatars/mengyao-profile.png")
        XCTAssertEqual(payload.callerAvatarVersion, "voice-v2")
        XCTAssertEqual(payload.callerAvatarUpdatedAt, "2026-06-26T03:05:00Z")
        XCTAssertEqual(payload.provider, "self_hosted_webrtc")
    }

    func testRTCVoIPPushPayloadMapsTerminalCancelAndRejectsNonRTC() throws {
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "cancel",
            "call_id": "call-voice-2"
        ]))

        XCTAssertTrue(payload.isTerminal)
        XCTAssertFalse(payload.isPushKitEligibleRinging)
        XCTAssertEqual(payload.normalizedTerminalEvent, "canceled")
        XCTAssertNil(RTCVoIPPushPayload(dictionary: [
            "kind": "message",
            "event": "ringing",
            "call_id": "call-voice-2"
        ]))
    }

    func testRemotePushTokenRegistrationFingerprintIsStableSHA256AndNeverRawToken() {
        let registration = RemoteDeviceRegistration.apns(
            token: "secret",
            bundleID: "app.mltest.com",
            environment: "production"
        )

        XCTAssertEqual(
            registration.tokenFingerprint,
            "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b" // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
            // Original normalized UTF8(secret); Python hashlib and OpenSSL independently agree.
            // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END
        )
        XCTAssertNotEqual(registration.tokenFingerprint, registration.pushToken)
    }

    func testRemotePushTokenRetirementResponseRejectsUnknownOrMismatchedContractValues() throws {
        let decoder = JSONDecoder()
        let valid = try decoder.decode(
            RemotePushTokenRetirementResponse.self,
            from: Data(#"{"status":"already_empty","slot":"ordinary","provider":"apns","terminal":true}"#.utf8)
        )
        XCTAssertEqual(valid.status, .alreadyEmpty)
        XCTAssertEqual(valid.slot, .ordinary)
        XCTAssertEqual(valid.provider, .apns)
        XCTAssertTrue(valid.terminal)

        for invalid in [
            #"{"status":"unknown","slot":"ordinary","provider":"apns","terminal":false}"#,
            #"{"status":"retired","slot":"voip","provider":"apns","terminal":false}"#,
            #"{"status":"retired","slot":"ordinary","provider":"apns_voip","terminal":false}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(RemotePushTokenRetirementResponse.self, from: Data(invalid.utf8)))
        }
    }

    func testRemoteNotificationTargetResolutionStrictlyDecodesFrozenAllowlistedShapes() throws {
        let decoder = JSONDecoder()
        let conversation = try decoder.decode(
            RemoteNotificationTargetResolution.self,
            from: Data(#"{"kind":"conversation","conversation_id":"conversation-opaque","message_id":"message-opaque","channel_seq":123}"#.utf8)
        )
        XCTAssertEqual(conversation.kind, .conversation)
        XCTAssertEqual(conversation.conversationID, "conversation-opaque")
        XCTAssertNil(conversation.systemDestination)

        let system = try decoder.decode(
            RemoteNotificationTargetResolution.self,
            from: Data(#"{"kind":"system","system_destination":"system_notification"}"#.utf8)
        )
        XCTAssertEqual(system.kind, .system)
        XCTAssertEqual(system.systemDestination, "system_notification")
        XCTAssertNil(system.conversationID)

        for invalid in [
            #"{"kind":"conversation","conversation_id":""}"#,
            #"{"kind":"conversation","conversation_id":"c","system_destination":"system_notification"}"#,
            #"{"kind":"system","system_destination":"other"}"#,
            #"{"kind":"system","system_destination":"system_notification","conversation_id":"c"}"#,
            #"{"kind":"conversation","conversation_id":"c","channel_seq":0}"#,
            #"{"kind":"conversation","conversation_id":"c","message_id":null}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(RemoteNotificationTargetResolution.self, from: Data(invalid.utf8)))
        }
    }
}
