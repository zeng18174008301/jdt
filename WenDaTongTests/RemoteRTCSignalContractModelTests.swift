import XCTest
@testable import WenDaTong

extension RemoteAPIModelsTests {
    func testRTCRoomJoinPayloadDecodesParticipants() throws {
        let json = """
        {
          "room_id": "room-123",
          "rtc_token": "rtc-token",
          "media": {
            "owt_base_url": "https://rtc.example.test",
            "ice_servers": [
              {
                "urls": ["turn:turn.example.test"],
                "username": "turn-user",
                "credential": "turn-pass"
              }
            ]
          },
          "self_participant": {
            "uid": "uid-a",
            "device_id": "ios-123",
            "device_type": "ios",
            "role": "caller",
            "joined_at": "2026-06-26T00:00:00Z"
          },
          "peer_participant": {
            "uid": "uid-b",
            "device_id": "web-456",
            "device_type": "web",
            "role": "callee",
            "joined_at": "2026-06-26T00:00:01Z"
          },
          "participants": [
            {
              "uid": "uid-a",
              "device_id": "ios-123",
              "device_type": "ios",
              "role": "caller",
              "joined_at": "2026-06-26T00:00:00Z"
            }
          ]
        }
        """

        let join = try JSONDecoder().decode(RemoteRTCRoomJoinData.self, from: Data(json.utf8))

        XCTAssertEqual(join.roomID, "room-123")
        XCTAssertEqual(join.rtcToken, "rtc-token")
        XCTAssertEqual(join.selfParticipant?.deviceID, "ios-123")
        XCTAssertEqual(join.peerParticipant?.uid, "uid-b")
        XCTAssertEqual(join.participants.first?.role, "caller")
        XCTAssertEqual(join.media.iceServers.first?.username, "turn-user")
    }

    func testRTCRoomJoinPayloadDecodesLegacyParticipantAsSelf() throws {
        let json = """
        {
          "participant": {
            "tenant_id": "tenant-1",
            "room_id": "room-legacy",
            "im_uid": "uid-a",
            "device_id": "ios-123",
            "app_id": "com.jianhuitongim.app",
            "status": "joined",
            "joined_at": "2026-06-26T00:00:00Z"
          },
          "media": {
            "room_id": "room-legacy",
            "ice_servers": [
              { "urls": "stun:stun.example.test" }
            ]
          }
        }
        """

        let join = try JSONDecoder().decode(RemoteRTCRoomJoinData.self, from: Data(json.utf8))

        XCTAssertEqual(join.roomID, "room-legacy")
        XCTAssertEqual(join.selfParticipant?.uid, "uid-a")
        XCTAssertEqual(join.selfParticipant?.deviceID, "ios-123")
        XCTAssertEqual(join.selfParticipant?.role, "joined")
        XCTAssertEqual(join.participants.first?.deviceID, "ios-123")
        XCTAssertEqual(join.media.iceServers.first?.urls, ["stun:stun.example.test"])
    }

