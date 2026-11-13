import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    func testRemoteRTCCallEventPreservesFlatVideoIntentRevisionAndDevices() throws {
        let data = """
        {
          "notification_id": "notification-flat-video-1",
          "event": "rtc.call.ringing",
          "call_id": "call-flat-video",
          "caller_uid": "friend-1",
          "callee_uid": "me",
          "call_type": "video",
          "requested_media_mode": "video",
          "media_mode": "audio",
          "state_version": 4,
          "caller_device_id": "web-caller",
          "callee_device": { "device_id": "ios-callee" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RemoteRTCCallEvent.self, from: data)

        XCTAssertEqual(event.payload["call_type"]?.stringValue, "video")
        XCTAssertEqual(event.payload["requested_media_mode"]?.stringValue, "video")
        XCTAssertEqual(event.payload["media_mode"]?.stringValue, "audio")
        XCTAssertEqual(event.payload["state_version"]?.stringValue, "4")
        XCTAssertEqual(event.payload["caller_device_id"]?.stringValue, "web-caller")
        XCTAssertEqual(
            event.payload["callee_device"]?.objectValue?["device_id"]?.stringValue,
            "ios-callee"
        )
    }

    @MainActor
    func testNestedRealtimeVideoRingingPreservesRequestedCallType() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [makeUser(id: "friend-1", name: "Friend")]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "rtc_call",
                requestID: "nested-video-ringing",
                payload: [
                    "rtc_call": .object([
                        "event": .string("rtc.call.ringing"),
                        "call_type": .string("audio"),
                        "requested_media_mode": .string("audio"),
                        "call": .object([
                            "id": .string("call-nested-video"),
                            "status": .string("ringing"),
                            "caller_uid": .string("friend-1"),
                            "callee_uid": .string("uid-1"),
                            "room_id": .string("room-nested-video"),
                            "channel_id": .string("friend-1:uid-1"),
                            "call_type": .string("video"),
                            "requested_media_mode": .string("video"),
                            "media_mode": .string("audio")
                        ])
                    ])
                ]
            )
        )

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-nested-video")
        XCTAssertTrue(state.incomingVoiceCall?.isVideo == true)
        XCTAssertEqual(state.incomingVoiceCall?.source, "好友视频通话")
    }

    @MainActor
    func testAcceptedEventForLosingCalleeDeviceEndsOnlyLocalCallWithoutStartingMedia() throws {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.receiveIncomingVoiceCall(from: caller, callID: "call-device-winner",
            roomID: "room-device-winner", mediaMode: "video")
        // A presented incoming call has not started a local answer operation.
        // Installing a connecting active session would describe an in-flight
        // answer, which the existing accepted-elsewhere fence must preserve.
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-device-winner")

        state.debugHandleRealtimeEnvelopeForTesting(
            RealtimeEnvelope(
                type: "rtc.call.accepted",
                requestID: "accepted-on-other-device",
                payload: [
                    "event": .string("rtc.call.accepted"),
                    "call": .object([
                        "id": .string("call-device-winner"),
                        "status": .string("accepted"),
                        "caller_uid": .string("friend-1"),
                        "callee_uid": .string("uid-1"),
                        "call_type": .string("video"),
                        "requested_media_mode": .string("video"),
                        "media_mode": .string("video"),
                        "state_version": .int(2),
                        "delivery_context": .object([
                            "schema": .string("rtc-call-delivery-v1"),
                            "viewer_role": .string("callee"),
                            "viewer_is_bound_participant": .bool(false)
                        ])
                    ])
                ]
            )
        )

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.callID, "call-device-winner")
        XCTAssertEqual(state.calls.first?.status, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.endReason, "answered_elsewhere")
        XCTAssertEqual(videoClient.startCount, 0)
    }

    @MainActor
    func testAcceptedPollingForLosingCalleeDeviceDoesNotStartMedia() async throws {
        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_BEGIN
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let videoClient = TestVideoMediaClient()
        let voiceClient = TestVoiceMediaClient()
        let suite = "core-fixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let callStore = CallStore(callRecordStore: UserDefaultsCallRecordStore(defaults: defaults,
            storageKey: "fixture.callRecords", archiveURL: root.appendingPathComponent("call-records.json")))
        let context = makeAuthenticatedAPIContext(accountID: UUID().uuidString)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context
        )
        let state = AppState(api: api,
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: voiceClient, videoMediaClient: videoClient,
            callStore: callStore, messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        state.suppressCurrentUserIdentityPersistence = true
        defer {
            state.clearRTCTerminalCompensationsForScopeReset()
            callStore.clearCallRecordPersistenceBinding()
        }
        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_END
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-polled-other-device",
            roomID: "room-polled-other-device",
            mediaMode: "video"
        )

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-polled-other-device",
                status: "accepted",
                roomID: "room-polled-other-device",
                callerUID: "friend-1",
                calleeUID: "uid-1",
                channelID: "friend-1:uid-1",
                channelType: "direct",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                acceptedDevice: RemoteRTCDevice(
                    uid: "uid-1",
                    deviceID: "another-device",
                    deviceType: "ios"
                ),
                stateVersion: 3
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "已在其他设备接听")
        XCTAssertEqual(state.calls.first?.endReason, "answered_elsewhere")
        XCTAssertEqual(videoClient.startCount, 0)

        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_BEGIN
        // Exercise the historical unavailable-media branch separately from the
        // losing-device assertions, through the same AppState and local API.
        XCTAssertTrue(transport.requests().isEmpty)
        state.voiceMediaClientAvailableOverride = false
        let rejectedCallID = "fixture-polled-other-device-unavailable"
        state.receiveIncomingVoiceCall(from: caller, callID: rejectedCallID, mediaMode: "video")
        let rejectPath = "/api/rtc/calls/\(rejectedCallID)/reject"
        for _ in 0..<100 {
            if transport.requests().contains(where: { $0.url?.path == rejectPath }),
               state.rtcTerminalCompensationsInFlightCountForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = transport.requests()
        XCTAssertEqual(requests.compactMap { $0.url?.path }, [rejectPath])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 0)
        XCTAssertNil(state.pendingRTCTerminalCompensations[rejectedCallID])
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertTrue(voiceClient.startedContexts.isEmpty)
        XCTAssertEqual(videoClient.startCount, 0)
        let evidence = XCTAttachment(string: "answered_elsewhere: no request\nPOST \(rejectPath): local response")
        evidence.name = "core-fixture-rtc-requests"
        evidence.lifetime = .keepAlways
        add(evidence)
        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_END
    }

    func testIncomingCallAdmissionDeduplicatesOneCallAndRejectsSecondWhileBusy() {
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-1",
                isRinging: true,
                presentedCallIDs: []
            ),
            .accept
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-1",
                isRinging: true,
                presentedCallIDs: ["call-1"]
            ),
            .duplicate
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: "call-2",
                isRinging: true,
                presentedCallIDs: ["call-1"]
            ),
            .busy
        )
        XCTAssertEqual(
            IncomingCallAdmissionPolicy.resolve(
                callID: " ",
                isRinging: true,
                presentedCallIDs: []
            ),
            .invalid
        )
    }

    @MainActor
    func testLoginRTCPollAcknowledgesClosedVideoCallWithoutShowingIt() async throws {
        for reversed in [false, true] {
            let ringing = loginRTCPollEvent(id: "old-video", status: "ringing", revision: 1)
            let canceled = loginRTCPollEvent(id: "old-video", status: "canceled", revision: 2)
            let batch = try loginRTCPollResponse(reversed ? [canceled, ringing] : [ringing, canceled])
            let transport = FakeHTTPTransport(results: [
                batch, successfulEmptyAPIResponse(), batch, successfulEmptyAPIResponse()
            ])
            let state = makeLoginRTCPollState(transport: transport)
            var presented: [String] = []
            let observation = state.callStore.$incomingVoiceCall.sink {
                if let callID = $0?.callID { presented.append(callID) }
            }
            defer { observation.cancel() }

            await state.refreshRTCCallEventsForTesting()
            await state.refreshRTCCallEventsForTesting()

            XCTAssertTrue(presented.isEmpty, "an old ringing event must never briefly present")
            XCTAssertNil(state.incomingVoiceCall)
            XCTAssertNil(state.activeVoiceCall)
            XCTAssertNil(state.videoCallTerminalResult)
            XCTAssertNil(state.toast)
            XCTAssertEqual(state.calls.map(\.callID), ["old-video"])
            XCTAssertEqual(state.calls.first?.status, "已取消")
            XCTAssertEqual(state.calls.first?.direction, .incoming)
            XCTAssertEqual(state.calls.first?.stateVersion, 2)
            XCTAssertEqual(state.calls.first?.endedAt, RTCCallRecordTimeProjection.parseServerTimestamp("2026-11-07T10:11:02Z"))

            let acknowledgements = transport.requests().filter { $0.url?.path == "/api/rtc/calls/events/ack" }
            XCTAssertEqual(acknowledgements.count, 2)
            for ack in acknowledgements {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ack.httpBody)) as? [String: Any])
                XCTAssertEqual(Set(body["notification_ids"] as? [String] ?? []), ["old-video-ringing", "old-video-canceled"])
            }
        }
    }

    @MainActor
    func testLoginRTCPollStillShowsDistinctLiveVideoCallAndKeepsItsRecordIfCanceled() async throws {
        let transport = FakeHTTPTransport(results: [
            try loginRTCPollResponse([
                loginRTCPollEvent(id: "old-video", status: "ringing", revision: 1),
                loginRTCPollEvent(id: "old-video", status: "canceled", revision: 2),
                loginRTCPollEvent(id: "new-video", status: "ringing", revision: 3)
            ]),
            successfulEmptyAPIResponse()
        ])
        let state = makeLoginRTCPollState(transport: transport)
        var presented: [String] = []
        let observation = state.callStore.$incomingVoiceCall.sink {
            if let callID = $0?.callID { presented.append(callID) }
        }
        defer { observation.cancel() }

        await state.refreshRTCCallEventsForTesting()
        XCTAssertEqual(Set(presented), ["new-video"])
        XCTAssertEqual(state.incomingVoiceCall?.callID, "new-video")
        XCTAssertEqual(state.incomingVoiceCall?.isVideo, true)
        XCTAssertNil(state.videoCallTerminalResult)

        let cancellation = loginRTCPollEvent(id: "new-video", status: "canceled", revision: 4)
        let event = try JSONDecoder().decode(RemoteRTCCallEvent.self, from: JSONSerialization.data(withJSONObject: cancellation))
        XCTAssertTrue(state.handleRTCCallEvent(RealtimeEnvelope(type: event.type, requestID: nil, payload: event.payload)))
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.videoCallTerminalResult, "an unanswered incoming call should not open a result screen")
        XCTAssertEqual(state.calls.first?.callID, "new-video")
        XCTAssertEqual(state.calls.first?.status, "已取消")
    }

    private func makeLoginRTCPollState(transport: HTTPTransport) -> AppState {
        let state = AppState(
            api: makeCallEndingAPI(transport: transport), voiceMediaClient: NoopVoiceMediaClient(),
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext(accountID: "rtc-login-\(UUID())")
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [makeUser(id: "friend-1", name: "Friend")]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(
            maxBytes: 20 * 1024 * 1024, maxMB: 20, source: "test", messageRecallMaxMinutes: 120,
            voiceCallEnabled: true, videoCallEnabled: true, readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false
        )
        return state
    }

    private func loginRTCPollEvent(id: String, status: String, revision: Int) -> [String: Any] {
        var call: [String: Any] = [
            "call_id": id, "status": status, "state_version": revision, "room_id": "room-\(id)",
            "caller_uid": "friend-1", "callee_uid": "uid-1", "channel_id": "uid-1:friend-1",
            "call_type": "video", "requested_media_mode": "video", "started_at": "2026-11-07T10:11:00Z"
        ]
        if status == "canceled" { call["ended_at"] = "2026-11-07T10:11:02Z" }
        return ["type": "rtc.call.\(status)", "notification_id": "\(id)-\(status)", "payload": ["call": call]]
    }

    private func loginRTCPollResponse(_ events: [[String: Any]]) throws -> HTTPTransportResult {
        HTTPTransportResult(
            data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["events": events]]),
            isHTTPResponse: true, statusCode: 200
        )
    }

    @MainActor
    func testAppStateRTCCallsReconcileShowsRingingWhenTerminalCallIsAlsoReturned() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "陈星")
        let caller = makeUser(id: "WXT00000003", name: "孟瑶")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.activeVoiceCall = VoiceCallSession(
            id: "voice-old-call",
            callID: "call-old",
            peer: caller,
            direction: "呼出",
            startedAt: "刚刚",
            isMuted: false,
            speakerOn: true
        )

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-old",
                status: "canceled",
                roomID: "room-old",
                callerUID: "WXT00000002",
                calleeUID: "WXT00000003",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            ),
            RemoteRTCCall(
                id: "call-new",
                status: "ringing",
                roomID: "room-new",
                callerUID: "WXT00000003",
                calleeUID: "WXT00000002",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-new")
        XCTAssertEqual(state.incomingVoiceCall?.caller.id, "WXT00000003")
    }

    @MainActor
    func testAppStateIncomingVoiceCallDuplicateEventKeepsExistingBanner() throws {
        let state = AppState()
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")
        let firstIncomingID = state.incomingVoiceCall?.id

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")

        XCTAssertNotNil(firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.id, firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
    }

    @MainActor
    func testAppStateForegroundCallKitRingtoneStillKeepsOneInAppCallCard() throws {
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["call-1"])
        let state = AppState(voiceCallSystem: system)
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertTrue(system.started)
        XCTAssertTrue(system.hasPresentedCall(callID: "call-1"))
    }

    @MainActor
    func testAppStateForegroundIncomingVoiceCallUsesInAppPresentationWithoutCallKit() throws {
        let system = TestVoiceCallSystemIntegration()
        let state = AppState(voiceCallSystem: system, apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: friend, callID: "call-1", roomID: "room-1")

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertFalse(state.incomingVoiceCall?.isVideo ?? true)
        XCTAssertTrue(system.reportedPayloads.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: "call-1"))
    }

    func testAppStateForegroundVideoCallUsesInAppPresentationWithoutCallKit() throws {
        let system = TestVoiceCallSystemIntegration()
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            voiceCallSystem: system,
            apiContextOverride: makeIsolatedAPIContext()
        )
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(
            maxBytes: 20 * 1024 * 1024,
            maxMB: 20,
            source: "test",
            messageRecallMaxMinutes: 120,
            voiceCallEnabled: true,
            videoCallEnabled: true,
            readReceiptsEnabled: true,
            groupAdminDeleteMessageEnabled: false
        )

        state.receiveIncomingVoiceCall(
            from: friend,
            callID: "video-call-1",
            roomID: "video-room-1",
            mediaMode: "video"
        )

        XCTAssertEqual(state.incomingVoiceCall?.callID, "video-call-1")
        XCTAssertTrue(state.incomingVoiceCall?.isVideo ?? false)
        XCTAssertTrue(system.reportedPayloads.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: "video-call-1"))
    }

    @MainActor
    func testSecondIncomingCallRejectsServerExactlyOnceWhileFirstCallRemainsVisible() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = makeCallEndingAPI(transport: transport)
        let system = TestVoiceCallSystemIntegration(
            presentedCallIDs: ["call-first", "call-second"]
        )
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/call-second/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/call-second/reject"), 1)
        XCTAssertEqual(system.endedCalls.map(\.callID), ["call-second"])
        XCTAssertEqual(system.endedCalls.map(\.reason), ["client_busy"])
        XCTAssertTrue(system.hasPresentedCall(callID: "call-first"))
        XCTAssertFalse(system.hasPresentedCall(callID: "call-second"))
    }

    @MainActor
    func testTerminalCompensationFailuresDoNotScheduleOtherInFlightCalls() async throws {
        let a = "/api/rtc/calls/call-a/reject"
        let b = "/api/rtc/calls/call-b/reject"
        let transport = RTCSystemEndHTTPTransport(
            remainingFailuresByPath: [a: 1000, b: 1000],
            failureDelayNanoseconds: 1_000_000
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            rtcTerminalCompensationFailureDelayNanoseconds: [500_000_000],
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        defer { state.clearRTCTerminalCompensationsForTesting() }
        let first = makeUser(id: "friend-first")
        let other = makeUser(id: "friend-other")
        state.setCurrentUser(makeUser(id: "uid-1")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [first, other]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: other, callID: "call-a")
        state.receiveIncomingVoiceCall(from: other, callID: "call-b")
        for _ in 0..<100 where state.rtcTerminalCompensationsInFlightCountForTesting > 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 0)
        let before = transport.requestCount(path: a) + transport.requestCount(path: b)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(before, 2)
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requestCount(path: a) + transport.requestCount(path: b), before)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        // Refresh/retry triggers before nextAttemptAt must not bypass the independent backoff timer.
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        state.retryPendingRTCTerminalCompensationsForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 0)
        XCTAssertEqual(transport.requestCount(path: a) + transport.requestCount(path: b), before)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
    }

    @MainActor
    func testBusyRejectTerminalCompensationRetriesAfterTransportRecoveryAndClearsIntent() async throws {
        let path = "/api/rtc/calls/call-second/reject"
        let transport = RTCSystemEndHTTPTransport(
            remainingFailuresByPath: [path: 1],
            failureDelayNanoseconds: 50_000_000
        )
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            rtcTerminalCompensationFailureDelayNanoseconds: [10_000_000],
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        defer { state.clearRTCTerminalCompensationsForTesting() }
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: path) == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcTerminalCompensationsInFlightCountForTesting, 1)
        await state.refreshRTCCallsForTesting()
        for _ in 0..<100 where transport.requestCount(path: path) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: path), 2)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        let keys = transport.idempotencyKeys(path: path)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1)
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-first")
    }

    @MainActor
    func testTerminalCompensationScopeResetDropsOldIntentAndPreventsRetry() async throws {
        let path = "/api/rtc/calls/call-second/reject"
        let transport = RTCSystemEndHTTPTransport(remainingFailuresByPath: [path: 10])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let first = makeUser(id: "friend-1", name: "Friend One")
        let second = makeUser(id: "friend-2", name: "Friend Two")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [first, second]
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: first, callID: "call-first")
        state.receiveIncomingVoiceCall(from: second, callID: "call-second")
        for _ in 0..<100 where transport.requestCount(path: path) == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.clearRTCTerminalCompensationsForTesting()
        state.retryPendingRTCTerminalCompensationsForTesting()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
        XCTAssertEqual(transport.requestCount(path: path), 1)
    }

    @MainActor
    func testCallKitPresentedVideoAdmissionFailureEndsSystemCallAndRejectsServerOnce() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["video-unavailable"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: NoopVideoMediaClient(),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "video-unavailable",
            mediaMode: "video",
            systemOwnsRingtone: true
        )
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-unavailable/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertFalse(system.hasPresentedCall(callID: "video-unavailable"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-unavailable/reject"), 1)
    }

    @MainActor
    func testCallKitAnswerProviderFailureRollsBackSystemAndRejectsServerCall() async throws {
        for videoAsAudio in [false, true] {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["answer-failure"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "answer-failure",
            roomID: "answer-room",
            systemOwnsRingtone: true
        )
        if videoAsAudio {
            state.incomingVoiceCall = IncomingVoiceCall(id: "answer-failure", callID: "answer-failure",
                caller: caller, startedAt: "刚刚", source: "系统视频来电", requestedMediaMode: "video")
        }

        state.handleVoiceCallSystemEventForTesting(.answer(callID: "answer-failure"))
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/answer-failure/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(system.hasPresentedCall(callID: "answer-failure"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/answer-failure/reject"), 1)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/answer-failure/accept"), 0)
        }
    }

    @MainActor
    func testAcceptedVideoCallOnColdLaunchAuthoritativelyTerminatesWhenResumeIsUnsupported() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["accepted-video"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "accepted-video",
                status: "accepted",
                roomID: "room-accepted-video",
                callerUID: "uid-1",
                calleeUID: "friend-1",
                channelID: "uid-1:friend-1",
                channelType: "direct",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                callerDevice: RemoteRTCDevice(uid: "uid-1", deviceID: "unit-test-device", deviceType: "ios"),
                acceptedDevice: RemoteRTCDevice(uid: "friend-1", deviceID: "peer-device", deviceType: "ios"),
                stateVersion: 9
            )
        ])
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/accepted-video/hangup") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.toast, "视频通话因应用重启已安全结束")
        XCTAssertFalse(system.hasPresentedCall(callID: "accepted-video"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/accepted-video/hangup"), 1)
    }
}
