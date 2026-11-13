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
    @MainActor
    func testIncomingVoiceAcceptAttemptCannotReviveAcrossSameScopeLicenseABA() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-license-aba",
            callID: "incoming-voice-license-aba",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let abaPermissionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(abaPermissionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: false,
            videoEnabled: true
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        await permissionDecision.resume(returning: true)
        for _ in 0..<30 {
            await Task.yield()
        }

        XCTAssertEqual(state.incomingVoiceCall?.id, incoming.id)
        XCTAssertEqual(state.incomingVoiceCall?.callID, incoming.callID)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-license-aba/accept"),
            0
        )
    }

    @MainActor
    func testIncomingVoiceOldPermissionCallbackCannotOwnSameScopeReplacementSession() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-session-replaced",
            callID: "incoming-voice-session-replaced",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        recordCallsAcceptanceDiagnostic(self, state: state, stage: "voice-permission-entry", counts: transport.callsAcceptancePathCounts())
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "voice-permission-exit", counts: transport.callsAcceptancePathCounts()) }
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let replacementPermissionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(replacementPermissionIsWaiting)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = incoming

        await permissionDecision.resume(returning: true)
        for _ in 0..<30 {
            await Task.yield()
        }

        XCTAssertEqual(state.incomingVoiceCall?.id, incoming.id)
        XCTAssertEqual(state.incomingVoiceCall?.callID, incoming.callID)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-session-replaced/accept"),
            0
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    @MainActor
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: accepted callee appID may be missing on Android; device remains authoritative.
    func testOutgoingV1RequiresAuthoritativeWinningDevice() throws {
        func snapshot(status: String = "accepted", app: String = "callee-app", device: String = "winner", version: Int64 = 2) -> RemoteRTCCall {
            RemoteRTCCall(id: "call", status: status, roomID: "room", callerUID: "caller", calleeUID: "callee",
                callerDevice: RemoteRTCDevice(uid: "caller", deviceID: "self-device", appID: "caller-app"),
                acceptedDevice: RemoteRTCDevice(uid: "callee", deviceID: device, appID: app), stateVersion: version)
        }
        func permits(_ call: RemoteRTCCall?, localApp: String = "caller-app", localDevice: String = "self-device", id: String = "call", room: String = "room") -> Bool {
            AppState.hasBoundAcceptedOutgoingCall(call, callID: id, roomID: room,
                callerUID: "caller", callerDeviceID: localDevice, callerAppID: localApp,
                calleeUID: "callee", minimumStateVersion: 2)
        }
        XCTAssertTrue(permits(snapshot()))
        XCTAssertFalse(permits(nil))
        for status in ["ringing", "canceled", "ended", "timed_out", "rejected"] { XCTAssertFalse(permits(snapshot(status: status))) }
        XCTAssertTrue(permits(snapshot(app: "")))
        XCTAssertFalse(permits(snapshot(device: "")))
        XCTAssertFalse(permits(snapshot(version: 1)))
        XCTAssertFalse(permits(snapshot(), localApp: "another-app"))
        XCTAssertFalse(permits(snapshot(), localDevice: "another-device"))
        XCTAssertFalse(permits(snapshot(), id: "later-call"))
        XCTAssertFalse(permits(snapshot(), room: "later-room"))
        let decoded = try JSONDecoder().decode(RemoteRTCDevice.self,
            from: Data(#"{"uid":"callee","device_id":"winner","app_id":"callee-app"}"#.utf8))
        XCTAssertEqual(decoded.appID, "callee-app")
        XCTAssertTrue(AppState.isRTCTransportPolicyPending(IMAPIError.conflict(code: "rtc_transport_policy_pending", message: "pending")))
        XCTAssertFalse(AppState.isRTCTransportPolicyPending(IMAPIError.conflict(code: "callee_busy", message: "busy")))
        XCTAssertFalse(AppState.isRTCTransportPolicyPending(CancellationError()))
    }
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END

    @MainActor
    func testOutgoingV1AudioAndVideoWaitWithoutJoinAndDoNotCancelPendingAcceptance() async throws {
        for video in [false, true] {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, outgoingPolicyFixture: true)
            let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, httpTransport: transport)
            let state = AppState(api: api, voiceMediaClient: TestVoiceMediaClient(events: []),
                videoMediaClient: TestVideoMediaClient(), microphonePermissionDecisionOverride: { true },
                apiContextOverride: makeAuthenticatedAPIContext())
            let peer = makeUser(id: "policy-peer", name: "Peer")
            state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            if video { state.startOutgoingVideoCall(to: peer, cameraEnabled: false) }
            else { state.startOutgoingVoiceCall(to: peer) }
            for _ in 0..<200 where state.activeVoiceCall == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(state.activeVoiceCall?.callID, "policy-call")
            XCTAssertTrue(state.activeVoiceCall?.requiresAcceptedDeviceBeforeJoin == true)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/rooms/policy-room/join"), 0)
            let payload: [String: JSONValue] = ["call": .object([
                "id": .string("policy-call"), "room_id": .string("policy-room"), "status": .string("accepted"),
                "caller_uid": .string("uid-1"), "callee_uid": .string(peer.id), "state_version": .int(2),
                "caller_device": .object(["uid": .string("uid-1"), "device_id": .string("unit-test-device"), "app_id": .string(IMAPIContext.canonicalIOSAppID)]),
                "accepted_device": .object(["uid": .string(peer.id), "device_id": .string("winning-device"), "app_id": .string("callee-app")])
            ])]
            state.debugHandleRealtimeEnvelopeForTesting(RealtimeEnvelope(type: "rtc.call.accepted", requestID: nil, payload: payload))
            for _ in 0..<200 where transport.requestCount(path: "/api/rtc/rooms/policy-room/join") == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/rooms/policy-room/join"), 1)
            XCTAssertEqual(state.activeVoiceCall?.callID, "policy-call")
            XCTAssertNotEqual(state.activeVoiceCall?.mediaState, .failed)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/policy-call/cancel"), 0)
            state.activeVoiceCall = nil
        }
    }

    @MainActor
    func testOutgoingVideoDelayedProviderStageCannotPolluteNextLicenseGeneration() async throws {
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 150_000_000,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "video-delayed-provider-peer", name: "Video Peer")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.videoCallPreview = VideoCallPreview(
            id: "video-delayed-provider-old",
            peer: peer,
            channelID: "uid-1:video-delayed-provider-peer",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )

        state.startOutgoingVideoCallFromPreview()
        for _ in 0..<200 where transport.requestCount(path: "/api/tenant/files/config") == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 1)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.videoCallPreview = VideoCallPreview(
            id: "video-delayed-provider-new",
            peer: peer,
            channelID: "uid-1:video-delayed-provider-peer",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(state.videoCallPreview?.id, "video-delayed-provider-new")
        XCTAssertNil(state.videoCallPreview?.startError)
        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
    }

    @MainActor
    func testIncomingVideoAcceptClearsRevokedCallWhenMicrophoneDecisionReturnsDenied() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-permission-denied",
            callID: "incoming-video-permission-denied",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let microphoneDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(microphoneDecisionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        await permissionDecision.resume(returning: false)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-permission-denied/accept"),
            0
        )
    }

    @MainActor
    func testVideoPreviewRevocationClearsPendingPermissionAndCannotRestoreStalePreview() async throws {
        let permissionDecision = SuspendedBoolDecision()
        let videoClient = TestVideoMediaClient()
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            videoPermissionDecisionOverride: {
                await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "preview-revocation-peer", name: "Preview Peer")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )

        state.presentVideoCallPreview(to: peer)

        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let videoDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(videoDecisionIsWaiting)
        XCTAssertNotNil(state.videoCallPreview)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )
        XCTAssertNil(state.videoCallPreview)
        XCTAssertFalse(state.isStartingVideoCall)

        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.videoCallPreview)
        XCTAssertEqual(videoClient.prepareCount, 0)
        XCTAssertTrue(videoClient.stopReasons.isEmpty, "Unstarted preview does not own capture to stop")
    }

    func testRTCLicenseSystemAnswerDenialCleansOnceWithoutEndingAnotherOwnedCall() async {
        for unknown in [false, true] {
            for videoAsAudio in [false, true] {
                for preserveConnected in [false, true] {
                    let transport = RTCSystemEndHTTPTransport()
                    let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["denied-system", "other-connected"])
                    let voice = TestVoiceMediaClient()
                    let video = TestVideoMediaClient()
                    var permissions = 0
                    let state = AppState(
                        api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice,
                        videoMediaClient: video, voiceCallSystem: system,
                        microphonePermissionDecisionOverride: { permissions += 1; return true },
                        apiContextOverride: makeAuthenticatedAPIContext()
                    )
                    state.fileUploadConfig = unknown ? .defaultValue : callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
                    if preserveConnected {
                        var active = makeRTCMediaHeartbeatVideoCall(callID: "other-connected")
                        active.mediaState = .connected
                        active.isRecoveringNetwork = unknown
                        active.connectedAt = Date()
                        state.activeVoiceCall = active
                        _ = state.callStore.claimLifecycle(scopeID: "license-system-test", callID: "other-connected", direction: .outgoing, stateVersion: 1)
                        _ = state.callStore.advanceLifecycle(callID: "other-connected", to: .connected, stateVersion: 2)
                        if unknown {
                            _ = state.callStore.advanceLifecycle(callID: "other-connected", to: .reconnecting, stateVersion: 3)
                        }
                    } else {
                        _ = state.callStore.claimLifecycle(scopeID: "license-system-test", callID: "denied-system", direction: .incoming, stateVersion: 1)
                    }
                    state.incomingVoiceCall = IncomingVoiceCall(
                        id: "denied-system", callID: "denied-system", caller: makeUser(id: "peer", name: "Peer"),
                        startedAt: "刚刚", source: "好友通话", requestedMediaMode: videoAsAudio ? "video" : "audio"
                    )
                    for _ in 0..<2 {
                        state.handleVoiceCallSystemEventForTesting(.answer(callID: "denied-system"))
                    }
                    for _ in 0..<100 {
                        if transport.requestCount(path: "/api/rtc/calls/denied-system/reject") > 0 { break }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    XCTAssertNil(state.incomingVoiceCall)
                    XCTAssertFalse(system.hasPresentedCall(callID: "denied-system"))
                    XCTAssertEqual(system.endedCalls.filter { $0.callID == "denied-system" }.count, 1)
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/denied-system/reject"), 1)
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/denied-system/accept"), 0)
                    XCTAssertEqual(permissions, 0)
                    XCTAssertTrue(voice.startedContexts.isEmpty)
                    XCTAssertEqual(video.startCount, 0)
                    XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认语音通话权限，请稍后重试" : "该企业未开通语音通话")
                    if preserveConnected {
                        XCTAssertEqual(state.activeVoiceCall?.callID, "other-connected")
                        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, "other-connected")
                        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, unknown ? .reconnecting : .connected)
                        XCTAssertTrue(system.hasPresentedCall(callID: "other-connected"))
                        XCTAssertTrue(system.endedCalls.allSatisfy { $0.callID != "other-connected" })
                    } else {
                        XCTAssertNil(state.activeVoiceCall)
                        XCTAssertNil(state.callStore.activeLifecycleSnapshot)
                    }
                }
            }
        }
    }

    func testRTCLicenseRepeatedSystemAnswerPreservesSameEstablishedCall() async {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["already-connected"])
        let state = AppState(api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                             apiContextOverride: makeAuthenticatedAPIContext())
        state.fileUploadConfig = .defaultValue
        var active = makeRTCMediaHeartbeatVideoCall(callID: "already-connected")
        active.connectedAt = Date()
        active.mediaState = .connected
        active.isRecoveringNetwork = true
        state.activeVoiceCall = active
        _ = state.callStore.claimLifecycle(scopeID: "same-call", callID: "already-connected", direction: .incoming, stateVersion: 1)
        _ = state.callStore.advanceLifecycle(callID: "already-connected", to: .connected, stateVersion: 2)
        state.incomingVoiceCall = IncomingVoiceCall(id: "already-connected", callID: "already-connected",
            caller: active.peer, startedAt: "刚刚", source: "系统视频来电", requestedMediaMode: "video")
        for _ in 0..<2 { state.handleVoiceCallSystemEventForTesting(.answer(callID: "already-connected")) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.callID, "already-connected")
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, .connected)
        XCTAssertTrue(system.hasPresentedCall(callID: "already-connected"))
        XCTAssertTrue(system.endedCalls.isEmpty)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/already-connected/reject"), 0)
    }

    func testRTCSystemAnswerFreshConfigDenialCleansAfterIncomingUIInvalidation() async {
        let fields = [#""voice_call_enabled":false,"video_call_enabled":false,"#,
                      "", #""voice_call_enabled":null,"video_call_enabled":null,"#]
        for licenseFields in fields {
            for (videoAsAudio, established) in [(false, 0), (true, 0), (false, 1), (true, 2)] {
                let gate = SuspendedBoolDecision()
                let transport = RTCSystemEndHTTPTransport(fileConfigDecision: gate, fileConfigLicenseFields: licenseFields)
                let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["fresh-denial", "other-established"])
                let voice = TestVoiceMediaClient()
                let video = TestVideoMediaClient()
                var permissions = 0
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice,
                    videoMediaClient: video, voiceCallSystem: system,
                    microphonePermissionDecisionOverride: { permissions += 1; return true },
                    apiContextOverride: makeAuthenticatedAPIContext()
                )
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(id: "fresh-denial", callID: "fresh-denial", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友通话", requestedMediaMode: videoAsAudio ? "video" : "audio")
                state.handleVoiceCallSystemEventForTesting(.answer(callID: "fresh-denial"))
                for _ in 0..<200 {
                    if await gate.isWaiting() { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let waiting = await gate.isWaiting()
                XCTAssertTrue(waiting)
                if established > 0 {
                    var active = makeRTCMediaHeartbeatVideoCall(callID: "other-established")
                    active.mediaState = .connected
                    active.connectedAt = Date()
                    active.isRecoveringNetwork = established == 2
                    state.activeVoiceCall = active
                    _ = state.callStore.claimLifecycle(scopeID: "fresh-denial-test", callID: "other-established", direction: .outgoing, stateVersion: 1)
                    _ = state.callStore.advanceLifecycle(callID: "other-established", to: .connected, stateVersion: 2)
                    if established == 2 {
                        _ = state.callStore.advanceLifecycle(callID: "other-established", to: .reconnecting, stateVersion: 3)
                    }
                }
                await gate.resume(returning: true)
                for _ in 0..<200 {
                    if transport.requestCount(path: "/api/rtc/calls/fresh-denial/reject") == 1,
                       state.directCallTrackingCountsForTesting.resourceOwners == 0 { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                state.handleVoiceCallSystemEventForTesting(.answer(callID: "fresh-denial"))
                for _ in 0..<20 { await Task.yield() }
                XCTAssertNil(state.incomingVoiceCall)
                if established > 0 {
                    XCTAssertEqual(state.activeVoiceCall?.callID, "other-established")
                    XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, "other-established")
                    XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, established == 2 ? .reconnecting : .connected)
                    XCTAssertTrue(system.hasPresentedCall(callID: "other-established"))
                    XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/other-established/reject"), 0)
                } else {
                    XCTAssertNil(state.callStore.activeLifecycleSnapshot)
                }
                XCTAssertEqual(system.endedCalls.filter { $0.callID == "fresh-denial" }.count, 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/fresh-denial/reject"), 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/fresh-denial/accept"), 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
                XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
                XCTAssertEqual(permissions, 0)
                XCTAssertTrue(voice.startedContexts.isEmpty)
                XCTAssertEqual(video.startCount, 0)
            }
        }
    }

    func testRTCSystemAnswerExplicitEndWhileConfigPendingDoesNotDuplicateCleanup() async {
        for systemEnd in [false, true] {
            let gate = SuspendedBoolDecision()
            let transport = RTCSystemEndHTTPTransport(fileConfigDecision: gate, fileConfigLicenseFields: #""voice_call_enabled":false,"video_call_enabled":false,"#)
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["explicit-end"])
            var permissions = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                microphonePermissionDecisionOverride: { permissions += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: "explicit-end", callID: "explicit-end", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: "explicit-end"))
            for _ in 0..<200 {
                if await gate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await gate.isWaiting()
            XCTAssertTrue(waiting)
            if systemEnd { state.handleVoiceCallSystemEventForTesting(.end(callID: "explicit-end", reason: "callkit_end")) }
            else { state.declineIncomingVoiceCall() }
            await gate.resume(returning: true)
            for _ in 0..<200 {
                if transport.requestCount(path: "/api/rtc/calls/explicit-end/reject") == 1,
                   state.directCallTrackingCountsForTesting.resourceOwners == 0 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/explicit-end/reject"), 1)
            XCTAssertLessThanOrEqual(system.endedCalls.filter { $0.callID == "explicit-end" }.count, 1)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/explicit-end/accept"), 0)
            XCTAssertEqual(permissions, 0)
            XCTAssertNil(state.incomingVoiceCall)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
        }
    }

    func testRTCSystemAnswerStalePermissionCannotEndReplacementOperationOrScope() async {
        for replacement in ["different-call", "same-call", "context-aba"] {
            let oldPermissionGate = SuspendedBoolDecision()
            let newPermissionGate = SuspendedBoolDecision()
            let transport = RTCSystemEndHTTPTransport(fileConfigLicenseFields: #""voice_call_enabled":true,"video_call_enabled":true,"#)
            let newCallID = replacement == "different-call" ? "new-operation" : "old-operation"
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["old-operation", newCallID])
            let original = makeAuthenticatedAPIContext()
            var permissionIndex = 0
            var oldPermissionReturned = false
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                microphonePermissionDecisionOverride: {
                    permissionIndex += 1
                    if permissionIndex == 1 {
                        let decision = await oldPermissionGate.wait()
                        oldPermissionReturned = true
                        return decision
                    }
                    return await newPermissionGate.wait()
                }, apiContextOverride: original
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            let peer = makeUser(id: "peer", name: "Peer")
            state.incomingVoiceCall = IncomingVoiceCall(id: "old-operation", callID: "old-operation", caller: peer, startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: "old-operation"))
            for _ in 0..<200 {
                if await oldPermissionGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let oldWaiting = await oldPermissionGate.isWaiting()
            XCTAssertTrue(oldWaiting)
            if replacement == "context-aba" {
                var other = original
                other.imToken = "replacement-session"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(original)
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            }
            state.incomingVoiceCall = IncomingVoiceCall(id: "replacement", callID: newCallID, caller: peer, startedAt: "刚刚", source: "好友语音通话")
            state.handleVoiceCallSystemEventForTesting(.answer(callID: newCallID))
            for _ in 0..<200 {
                if await newPermissionGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let replacementWaiting = await newPermissionGate.isWaiting()
            XCTAssertTrue(replacementWaiting)
            let endsBefore = system.endedCalls.filter { $0.callID == newCallID }.count
            let rejectsBefore = transport.requestCount(path: "/api/rtc/calls/\(newCallID)/reject")
            await oldPermissionGate.resume(returning: false)
            for _ in 0..<200 {
                if oldPermissionReturned, state.directCallTrackingCountsForTesting.resourceOwners == 1,
                   replacement != "different-call" || transport.requestCount(path: "/api/rtc/calls/old-operation/reject") == 1 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(oldPermissionReturned)
            for _ in 0..<20 { await Task.yield() }
            if replacement == "different-call" {
                XCTAssertEqual(system.endedCalls.filter { $0.callID == "old-operation" }.count, 1)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/old-operation/reject"), 1)
            }
            XCTAssertEqual(system.endedCalls.filter { $0.callID == newCallID }.count, endsBefore)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(newCallID)/reject"), rejectsBefore)
            XCTAssertTrue(system.hasPresentedCall(callID: newCallID))
            // Discard the replacement's suspended permission without creating media.
            state.declineIncomingVoiceCall()
            await newPermissionGate.resume(returning: false)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(newCallID)/accept"), 0)
        }
    }

    func testRTCPreviewProviderAuthorityPrecedesCameraAndAllowsVideoOnlyTenant() async {
        for scenario in ["disabled", "missing", "unavailable", "network", "video-only"] {
            let transport = VideoCallStartHTTPTransport(
                fileConfigDelayNanoseconds: 0, providerStatusCode: scenario == "unavailable" ? 503 : 200,
                voiceEnabled: false, providerErrorCode: "rtc_license_capabilities_unavailable",
                providerOmitsLicense: scenario == "missing", providerNetworkFailure: scenario == "network",
                providerVideoEnabled: scenario != "disabled"
            )
            let video = TestVideoMediaClient()
            var permissions = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                videoPermissionDecisionOverride: { permissions += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            let peer = makeUser(id: "preview-provider-peer", name: "Peer")
            state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if state.rtcCapabilityAlertMessage != nil || video.prepareCount > 0 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if scenario == "video-only" {
                XCTAssertNil(state.rtcCapabilityAlertMessage)
                XCTAssertEqual(permissions, 1)
                XCTAssertEqual(video.prepareCount, 1)
            } else {
                XCTAssertEqual(state.rtcCapabilityAlertMessage, scenario == "disabled" ? "该企业未开通视频通话" : "暂时无法确认视频通话权限，请稍后重试")
                XCTAssertEqual(permissions, 0, scenario)
                XCTAssertEqual(video.prepareCount, 0, scenario)
            }
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            XCTAssertEqual(video.startCount, 0)
            state.dismissVideoCallPreview()
        }
    }

    func testRTCPreviewPermissionCallbackCannotReviveAfterLicenseOrSessionABA() async {
        for sessionABA in [false, true] {
            let permission = SuspendedBoolDecision()
            let video = TestVideoMediaClient()
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let original = makeAuthenticatedAPIContext()
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                videoPermissionDecisionOverride: { await permission.wait() }, apiContextOverride: original
            )
            let peer = makeUser(id: "preview-aba-peer", name: "Peer")
            state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if await permission.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await permission.isWaiting()
            XCTAssertTrue(waiting)
            if sessionABA {
                var other = original
                other.imToken = "preview-session-b"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(original)
            } else {
                state.fileUploadConfig = .defaultValue
            }
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            await permission.resume(returning: true)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(video.prepareCount, 0, "A stale granted permission must not activate the camera")
            XCTAssertEqual(video.startCount, 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            state.dismissVideoCallPreview()
        }
    }
}