    func testRTCSignalEnvelopeDecodesItemsAndOfferData() throws {
        let json = """
        {
          "items": [
            {
              "from_uid": "uid-a",
              "from_device": "web-123",
              "to_uid": "uid-b",
              "to_device": "ios-456",
              "kind": "offer",
              "data": {
                "type": "offer",
                "sdp": "v=0\\r\\no=- 1 2 IN IP4 127.0.0.1"
              },
              "created_at": "2026-06-26T00:00:00Z"
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(RemoteRTCSignalItemsData.self, from: Data(json.utf8))
        let item = try XCTUnwrap(result.items.first)
        let offerData = try JSONEncoder().encode(item.data)
        let offer = try JSONDecoder().decode(RemoteRTCSessionDescriptionSignalData.self, from: offerData)

        XCTAssertEqual(item.fromUID, "uid-a")
        XCTAssertEqual(item.fromDevice, "web-123")
        XCTAssertEqual(item.toUID, "uid-b")
        XCTAssertEqual(item.toDevice, "ios-456")
        XCTAssertEqual(item.kind, .offer)
        XCTAssertEqual(item.createdAt, "2026-06-26T00:00:00Z")
        XCTAssertEqual(offer.type, "offer")
        XCTAssertTrue(offer.isOfferOrAnswer)
        XCTAssertEqual(offer.sdp, "v=0\r\no=- 1 2 IN IP4 127.0.0.1")
    }

    func testRTCSignalEnvelopeEncodesSendBody() throws {
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "uid-b",
            toDevice: "ios-456",
            kind: .answer,
            data: [
                "type": .string("answer"),
                "sdp": .string("v=0...")
            ]
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["to_uid"] as? String, "uid-b")
        XCTAssertEqual(object?["to_device"] as? String, "ios-456")
        XCTAssertEqual(object?["kind"] as? String, "answer")
        let payload = try XCTUnwrap(object?["data"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "answer")
        XCTAssertEqual(payload["sdp"] as? String, "v=0...")
    }

    func testRTCSignalV2DecodesCursorEnvelopeAndDeduplicationResult() throws {
        let page = try JSONDecoder().decode(RemoteRTCSignalItemsData.self, from: Data("""
        {
          "items": [{
            "server_cursor": "cursor-9",
            "message_id": "message-9",
            "seq": 9,
            "negotiation_id": "neg-1",
            "call_id": "call-video-1",
            "from_uid": "uid-a",
            "from_device": "ios-a",
            "to_uid": "uid-b",
            "to_device": "ios-b",
            "kind": "ice_restart",
            "data": {"reason": "network_changed"},
            "created_at": "2026-07-25T00:00:00Z"
          }],
          "next_cursor": "cursor-9",
          "has_more": false
        }
        """.utf8))
        XCTAssertEqual(page.nextCursor, "cursor-9")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.items.first?.messageID, "message-9")
        XCTAssertEqual(page.items.first?.kind, .iceRestart)

        let result = try JSONDecoder().decode(RemoteRTCSignalPostResult.self, from: Data("""
        {
          "message_id": "message-9",
          "server_cursor": "cursor-9",
          "duplicate": true,
          "server_received_at": "2026-07-25T00:00:00Z",
          "expires_at": "2026-07-25T00:05:00Z"
        }
        """.utf8))
        XCTAssertTrue(result.duplicate)
        XCTAssertEqual(result.serverCursor, "cursor-9")
    }

    func testRTCSignalV2EnvelopeCarriesStableIdentityAndNeverNeedsCredentials() throws {
        let envelope = RemoteRTCSignalEnvelope(
            protocolVersion: RTCDeviceCapabilities.protocolVersion,
            messageID: "message-1",
            seq: 1,
            negotiationID: "neg-1",
            callID: "call-video-1",
            toUID: "uid-b",
            toDevice: "ios-b",
            kind: .mediaState,
            data: ["camera_enabled": .bool(false)],
            sentAt: "2026-07-25T00:00:00Z"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        XCTAssertEqual(object["protocol_version"] as? String, "video-call-v1")
        XCTAssertEqual(object["message_id"] as? String, "message-1")
        XCTAssertEqual(object["seq"] as? Int, 1)
        XCTAssertNil(object["rtc_token"])
        XCTAssertNil(object["credential"])
    }

    func testRTCCandidateDataDecodesSingleAndBatchFormats() throws {
        let snakeCaseSingle = try JSONDecoder().decode(RemoteRTCIceCandidatesSignalData.self, from: Data("""
        {
          "candidate": "candidate:single",
          "sdp_mid": "0",
          "sdp_mline_index": 0,
          "username_fragment": "ufrag-single"
        }
        """.utf8))

        let camelCaseBatch = try JSONDecoder().decode(RemoteRTCIceCandidatesSignalData.self, from: Data("""
        {
          "candidates": [
            {
              "candidate": "candidate:first",
              "sdpMid": "0",
              "sdpMLineIndex": 0,
              "usernameFragment": "ufrag-first"
            },
            {
              "candidate": "candidate:second",
              "sdpMid": null,
              "sdpMLineIndex": null
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(snakeCaseSingle.candidates.count, 1)
        XCTAssertEqual(snakeCaseSingle.candidates.first?.candidate, "candidate:single")
        XCTAssertEqual(snakeCaseSingle.candidates.first?.sdpMid, "0")
        XCTAssertEqual(snakeCaseSingle.candidates.first?.sdpMLineIndex, 0)
        XCTAssertEqual(snakeCaseSingle.candidates.first?.usernameFragment, "ufrag-single")
        XCTAssertEqual(camelCaseBatch.candidates.map(\.candidate), ["candidate:first", "candidate:second"])
        XCTAssertEqual(camelCaseBatch.candidates.first?.sdpMid, "0")
        XCTAssertEqual(camelCaseBatch.candidates.first?.sdpMLineIndex, 0)
        XCTAssertEqual(camelCaseBatch.candidates.first?.usernameFragment, "ufrag-first")
        XCTAssertNil(camelCaseBatch.candidates[1].sdpMid)
        XCTAssertNil(camelCaseBatch.candidates[1].sdpMLineIndex)
    }

    func testRTCIceCandidateCodableWritesOnlyFrozenSnakeCaseKeys() throws {
        let candidate = RemoteRTCIceCandidateSignalData(
            candidate: "candidate:direct",
            sdpMid: "video",
            sdpMLineIndex: 1,
            usernameFragment: "ufrag-direct"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )

        XCTAssertEqual(object["candidate"] as? String, "candidate:direct")
        XCTAssertEqual(object["sdp_mid"] as? String, "video")
        XCTAssertEqual(object["sdp_mline_index"] as? Int, 1)
        XCTAssertEqual(object["username_fragment"] as? String, "ufrag-direct")
        XCTAssertNil(object["sdpMid"])
        XCTAssertNil(object["sdpMLineIndex"])
        XCTAssertNil(object["usernameFragment"])
    }

    func testRTCSignalPayloadCodecEncodesCandidateAsBatchForSend() throws {
        let data = RTCSignalPayloadCodec.candidateData([
            RemoteRTCIceCandidateSignalData(
                candidate: "candidate:local",
                sdpMid: "0",
                sdpMLineIndex: 0,
                usernameFragment: "ufrag-local"
            )
        ])
        let envelope = RemoteRTCSignalEnvelope(
            toUID: "uid-b",
            toDevice: "ios-456",
            kind: .candidate,
            data: data
        )

        let encoded = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(object["data"] as? [String: Any])
        let candidates = try XCTUnwrap(payload["candidates"] as? [[String: Any]])

        XCTAssertNil(payload["candidate"])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?["candidate"] as? String, "candidate:local")
        XCTAssertEqual(candidates.first?["sdp_mid"] as? String, "0")
        XCTAssertEqual(candidates.first?["sdp_mline_index"] as? Int, 0)
        XCTAssertEqual(candidates.first?["username_fragment"] as? String, "ufrag-local")
        XCTAssertNil(candidates.first?["sdpMid"])
        XCTAssertNil(candidates.first?["sdpMLineIndex"])
        XCTAssertNil(candidates.first?["usernameFragment"])
    }

    func testRTCSignalPayloadCodecUsesStrictEOCAndRestartPayloads() {
        XCTAssertTrue(RTCSignalPayloadCodec.iceCompleteData.isEmpty)
        XCTAssertEqual(
            RTCSignalPayloadCodec.iceRestartData(),
            ["reason": .string("stable_token")]
        )
    }

    func testRTCVoiceMediaEventsKeepAcceptedAndJoinBeforeConnected() {
        XCTAssertEqual(RTCVoiceMediaEvent.callAccepted.mediaState, .preparing)
        XCTAssertEqual(RTCVoiceMediaEvent.roomJoined.mediaState, .preparing)
        XCTAssertEqual(RTCVoiceMediaEvent.remoteAudioTrackReady.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.localDescriptionSet.mediaState, .signaling)
        XCTAssertEqual(RTCVoiceMediaEvent.iceChecking.mediaState, .connecting)

        XCTAssertFalse(RTCVoiceMediaEvent.callAccepted.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.roomJoined.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.remoteAudioTrackReady.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.localDescriptionSet.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.iceChecking.qualifiesForConnectedAt)

        XCTAssertEqual(RTCVoiceMediaEvent.iceConnected.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.iceCompleted.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.peerConnectionConnected.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.connectionRecovered.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.remoteAudioRTPReady.mediaState, .connecting)
        XCTAssertEqual(RTCVoiceMediaEvent.recoveryExhausted.mediaState, .failed)
        XCTAssertFalse(RTCVoiceMediaEvent.iceConnected.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.iceCompleted.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.peerConnectionConnected.qualifiesForConnectedAt)
        XCTAssertFalse(RTCVoiceMediaEvent.remoteAudioRTPReady.qualifiesForConnectedAt)
    }
}
