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
    func testRTCPreviewPrepareCompletionCannotReviveAfterLicenseOrSessionABA() async {
        for sessionABA in [false, true] {
            let prepare = SuspendedBoolDecision()
            let video = TestVideoMediaClient()
            video.firstPrepareDecision = prepare
            let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
            let context = makeAuthenticatedAPIContext()
            let state = AppState(api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                                 videoPermissionDecisionOverride: { true }, apiContextOverride: context)
            let peer = makeUser(id: "prepare-aba", name: "Peer")
            state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            state.contacts = [peer]
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.presentVideoCallPreview(to: peer)
            for _ in 0..<200 {
                if await prepare.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let waiting = await prepare.isWaiting()
            XCTAssertTrue(waiting)
            if sessionABA {
                var other = context
                other.imToken = "prepare-session-b"
                state.overrideAPIContextForTesting(other)
                state.overrideAPIContextForTesting(context)
            } else {
                state.fileUploadConfig = .defaultValue
            }
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            await prepare.resume(returning: true)
            for _ in 0..<200 {
                if state.videoCallPreview == nil, video.previewEvents.last == "stop" { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNil(state.videoCallPreview)
            XCTAssertEqual(video.prepareCount, 1)
            XCTAssertNil(video.preparedGeneration)
            XCTAssertEqual(video.previewEvents.last, "stop")
            XCTAssertEqual(video.stopReasons.count, 1)
            XCTAssertEqual(video.startCount, 0)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls"), 0)
        }
    }

    func testRTCPreviewReplacementWaitsForOldPrepareCleanupWithoutStoppingNewOwner() async {
        let prepare = SuspendedBoolDecision()
        let video = TestVideoMediaClient()
        video.firstPrepareDecision = prepare
        let transport = VideoCallStartHTTPTransport(fileConfigDelayNanoseconds: 0, providerStatusCode: 200)
        let state = AppState(
            api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
            videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext()
        )
        let firstPeer = makeUser(id: "preview-first", name: "First")
        let secondPeer = makeUser(id: "preview-second", name: "Second")
        state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [firstPeer, secondPeer]
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.presentVideoCallPreview(to: firstPeer)
        for _ in 0..<200 {
            if await prepare.isWaiting() { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiting = await prepare.isWaiting()
        XCTAssertTrue(waiting)
        state.dismissVideoCallPreview()
        state.presentVideoCallPreview(to: secondPeer)
        let replacementID = state.videoCallPreview?.id
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(video.prepareCount, 1, "New prepare must wait until stale SDK work is cleaned up")
        await prepare.resume(returning: true)
        for _ in 0..<200 {
            if video.preparedGeneration == 2, state.videoCallPreview?.isPreparing == false { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state.videoCallPreview?.id, replacementID)
        XCTAssertEqual(state.videoCallPreview?.peer.id, secondPeer.id)
        XCTAssertEqual(video.prepareCount, 2)
        XCTAssertEqual(video.preparedGeneration, 2)
        XCTAssertEqual(video.previewEvents.last, "prepared:2", "Old cleanup must not stop the replacement camera")
        XCTAssertTrue(video.previewEvents.contains("stop"))
        state.dismissVideoCallPreview()
    }

    @MainActor
    func testIncomingVideoAcceptAfterServerAcceptCleansOldCallWhenTenantChangesDuringJoin() async throws {
        let joinDecision = SuspendedBoolDecision()
        let transport = VideoCallStartHTTPTransport(
            fileConfigDelayNanoseconds: 0,
            providerStatusCode: 200,
            incomingVideoJoinDecision: joinDecision
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
        state.fileUploadConfig = callLicenseFileConfig(
            voiceEnabled: true,
            videoEnabled: true
        )
        state.incomingVoiceCall = IncomingVoiceCall(
            id: "incoming-video-after-accept",
            callID: "incoming-video-after-accept",
            caller: makeUser(id: "incoming-video-peer", name: "Video Peer"),
            startedAt: "刚刚",
            source: "好友视频通话",
            requestedMediaMode: "video"
        )

        recordCallsAcceptanceDiagnostic(self, state: state, stage: "video-join-entry", counts: transport.callsAcceptancePathCounts())
        defer { recordCallsAcceptanceDiagnostic(self, state: state, stage: "video-join-exit", counts: transport.callsAcceptancePathCounts()) }
        state.acceptIncomingVideoCall(as: "audio")
        for _ in 0..<200 {
            if await joinDecision.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let joinIsWaiting = await joinDecision.isWaiting()
        XCTAssertTrue(joinIsWaiting)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/accept"),
            1
        )

        var switchedContext = makeAuthenticatedAPIContext()
        switchedContext.tenantID = "tenant-after-accept"
        switchedContext.imUID = "uid-after-accept"
        switchedContext.imToken = "im-token-after-accept"
        state.overrideAPIContextForTesting(switchedContext)
        await joinDecision.resume(returning: true)
        for _ in 0..<200 where
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/hangup") == 0
                || state.directCallTrackingCountsForTesting.attempts != 0
                || state.directCallTrackingCountsForTesting.resourceOwners != 0
                || state.directCallTrackingCountsForTesting.cleanupObligations != 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(
            transport.requestCount(path: "/api/rtc/calls/incoming-video-after-accept/hangup"),
            1
        )
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, 0)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.cleanupObligations, 0)
    }

    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: reproduce the two review timing windows, not just an earlier refresh.
    func testQueuedTerminalCleanupUsesRetainedCredentialAfterRefreshAndNewLogin() async throws {
        let callID = "queued-cleanup-new-login"
        let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "audio", peerUID: "peer", firstJoinGate: FirstJoinSuspensionGate())
        var context = makeAuthenticatedAPIContext()
        context.tenantAuthSession = IMStoredAuthSession(sessionID: "queued-session", refreshToken: "test-refresh", tokenType: "tenant")
        let state = AppState(api: makeCallEndingAPI(transport: transport), apiContextOverride: context)
        state.pendingRTCTerminalCompensations[callID] = PendingRTCTerminalCompensation(
            callID: callID, action: .hangup, reason: "setup_failed", context: context,
            scope: state.remoteDataScopeKey(for: context), idempotencyKey: "queued-stable-key",
            attemptCount: 0, nextAttemptAtNanoseconds: 0, lastErrorCode: nil)
        state.retryPendingRTCTerminalCompensationsForTesting()
        // No await: the retry Task is enqueued but cannot run on MainActor before these two changes.
        context.imToken = "last-owned-token"
        context.credentialRevision += 1
        state.overrideAPIContextForTesting(context)
        context.sessionEpoch = "new-login"
        context.imToken = "new-login-must-not-be-used"
        state.overrideAPIContextForTesting(context)
        for _ in 0..<200 where state.pendingRTCTerminalCompensationCountForTesting != 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        let path = "/api/rtc/calls/\(callID)/hangup"
        XCTAssertEqual(transport.requestCount(path: path), 1)
        XCTAssertEqual(transport.authorizationHeader(path: path), "Bearer last-owned-token")
        XCTAssertEqual(transport.idempotencyKeys(path: path), ["queued-stable-key"])
        XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
    }

    func testAcceptResponseAfterRefreshThenJoinAfterNewLoginKeepsOwnedCredential() async throws {
        for (callType, mode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            let acceptGate = FirstJoinSuspensionGate(), joinGate = FirstJoinSuspensionGate()
            let callID = "accept-refresh-\(callType)-\(mode)"
            let peer = makeUser(id: "accept-peer", name: "Peer")
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: joinGate, acceptGate: acceptGate, acceptedMediaMode: mode)
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(sessionID: "accept-session", refreshToken: "test-refresh", tokenType: "tenant")
            let voice = TestVoiceMediaClient(), video = TestVideoMediaClient()
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, videoMediaClient: video,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: context)
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: callType)
            if callType == "audio" { state.acceptIncomingVoiceCall() } else { state.acceptIncomingVideoCall(as: mode) }
            for _ in 0..<200 { if await acceptGate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let acceptWaiting = await acceptGate.isWaiting(); XCTAssertTrue(acceptWaiting, callID)
            context.imToken = "accept-refreshed-token"; context.credentialRevision += 1
            state.overrideAPIContextForTesting(context)
            await acceptGate.resumeFirst()
            for _ in 0..<200 { if await joinGate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let joinWaiting = await joinGate.isWaiting(); XCTAssertTrue(joinWaiting, callID)
            context.sessionEpoch = "replacement-login"; context.imToken = "replacement-must-not-be-used"
            state.overrideAPIContextForTesting(context)
            await joinGate.resumeFirst()
            let path = "/api/rtc/calls/\(callID)/hangup"
            for _ in 0..<200 where transport.requestCount(path: path) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(transport.authorizationHeader(path: path), "Bearer accept-refreshed-token", callID)
            XCTAssertEqual(transport.requestCount(path: path), 1, callID)
            XCTAssertTrue(voice.startedContexts.isEmpty); XCTAssertEqual(video.startCount, 0)
        }
    }
    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END

    @MainActor
    func testIncomingVoiceStaleJoinCannotClearOrHangupSameCallOwnedByReplacementSession() async throws {
        let joinGate = FirstJoinSuspensionGate()
        let callID = "incoming-voice-same-call-owner"
        let peer = makeUser(id: "incoming-voice-owner-peer", name: "Voice Peer")
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
            voiceMediaClient: NoopVoiceMediaClient(),
            microphonePermissionDecisionOverride: { true },
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        let incoming = IncomingVoiceCall(
            id: "incoming-voice-same-call",
            callID: callID,
            caller: peer,
            startedAt: "刚刚",
            source: "好友语音通话"
        )
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming

        state.acceptIncomingVoiceCall()
        for _ in 0..<200 {
            if await joinGate.isWaiting() {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let firstVoiceJoinIsWaiting = await joinGate.isWaiting()
        XCTAssertTrue(firstVoiceJoinIsWaiting)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)

        var replacementSession = makeAuthenticatedAPIContext()
        replacementSession.imToken = "replacement-voice-im-token"
        state.overrideAPIContextForTesting(replacementSession)
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = incoming
        state.acceptIncomingVoiceCall()

        for _ in 0..<200 where state.activeVoiceCall == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let replacementActiveID = try XCTUnwrap(state.activeVoiceCall?.id)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 2)

        await joinGate.resumeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.activeVoiceCall?.id, replacementActiveID)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/hangup"), 0)
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: replay notification feedback and delayed work after hangup.
    func testAudioRouteFeedbackDoesNotReconfigureAndOldTaskCannotReviveEndedCall() async throws {
        let voice = TestVoiceMediaClient()
        let state = AppState(voiceMediaClient: voice, apiContextOverride: makeAuthenticatedAPIContext())
        state.activeVoiceCall = VoiceCallSession(
            id: "route-owner",
            callID: "route-call",
            peer: makeUser(id: "peer", name: "Peer"),
            direction: "来电",
            startedAt: "now",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: false
        )
        for _ in 0..<346 {
            state.handleCallAudioRouteChange(.categoryChange)
            state.handleCallAudioRouteChange(.override)
            state.handleCallAudioRouteChange(.routeConfigurationChange)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(voice.audioReconcileSpeakerValues.isEmpty)
        state.handleCallAudioRouteChange(.newDeviceAvailable)
        for _ in 0..<20 where voice.audioReconcileSpeakerValues.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(voice.audioReconcileSpeakerValues, [false])
        state.handleCallAudioRouteChange(.oldDeviceUnavailable)
        state.activeVoiceCall = nil
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(
            voice.audioReconcileSpeakerValues,
            [false],
            "queued work after hangup must not reconfigure shared audio"
        )
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: app UI must request the existing CallKit answer then wait for activation.
    // Independent review regression: echo of in-app CXAnswerCallAction must not reject valid video-only call.
    @MainActor
    func testInAppVideoAnswerCallKitEchoPreservesVideoOnlyLicense() async throws {
        for voiceEnabled in [true, false] {
            let callID = "review-echo-video-\(voiceEnabled)", gate = FirstJoinSuspensionGate()
            let peer = makeUser(id: "review-peer", name: "Peer")
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let video = TestVideoMediaClient()
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "video", peerUID: peer.id, firstJoinGate: gate, acceptedMediaMode: "video", voiceEnabled: voiceEnabled)
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: TestVoiceMediaClient(), videoMediaClient: video, voiceCallSystem: system,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
            system.onAnswerRequest = { [weak state] callID in
                state?.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            }
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: voiceEnabled, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: "video")
            state.acceptIncomingVideoCall(as: "video")
            for _ in 0..<200 { if await gate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let waiting = await gate.isWaiting(); XCTAssertTrue(waiting, callID)
            XCTAssertEqual(system.requestedAnswers, [callID])
            XCTAssertEqual(state.incomingCallAnswerMode, "video", callID)
            XCTAssertEqual(state.fileUploadConfig.voiceCallEnabled, voiceEnabled)
            // Real CXProviderDelegate emits this for the action requested above.
            state.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            XCTAssertTrue(system.endedCalls.isEmpty, "Self-generated answer must not end \(callID)")
            XCTAssertEqual(state.incomingVoiceCall?.callID, callID, "Self-generated answer must preserve incoming owner")
            XCTAssertEqual(state.incomingCallAnswerMode, "video")
            await gate.resumeFirst()
            state.handleVoiceCallSystemEventForTesting(.audioSessionActivated)
            for _ in 0..<200 where video.startCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(video.startCount, 1, callID)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/reject"), 0, callID)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    func testInAppCallKitAnswerWaitsForAudioActivationForAllIncomingModes() async throws {
        for (callType, mode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            let callID = "system-answer-\(callType)-\(mode)", gate = FirstJoinSuspensionGate()
            let peer = makeUser(id: "system-peer", name: "Peer")
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let voice = TestVoiceMediaClient(), video = TestVideoMediaClient()
            let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: gate, acceptedMediaMode: mode)
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, videoMediaClient: video, voiceCallSystem: system,
                                 microphonePermissionDecisionOverride: { true }, videoPermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
            system.onAnswerRequest = { [weak state] callID in
                state?.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            }
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test", requestedMediaMode: callType)
            if callType == "audio" { state.acceptIncomingVoiceCall() } else { state.acceptIncomingVideoCall(as: mode) }
            for _ in 0..<200 { if await gate.isWaiting() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            let waiting = await gate.isWaiting(); XCTAssertTrue(waiting, callID)
            XCTAssertEqual(system.requestedAnswers, [callID])
            await gate.resumeFirst()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(voice.startedContexts.isEmpty, callID); XCTAssertEqual(video.startCount, 0, callID)
            state.handleVoiceCallSystemEventForTesting(.audioSessionActivated)
            for _ in 0..<200 where voice.startedContexts.isEmpty && video.startCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(voice.startedContexts.count, mode == "audio" ? 1 : 0, callID)
            XCTAssertEqual(video.startCount, mode == "video" ? 1 : 0, callID)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 1)
        }
    }
    func testSystemAnswerDoesNotDeduplicateUnrelatedOrInvalidatedOperation() async throws {
        for mismatch in ["call", "operation", "generation", "license"] {
            let callID = "system-answer-ownership-\(mismatch)"
            let context = makeAuthenticatedAPIContext()
            let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
            let transport = RTCSystemEndHTTPTransport()
            let state = AppState(api: makeCallEndingAPI(transport: transport), voiceCallSystem: system,
                                 apiContextOverride: context)
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: mismatch != "license")
            state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID,
                caller: makeUser(id: "peer", name: "Peer"), startedAt: "now", source: "test", requestedMediaMode: "video")
            let operationID = UUID()
            state.callStore.incomingCallAnswerOperationID = operationID
            state.incomingCallAnswerMode = "video"
            state.directCallAttempts[.video] = DirectCallAttempt(kind: .video,
                context: DirectCallContextBinding(context: context),
                capabilityGeneration: state.directCallCapabilityGeneration(for: .video) + (mismatch == "generation" ? 1 : 0),
                callID: mismatch == "call" ? "other-call" : callID, peerID: "peer", mediaMode: "video",
                operationID: mismatch == "operation" ? UUID() : operationID)
            state.handleVoiceCallSystemEventForTesting(.answer(callID: callID))
            for _ in 0..<100 where transport.requestCount(path: "/api/rtc/calls/\(callID)/reject") == 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(system.endedCalls.map(\.callID), [callID], mismatch)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/reject"), 1, mismatch)
            XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 0, mismatch)
            XCTAssertTrue(system.requestedAnswers.isEmpty, mismatch)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    func testInAppCallKitAnswerTransactionFailureNeverAcceptsOrStartsMedia() async throws {
        let callID = "system-answer-denied"
        let peer = makeUser(id: "system-peer", name: "Peer")
        let system = TestVoiceCallSystemIntegration(presentedCallIDs: [callID])
        system.answerRequestError = NSError(domain: "com.apple.CallKit.error.requesttransaction", code: 4)
        let voice = TestVoiceMediaClient()
        let transport = IncomingSameCallOwnershipHTTPTransport(callID: callID, callType: "audio", peerUID: peer.id, firstJoinGate: FirstJoinSuspensionGate())
        let state = AppState(api: makeCallEndingAPI(transport: transport), voiceMediaClient: voice, voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true }, apiContextOverride: makeAuthenticatedAPIContext())
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.incomingVoiceCall = IncomingVoiceCall(id: callID, callID: callID, caller: peer, startedAt: "now", source: "test")
        state.acceptIncomingVoiceCall()
        for _ in 0..<200 where system.endedCalls.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(system.requestedAnswers, [callID])
        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/accept"), 0)
        XCTAssertTrue(voice.startedContexts.isEmpty)
        XCTAssertFalse(system.hasPresentedCall(callID: callID))
        XCTAssertEqual(system.endedCalls.count, 1)
        state.clearRTCTerminalCompensationsForTesting()
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END

    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: restore focused refresh/owner regression coverage on the new baseline.
    @MainActor
    func testRefreshedAcceptedCallFailureCleansWithOwnedLatestCredential() async throws {
        for (callType, answerMode) in [("audio", "audio"), ("video", "audio"), ("video", "video")] {
            for switchSession in [false, true] {
                let gate = FirstJoinSuspensionGate()
                let callID = "refresh-cleanup-\(callType)-\(answerMode)-\(switchSession)"
                let peer = makeUser(id: "refresh-cleanup-peer", name: "Peer")
                let transport = IncomingSameCallOwnershipHTTPTransport(
                    callID: callID, callType: callType, peerUID: peer.id, firstJoinGate: gate,
                    gateStage: switchSession ? "join" : "provider", acceptedMediaMode: answerMode,
                    failJoin: true
                )
                var context = makeAuthenticatedAPIContext()
                context.tenantAuthSession = IMStoredAuthSession(
                    sessionID: "stable-cleanup-session", refreshToken: "test-refresh", tokenType: "tenant"
                )
                let state = AppState(
                    api: makeCallEndingAPI(transport: transport), voiceMediaClient: TestVoiceMediaClient(),
                    videoMediaClient: TestVideoMediaClient(), microphonePermissionDecisionOverride: { true },
                    videoPermissionDecisionOverride: { true }, apiContextOverride: context
                )
                state.voiceMediaClientAvailableOverride = true
                state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                state.incomingVoiceCall = IncomingVoiceCall(
                    id: callID, callID: callID, caller: peer, startedAt: "now", source: "test",
                    requestedMediaMode: callType
                )
                if callType == "audio" { state.acceptIncomingVoiceCall() }
                else { state.acceptIncomingVideoCall(as: answerMode) }
                for _ in 0..<200 {
                    if await gate.isWaiting() { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let waiting = await gate.isWaiting()
                XCTAssertTrue(waiting, callID)
                context.imToken = "rotated-cleanup-token"
                context.credentialRevision += 1
                state.overrideAPIContextForTesting(context)
                if switchSession {
                    // A -> refresh -> B: old cleanup must keep A's last token, never B's.
                    context.sessionEpoch = "replacement-login"
                    context.imToken = "different-login-token"
                    state.overrideAPIContextForTesting(context)
                }
                await gate.resumeFirst()
                let hangup = "/api/rtc/calls/\(callID)/hangup"
                for _ in 0..<200 where transport.requestCount(path: hangup) == 0 {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                XCTAssertEqual(transport.requestCount(path: hangup), 1, callID)
                XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer rotated-cleanup-token", callID)
                XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/accept"),
                               switchSession ? "Bearer im-token" : "Bearer rotated-cleanup-token", callID)
                XCTAssertNil(state.activeVoiceCall)
            }
        }
    }

    @MainActor
    func testTerminalCleanupRetryRefreshesOwnedCredentialsAndKeepsIdempotency() async throws {
        for switchSession in [false, true] {
            let callID = "cleanup-retry-\(switchSession)"
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID, callType: "audio", peerUID: "peer", firstJoinGate: FirstJoinSuspensionGate(),
                hangupFailures: 1
            )
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "retry-session", refreshToken: "test-refresh", tokenType: "tenant"
            )
            var now: UInt64 = 0
            let state = AppState(
                api: makeCallEndingAPI(transport: transport), rtcRequestNowNanoseconds: { now },
                rtcTerminalCompensationFailureDelayNanoseconds: [60_000_000_000], apiContextOverride: context
            )
            // An already queued cleanup uses the same production retry path as setup failure.
            state.pendingRTCTerminalCompensations[callID] = PendingRTCTerminalCompensation(
                callID: callID, action: .hangup, reason: "setup_failed", context: context,
                scope: state.remoteDataScopeKey(for: context), idempotencyKey: "stable-test-cleanup-key",
                attemptCount: 0, nextAttemptAtNanoseconds: 0, lastErrorCode: nil
            )
            state.retryPendingRTCTerminalCompensationsForTesting()
            for _ in 0..<200 where state.pendingRTCTerminalCompensations[callID]?.lastErrorCode == nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let hangup = "/api/rtc/calls/\(callID)/hangup"
            XCTAssertEqual(transport.requestCount(path: hangup), 1)
            XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer im-token")
            context.imToken = "retry-refreshed-token"
            context.credentialRevision += 1
            state.overrideAPIContextForTesting(context)
            if switchSession {
                context.sessionEpoch = "different-retry-login"
                context.imToken = "must-not-use-new-login-token"
                state.overrideAPIContextForTesting(context)
            }
            now = 120_000_000_000
            state.retryPendingRTCTerminalCompensationsForTesting()
            for _ in 0..<200 where state.pendingRTCTerminalCompensationCountForTesting != 0 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(transport.requestCount(path: hangup), 2)
            XCTAssertEqual(transport.authorizationHeader(path: hangup), "Bearer retry-refreshed-token")
            XCTAssertEqual(transport.idempotencyKeys(path: hangup), ["stable-test-cleanup-key", "stable-test-cleanup-key"])
            XCTAssertEqual(state.pendingRTCTerminalCompensationCountForTesting, 0)
            state.clearRTCTerminalCompensationsForTesting()
        }
    }

    @MainActor
    func testVideoPreviewAndDowngradeRefreshUseLatestCredentialsWithoutRevivingStaleWork() async throws {
        for action in ["preview", "downgrade"] {
            for stage in ["files", "provider"] {
                for change in ["refresh", "session", "license"] {
                    let gate = FirstJoinSuspensionGate()
                    let callID = "video-\(action)-\(stage)-\(change)"
                    let peer = makeUser(id: "refresh-video-peer", name: "Peer")
                    let transport = IncomingSameCallOwnershipHTTPTransport(
                        callID: callID, callType: "video", peerUID: peer.id, firstJoinGate: gate,
                        gateStage: stage
                    )
                    var context = makeAuthenticatedAPIContext()
                    context.tenantAuthSession = IMStoredAuthSession(
                        sessionID: "stable-video-session", refreshToken: "test-refresh", tokenType: "tenant"
                    )
                    let video = TestVideoMediaClient()
                    let state = AppState(
                        api: makeCallEndingAPI(transport: transport), videoMediaClient: video,
                        videoPermissionDecisionOverride: { true }, apiContextOverride: context
                    )
                    state.setCurrentUser(makeUser(id: "uid-1", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
                    state.contacts = [peer]
                    state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
                    if action == "preview" {
                        state.presentVideoCallPreview(to: peer)
                    } else {
                        state.activeVoiceCall = VoiceCallSession(
                            id: callID, callID: callID, peer: peer, direction: "呼出", startedAt: "now",
                            statusText: "连接中", mediaState: .connecting, isMuted: false, speakerOn: true,
                            requestedMediaMode: "video", mediaMode: "video", localCameraEnabled: true
                        )
                        state.downgradeActiveVideoCallToAudio()
                    }
                    for _ in 0..<200 {
                        if await gate.isWaiting() { break }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    let waiting = await gate.isWaiting()
                    XCTAssertTrue(waiting, callID)
                    context.imToken = "rotated-video-token"
                    context.credentialRevision += 1
                    if change == "session" { context.sessionEpoch = "replacement-video-login" }
                    state.overrideAPIContextForTesting(context)
                    if change == "license" {
                        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: false, videoEnabled: false)
                    }
                    await gate.resumeFirst()
                    if change == "refresh" {
                        for _ in 0..<200 where video.prepareCount + video.downgradeToAudioCount == 0 {
                            try await Task.sleep(nanoseconds: 5_000_000)
                        }
                        XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/provider"),
                                       stage == "files" ? "Bearer rotated-video-token" : "Bearer im-token", callID)
                        if action == "preview" {
                            XCTAssertEqual(video.prepareCount, 1, callID)
                            XCTAssertNotNil(state.videoCallPreview, callID)
                        } else {
                            XCTAssertEqual(video.downgradeToAudioCount, 1, callID)
                            XCTAssertEqual(transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/downgrade"),
                                           "Bearer rotated-video-token", callID)
                            XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio", callID)
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        XCTAssertEqual(video.prepareCount, 0, callID)
                        XCTAssertEqual(video.downgradeToAudioCount, 0, callID)
                        XCTAssertEqual(transport.requestCount(path: "/api/rtc/calls/\(callID)/downgrade"), 0, callID)
                    }
                    if action == "preview" { state.dismissVideoCallPreview() }
                }
            }
        }
    }

    @MainActor
    func testDirectCallBindingPreservesRealSessionAndAuthorityBoundaries() {
        func session(id: String = "stable-session", refresh: String = "test-refresh-token",
                     authVersion: Int64 = 2, generation: Int64 = 3) -> IMStoredAuthSession {
            IMStoredAuthSession(sessionID: id, refreshToken: refresh, tokenType: "tenant",
                                authVersion: authVersion, sessionGeneration: generation)
        }
        var context = makeAuthenticatedAPIContext()
        context.tenantAuthSession = session()
        let original = DirectCallContextBinding(context: context)
        var refreshed = context
        refreshed.imToken = "rotated-test-token"
        refreshed.credentialRevision += 1
        refreshed.tenantAuthSession = session(refresh: "rotated-test-refresh-token", generation: 4)
        XCTAssertEqual(original, DirectCallContextBinding(context: refreshed))

        let identityChanges: [(String, (inout IMAPIContext) -> Void)] = [
            ("account", { $0.accountID = "another-account" }),
            ("tenant", { $0.tenantID = "another-tenant" }),
            ("uid", { $0.imUID = "another-uid" }),
            ("app", { $0.appID = "another-app" }),
            ("device", { $0.deviceID = "another-device" }),
            ("epoch", { $0.sessionEpoch = "another-epoch" }),
            ("session", { $0.tenantAuthSession = session(id: "another-session") }),
            ("authVersion", { $0.tenantAuthSession = session(authVersion: 3) }),
            ("logout", { $0.imToken = nil }),
            ("sessionRemoved", { $0.tenantAuthSession = nil })
        ]
        for (name, change) in identityChanges {
            var changed = context
            change(&changed)
            XCTAssertNotEqual(original, DirectCallContextBinding(context: changed), name)
        }
        var legacy = makeAuthenticatedAPIContext()
        let originalLegacy = DirectCallContextBinding(context: legacy)
        legacy.imToken = "different-legacy-token"
        XCTAssertNotEqual(originalLegacy, DirectCallContextBinding(context: legacy))
    }

    @MainActor
    func testIncomingCallSurvivesSameSessionCredentialRotationDuringJoin() async throws {
        let scenarios = [("audio", "audio"), ("video", "audio"), ("video", "video")].flatMap { callType, answerMode in
            ["provider", "join", "participants"].map { (callType, answerMode, $0) }
        }
        for (callType, answerMode, gateStage) in scenarios {
            let joinGate = FirstJoinSuspensionGate()
            let callID = "incoming-\(callType)-\(answerMode)-\(gateStage)-rotation"
            let peer = makeUser(id: "refresh-peer", name: "Refresh Peer")
            let transport = IncomingSameCallOwnershipHTTPTransport(
                callID: callID,
                callType: callType,
                peerUID: peer.id,
                firstJoinGate: joinGate,
                gateStage: gateStage,
                acceptedMediaMode: answerMode
            )
            let media = TestVoiceMediaClient()
            let videoMedia = TestVideoMediaClient()
            var context = makeAuthenticatedAPIContext()
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "stable-tenant-session",
                refreshToken: "test-refresh-token",
                tokenType: "tenant"
            )
            let state = AppState(
                api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: media,
                videoMediaClient: videoMedia,
                microphonePermissionDecisionOverride: { true },
                videoPermissionDecisionOverride: { true },
                apiContextOverride: context
            )
            state.voiceMediaClientAvailableOverride = true
            state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
            state.incomingVoiceCall = IncomingVoiceCall(
                id: callID,
                callID: callID,
                caller: peer,
                startedAt: "刚刚",
                source: "好友通话",
                requestedMediaMode: callType
            )
            if callType == "audio" {
                state.acceptIncomingVoiceCall()
            } else {
                state.acceptIncomingVideoCall(as: answerMode)
            }
            for _ in 0..<200 {
                if await joinGate.isWaiting() { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let joinIsWaiting = await joinGate.isWaiting()
            XCTAssertTrue(joinIsWaiting, callType)

            // Foreground refresh advances credentials without replacing the login session.
            context.imToken = "rotated-test-im-token"
            context.credentialRevision += 1
            context.tenantAuthSession = IMStoredAuthSession(
                sessionID: "stable-tenant-session", refreshToken: "rotated-test-refresh-token",
                tokenType: "tenant", sessionGeneration: 1
            )
            state.overrideAPIContextForTesting(context)
            await joinGate.resumeFirst()
            let hangupPath = "/api/rtc/calls/\(callID)/hangup"
            for _ in 0..<200 where media.startedContexts.isEmpty && videoMedia.startCount == 0 && transport.requestCount(path: hangupPath) == 0 {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(
                transport.authorizationHeader(path: "/api/rtc/calls/\(callID)/accept"),
                gateStage == "provider" ? "Bearer rotated-test-im-token" : "Bearer im-token",
                "\(callType)/\(gateStage)"
            )
            XCTAssertEqual(media.startedContexts.count, answerMode == "audio" ? 1 : 0, "\(callType)/\(gateStage)")
            XCTAssertEqual(videoMedia.startCount, answerMode == "video" ? 1 : 0, "\(callType)/\(gateStage)")
            XCTAssertEqual(state.activeVoiceCall?.callID, callID, callType)
            XCTAssertEqual(transport.requestCount(path: hangupPath), 0, callType)
        }
    }
    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END
}
