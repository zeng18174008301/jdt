import XCTest; @testable import IM4Features // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testAudioHeartbeatUsesTransportReadinessAfterDisconnect() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: (2...12).map {
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: Int64($0)))
        })
        let state = startAudioHeartbeat(transport: transport)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.handleVoiceMediaEvent(.callAccepted)
        state.handleVoiceMediaEvent(.iceConnected)
        for _ in 0..<100 where state.rtcMediaHeartbeatSnapshotForTesting?.hasReportedConnected != true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
        XCTAssertTrue(heartbeatStates(transport).contains("connected"))
        state.handleVoiceMediaEvent(.remoteAudioRTPReady)
        state.handleVoiceMediaEvent(.iceDisconnected)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "reconnecting")
        state.handleVoiceMediaEvent(.connectionRecovered)
        for _ in 0..<100 where heartbeatStates(transport).last != "connected" {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(heartbeatStates(transport).last, "connected")
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
    }

    func testAudioHeartbeatShortConnectedCallFlushesBeforeSingleHangup() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 150_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 3), delayNanoseconds: 30_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        state.endActiveVoiceCall()
        state.endActiveVoiceCall()
        XCTAssertTrue(state.isEndingActiveCall)
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true })
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(heartbeatStates(transport), ["connecting", "connected"])
        XCTAssertEqual(transport.requests().map { $0.url!.lastPathComponent }, ["media-state", "media-state", "hangup"])
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
    }

    func testAudioHeartbeatHangupTimeoutRemainsBoundedAndVisible() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 30_000_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        let started = Date()
        state.endActiveVoiceCall()
        for _ in 0..<160 where state.activeVoiceCall != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.2)
        XCTAssertEqual(state.toast, "通话已结束，连接记录同步未确认")
        XCTAssertEqual(transport.requests().filter { $0.url?.path.hasSuffix("/hangup") == true }.count, 1)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
    }

    func testAudioHeartbeatPendingConnectionSurvivesImmediateReconnect() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: (2...4).map {
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: Int64($0)), delayNanoseconds: 50_000_000)
        })
        let state = startAudioHeartbeat(transport: transport)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        qualifyAudio(state)
        state.handleVoiceMediaEvent(.iceDisconnected)
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        XCTAssertEqual(heartbeatStates(transport), ["connecting", "connected", "reconnecting"])
    }

    func testAudioHeartbeatUnconnectedCancelIgnoresLateReadyEvents() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 2), delayNanoseconds: 100_000_000)
        ])
        let state = startAudioHeartbeat(transport: transport)
        state.activeVoiceCall?.mediaState = .preparing
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.endActiveVoiceCall()
        qualifyAudio(state)
        XCTAssertNil(state.activeVoiceCall?.connectedAt)
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(heartbeatStates(transport), ["connecting"])
        XCTAssertEqual(transport.requests().filter { $0.url?.path.hasSuffix("/cancel") == true }.count, 1)
        XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true })
    }

    func testAudioHeartbeatContextReplacementRejectsLateResultAndHangup() async throws {
        for replacement in ["account", "device", "epoch"] {
            let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
                .init(result: rtcMediaHeartbeatCallResult(callID: "audio-heartbeat", stateVersion: 999), delayNanoseconds: 100_000_000, ignoresCancellation: true)
            ])
            let state = startAudioHeartbeat(transport: transport)
            await waitForRTCMediaHeartbeatRequests(1, transport: transport)
            qualifyAudio(state)
            state.endActiveVoiceCall()
            state.updateRTCMediaHeartbeatContextForTesting { context in
                switch replacement {
                case "account": context.accountID = "different-account"
                case "device": context.deviceID = "different-device"
                default: context.sessionEpoch = "different-epoch"
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting, replacement)
            XCTAssertNotEqual(state.activeVoiceCall?.stateVersion, 999, replacement)
            XCTAssertFalse(transport.requests().contains { $0.url?.path.hasSuffix("/hangup") == true }, replacement)
        }
    }

    func testVideoMediaHeartbeatReportsConnectingConnectedAndReconnectingSerially() async throws {
        XCTAssertEqual(
            RTCMediaStateHeartbeatFailurePolicy.defaultIntervalNanoseconds,
            10_000_000_000
        )
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 2), delayNanoseconds: 80_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 3), delayNanoseconds: 20_000_000),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-heartbeat", stateVersion: 4), delayNanoseconds: 20_000_000)
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-heartbeat")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-heartbeat",
            roomID: "room-heartbeat",
            rtcToken: "rtc-token-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-heartbeat")
        )

        state.renewRTCMediaStateHeartbeatForTesting()
        state.renewRTCMediaStateHeartbeatForTesting()
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        state.handleVideoMediaEvent(.mediaConnected, callID: "video-heartbeat")
        state.handleVideoMediaEvent(.remoteAudioTrackReady, callID: "video-heartbeat")
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        state.handleVideoMediaEvent(.reconnecting, callID: "video-heartbeat")
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 4 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let states = transport.requests().compactMap { request -> String? in
            guard request.url?.path.hasSuffix("/media-state") == true,
                  let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return nil
            }
            return object["media_state"] as? String
        }
        XCTAssertEqual(states, ["connecting", "connected", "reconnecting"])
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 4)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatRecoversLeaseOnceAndForegroundRenewsImmediately() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_participant_lease_expired")),
            .init(
                result: HTTPTransportResult(
                    data: Data(
                        """
                        {"ok":true,"data":{
                          "room_id":"room-lease",
                          "rtc_token":"rtc-token-renewed",
                          "self_participant":{
                            "uid":"uid-1",
                            "device_id":"ios-device-renewed",
                            "device_type":"ios",
                            "role":"self"
                          },
                          "participants":[]
                        }}
                        """.utf8
                    ),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-lease", stateVersion: 7)),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-lease", stateVersion: 8))
        ])
        let preparation = CallsAcceptancePhasedHTTPTransport.providerPreparation()
        let phasedTransport = CallsAcceptancePhasedHTTPTransport(preparation: preparation, operation: transport)
        let state = makeRTCMediaHeartbeatState(transport: phasedTransport)
        try installActiveAppPolicyForHTTPFixture(on: state) // WDT_IOS1_RTC_VIDEO_ORDER_POLICY_FIXTURE_20261112
        _ = try await state.api.rtcProvider(context: state.apiContext)
        XCTAssertEqual(preparation.requests().map(\.url?.path), ["/api/rtc/provider"])
        phasedTransport.beginOperation()
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-lease")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-lease",
            roomID: "room-lease",
            rtcToken: "rtc-token-original",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-original")
        )
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)

        let firstPaths = transport.requests().prefix(3).compactMap(\.url?.path)
        XCTAssertEqual(firstPaths, [
            "/api/rtc/calls/video-lease/media-state",
            "/api/rtc/rooms/room-lease/join",
            "/api/rtc/calls/video-lease/media-state"
        ])
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.rtcToken, "rtc-token-renewed")
        XCTAssertEqual(
            state.rtcMediaHeartbeatSnapshotForTesting?.selfParticipant?.deviceID,
            "ios-device-renewed"
        )
        XCTAssertEqual(state.activeVoiceCall?.rtcToken, "rtc-token-renewed")

        state.resumeRTCMediaStateHeartbeatAfterForegroundForTesting()
        await waitForRTCMediaHeartbeatRequests(4, transport: transport)
        XCTAssertEqual(
            transport.requests()[3].url?.path,
            "/api/rtc/calls/video-lease/media-state"
        )
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 8)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatRetriesStateVersionConflictWithoutParticipantRejoin() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_state_version_conflict")),
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_state_version_conflict")),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-conflict", stateVersion: 14))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-conflict")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-conflict",
            roomID: "room-conflict",
            rtcToken: "rtc-token-conflict",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-conflict")
        )
        await waitForRTCMediaHeartbeatRequests(3, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 14 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            transport.requests().compactMap(\.url?.path),
            Array(repeating: "/api/rtc/calls/video-conflict/media-state", count: 3)
        )
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 14)
        XCTAssertTrue(state.rtcMediaHeartbeatTimerArmedForTesting)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testVideoMediaHeartbeatAuthoritativeTerminalAfterNinetySecondsEndsAndCleansUp() async throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-terminal-heartbeat", stateVersion: 5)),
            .init(result: rtcMediaHeartbeatErrorResult(statusCode: 409, code: "rtc_call_not_active"))
        ])
        let state = makeRTCMediaHeartbeatState(
            transport: transport,
            now: { now }
        )
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-terminal-heartbeat")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-terminal-heartbeat",
            roomID: "room-terminal-heartbeat",
            rtcToken: "rtc-token-terminal-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-terminal-heartbeat")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 5 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 5)
        now = now.addingTimeInterval(91)
        state.renewRTCMediaStateHeartbeatForTesting()
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        await waitForCallEnd { state.activeVoiceCall == nil }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        XCTAssertEqual(state.calls.first?.endReason, "server_heartbeat_terminal")
        XCTAssertEqual(state.toast, "视频通话已结束")
    }

    func testVideoMediaHeartbeatLateCallResponseCannotMutateReplacementAndTerminationCancels() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(
                result: rtcMediaHeartbeatCallResult(callID: "video-a", stateVersion: 101),
                delayNanoseconds: 120_000_000,
                ignoresCancellation: true
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-b", stateVersion: 202))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-a")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-a",
            roomID: "room-a",
            rtcToken: "rtc-token-a",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-a")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)

        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-b")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-b",
            roomID: "room-b",
            rtcToken: "rtc-token-b",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-b")
        )
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(state.activeVoiceCall?.callID, "video-b")
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 202)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, "video-b")

        state.activeVoiceCall = nil
        XCTAssertNil(state.rtcMediaHeartbeatSnapshotForTesting)
        let requestCount = transport.requests().count
        state.renewRTCMediaStateHeartbeatForTesting()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.requests().count, requestCount)
    }

    func testVideoMediaHeartbeatInFlightSameCallRefreshQueuesFreshRenewalAndKeepsTimerArmed() async throws {
        let transport = RTCMediaHeartbeatHTTPTransport(stubs: [
            .init(
                result: rtcMediaHeartbeatCallResult(callID: "video-refresh", stateVersion: 11),
                delayNanoseconds: 100_000_000,
                ignoresCancellation: true
            ),
            .init(result: rtcMediaHeartbeatCallResult(callID: "video-refresh", stateVersion: 12))
        ])
        let state = makeRTCMediaHeartbeatState(transport: transport)
        state.activeVoiceCall = makeRTCMediaHeartbeatVideoCall(callID: "video-refresh")
        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-refresh",
            roomID: "room-refresh",
            rtcToken: "rtc-token-old",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-old")
        )
        await waitForRTCMediaHeartbeatRequests(1, transport: transport)
        let generation = try XCTUnwrap(state.rtcMediaHeartbeatSnapshotForTesting?.generation)

        state.startRTCMediaStateHeartbeatForTesting(
            callID: "video-refresh",
            roomID: "room-refresh",
            rtcToken: "rtc-token-fresh",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-fresh")
        )
        await waitForRTCMediaHeartbeatRequests(2, transport: transport)
        for _ in 0..<100 where state.activeVoiceCall?.stateVersion != 12 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.generation, generation)
        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.rtcToken, "rtc-token-fresh")
        XCTAssertEqual(state.activeVoiceCall?.stateVersion, 12)
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertTrue(state.rtcMediaHeartbeatTimerArmedForTesting)
        state.stopRTCMediaStateHeartbeatForTesting()
    }

    func testMinimizedVideoCallDismissalKeepsActiveSessionAndCanRestore() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        try installActiveAppPolicyForHTTPFixture(on: state) // WDT_IOS1_RTC_VIDEO_ORDER_POLICY_FIXTURE_20261112
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-1",
            callID: "video-1",
            roomID: "room-video-1",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        XCTAssertEqual(state.presentedCallSession?.callID, "video-1")

        state.setActiveVideoCallMinimized(true)
        XCTAssertNil(state.presentedCallSession)

        state.presentedCallSession = nil
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-1")
        XCTAssertTrue(state.activeVoiceCall?.isMinimized ?? false)

        state.setActiveVideoCallMinimized(false)
        XCTAssertEqual(state.presentedCallSession?.callID, "video-1")

        state.endActiveVoiceCall()
        await waitForCallEnd { state.activeVoiceCall == nil }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "视频通话已结束")
        XCTAssertEqual(state.calls.first?.subtitle, "视频呼出 · 通话已结束")
        XCTAssertNil(state.videoCallTerminalResult, "Frozen0581 local video hangup must not reopen the result cover")
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/calls/video-1/hangup")
    }

    func testRTCMessageAndListProjectValidatedEndTimeWithoutChangingOuterAuthority() throws {
        for outer in [nil, "bad-time", "2026-08-24T00:01:45Z"] as [String?] {
            let state = makeHistoricalRTCTestState()
            let object = historicalRTCMessageObject(outer: outer)
            let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: object))
            let mapped = state.debugChatMessageForTesting(remote)
            let endedOuter = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(
                withJSONObject: historicalRTCMessageObject(outer: "2026-08-24T00:01:45Z")
            ))
            let expectedDisplay = state.debugChatMessageForTesting(endedOuter).time
            let record = try XCTUnwrap(mapped.rtcCallRecord)
            XCTAssertEqual(mapped.time, expectedDisplay)
            XCTAssertEqual(CachedMessage(message: mapped).model.time, mapped.time)
            XCTAssertEqual(mapped.createdAt, RTCCallRecordTimeProjection.parseServerTimestamp(outer))
            XCTAssertEqual(mapped.channelSeq, 81)
            XCTAssertEqual(remote.createdAt, outer)
            XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
            XCTAssertEqual(record.answeredAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:20Z"))
            XCTAssertEqual(record.mediaConnectedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:45Z"))
            XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
            XCTAssertEqual(record.presentation(viewerIsCaller: false).statusText, "通话时长 02:00")

            let listObject: [String: Any] = [
                "channel_id": "friend-1:uid-1", "channel_type": "direct",
                "last_msg_seq": 81, "unread_count": 0, "last_message": object
            ]
            let remoteConversation = try JSONDecoder().decode(RemoteConversation.self, from: JSONSerialization.data(withJSONObject: listObject))
            state.debugApplyRemoteConversationsForTesting([remoteConversation])
            let summary = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first { $0.id == "friend-1:uid-1" })
            XCTAssertEqual(summary.time, expectedDisplay)
            XCTAssertEqual(summary.lastMsgSeq, 81)
            let summarizedMessage = try XCTUnwrap(summary.messages.first { $0.id == remote.messageID })
            XCTAssertEqual(summarizedMessage.createdAt, mapped.createdAt)
            XCTAssertEqual(summarizedMessage.channelSeq, 81)
        }
    }

    func testRTCMessageWithInvalidTypedTimesCannotInventHistoricalDisplay() throws {
        let state = makeHistoricalRTCTestState()
        var object = historicalRTCMessageObject(outer: "bad-time")
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["ended_at"] = "2026-08-23T23:58:00Z"
        object["payload"] = payload
        let remote = try JSONDecoder().decode(RemoteMessage.self, from: JSONSerialization.data(withJSONObject: object))
        let mapped = state.debugChatMessageForTesting(remote)
        XCTAssertNil(mapped.rtcCallRecord)
        XCTAssertNil(mapped.createdAt)
        XCTAssertEqual(mapped.channelSeq, 81)
        XCTAssertEqual(mapped.time, "时间未知")
    }

    func testDelayedRTCReconciliationUsesServerHistoryAndIgnoresTerminalReplays() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "delayed-terminal")
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "foreign-call", stateVersion: 99))
        XCTAssertEqual(state.activeVoiceCall?.callID, "delayed-terminal")
        XCTAssertTrue(state.calls.isEmpty)

        let terminal = historicalRTCRemoteCall(callID: "delayed-terminal")
        state.reconcileRTCCallsForTesting([terminal])
        XCTAssertNil(state.activeVoiceCall)
        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.callID, "delayed-terminal")
        XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp(terminal.startedAt))
        XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp(terminal.endedAt))
        XCTAssertNil(record.durationSeconds, "RemoteRTCCall has no media-connected time or duration contract")
        XCTAssertEqual(record.stateVersion, 8)
        XCTAssertNotEqual(record.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(record.time, "刚刚")
        let established = state.calls

        state.reconcileRTCCallsForTesting([terminal])
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
            callID: "delayed-terminal", started: "2026-08-20T00:00:00Z", ended: "2026-08-20T00:01:00Z", stateVersion: 7
        )])
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "delayed-terminal", stateVersion: 7))
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "foreign-call", stateVersion: 99))
        XCTAssertEqual(state.calls, established)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
    }

    func testDelayedRTCIncomingRawTerminalKeepsServerTimesAndUnknownDuration() throws {
        let state = makeHistoricalRTCTestState()
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-local", callID: "incoming-terminal",
            caller: makeUser(id: "friend-1", name: "Friend"), startedAt: "刚刚", source: "好友视频通话",
            requestedMediaMode: "video", stateVersion: 7
        )
        let terminal = historicalRTCTerminalEnvelope(callID: "incoming-terminal")
        state.debugHandleRealtimeEnvelopeForTesting(terminal)
        XCTAssertNil(state.incomingVoiceCall)
        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
        XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        XCTAssertNil(record.durationSeconds)
        XCTAssertEqual(record.stateVersion, 8)
        XCTAssertEqual(record.callType, "视频通话")
        let established = state.calls
        state.debugHandleRealtimeEnvelopeForTesting(terminal)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "incoming-terminal", stateVersion: 6))
        XCTAssertEqual(state.calls, established)
    }

    func testRTCTerminalMissingOrInvalidTimesRemainUnknownAcrossReconcileAndRawEvents() throws {
        let cases = [("", ""), ("bad-start", "bad-end"), ("2026-08-24T00:02:00Z", "2026-08-24T00:01:00Z")]
        for (started, ended) in cases {
            for rawEvent in [false, true] {
                let state = makeHistoricalRTCTestState()
                state.activeVoiceCall = historicalRTCActiveSession(callID: "unknown-history")
                if rawEvent {
                    state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(
                        callID: "unknown-history", started: started, ended: ended
                    ))
                } else {
                    state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
                        callID: "unknown-history", started: started, ended: ended
                    )])
                }
                let record = try XCTUnwrap(state.calls.first)
                XCTAssertNil(state.activeVoiceCall)
                XCTAssertNil(record.startedAt, "rawEvent=\(rawEvent)")
                XCTAssertNil(record.endedAt, "rawEvent=\(rawEvent)")
                XCTAssertNil(record.durationSeconds)
                XCTAssertEqual(record.time, "时间未知")
            }
        }
    }

    // WDT_IOS1_CALL_DURATION_20261023_BEGIN
    func testRTCHistoryDurationInputRejectsUnsafeRoundTripAndKeepsNormalValues() throws {
        let invalid: [JSONValue] = [.int(Int.max), .string(String(Int.max)), .double(Double(Int.max)),
            .double(.nan), .double(.infinity), .double(-.infinity), .int(9_007_199_254_740_993), .int(-1)]
        let normal: [JSONValue] = [0, 61, 3661].flatMap { [.int($0), .string(String($0)), .double(Double($0))] }
        for (index, value) in (invalid + normal).enumerated() {
            let state = makeHistoricalRTCTestState()
            let id = "duration-boundary-\(index)"
            state.activeVoiceCall = historicalRTCActiveSession(callID: id)
            let source = historicalRTCTerminalEnvelope(callID: id)
            var payload = source.payload
            var call = try XCTUnwrap(payload["call"]?.objectValue)
            call["media_connected_at"] = .string("2026-08-23T23:59:45Z")
            call["duration_seconds"] = value
            payload["call"] = .object(call)
            state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(type: source.type, requestID: source.requestID, payload: payload))
            let record = try XCTUnwrap(state.calls.first)
            if index < invalid.count {
                XCTAssertNil(record.durationSeconds, "Invalid input at index \(index) must remain unknown")
                XCTAssertEqual(RTCCallRecordTimeProjection.durationText(seconds: record.durationSeconds), "未记录")
            } else {
                let expected = Double([0, 61, 3661][(index - invalid.count) / 3])
                XCTAssertEqual(record.durationSeconds, expected)
            }
        }
    }
    // WDT_IOS1_CALL_DURATION_20261023_END

    func testRTCRawTerminalDurationUsesMediaConnectionNotSignalAnswerOrLocalClock() throws {
        for suppliedDuration in [nil, 117] as [Int?] {
            let state = makeHistoricalRTCTestState()
            state.activeVoiceCall = historicalRTCActiveSession(callID: "media-history")
            let source = historicalRTCTerminalEnvelope(callID: "media-history")
            var payload = source.payload
            var call = try XCTUnwrap(payload["call"]?.objectValue)
            call["media_connected_at"] = .string("2026-08-23T23:59:45Z")
            if let suppliedDuration { call["duration_seconds"] = .int(suppliedDuration) }
            payload["call"] = .object(call)
            state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(type: source.type, requestID: source.requestID, payload: payload))
            let record = try XCTUnwrap(state.calls.first)
            XCTAssertEqual(record.durationSeconds, suppliedDuration.map(TimeInterval.init) ?? 120)
            XCTAssertEqual(record.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        }
    }

    func testRTCUnknownTerminalTimeCanRefineOnceWithoutAcceptingOlderOrConflictingHistory() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "refine-history")
        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "refine-history")
        let unknown = try XCTUnwrap(state.calls.first)
        XCTAssertNil(unknown.endedAt)
        XCTAssertNil(unknown.durationSeconds)
        XCTAssertEqual(unknown.time, "时间未知")

        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(callID: "refine-history", stateVersion: 6)])
        XCTAssertEqual(state.calls.first, unknown)
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(callID: "refine-history", stateVersion: 7)])
        let canonical = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(canonical.startedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-23T23:59:00Z"))
        XCTAssertEqual(canonical.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
        XCTAssertEqual(canonical.endReason, "caller_hangup")
        XCTAssertNil(canonical.durationSeconds)
        state.reconcileRTCCallsForTesting([historicalRTCRemoteCall(
            callID: "refine-history", ended: "2026-08-25T00:01:45Z", stateVersion: 8
        )])
        XCTAssertEqual(state.calls.first, canonical)
    }

    func testRTCOlderTerminalCannotEndNewerActiveLifecycleOrPersistHistory() throws {
        let state = makeHistoricalRTCTestState()
        state.activeVoiceCall = historicalRTCActiveSession(callID: "versioned-history")
        XCTAssertEqual(state.callStore.claimLifecycle(
            scopeID: "isolated-rtc-test", callID: "versioned-history", direction: .outgoing, stateVersion: 7
        )?.isApplied, true)
        XCTAssertEqual(state.callStore.advanceLifecycle(
            callID: "versioned-history", to: .connected, stateVersion: 7
        )?.isApplied, true)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "versioned-history", stateVersion: 6))
        XCTAssertEqual(state.activeVoiceCall?.callID, "versioned-history")
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.revision, 7)
        XCTAssertTrue(state.calls.isEmpty)
        state.debugHandleRealtimeEnvelopeForTesting(historicalRTCTerminalEnvelope(callID: "versioned-history", stateVersion: 8))
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.calls.first?.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-08-24T00:01:45Z"))
    }

    private func makeHistoricalRTCTestState() -> AppState {
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.calls = []
        return state
    }

    private func historicalRTCActiveSession(callID: String) -> VoiceCallSession {
        VoiceCallSession(
            id: "local-\(callID)", callID: callID, peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出", startedAt: "刚刚", statusText: "通话中", mediaState: .connected,
            isMuted: false, speakerOn: true, startedAtDate: Date(timeIntervalSince1970: 100),
            connectedAt: Date(timeIntervalSince1970: 120), requestedMediaMode: "video", mediaMode: "video", stateVersion: 7
        )
    }

    private func historicalRTCRemoteCall(
        callID: String, started: String = "2026-08-23T23:59:00Z",
        ended: String = "2026-08-24T00:01:45Z", stateVersion: Int64 = 8
    ) -> RemoteRTCCall {
        RemoteRTCCall(
            id: callID, status: "ended", callerUID: "friend-1", calleeUID: "uid-1",
            callType: "video", requestedMediaMode: "video", mediaMode: "video",
            createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-02T12:00:00Z",
            startedAt: started, acceptedAt: "2026-08-23T23:59:20Z", endedAt: ended,
            endReason: "caller_hangup", stateVersion: stateVersion
        )
    }

    private func historicalRTCTerminalEnvelope(
        callID: String, started: String = "2026-08-23T23:59:00Z",
        ended: String = "2026-08-24T00:01:45Z", stateVersion: Int = 8
    ) -> RealtimeEnvelope {
        RealtimeEnvelope(type: "rtc.call.ended", requestID: "history-\(callID)-\(stateVersion)", payload: [
            "event": .string("rtc.call.ended"),
            "call": .object([
                "id": .string(callID), "status": .string("ended"), "caller_uid": .string("friend-1"),
                "callee_uid": .string("uid-1"), "call_type": .string("video"), "requested_media_mode": .string("video"),
                "media_mode": .string("video"), "state_version": .int(stateVersion), "end_reason": .string("caller_hangup"),
                "started_at": .string(started), "accepted_at": .string("2026-08-23T23:59:20Z"), "ended_at": .string(ended),
                "created_at": .string("2026-09-01T12:00:00Z"), "updated_at": .string("2026-09-02T12:00:00Z")
            ])
        ])
    }

    func historicalRTCMessageObject(outer: String?) -> [String: Any] {
        var message: [String: Any] = [
            "message_id": "historical-rtc-message", "channel_id": "friend-1:uid-1", "channel_type": "direct",
            "channel_seq": 81, "from_uid": "friend-1", "content_type": "rtc_call_record", "status": "sent",
            "updated_at": "2026-09-02T12:00:00Z", "received_at": "2026-09-03T12:00:00Z",
            "payload": [
                "schema_version": 1, "call_id": "historical-rtc-call", "call_type": "video",
                "caller_uid": "friend-1", "callee_uid": "uid-1", "final_outcome": "completed",
                "started_at": "2026-08-23T23:59:00Z", "answered_at": "2026-08-23T23:59:20Z",
                "media_connected_at": "2026-08-23T23:59:45Z", "ended_at": "2026-08-24T00:01:45Z",
                "duration_seconds": 120, "end_actor_uid": "friend-1", "reason_code": "completed",
                "text": "视频通话已结束", "fallback_text": "通话记录"
            ] as [String: Any]
        ]
        if let outer { message["created_at"] = outer }
        return message
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
