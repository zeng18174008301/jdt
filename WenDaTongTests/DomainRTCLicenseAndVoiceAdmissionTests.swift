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
    func testAppStateVoiceCallRequiresFriendRelationship() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        let currentUser = makeUser(id: "me", name: "Me")
        let friend = makeUser(id: "friend-1", name: "Friend")
        let stranger = makeUser(id: "stranger-1", name: "Stranger")

        state.setCurrentUser(currentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [friend]

        // This test exercises relationship/media availability, not unknown license authority.
        state.overrideAPIContextForTesting(makeAuthenticatedAPIContext())
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)

        XCTAssertFalse(state.canStartVoiceCall(with: friend))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: friend), "当前 iOS 版本暂未接入真实语音媒体，暂不能使用语音通话")
        XCTAssertFalse(state.canStartVoiceCall(with: stranger))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: stranger), "需先添加好友后才能发起语音通话")

        state.startOutgoingVoiceCall(to: friend)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "当前 iOS 版本暂未接入真实语音媒体，暂不能使用语音通话")

        state.startOutgoingVoiceCall(to: stranger)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "需先添加好友后才能发起语音通话")
    }

    @MainActor
    func testDirectCallLicenseMatrixKeepsVoiceAndVideoIndependentAndBlocksVoiceBeforeNetwork() throws {
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
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-call-license", name: "Call Peer")
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true

        let matrix: [(voice: Bool, video: Bool)] = [
            (true, false),
            (true, true),
            (false, false),
            (false, true)
        ]
        for row in matrix {
            state.fileUploadConfig = callLicenseFileConfig(
                voiceEnabled: row.voice,
                videoEnabled: row.video
            )

            XCTAssertEqual(state.isVoiceCallLicensedForCurrentTenant, row.voice)
            XCTAssertEqual(state.isVideoCallLicensedForCurrentTenant, row.video)
            state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
            XCTAssertEqual(state.guardCallLicenseForAction(.voice), row.voice)
            XCTAssertEqual(state.rtcCapabilityAlertMessage, row.voice ? nil : "该企业未开通语音通话")
            state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
            XCTAssertEqual(state.guardCallLicenseForAction(.video), row.video)
            XCTAssertEqual(state.rtcCapabilityAlertMessage, row.video ? nil : "该企业未开通视频通话")
            XCTAssertTrue(state.canStartVoiceCall(with: peer))
            XCTAssertEqual(state.videoCallUnavailableReason(for: peer) == nil, row.video)

            XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
            if !row.voice {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(nil)
                state.startOutgoingVoiceCall(to: peer, channelID: "uid-1:peer-call-license")
                XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
                XCTAssertFalse(state.isStartingVoiceCall)
                XCTAssertNil(state.activeVoiceCall)
            }
        }

        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
    }

    @MainActor
    func testDirectCallLicenseCapabilitiesFailClosedAfterTenantSwitchUntilCurrentConfigArrives() throws {
        let state = AppState(
            videoMediaClient: TestVideoMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-tenant-switch", name: "Peer")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)

        XCTAssertTrue(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertTrue(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertNil(state.videoCallUnavailableReason(for: peer))

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-2"
        switchedContext.imUID = "uid-2"
        switchedContext.imToken = "im-token-2"
        state.overrideAPIContextForTesting(switchedContext)

        XCTAssertFalse(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertFalse(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertEqual(state.videoCallUnavailableReason(for: peer), "暂时无法确认视频通话权限，请稍后重试")
        state.startOutgoingVoiceCall(to: peer)
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试")
        XCTAssertFalse(state.isStartingVoiceCall)

        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(nil)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-voice-old-tenant",
            callID: "incoming-voice-old-tenant",
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.acceptIncomingVoiceCall()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试")
        XCTAssertNil(state.activeVoiceCall)
        state.incomingVoiceCall = nil

        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)

        XCTAssertFalse(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertTrue(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertNil(state.voiceCallUnavailableReason(for: peer))
        XCTAssertNil(state.videoCallUnavailableReason(for: peer))
    }

    @MainActor
    func testIncomingVideoAcceptFailsClosedForRevokedLicenseAndStalePermissionCallback() async throws {
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
        let incoming = IncomingVoiceCall(
            id: "incoming-video-license",
            callID: "incoming-video-stale",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )
        state.incomingVoiceCall = incoming
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: false
        )

        state.acceptIncomingVideoCall(as: "video")

        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通视频通话")
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-stale/accept"),
            0
        )

        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(nil)
        state.incomingVoiceCall = incoming
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
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

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-after-permission"
        switchedContext.imUID = "uid-after-permission"
        switchedContext.imToken = "im-token-after-permission"
        state.overrideAPIContextForTesting(switchedContext)
        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(state.isVideoCallLicensedForCurrentTenant)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-stale/accept"),
            0
        )
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCLicenseMissingFieldsStayUnknownWithoutDisablingTheOtherKnownMedia() throws {
        let cases: [(String, Bool, Bool)] = [
            (#"{}"#, false, false),
            (#"{"voice_call_enabled":null,"video_call_enabled":"invalid"}"#, false, false),
            (#"{"voice_message":true,"video_message":true}"#, false, false),
            (#"{"voice_call_enabled":false}"#, true, false),
            (#"{"features":{"video_call_enabled":true}}"#, false, true),
            (#"{"features":{"voice_call_enabled":false,"video_call_enabled":true}}"#, true, true)
        ]
        for (json, voiceKnown, videoKnown) in cases {
            let config = try JSONDecoder().decode(RemoteFileUploadConfig.self, from: Data(json.utf8)).model
            XCTAssertEqual(config.voiceCallLicenseKnown, voiceKnown, json)
            XCTAssertEqual(config.videoCallLicenseKnown, videoKnown, json)
            let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
            state.fileUploadConfig = config
            if !voiceKnown {
                XCTAssertEqual(state.callLicenseUnavailableMessage(for: .voice), "暂时无法确认语音通话权限，请稍后重试")
            }
            if !videoKnown {
                XCTAssertEqual(state.callLicenseUnavailableMessage(for: .video), "暂时无法确认视频通话权限，请稍后重试")
            }
        }
        XCTAssertFalse(FileUploadConfig.defaultValue.voiceCallLicenseKnown)
        XCTAssertFalse(FileUploadConfig.defaultValue.videoCallLicenseKnown)
    }

    func testRTCLicenseScopeChangesAndABACannotRestoreAuthorityWithoutFreshConfig() {
        let original = makeAuthenticatedAPIContext()
        // Ordinary legacy-token renewal keeps license while retiring the old RTC capability generation.
        let renewedState = AppState(apiContextOverride: original)
        renewedState.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let oldGeneration = renewedState.directCallCapabilityGeneration(for: .voice)
        var renewed = original
        renewed.imToken = "ordinary-renewed-synthetic-token"
        XCTAssertNotEqual(renewed.imToken, original.imToken)
        XCTAssertEqual(renewed.sessionEpoch, original.sessionEpoch)
        renewedState.overrideAPIContextForTesting(renewed)
        XCTAssertTrue(renewedState.guardCallLicenseForAction(.voice))
        XCTAssertTrue(renewedState.guardCallLicenseForAction(.video))
        XCTAssertGreaterThan(renewedState.directCallCapabilityGeneration(for: .voice), oldGeneration)
        // Five identity axes plus an explicit committed new-auth epoch retain the original ABA/fresh-config assertions.
        let mutations: [(inout IMAPIContext) -> Void] = [
            { $0.tenantID = "tenant-other" },
            { $0.accountID = "account-other" },
            { $0.imUID = "uid-other" },
            { $0.deviceID = "device-other" },
            { $0.appID = "other-ios-app" },
            { $0.sessionEpoch = UUID().uuidString }
        ]
        for (mutationIndex, mutate) in mutations.enumerated() {
            let state = AppState(apiContextOverride: original)
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            XCTAssertTrue(state.guardCallLicenseForAction(.voice))
            var changed = original
            mutate(&changed)
            state.overrideAPIContextForTesting(changed)
            XCTAssertFalse(state.guardCallLicenseForAction(.voice), "mutation index \(mutationIndex)")
            XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认语音通话权限，请稍后重试", "mutation index \(mutationIndex)")
            state.overrideAPIContextForTesting(original)
            XCTAssertFalse(state.guardCallLicenseForAction(.video), "Returning to the same scope must not resurrect stale authority; mutation index \(mutationIndex)")
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            XCTAssertFalse(state.guardCallLicenseForAction(.voice), "mutation index \(mutationIndex)")
            XCTAssertTrue(state.guardCallLicenseForAction(.video))
        }
        let loggedOut = AppState(apiContextOverride: makeIsolatedAPIContext())
        loggedOut.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        XCTAssertFalse(loggedOut.guardCallLicenseForAction(.voice))
        XCTAssertFalse(loggedOut.guardCallLicenseForAction(.video))
    }

    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_BEGIN
    func testUploadConfigurationPublishesSameValuesWhenNewScopeGainsCallAuthority() {
        let original = makeAuthenticatedAPIContext()
        let state = AppState(apiContextOverride: original)
        let config = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let store = state.fileStore
        var updates: [FileStore.UploadConfigurationSnapshot] = []
        let observation = store.configurationUpdates(for: \.self).sink { updates.append($0) } // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110
        defer { observation.cancel() }

        state.fileUploadConfig = config
        XCTAssertEqual(updates.last?.callLicenseScopeKey, state.callLicenseScopeKey(for: original))
        XCTAssertTrue(state.isVoiceCallLicensedForCurrentTenant)

        var changed = original
        changed.tenantID = "other-tenant"
        state.overrideAPIContextForTesting(changed)
        XCTAssertNil(updates.last?.callLicenseScopeKey)
        XCTAssertFalse(state.isVoiceCallLicensedForCurrentTenant)
        XCTAssertEqual(store.currentUploadConfig(), config)

        state.fileUploadConfig = config
        XCTAssertEqual(updates.count, 4)
        XCTAssertEqual(updates.last?.config, config)
        XCTAssertEqual(updates.last?.callLicenseScopeKey, state.callLicenseScopeKey(for: changed))
        XCTAssertTrue(state.isVoiceCallLicensedForCurrentTenant)

        state.setReadReceiptsEnabled(false)
        XCTAssertEqual(updates.last?.config.readReceiptsEnabled, false)
        XCTAssertEqual(updates.last?.callLicenseScopeKey, state.callLicenseScopeKey(for: changed))
        XCTAssertTrue(state.isVoiceCallLicensedForCurrentTenant)
    }
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_END

    func testRTCLicenseRepeatedDeniedAndUnknownActionsHaveZeroMediaAndCallSideEffects() async {
        for unknown in [false, true] {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let video = TestVideoMediaClient()
            let voice = TestVoiceMediaClient()
            var microphoneRequests = 0
            var videoPermissionRequests = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: voice,
                videoMediaClient: video,
                microphonePermissionDecisionOverride: { microphoneRequests += 1; return true },
                videoPermissionDecisionOverride: { videoPermissionRequests += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            let peer = makeUser(id: "license-denied-peer", name: "Peer")
            state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            state.contacts = [peer]
            state.fileUploadConfig = unknown ? .defaultValue : callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
            let initialRecords = state.calls.count
            for _ in 0..<3 {
                state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
                state.startOutgoingVoiceCall(to: peer)
                XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认语音通话权限，请稍后重试" : "该企业未开通语音通话")
                state.startOutgoingVideoCall(to: peer)
                XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认视频通话权限，请稍后重试" : "该企业未开通视频通话")
                for type in [RTCCallRecordType.audio, .video] {
                    state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
                    let record = RTCCallRecordPayload(
                        schemaVersion: 1, callID: "historical-license", callType: type,
                        callerUID: "uid-1", calleeUID: peer.id, finalOutcome: .noAnswer,
                        startedAt: Date(), answeredAt: nil, mediaConnectedAt: nil,
                        endedAt: Date(), durationSeconds: 0, reasonCode: "no_answer",
                        fallbackText: "", endActorUID: nil, finalMediaMode: nil
                    )
                    state.redialRTCCallRecord(record, viewerIsCaller: true, conversationID: "license-conversation")
                    let media = type == .audio ? "语音通话" : "视频通话"
                    XCTAssertEqual(state.rtcCapabilityAlertMessage, unknown ? "暂时无法确认\(media)权限，请稍后重试" : "该企业未开通\(media)")
                }
                state.presentVideoCallPreview(to: peer)
                XCTAssertNil(state.videoCallPreview)
                state.incomingVoiceCall = IncomingVoiceCall(id: "license-incoming", callID: "license-incoming", caller: peer, startedAt: "刚刚", source: "好友语音通话")
                state.acceptIncomingVoiceCall()
                state.incomingVoiceCall = IncomingVoiceCall(id: "license-incoming", callID: "license-incoming", caller: peer, startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
                state.acceptIncomingVideoCall(as: "video")
                state.incomingVoiceCall = nil
            }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(microphoneRequests, 0)
            XCTAssertEqual(videoPermissionRequests, 0)
            XCTAssertEqual(video.startCount, 0)
            XCTAssertTrue(voice.startedContexts.isEmpty)
            XCTAssertTrue(video.cameraValues.isEmpty)
            XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/license-incoming/accept"), 0)
            XCTAssertEqual(state.calls.count, initialRecords)
            XCTAssertNil(state.activeVoiceCall)
            XCTAssertFalse(state.isStartingVoiceCall)
            XCTAssertFalse(state.isStartingVideoCall)
        }
    }

    func testRTCVideoOnlyLicenseAllowsVideoButBlocksExplicitAudioAnswerBeforePermission() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, voiceEnabled: false)
        let permission = SuspendedBoolDecision()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { await permission.wait() },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "video-only", callID: "video-only", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
        state.acceptIncomingVideoCall(as: "audio")
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
        let blockedPermission = await permission.isWaiting()
        XCTAssertFalse(blockedPermission)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)

        state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
        state.acceptIncomingVideoCall(as: "video")
        for _ in 0..<200 {
            if await permission.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let allowedPermission = await permission.isWaiting()
        XCTAssertTrue(allowedPermission, "Video permission proceeds independently of disabled voice calls")
        XCTAssertNil(state.rtcCapabilityAlertMessage)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 1)
        // End the test before camera/media activation; this is not a real call.
        await permission.resume(returning: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/video-only/accept"), 0)
    }

    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_BEGIN
    func testMountedRootPresentsAndClearsScopedRTCCapabilityWindow() async throws {
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [successfulEmptyAPIResponse()])),
            apiContextOverride: makeIsolatedAPIContext()
        )
        // Keep the host on the launch view so auth policy caching stays outside this test.
        state.bootstrapPresentationStore.launch.isShowingLaunchSplash = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.rootViewController = UIHostingController(
            rootView: RootView().appStateEnvironment(state).environment(\.scenePhase, .active)
        )
        host.makeKeyAndVisible()
        defer {
            state.rtcCapabilityAlertStore.message = nil
            host.isHidden = true
            host.rootViewController = nil
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let originalWindows = Set(scene.windows.map { ObjectIdentifier($0) })
        let error = IMAPIError.businessForbidden(code: "voice_call_not_enabled", message: "", error: nil)
        XCTAssertTrue(state.presentRTCLicenseFailure(error, media: .voice))
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")

        var overlay: UIWindow?
        for _ in 0..<30 {
            overlay = scene.windows.first {
                !originalWindows.contains(ObjectIdentifier($0)) && $0.windowLevel == .alert + 1 && !$0.isHidden
            }
            if overlay != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let overlay else {
            XCTFail("RTC capability alert window did not appear")
            return
        }
        XCTAssertTrue(overlay.rootViewController?.view.accessibilityViewIsModal == true)

        state.rtcCapabilityAlertStore.message = nil
        for _ in 0..<30 where !overlay.isHidden {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(overlay.rootViewController)
    }
    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_END

    func testRTCFreshProviderRefusalShowsTypedLicenseModalBeforePermissions() async {
        let cases = [(403, "voice_call_not_enabled", "该企业未开通语音通话"),
                     (503, "rtc_license_capabilities_unavailable", "暂时无法确认语音通话权限，请稍后重试")]
        for (status, code, message) in cases {
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: status, providerErrorCode: code)
            var permissionRequests = 0
            let voice = TestVoiceMediaClient()
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: voice,
                microphonePermissionDecisionOverride: { permissionRequests += 1; return true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: "provider-refusal", callID: "provider-refusal", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
            state.acceptIncomingVoiceCall()
            for _ in 0..<200 {
                if state.rtcCapabilityAlertMessage != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(state.rtcCapabilityAlertMessage, message)
            XCTAssertEqual(permissionRequests, 0)
            XCTAssertTrue(voice.startedContexts.isEmpty)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/provider-refusal/accept"), 0)
            XCTAssertNil(state.activeVoiceCall)
        }
    }

    func testRTCFreshFileConfigFailureBecomesUnknownBeforeVideoPermission() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, fileConfigStatusCode: 503)
        var permissionRequests = 0
        let video = TestVideoMediaClient()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            videoMediaClient: video,
            microphonePermissionDecisionOverride: { permissionRequests += 1; return true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "config-failure", callID: "config-failure", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video")
        state.acceptIncomingVideoCall(as: "video")
        for _ in 0..<200 {
            if state.rtcCapabilityAlertMessage != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认视频通话权限，请稍后重试")
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(video.startCount, 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/config-failure/accept"), 0)
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCLateConfigResponseAcrossScopeABACannotOverwriteCurrentDenial() async {
        let gate = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200, fileConfigDecision: gate)
        var permissions = 0
        let original = makeAuthenticatedAPIContext()
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            microphonePermissionDecisionOverride: { permissions += 1; return true },
            apiContextOverride: original
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: "config-aba", callID: "config-aba", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await gate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let isWaiting = await gate.isWaiting()
        XCTAssertTrue(isWaiting)
        var other = original
        other.tenantID = "tenant-config-aba"
        state.overrideAPIContextForTesting(other)
        state.overrideAPIContextForTesting(original)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
        let voiceGeneration = state.callLicenseActionGeneration(for: .voice)
        await gate.resume(returning: true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(state.callLicenseActionGeneration(for: .voice), voiceGeneration)
        XCTAssertEqual(state.callLicenseUnavailableMessage(for: .voice), "该企业未开通语音通话")
        XCTAssertEqual(state.callLicenseUnavailableMessage(for: .video), "该企业未开通视频通话")
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/config-aba/accept"), 0)
        XCTAssertNil(state.activeVoiceCall)
    }

    func testRTCProviderMissingLicenseAndNetworkFailureRemainUnknownBeforeMedia() async {
        for networkFailure in [false, true] {
            for media in [RTCCapabilityMedia.voice, .video] {
                let transport = VideoCallStartHTTPTransport(
                    fileConfigDelayNanoseconds: 0, providerStatusCode: 200,
                    providerOmitsLicense: !networkFailure, providerNetworkFailure: networkFailure
                )
                var permissions = 0
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport),
                    videoMediaClient: TestVideoMediaClient(),
                    microphonePermissionDecisionOverride: { permissions += 1; return true },
                    apiContextOverride: makeAuthenticatedAPIContext()
                )
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(id: "provider-unknown", callID: "provider-unknown", caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友通话", requestedMediaMode: media == .video ? "video" : "audio")
                if media == .video {
                    state.acceptIncomingVideoCall(as: "video")
                } else {
                    state.acceptIncomingVoiceCall()
                }
                for _ in 0..<200 {
                    if state.rtcCapabilityAlertMessage != nil { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let name = media == .video ? "视频通话" : "语音通话"
                XCTAssertEqual(state.rtcCapabilityAlertMessage, "暂时无法确认\(name)权限，请稍后重试")
                XCTAssertEqual(permissions, 0)
                XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/provider-unknown/accept"), 0)
                XCTAssertNil(state.activeVoiceCall)
            }
        }
    }

    func testRTCLicenseRevocationKeepsEstablishedCallAndBlocksNewMediaModeActions() async {
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let video = TestVideoMediaClient()
        let state = AppState(api: makeCallEndingAPI(transport: transport), videoMediaClient: video, apiContextOverride: makeAuthenticatedAPIContext())
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        var connected = makeRTCMediaHeartbeatVideoCall(callID: "established-license")
        connected.mediaState = .connected
        connected.statusText = "通话中"
        connected.connectedAt = Date()
        state.activeVoiceCall = connected

        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
        XCTAssertEqual(state.activeVoiceCall?.callID, "established-license")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        state.downgradeActiveVideoCallToAudio()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通语音通话")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "video")

        connected.mediaMode = "audio"
        state.activeVoiceCall = connected
        state.requestActiveAudioCallVideoUpgrade()
        XCTAssertEqual(state.rtcCapabilityAlertMessage, "该企业未开通视频通话")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.activeVoiceCall?.callID, "established-license")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(video.downgradeToAudioCount, 0)
        XCTAssertTrue(video.stopReasons.isEmpty)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/established-license/downgrade"), 0)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/established-license/hangup"), 0)
    }

    @MainActor
    func testIncomingVoiceAnswerCoalescesTapsAndPermissionDenialReenablesSameCall() async throws {
        let permissionDecision = SuspendedBoolDecision()
        var permissionRequests = 0
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            microphonePermissionDecisionOverride: {
                permissionRequests += 1
                return await permissionDecision.wait()
            },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-repeat-answer", callID: "incoming-repeat-answer",
            caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话"
        )

        state.acceptIncomingVoiceCall()
        XCTAssertEqual(state.incomingCallAnswerMode, "audio")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(permissionRequests, 1, "repeated taps must share the first answer attempt")
        await permissionDecision.resume(returning: false)
        for _ in 0..<200 where state.incomingCallAnswerMode != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertEqual(state.incomingVoiceCall?.id, "incoming-repeat-answer")
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/incoming-repeat-answer/accept"), 0)
    }

    @MainActor
    func testIncomingAnswerStatePreservesRefreshAndClearsOnReplacementOrTermination() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        var incoming = IncomingVoiceCall(
            id: "first-presentation", callID: "first-call",
            caller: makeUser(id: "peer", name: "Peer"), startedAt: "刚刚", source: "好友语音通话"
        )
        state.incomingVoiceCall = incoming
        state.incomingCallAnswerMode = "audio"
        let answerOperation = UUID()
        state.callStore.incomingCallAnswerOperationID = answerOperation
        incoming.caller = makeUser(id: "peer", name: "Updated Peer")
        incoming.stateVersion = 2
        state.incomingVoiceCall = incoming
        XCTAssertEqual(state.incomingCallAnswerMode, "audio", "profile refresh must not unlock another answer")
        XCTAssertEqual(state.callStore.incomingCallAnswerOperationID, answerOperation)

        let replacement = IncomingVoiceCall(
            id: "next-presentation", callID: "next-call", caller: incoming.caller,
            startedAt: "刚刚", source: "好友视频通话", requestedMediaMode: "video"
        )
        state.incomingVoiceCall = replacement
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertNil(state.callStore.incomingCallAnswerOperationID)
        state.incomingCallAnswerMode = "video"
        state.incomingVoiceCall = nil
        XCTAssertNil(state.incomingCallAnswerMode)
        state.callStore.incomingCallAnswerMode = "audio"
        state.callStore.incomingCallAnswerOperationID = UUID()
        state.callStore.reset()
        XCTAssertNil(state.incomingCallAnswerMode)
        XCTAssertNil(state.callStore.incomingCallAnswerOperationID)
    }

    @MainActor
    func testIncomingVoiceAcceptFailsClosedWhenLicenseIsRevokedDuringMicrophonePermission() async throws {
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
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-voice-license-revoked",
            callID: "incoming-voice-license-revoked",
            caller: makeUser(id: "incoming-voice-peer", name: "Voice Peer"),
            startedAt: "刚刚",
            source: "好友语音通话"
        )

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await permissionDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let microphoneDecisionIsWaiting = await permissionDecision.isWaiting()
        XCTAssertTrue(microphoneDecisionIsWaiting)

        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: false,
            videoEnabled: true
        )
        await permissionDecision.resume(returning: true)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-voice-license-revoked/accept"),
            0
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }
}
