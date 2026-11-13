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
    func testOutgoingVideoRingingOnColdLaunchIsCanceledExactlyOnce() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["ringing-video"])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        let remote = RemoteRTCCall(
            id: "ringing-video",
            status: "ringing",
            roomID: "room-ringing-video",
            callerUID: "uid-1",
            calleeUID: "friend-1",
            channelID: "uid-1:friend-1",
            channelType: "direct",
            callType: "video",
            requestedMediaMode: "video",
            mediaMode: "video",
            callerDevice: RemoteRTCDevice(uid: "uid-1", deviceID: "unit-test-device", deviceType: "ios"),
            stateVersion: 3
        )
        state.reconcileRTCCallsForTesting([remote])
        state.reconcileRTCCallsForTesting([remote])
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/ringing-video/cancel") == 0
            || state.pendingRTCTerminalCompensationCountForTesting != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.toast, "视频呼叫因应用重启已安全取消")
        XCTAssertFalse(system.hasPresentedCall(callID: "ringing-video"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/ringing-video/cancel"), 1)
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
    }

    @MainActor
    func testVideoMediaFailureEndsLocalCallAndCompensatesServerHangup() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-failure",
            callID: "video-media-failure",
            peer: makeUser(id: "friend-1", name: "Friend"),
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

        state.handleVideoMediaEvent(.failed, callID: "video-media-failure")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-media-failure/hangup") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "视频通话连接失败")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-media-failure/hangup"), 1)
    }

    @MainActor
    func testVideoAudioLifecycleReconciliationSurfacesFailureWithoutChangingCallState() async throws {
        let videoClient = TestVideoMediaClient()
        videoClient.audioReconcileError = IMAPIError.server("route failed")
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-audio-local",
            callID: "video-audio-reconcile",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video"
        )

        state.reconcileActiveVideoAudioSessionForTesting(reason: "media_services_reset")
        for _ in 0..<20 where videoClient.audioReconcileCount == 0 { await Task.yield() }

        XCTAssertEqual(videoClient.audioReconcileCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-audio-reconcile")
        XCTAssertEqual(state.toast, "视频通话音频服务恢复失败，请结束后重试")
    }

    @MainActor
    func testVoiceAudioLifecycleReconciliationUsesVoiceMediaClient() async throws {
        let voiceClient = TestVoiceMediaClient()
        let state = AppState(
            voiceMediaClient: voiceClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "voice-audio-local",
            callID: "voice-audio-reconcile",
            peer: makeUser(id: "friend-voice", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: false
        )

        state.reconcileActiveVideoAudioSessionForTesting(reason: "route_changed")
        for _ in 0..<20 where voiceClient.audioReconcileSpeakerValues.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(voiceClient.audioReconcileSpeakerValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.callID, "voice-audio-reconcile")
    }

    func testVideoRendererContractRebindsTracksObservesFirstFrameAndDetachesOnClose() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        // WDT_IOS1_REFACTOR_VIDEO_MEDIA_20261110_BEGIN
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let source = try [
            "WenDaTong/VideoMediaClient.swift",
            "WenDaTong/RTCVideoRenderer.swift",
        ].map { path in
            try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")
        // WDT_IOS1_REFACTOR_VIDEO_MEDIA_20261110_END

        XCTAssertTrue(source.contains("localRenderers.values.forEach { old.remove($0) }"))
        XCTAssertTrue(source.contains("remoteRenderers.values.forEach { old.remove($0) }"))
        XCTAssertTrue(source.contains("remoteVideoTrack.remove(remoteFirstFrameObserver)"))
        XCTAssertTrue(source.contains("self.emit(.remoteVideoTrackReady)"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.setRemoteTrack(track)"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.clear()"))
        XCTAssertTrue(source.contains("RTCVideoRenderRegistry.shared.setRemoteTrack(nil)"))
    }

    func testVideoCallAccessibilityAndPrivacyUsageDescriptionsRemainReleaseReady() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let videoViews = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/IM4Features/Calls/VideoCallScreenContent.swift"),
            encoding: .utf8
        )
        let incomingViews = try String(
            // WDT_IOS1_REFACTOR_FILES_RTC_VIEWS_20261109
            contentsOf: sourceRoot.appendingPathComponent("Sources/IM4Features/Calls/CallScreenContent.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: sourceRoot.appendingPathComponent("WenDaTong/App/WDTApp.swift"),
            encoding: .utf8
        )
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: sourceRoot.appendingPathComponent("WenDaTong/WDTConfiguration/Info.plist"))
        )

        for identifier in [
            "video_call_peer_profile_disabled",
            "video_call_mute_button",
            "video_call_camera_button",
            "video_call_switch_camera_button",
            "video_call_speaker_button",
            "video_call_end_button"
        ] {
            XCTAssertTrue(videoViews.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
        for identifier in ["incoming_call_reject_button", "incoming_voice_answer_button",
                           "incoming_video_answer_audio_button", "incoming_video_answer_video_button"] {
            XCTAssertTrue(incomingViews.contains("\"\(identifier)\""), identifier)
        }
        XCTAssertTrue(incomingViews.contains(".accessibilityIdentifier(identifier)"))
        XCTAssertTrue(app.contains("overlayWindow?.frame = scene.coordinateSpace.bounds"))
        XCTAssertTrue(app.contains("view.accessibilityViewIsModal = true"))
        XCTAssertFalse(app.contains("IncomingVoiceCallBanner("))
        XCTAssertFalse(app.contains("IncomingVideoCallOverlay("))
        XCTAssertTrue((plist["NSMicrophoneUsageDescription"] as? String)?.contains("视频通话") == true)
        XCTAssertTrue((plist["NSCameraUsageDescription"] as? String)?.contains("视频通话") == true)
        let backgroundModes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])
        XCTAssertTrue(backgroundModes.contains("audio"))
        XCTAssertFalse(backgroundModes.contains("voip"))
        XCTAssertTrue(backgroundModes.contains("remote-notification"))
    }

    func testVideoCameraFailurePolicyNeverRestartsCameraAfterDisableFailure() {
        XCTAssertFalse(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: false,
                previousIntent: true
            )
        )
        XCTAssertFalse(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: true,
                previousIntent: false
            )
        )
        XCTAssertTrue(
            RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: true,
                previousIntent: true
            )
        )
    }

    @MainActor
    func testActiveVideoCallBackgroundLifecyclePreservesCallWhilePausingVideoCapture() async {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-background-local",
            callID: "video-background-call",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.handleVideoApplicationDidEnterBackground()
        for _ in 0..<20 where videoClient.backgroundCount == 0 { await Task.yield() }

        XCTAssertEqual(videoClient.backgroundCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.callID, "video-background-call")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
    }

    @MainActor
    func testVideoSpeakerAndCameraControlsUpdateImmediatelyAndRollbackOnMediaFailure() async throws {
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.voiceMediaClientAvailableOverride = true
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local",
            callID: "video-controls",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            cameraPosition: .front
        )

        state.toggleActiveCallSpeaker()
        XCTAssertEqual(state.activeVoiceCall?.speakerOn, false)
        for _ in 0..<20 where videoClient.speakerValues.isEmpty { await Task.yield() }
        XCTAssertEqual(videoClient.speakerValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.speakerOn, false)

        videoClient.cameraError = IMAPIError.server("camera failed")
        state.toggleActiveVideoCamera()
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        for _ in 0..<20 where videoClient.cameraValues.isEmpty { await Task.yield() }
        XCTAssertEqual(videoClient.cameraValues, [false])
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, true)

        videoClient.switchCameraError = IMAPIError.server("switch failed")
        state.switchActiveVideoCamera()
        XCTAssertEqual(state.activeVoiceCall?.cameraPosition, .back)
        for _ in 0..<20 where videoClient.switchCameraCount == 0 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.cameraPosition, .front)
        XCTAssertEqual(state.toast, "切换摄像头失败，已保留原摄像头")

        videoClient.foregroundError = IMAPIError.server("foreground resume failed")
        state.handleVideoApplicationWillEnterForeground()
        for _ in 0..<20 where videoClient.foregroundCount == 0 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.toast, "返回前台后摄像头恢复失败，已保持关闭")
    }

    @MainActor
    func testVideoDowngradeUsesExistingEndpointAndAppliesAudioMode() async throws {
        let transport = RTCSystemEndHTTPTransport(fileConfigLicenseFields: #""voice_call_enabled":true,"video_call_enabled":true,"#)
        let videoClient = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: videoClient,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local",
            callID: "video-downgrade",
            peer: makeUser(id: "friend-1", name: "Friend"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方连接",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            remoteVideoTrackReady: true
        )

        state.downgradeActiveVideoCallToAudio()
        XCTAssertEqual(state.activeVoiceCall?.statusText, "正在切换为语音通话")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/video-downgrade/downgrade") == 0
            || videoClient.downgradeToAudioCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-downgrade/downgrade"), 1)
        XCTAssertEqual(videoClient.downgradeToAudioCount, 1)
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "等待对方连接")
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteVideoTrackReady, false)
        XCTAssertEqual(state.toast, "已切换为语音通话，当前通话无法恢复视频")
    }

    @MainActor
    func testAppStateIgnoresSystemEndForInAppPollingCallNotPresentedByCallKit() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration()
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: caller, callID: "polling-call", roomID: "polling-room")

        state.handleVoiceCallSystemEventForTesting(.end(callID: "polling-call", reason: "callkit_end"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.incomingVoiceCall?.callID, "polling-call")
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/polling-call/reject"), 0)
        XCTAssertTrue(system.endedCalls.isEmpty)
    }

    @MainActor
    func testAppStateSystemEndRejectsCallActuallyPresentedByCallKit() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["push-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )

        state.handleVoiceCallSystemEventForTesting(.end(callID: "push-call", reason: "callkit_end"))
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/push-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/push-call/reject"), 1)
        XCTAssertFalse(system.hasPresentedCall(callID: "push-call"))
    }

    @MainActor
    func testCallKitProviderResetTerminatesServerSuppressesSameCallAndAllowsNextIncomingCall() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["reset-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let currentUser = makeUser(id: "uid-1", name: "Me")
        let firstCaller = makeUser(id: "friend-1", name: "Friend One")
        let nextCaller = makeUser(id: "friend-2", name: "Friend Two")
        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [firstCaller, nextCaller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(
            from: firstCaller,
            callID: "reset-call",
            roomID: "reset-room",
            systemOwnsRingtone: true
        )

        state.handleVoiceCallSystemEventForTesting(.providerReset)

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "系统通话服务已重置，通话已结束")

        state.receiveIncomingVoiceCall(
            from: firstCaller,
            callID: "reset-call",
            roomID: "reset-room"
        )
        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "reset-call",
                status: "ringing",
                roomID: "reset-room",
                callerUID: "friend-1",
                calleeUID: "uid-1",
                channelID: "friend-1:uid-1",
                channelType: "direct",
                callType: "audio"
            )
        ])
        XCTAssertNil(state.incomingVoiceCall, "A provider-reset terminal call must not resurrect from push or polling")

        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/reset-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/reset-call/reject"), 1)

        state.receiveIncomingVoiceCall(
            from: nextCaller,
            callID: "next-call",
            roomID: "next-room"
        )
        XCTAssertEqual(state.incomingVoiceCall?.callID, "next-call")
    }

    @MainActor
    func testCallKitProviderResetCleansLifecycleOnlyIncomingAndRejectsServerCall() async throws {
        let transport = RTCSystemEndHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["lifecycle-only-call"])
        let state = AppState(
            api: api,
            voiceCallSystem: system,
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let caller = makeUser(id: "friend-1", name: "Friend")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [caller]
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "lifecycle-only-call",
            roomID: "lifecycle-only-room",
            systemOwnsRingtone: true
        )
        state.incomingVoiceCall = nil

        state.handleVoiceCallSystemEventForTesting(.providerReset)

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "系统通话服务已重置，通话已结束")
        for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/lifecycle-only-call/reject") == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/lifecycle-only-call/reject"), 1)

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "lifecycle-only-call",
            roomID: "lifecycle-only-room"
        )
        XCTAssertNil(state.incomingVoiceCall)
    }

    @MainActor
    func testAppStateVoIPTerminalPayloadCannotDirectlyEndCallKitCall() throws {
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: ["call-1"])
        let state = AppState(voiceCallSystem: system)
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "cancel",
            "call_id": "call-1",
            "room_id": "room-1",
            "caller_uid": "friend-1",
            "callee_uid": "me",
            "caller_name": "Friend",
            "call_type": "audio",
            "provider": "self_hosted_webrtc"
        ]))

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-1",
            callID: "call-1",
            caller: friend,
            startedAt: "刚刚",
            source: "好友语音通话"
        )

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(payload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertTrue(system.endedCalls.isEmpty)
    }

    @MainActor
    func testAppStateIncomingVoiceCallDuplicateEventRefreshesGenericCallerProfile() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let genericCaller = makeUser(id: "WXT00000003", name: "语音联系人")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2"
        )

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: genericCaller, callID: "call-1")
        let firstIncomingID = state.incomingVoiceCall?.id

        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.id, firstIncomingID)
        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
    }

    @MainActor
    func testAppStateIncomingCallDuplicateHigherRevisionCorrectsAudioToVideoWithoutDowngrade() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let caller = makeUser(id: "WXT00000003", name: "Meng")
        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = videoCallEnabledFileConfig()

        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "audio",
            stateVersion: 1
        )
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "video",
            stateVersion: 2
        )
        state.receiveIncomingVoiceCall(
            from: caller,
            callID: "call-refine-video",
            mediaMode: "audio",
            stateVersion: 1
        )

        XCTAssertTrue(state.incomingVoiceCall?.isVideo == true)
        XCTAssertEqual(state.incomingVoiceCall?.source, "好友视频通话")
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
    }

    @MainActor
    func testAppStateIncomingVoiceCallRefreshesGenericCallerAcrossServerAndIMIDs() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let genericServerCaller = makeUser(id: "server-user-3", name: "语音联系人")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2"
        )

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true

        state.receiveIncomingVoiceCall(from: genericServerCaller, callID: "call-1")
        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        XCTAssertEqual(state.incomingVoiceCall?.caller.id, "WXT00000003")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
    }

    @MainActor
    func testAppStateVoIPPushAvatarHydratesIncomingCall() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let payload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-1",
            "room_id": "room-avatar-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "https://example.test/voice-avatar.png",
            "caller_avatar_version": "voice-v1",
            "caller_avatar_updated_at": "2026-06-26T04:00:00Z",
            "call_type": "audio"
        ]))

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(payload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-avatar-1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "孟瑶")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/voice-avatar.png")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "voice-v1")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarUpdatedAt, "2026-06-26T04:00:00Z")
    }

    @MainActor
    func testAppStateRTCBareRefreshDoesNotClearKnownIncomingAvatar() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let resolvedCaller = makeUser(
            id: "WXT00000003",
            name: "孟瑶",
            avatarURL: "https://example.test/avatar.png",
            avatarVersion: "v2",
            avatarUpdatedAt: "2026-06-26T04:05:00Z"
        )

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true
        state.receiveIncomingVoiceCall(from: resolvedCaller, callID: "call-1")

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "call-1",
                status: "ringing",
                roomID: "room-1",
                callerUID: "WXT00000003",
                calleeUID: "WXT00000002",
                channelID: "WXT00000002:WXT00000003",
                channelType: "direct",
                callType: "audio"
            )
        ])

        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/avatar.png")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "v2")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarUpdatedAt, "2026-06-26T04:05:00Z")
    }

    @MainActor
    func testAppStateNextVoIPCallWithoutAvatarDoesNotReusePreviousAvatar() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "WXT00000002", name: "Chen")
        let firstPayload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-1",
            "caller_uid": "WXT00000003",
            "callee_uid": "WXT00000002",
            "caller_name": "孟瑶",
            "caller_avatar": "https://example.test/voice-avatar.png",
            "caller_avatar_version": "voice-v1",
            "call_type": "audio"
        ]))
        let secondPayload = try XCTUnwrap(RTCVoIPPushPayload(dictionary: [
            "kind": "rtc_call",
            "event": "ringing",
            "call_id": "call-avatar-2",
            "caller_uid": "WXT00000004",
            "callee_uid": "WXT00000002",
            "caller_name": "李雷",
            "call_type": "audio"
        ]))

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.voiceMediaClientAvailableOverride = true

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(firstPayload))
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "https://example.test/voice-avatar.png")
        state.incomingVoiceCall = nil

        state.handleVoiceCallSystemEventForTesting(.voipPushPayload(secondPayload))

        XCTAssertEqual(state.incomingVoiceCall?.callID, "call-avatar-2")
        XCTAssertEqual(state.incomingVoiceCall?.caller.name, "李雷")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarURL, "")
        XCTAssertEqual(state.incomingVoiceCall?.caller.avatarVersion, "")
    }
}
