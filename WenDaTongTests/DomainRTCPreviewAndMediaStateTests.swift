import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong
@testable import IM4Features // WDT_IOS1_FEATURES_CALLS_UI_20261111

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
    func testRootPresentsAndDismissesTerminalCallCoverFromCallStore() throws {
        let context = makeIsolatedAPIContext()
        let suite = "terminal-cover-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
        let policyKey = "im2.ios.lastGoodAppPolicies.v1"
        let previousPolicy = UserDefaults.standard.data(forKey: policyKey)
        defer { XCTAssertEqual(UserDefaults.standard.data(forKey: policyKey), previousPolicy) }
        let cachedPolicy = try JSONDecoder().decode(RemoteAppCurrentPolicy.self, from: Data("""
        {"app_id":"\(context.appID)","platform":"ios","status":"active","registration_enabled":false,"cache_ttl_seconds":60}
        """.utf8))
        IMAppPolicyLastGoodStore.save(cachedPolicy, appID: context.appID, defaults: defaults)
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END
        let policy = HTTPTransportResult(
            data: Data("""
            {"ok":true,"data":{"app_id":"\(context.appID)","platform":"ios","status":"active","registration_enabled":true,"cache_ttl_seconds":60}}
            """.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [policy])
        let base = try XCTUnwrap(URL(string: "https://terminal-cover.example.test"))
        let api = IMAPIClient(platformBase: base, bootstrapBases: [], httpTransport: transport,
                              runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context)
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
        let state = IMAppPolicyLastGoodStore.$fixtureSuiteName.withValue(suite) {
            AppState(api: api, pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
                     rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
                     rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
                     protectedSessionStore: InMemoryProtectedSessionStore(),
                     registrationSessionStore: InMemoryProtectedSessionStore(), apiContextOverride: context)
        }
        XCTAssertTrue(state.hasResolvedCurrentAppPolicyForAuthUI)
        XCTAssertFalse(state.isRegistrationEnabledForAuthUI)
        let beforeMount = transport.requests().count
        func mountedPolicyRequest() -> URLRequest? {
            transport.requests().dropFirst(beforeMount).first { request in
                guard request.httpMethod == "GET", let url = request.url,
                      url.host == base.host, url.path == "/api/platform/apps/current-policy" else { return false }
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(where: { $0.name == "_ts" }) == true
            }
        }
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112
        let root = RootView(mountingNormalContentForTesting: true)
            .appStateEnvironment(state)
            .environment(\.scenePhase, .inactive)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        let policyDeadline = Date().addingTimeInterval(2)
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
        while (mountedPolicyRequest() == nil || !state.isRegistrationEnabledForAuthUI), Date() < policyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let policyRequest = try XCTUnwrap(mountedPolicyRequest())
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END
        let query = policyRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertEqual(policyRequest.url?.host, base.host)
        XCTAssertEqual(policyRequest.url?.path, "/api/platform/apps/current-policy")
        XCTAssertEqual(query?.first(where: { $0.name == "app_id" })?.value, context.appID)
        XCTAssertNotNil(query?.first(where: { $0.name == "_ts" })?.value)
        XCTAssertTrue(state.hasResolvedCurrentAppPolicyForAuthUI)
        XCTAssertEqual(state.currentAppPolicy?.appID, context.appID)
        XCTAssertTrue(state.isRegistrationEnabledForAuthUI)
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
        XCTAssertEqual(IMAppPolicyLastGoodStore.usable(appID: context.appID, defaults: defaults)?.policy.registrationEnabled, true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(host.presentedViewController)

        state.videoCallTerminalResult = VideoCallTerminalResult(
            callID: "terminal-cover", peer: makeUser(id: "peer-cover", name: "Call Peer"), reason: "local_hangup"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotNil(host.presentedViewController)

        state.dismissVideoCallTerminalResult()
        XCTAssertNil(state.videoCallTerminalResult)
        let dismissalDeadline = Date().addingTimeInterval(2)
        while host.presentedViewController != nil, Date() < dismissalDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(host.presentedViewController)
    }
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END

    // WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112: Caller identity tests are in DomainRTCJoinAndPeerResolutionTests.swift.

    @MainActor
    func testVoiceMediaEventsGateConnectedAtUntilTransportAndTrackReady() throws {
        let state = AppState()
        let peer = makeUser(id: "peer-1", name: "Peer")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let connectedAt = Date(timeIntervalSince1970: 1_030)
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "https://rtc.example.test",
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方接听",
            mediaState: .preparing,
            isMuted: false,
            speakerOn: true,
            startedAtDate: startedAt,
            connectedAt: nil
        )

        state.handleVoiceMediaEvent(.callAccepted, callID: "call-1", now: startedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .preparing)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "连接中")
        XCTAssertNil(state.activeVoiceCall?.connectedAt)

        state.handleVoiceMediaEvent(.roomJoined, callID: "call-1", now: startedAt)
        state.handleVoiceMediaEvent(.localDescriptionSet, callID: "call-1", now: startedAt)
        state.handleVoiceMediaEvent(.iceChecking, callID: "call-1", now: startedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connecting)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "连接中")
        XCTAssertNil(state.activeVoiceCall?.connectedAt)

        state.handleVoiceMediaEvent(.iceConnected, callID: "call-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "call-1", now: Date(timeIntervalSince1970: 1_031))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: "call-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.callAccepted, callID: "call-1", now: Date(timeIntervalSince1970: 1_060))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "call-1", now: Date(timeIntervalSince1970: 1_061))
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)
    }

    @MainActor
    func testIncomingVideoAnsweredAsAudioAcceptsVoiceMediaConnectedEvent() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-video-audio-connected"
        let peer = makeUser(id: "incoming-video-audio-peer", name: "Video Peer")
        let voiceMediaClient = TestVoiceMediaClient(
            events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady]
        )
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "video",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: voiceMediaClient,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-audio",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await joinGate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await joinGate.resumeFirst()
        for _ in 0..<200 where state.activeVoiceCall?.mediaState != .connected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, callID)
        defer { state.stopRTCMediaStateHeartbeatForTesting() }
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.requestedMediaMode, "video")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.callID, callID)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerUID, peer.id)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerDeviceID, "peer-device")
        XCTAssertNotEqual(
            voiceMediaClient.startedContexts.first?.peerDeviceID,
            voiceMediaClient.startedContexts.first?.localDeviceID
        )
        state.endActiveVoiceCall()
        for _ in 0..<100 where voiceMediaClient.stopReasons.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(voiceMediaClient.stopReasons, ["user_ending"])
        state.activeVoiceCall = nil // End the isolated fixture after verifying immediate capture cleanup.

    }

    @MainActor
    func testIncomingAudioStartsHeartbeatThroughRealAcceptAndJoin() async throws {
        for invalidator in ["account", "device", "epoch", "end", "license"] {
            let joinGate = FirstJoinSuspensionGate()
            let callID = "incoming-audio-connected-\(invalidator)"
            let peer = makeUser(id: "incoming-audio-peer", name: "Video Peer")
            let voiceMediaClient = TestVoiceMediaClient(
                events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady]
            )
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID,
                callType: "audio",
                peerUID: peer.id,
                firstJoinGate: joinGate
            )
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                httpTransport: transport
            )
            let state = AppState(
                api: api,
                voiceMediaClient: voiceMediaClient,
                videoMediaClient: TestVideoMediaClient(),
                microphonePermissionDecisionOverride: { true },
                apiContextOverride: makeAuthenticatedAPIContext()
            )
            state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(
                id: "incoming-audio",
                callID: callID,
                caller: peer,
                startedAt: "刚刚",
                source: "好友视频通话",
                requestedMediaMode: "audio"
            )

            state.acceptIncomingVoiceCall()
            for _ in 0..<200 {
                if await joinGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await joinGate.resumeFirst()
            for _ in 0..<200 where state.activeVoiceCall?.mediaState != .connected {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.callID, callID)
            defer { state.stopRTCMediaStateHeartbeatForTesting() }
            XCTAssertEqual(state.activeVoiceCall?.callID, callID)
            XCTAssertEqual(state.activeVoiceCall?.requestedMediaMode, "audio")
            XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
            XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
            XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
            XCTAssertNotNil(state.activeVoiceCall?.connectedAt)
            let heartbeat = try XCTUnwrap(state.rtcMediaHeartbeatSnapshotForTesting)
            let operationID = try XCTUnwrap(heartbeat.operationID)
            let savedContext = try XCTUnwrap(voiceMediaClient.startedContexts.first)
            let signalPath = "/api/rtc/rooms/\(callID)-room/signals"
            let icePath = "/api/rtc/rooms/\(callID)-room/ice-credentials"
            _ = try await savedContext.pollSignals("", "rtc-token-before-refresh")
            state.updateRTCMediaHeartbeatContextForTesting { $0.imToken = "refreshed-im-token" }
            _ = try await savedContext.pollSignals("", "rtc-token-after-refresh")
            let refreshedIce = try await savedContext.refreshIceCredentials("rtc-token-after-refresh")
            XCTAssertEqual(refreshedIce.rtcToken, "rtc-refreshed")
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.context.imToken, "refreshed-im-token")
            XCTAssertEqual(transport.requestCount(path: signalPath), 2)
            XCTAssertEqual(transport.requestCount(path: icePath), 1)
            XCTAssertEqual(transport.authorizationHeader(path: signalPath), "Bearer rtc-token-after-refresh")
            XCTAssertEqual(transport.authorizationHeader(path: icePath), "Bearer rtc-token-after-refresh")

            state.handleVoiceMediaEvent(.iceDisconnected, callID: callID, operationID: operationID)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.generation, heartbeat.generation)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "reconnecting")
            state.handleVoiceMediaEvent(.connectionRecovered, callID: callID, operationID: operationID)
            XCTAssertTrue(state.activeVoiceCall?.voiceTransportConnected ?? false)
            XCTAssertFalse(state.activeVoiceCall?.remoteAudioRTPReady ?? true)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "connected")
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.generation, heartbeat.generation)
            state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: callID, operationID: operationID)
            XCTAssertTrue(state.activeVoiceCall?.remoteAudioRTPReady ?? false)
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.desiredMediaState, "connected")
            XCTAssertEqual(state.rtcMediaHeartbeatSnapshotForTesting?.operationID, operationID)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.callID, callID)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerUID, peer.id)
            XCTAssertEqual(voiceMediaClient.startedContexts.first?.peerDeviceID, "peer-device")
            XCTAssertNotEqual(
                voiceMediaClient.startedContexts.first?.peerDeviceID,
                voiceMediaClient.startedContexts.first?.localDeviceID
            )
            switch invalidator {
            case "account": state.updateRTCMediaHeartbeatContextForTesting { $0.accountID = "replacement-account" }
            case "device": state.updateRTCMediaHeartbeatContextForTesting { $0.deviceID = "replacement-device" }
            case "epoch": state.updateRTCMediaHeartbeatContextForTesting { $0.sessionEpoch = "replacement-epoch" }
            case "end": state.endActiveVoiceCall()
            default: state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: true)
            }
            do {
                _ = try await savedContext.pollSignals("", "rtc-token-after-refresh")
                XCTFail("Old poll closure must be rejected after \(invalidator)")
            } catch is CancellationError {} catch { XCTFail("Unexpected poll error: \(error)") }
            do {
                _ = try await savedContext.refreshIceCredentials("rtc-token-after-refresh")
                XCTFail("Old ICE closure must be rejected after \(invalidator)")
            } catch is CancellationError {} catch { XCTFail("Unexpected ICE error: \(error)") }
            XCTAssertEqual(transport.requestCount(path: signalPath), 2, invalidator)
            XCTAssertEqual(transport.requestCount(path: icePath), 1, invalidator)
            state.activeVoiceCall = nil
        }

    }

    @MainActor
    func testIncomingAudioRetriesReceiverMediaStartBeforeEndingCall() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-audio-start-retry"
        let peer = makeUser(id: "incoming-audio-retry-peer", name: "Audio Peer")
        let voiceMediaClient = TestVoiceMediaClient(
            events: [.iceConnected, .remoteAudioTrackReady, .remoteAudioRTPReady],
            startErrors: [IMAPIError.server("音频设备启动暂不可用")]
        )
        let transport = IncomingSameCallOwnershipHTTPTransport(
            callID: callID,
            callType: "audio",
            peerUID: peer.id,
            firstJoinGate: joinGate
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: transport
        )
        let state = AppState(
            api: api,
            voiceMediaClient: voiceMediaClient,
            videoMediaClient: TestVideoMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-audio-retry",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话",
            requestedMediaMode: "audio"
        )

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await joinGate.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await joinGate.resumeFirst()
        for _ in 0..<300 {
            if voiceMediaClient.startedContexts.count == 2,
               state.activeVoiceCall?.mediaState == .connected {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(voiceMediaClient.startedContexts.count, 2)
        XCTAssertEqual(voiceMediaClient.startedContexts.first?.isCaller, false)
        XCTAssertEqual(voiceMediaClient.startedContexts.last?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertNotEqual(state.toast, Optional("音频设备启动失败，通话已结束"))
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/hangup"), 0)

        state.endActiveVoiceCall()
        for _ in 0..<100 where voiceMediaClient.stopReasons.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(voiceMediaClient.stopReasons, ["user_ending"])
        state.activeVoiceCall = nil
    }

    func testVideoCallPreviewShowsStartingStateRejectsDuplicateAndSurfacesProviderFailure() async throws {
        let routeDefaultsName = "BlueStoneIMTests.video-provider-route.\(UUID().uuidString)"
        let routeDefaults = try XCTUnwrap(UserDefaults(suiteName: routeDefaultsName))
        defer { routeDefaults.removePersistentDomain(forName: routeDefaultsName) }
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 503
        )
        let preparationTransport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0, providerStatusCode: 200
        )
        let phasedTransport = CallsAcceptancePhasedTransport(
            preparation: preparationTransport, operation: transport
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            httpTransport: phasedTransport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: routeDefaults)
        )
        XCTAssertEqual(
            api.activateRuntimeRoutesForTesting(try videoCallRuntimeRouteSnapshot()),
            .applied
        )
        let state = AppState(
            api: api,
            videoMediaClient: TestVideoMediaClient(),
            videoPermissionDecisionOverride: { false },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.fileUploadConfig = videoCallEnabledFileConfig()
        // A prepared preview has already negotiated provider/capabilities in the real factory.
        // Complete that original phase before simulating a later provider outage.
        state.presentVideoCallPreview(to: peer, channelID: "peer-video:uid-1")
        for _ in 0..<200 {
            if state.videoCallPreview?.isPreparing == false,
               state.rtcDeviceCapabilitiesReportedSessionKey != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(state.videoCallPreview)
        XCTAssertFalse(state.videoCallPreview?.isPreparing ?? true)
        XCTAssertNotNil(state.rtcDeviceCapabilitiesReportedSessionKey)
        XCTAssertEqual(preparationTransport.requestCount(path: "/api/rtc/device-capabilities"), 1)
        recordCallsAcceptanceDiagnostic(self, state: state, stage: "preview-preparation-complete",
            counts: preparationTransport.callsAcceptancePathCounts())
        phasedTransport.beginOperation()

        recordCallsAcceptanceDiagnostic(self, state: state, stage: "preview-provider-entry", counts: transport.callsAcceptancePathCounts())
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "preview-provider-exit", counts: transport.callsAcceptancePathCounts()) }
        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertTrue(state.videoCallPreview?.isStartingCall ?? false)
        XCTAssertNil(state.videoCallPreview?.startError)

        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertNil(state.videoCallPreview?.startError)

        let deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while state.isStartingVideoCall,
              DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds {
            await Task.yield()
        }

        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertFalse(state.videoCallPreview?.isStartingCall ?? true)
        XCTAssertNotNil(state.videoCallPreview)
        XCTAssertEqual(transport.requestCount(path: "/api/tenant/files/config"), 1)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/provider"), 1)
        XCTAssertEqual(state.videoCallPreview?.startError, "视频服务暂不可用，请稍后重试")
        XCTAssertNil(state.toast)
    }

    func testVideoCallPreviewScopeChangeReliablyClearsStartingWithoutPollutingNextGeneration() async throws {
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
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [peer]
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.videoCallPreview = VideoCallPreview(
            id: "preview-scope-change",
            peer: peer,
            channelID: "peer-video:uid-1",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: "摄像头暂不可用，可关闭摄像头继续"
        )

        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        var changedContext = makeAuthenticatedAPIContext()
        changedContext.tenantID = "tenant-2"
        changedContext.imUID = "uid-2"
        changedContext.imToken = "im-token-2"
        state.overrideAPIContextForTesting(changedContext)

        for _ in 0..<80 where state.isStartingVideoCall {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertFalse(state.videoCallPreview?.isStartingCall ?? true)
        XCTAssertEqual(state.videoCallPreview?.startError, "登录状态已变化，请重新打开视频通话")
        XCTAssertNil(state.activeVoiceCall)

        state.overrideAPIContextForTesting(makeAuthenticatedAPIContext())
        state.fileUploadConfig = videoCallEnabledFileConfig()
        state.videoCallPreview = VideoCallPreview(
            id: "preview-next-generation",
            peer: peer,
            channelID: "peer-video:uid-1",
            cameraEnabled: false,
            isPreparing: false,
            unavailableReason: nil
        )
        state.startOutgoingVideoCallFromPreview()
        XCTAssertTrue(state.isStartingVideoCall)
        XCTAssertTrue(state.videoCallPreview?.isStartingCall ?? false)
        state.dismissVideoCallPreview()
        XCTAssertFalse(state.isStartingVideoCall)
        XCTAssertNil(state.videoCallPreview)
    }

    func testEnabledVideoConfigReportsCapabilitiesOncePerAuthenticatedSession() async throws {
        let transport = RTCDeviceCapabilityBootstrapHTTPTransport()
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
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.refreshFileUploadConfig()
        await waitForRequestCount(1, path: "/api/rtc/device-capabilities", transport: transport)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)
        let firstBody = try XCTUnwrap(transport.lastJSONBody(path: "/api/rtc/device-capabilities"))
        let capabilities = try XCTUnwrap(firstBody["device_capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["version"] as? String, RTCDeviceCapabilities.protocolVersion)
        XCTAssertEqual(capabilities["audio"] as? Bool, true)
        XCTAssertEqual(capabilities["video"] as? Bool, true)
        XCTAssertEqual(capabilities["camera_available"] as? Bool, true)

        state.refreshFileUploadConfig()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)

        var nextSession = makeAuthenticatedAPIContext()
        nextSession.tenantID = "tenant-2"
        nextSession.imUID = "uid-2"
        nextSession.imToken = "im-token-2"
        state.overrideAPIContextForTesting(nextSession)
        state.refreshFileUploadConfig()
        await waitForRequestCount(2, path: "/api/rtc/device-capabilities", transport: transport)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 2)
    }

    func testVideoCapabilityBootstrapFailureDoesNotBlockConfigOrSurfaceToast() async throws {
        let transport = RTCDeviceCapabilityBootstrapHTTPTransport(capabilityStatusCode: 503)
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
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        state.refreshFileUploadConfig()
        await waitForRequestCount(1, path: "/api/rtc/device-capabilities", transport: transport)

        XCTAssertTrue(state.fileUploadConfig.videoCallEnabled)
        XCTAssertNil(state.toast)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/device-capabilities"), 1)
    }

    func testVideoMediaEventsGateTimingOnRemoteAudioAndTrackRemoteCameraState() {
        let state = AppState(videoMediaClient: NoopVideoMediaClient())
        let connectedAt = Date(timeIntervalSince1970: 2_030)
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-1",
            callID: "video-1",
            roomID: "room-video-1",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true
        )

        state.handleVideoMediaEvent(.mediaConnected, callID: "video-1", now: connectedAt)
        XCTAssertNil(state.activeVoiceCall?.connectedAt)
        state.handleVideoMediaEvent(.remoteAudioTrackReady, callID: "video-1", now: connectedAt)
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)

        state.handleVideoMediaEvent(.remoteCameraPaused, callID: "video-1")
        XCTAssertFalse(state.activeVoiceCall?.remoteCameraEnabled ?? true)
        XCTAssertFalse(state.activeVoiceCall?.remoteVideoTrackReady ?? true)
        state.handleVideoMediaEvent(.remoteCameraResumed, callID: "video-1")
        XCTAssertTrue(state.activeVoiceCall?.remoteCameraEnabled ?? false)
        XCTAssertFalse(state.activeVoiceCall?.remoteVideoTrackReady ?? true)
        state.handleVideoMediaEvent(.remoteVideoTrackReady, callID: "video-1")
        XCTAssertTrue(state.activeVoiceCall?.remoteVideoTrackReady ?? false)

        state.handleVideoMediaEvent(.cameraUnavailable, callID: "video-1")
        XCTAssertFalse(state.activeVoiceCall?.localCameraEnabled ?? true)
        XCTAssertEqual(state.activeVoiceCall?.mediaState, .connected)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.toast, "摄像头暂不可用，已关闭摄像头继续视频通话")

        state.handleVideoMediaEvent(.reconnecting, callID: "video-1", now: connectedAt.addingTimeInterval(10))
        XCTAssertTrue(state.activeVoiceCall?.isRecoveringNetwork ?? false)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "网络不稳定，正在恢复")
        state.handleVideoMediaEvent(.connectionRecovered, callID: "video-1", now: connectedAt.addingTimeInterval(15))
        XCTAssertFalse(state.activeVoiceCall?.isRecoveringNetwork ?? true)
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        state.handleVideoMediaEvent(.mediaConnected, callID: "video-1", now: connectedAt.addingTimeInterval(20))
        XCTAssertEqual(state.activeVoiceCall?.connectedAt, connectedAt)
    }

    func testIncomingVideoAnswerPlanKeepsVideoSessionWhenCameraUnavailable() {
        let unavailable = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "video",
            cameraAvailable: false,
            cameraAuthorized: false
        )
        XCTAssertEqual(unavailable.acceptedMode, "video")
        XCTAssertTrue(unavailable.startsVideoMedia)
        XCTAssertFalse(unavailable.cameraEnabled)
        XCTAssertEqual(unavailable.notice, "摄像头暂不可用，已关闭摄像头继续视频通话")

        let authorized = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "video",
            cameraAvailable: true,
            cameraAuthorized: true
        )
        XCTAssertEqual(authorized.acceptedMode, "video")
        XCTAssertTrue(authorized.startsVideoMedia)
        XCTAssertTrue(authorized.cameraEnabled)
        XCTAssertNil(authorized.notice)

        let audio = RTCIncomingVideoAnswerPlan.resolve(
            requestedMode: "audio",
            cameraAvailable: true,
            cameraAuthorized: true
        )
        XCTAssertEqual(audio.acceptedMode, "audio")
        XCTAssertFalse(audio.startsVideoMedia)
        XCTAssertFalse(audio.cameraEnabled)
        XCTAssertNil(audio.notice)
    }

    func testVideoCallPreviewControlsKeepUnavailableCameraStateTruthful() {
        let unavailable = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: true,
            isPreparing: false,
            isStartingCall: false,
            unavailableReason: "摄像头暂不可用，可关闭摄像头继续"
        )

        XCTAssertEqual(unavailable.cameraTitle, "摄像头不可用")
        XCTAssertEqual(unavailable.cameraSystemImage, "video.slash.fill")
        XCTAssertFalse(unavailable.cameraControlEnabled)
        XCTAssertEqual(unavailable.startTitle, "关闭摄像头继续")

        let available = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: false,
            isPreparing: false,
            isStartingCall: false,
            unavailableReason: nil
        )

        XCTAssertEqual(available.cameraTitle, "开启摄像头")
        XCTAssertEqual(available.cameraSystemImage, "video.slash.fill")
        XCTAssertTrue(available.cameraControlEnabled)
        XCTAssertEqual(available.startTitle, "开始呼叫")

        let preparing = VideoCallPreviewControlPresentation.resolve(
            cameraEnabled: true,
            isPreparing: true,
            isStartingCall: false,
            unavailableReason: nil
        )
        XCTAssertFalse(preparing.cameraControlEnabled)
    }

    func startAudioHeartbeat(transport: RTCMediaHeartbeatHTTPTransport, callID: String = "audio-heartbeat") -> AppState {
        let state = makeRTCMediaHeartbeatState(transport: transport)
        var call = makeRTCMediaHeartbeatVideoCall(callID: callID)
        call.requestedMediaMode = "audio"
        call.mediaMode = "audio"
        state.activeVoiceCall = call
        state.startRTCMediaStateHeartbeatForTesting(
            callID: callID, roomID: "room-heartbeat", rtcToken: "rtc-token-heartbeat",
            joinedRoom: rtcMediaHeartbeatJoinedRoom(token: "rtc-token-heartbeat")
        )
        return state
    }

    func heartbeatStates(_ transport: RTCMediaHeartbeatHTTPTransport) -> [String] {
        transport.requests().compactMap { request in
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return body["media_state"] as? String
        }
    }

    func qualifyAudio(_ state: AppState) {
        state.handleVoiceMediaEvent(.iceConnected, callID: "audio-heartbeat")
        state.handleVoiceMediaEvent(.remoteAudioTrackReady, callID: "audio-heartbeat")
        state.handleVoiceMediaEvent(.remoteAudioRTPReady, callID: "audio-heartbeat")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
