import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
    func testCallStoreSeparatesRootPresentationFromCallControlsAndHistory() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let store = state.callStore
        let peer = makeUser(id: "call-peer", name: "Call Peer")
        var updates: [CallStore.RootPresentation] = []
        var appStateChanges = 0
        let presentation = store.rootPresentationUpdates.sink { updates.append($0) }
        let forwarding = state.objectWillChange.sink { appStateChanges += 1 }
        defer {
            presentation.cancel()
            forwarding.cancel()
        }

        XCTAssertEqual(updates, [store.rootPresentation])
        store.calls = [CallRecord(id: "record", title: "Call Peer", subtitle: "通话", time: "12:00", status: "已结束")]
        store.incomingCallAnswerMode = "audio"
        store.isEndingActiveCall = true
        XCTAssertEqual(updates.count, 1)

        let incoming = IncomingVoiceCall(id: "incoming", caller: peer, startedAt: "12:00", source: "来电")
        store.incomingVoiceCall = incoming
        XCTAssertEqual(updates.last?.incoming, incoming)
        store.incomingVoiceCall = nil
        XCTAssertNil(updates.last?.incoming)

        let active = VoiceCallSession(
            id: "active", peer: peer, direction: "呼出", startedAt: "12:00",
            isMuted: false, speakerOn: false, requestedMediaMode: "video", mediaMode: "video"
        )
        store.activeVoiceCall = active
        XCTAssertEqual(updates.last?.activeCallID, active.id)
        let unminimizedUpdateCount = updates.count
        store.activeVoiceCall?.isMuted = true
        XCTAssertEqual(updates.count, unminimizedUpdateCount)

        store.activeVoiceCall?.isMinimized = true
        XCTAssertEqual(updates.last?.minimizedVideoCall?.id, active.id)
        XCTAssertNil(state.presentedCallSession)
        state.presentedCallSession = nil
        XCTAssertEqual(store.activeVoiceCall?.id, active.id)
        store.activeVoiceCall?.isMinimized = false
        XCTAssertNil(updates.last?.minimizedVideoCall)
        XCTAssertEqual(state.presentedCallSession?.id, active.id)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(appStateChanges, 0)
    }
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END

    func testRemoteVideoTerminalStateStopsVideoMediaBeforeClearingCall() async {
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeIsolatedAPIContext()
        )
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

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-1",
                status: "ended",
                roomID: "room-video-1",
                callerUID: "me",
                calleeUID: "peer-video",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video"
            )
        ])

        for _ in 0..<10 where videoMediaClient.stopReasons.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(videoMediaClient.stopReasons, ["remote_ended"])
        XCTAssertEqual(state.toast, "视频通话已结束")
        XCTAssertEqual(state.calls.first?.subtitle, "视频呼出 · 通话已结束")
        XCTAssertEqual(state.videoCallTerminalResult?.title, "对方已挂断")
        XCTAssertEqual(state.videoCallTerminalResult?.cause, "对方结束了本次通话。")

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-1",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "remote_hangup",
                stateVersion: 2
            )
        ])
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(videoMediaClient.stopReasons, ["remote_ended"])
        XCTAssertNil(state.activeVoiceCall)
    }

    @MainActor
    func testVideoTerminalResultDoesNotReplaceExistingPresentation() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let firstPeer = makeUser(id: "first-video-peer", name: "First Peer")
        let secondPeer = makeUser(id: "second-video-peer", name: "Second Peer")
        state.videoCallTerminalResult = VideoCallTerminalResult(
            callID: "first-video-call",
            peer: firstPeer,
            reason: "local_hangup"
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "second-video-session",
            callID: "second-video-call",
            roomID: "room-second-video",
            rtcToken: "rtc-token",
            peer: secondPeer,
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

        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "second-video-call")

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.videoCallTerminalResult?.callID, "first-video-call")
        XCTAssertEqual(state.videoCallTerminalResult?.peer.id, "first-video-peer")
    }

    @MainActor
    func testRemoteVideoDowngradeMediaStateAppliesAudioMode() {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-downgraded",
            callID: "video-remote-downgraded",
            roomID: "room-video-downgraded",
            rtcToken: "rtc-token",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "来电",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            connectedAt: Date(timeIntervalSince1970: 100),
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: true,
            remoteCameraEnabled: true,
            remoteVideoTrackReady: true
        )

        state.handleVideoMediaEvent(.remoteDowngradedToAudio, callID: "video-remote-downgraded")

        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "通话中")
        XCTAssertEqual(state.activeVoiceCall?.localCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteCameraEnabled, false)
        XCTAssertEqual(state.activeVoiceCall?.remoteVideoTrackReady, false)
    }

    @MainActor
    func testVideoUpgradeRequestWithoutExistingEndpointOnlyShowsUnsupportedNotice() {
        let state = AppState(apiContextOverride: makeAuthenticatedAPIContext())
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        state.activeVoiceCall = VoiceCallSession(
            id: "video-audio-local",
            callID: "video-audio-mode",
            peer: makeUser(id: "peer-video", name: "Video Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "等待对方连接",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            requestedMediaMode: "video",
            mediaMode: "audio",
            localCameraEnabled: false,
            remoteCameraEnabled: false
        )

        state.requestActiveAudioCallVideoUpgrade()

        XCTAssertEqual(state.toast, "当前接口暂不支持切回视频，请重新发起视频通话")
        XCTAssertEqual(state.activeVoiceCall?.mediaMode, "audio")
        XCTAssertEqual(state.activeVoiceCall?.statusText, "等待对方连接")
    }

    func testTerminalVideoSignalCreatesNeutralRecordAndLateCanonicalTerminalRefinesWithoutRestartingOrStoppingTwice() async {
        let videoMediaClient = TestVideoMediaClient()
        let state = AppState(
            videoMediaClient: videoMediaClient,
            apiContextOverride: makeIsolatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "video-local-terminal",
            callID: "video-terminal",
            roomID: "room-video-terminal",
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
            remoteCameraEnabled: true,
            stateVersion: 7
        )

        state.handleVideoMediaEvent(.serverSignalTerminal, callID: "video-terminal")

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.calls.first?.status, "已结束")
        XCTAssertEqual(state.calls.first?.endReason, "server_signal_terminal")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)
        XCTAssertTrue(videoMediaClient.stopReasons.isEmpty)

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-terminal",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "caller_hangup",
                stateVersion: 6
            )
        ])
        XCTAssertEqual(state.calls.first?.endReason, "server_signal_terminal")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)

        state.reconcileRTCCallsForTesting([
            RemoteRTCCall(
                id: "video-terminal",
                status: "ended",
                callType: "video",
                requestedMediaMode: "video",
                mediaMode: "video",
                endReason: "caller_hangup",
                stateVersion: 7
            ),
            RemoteRTCCall(
                id: "different-call",
                status: "ended",
                endReason: "peer_hangup",
                stateVersion: 99
            )
        ])

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingVoiceCall)
        XCTAssertEqual(state.calls.first?.endReason, "caller_hangup")
        XCTAssertEqual(state.calls.first?.stateVersion, 7)
        XCTAssertTrue(videoMediaClient.stopReasons.isEmpty)
    }

    func testVideoTerminalReasonsShareCauseAndSafeNextActionLanguage() {
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "rejected").title, "对方已拒绝")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "callee_busy").title, "对方正在通话中")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "timeout").title, "无人接听")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "permission_denied").title, "未获得媒体权限")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "media_failed").title, "媒体设备不可用")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "client_scope_changed").title, "会话已变更")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "license_revoked").title, "视频通话不可用")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "answered_elsewhere").title, "已在其他设备接听")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "network_error").title, "通话连接失败")
        XCTAssertEqual(VideoCallTerminalPresentation.resolve(reason: "remote_hangup").nextAction, "返回聊天")
    }

    func testVideoTerminalResultKeepsStableIDForSameCallID() {
        let peer = makeUser(id: "peer-video", name: "Video Peer")
        let first = VideoCallTerminalResult(callID: " video-terminal ", peer: peer, reason: "remote_hangup")
        let second = VideoCallTerminalResult(callID: "video-terminal", peer: peer, reason: "remote_hangup")
        let fallback = VideoCallTerminalResult(peer: peer, reason: "remote_hangup")

        XCTAssertEqual(first.callID, "video-terminal")
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, fallback.id)
    }

    @MainActor
    func testVoiceMediaClosedEventClearsActiveCall() throws {
        let state = AppState()
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "",
            peer: makeUser(id: "peer-1", name: "Peer"),
            direction: "来电",
            startedAt: "刚刚",
            statusText: "连接中",
            mediaState: .connecting,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: nil
        )

        state.handleVoiceMediaEvent(.closed, callID: "call-1")

        XCTAssertNil(state.activeVoiceCall)
    }

    @MainActor
    func testVoiceRecoveryExhaustionHangsUpAndClearsActiveCall() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-recovery",
            callID: "call-recovery",
            roomID: "room-recovery",
            rtcToken: "rtc-token-memory-only",
            mediaBaseURL: "",
            peer: makeUser(id: "peer-recovery", name: "Peer"),
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "网络不稳定",
            mediaState: .unstable,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: Date(timeIntervalSince1970: 1_010)
        )

        state.handleVoiceMediaEvent(.recoveryExhausted, callID: "call-recovery")
        for _ in 0..<100 where transport.requests().isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertEqual(state.toast, "语音连接恢复失败，通话已结束")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.path, "/api/rtc/calls/call-recovery/hangup")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["reason"] as? String, "ice_recovery_failed")
        XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("rtc-token-memory-only") == true)
    }

    @MainActor
    func testEndingVoiceCallRecordUsesClockTimeInsteadOfStaticJustNow() async throws {
        let transport = FakeHTTPTransport(results: [successfulEmptyAPIResponse()])
        let state = AppState(
            api: makeCallEndingAPI(transport: transport),
            apiContextOverride: makeAuthenticatedAPIContext()
        )
        // WDT_IOS1_RTC_HANGUP_POLICY_FIXTURE_20261112_BEGIN
        try installActiveAppPolicyForHTTPFixture(on: state)
        // WDT_IOS1_RTC_HANGUP_POLICY_FIXTURE_20261112_END
        let peer = makeUser(id: "peer-1", name: "Peer")
        state.calls = []
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.activeVoiceCall = VoiceCallSession(
            id: "call-local-1",
            callID: "call-1",
            roomID: "room-1",
            rtcToken: "rtc-token",
            mediaBaseURL: "",
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            startedAtDate: Date(timeIntervalSince1970: 1_000),
            connectedAt: Date(timeIntervalSince1970: 1_030)
        )

        state.endActiveVoiceCall()
        let immediateRecord = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(immediateRecord.callID, "call-1")
        XCTAssertEqual(immediateRecord.status, "已结束")
        await waitForCallEnd { state.activeVoiceCall == nil }

        let record = try XCTUnwrap(state.calls.first)
        XCTAssertEqual(record.callID, "call-1")
        XCTAssertEqual(record.status, "已结束")
        XCTAssertNotEqual(record.time, "刚刚")
        XCTAssertNotNil(record.startedAt)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(transport.requests().first?.url?.path, "/api/rtc/calls/call-1/hangup")
    }

    @MainActor
    func testCancelledUserDisplayAndVoiceCallAreBlocked() throws {
        // WDT_IOS1_CANCELLED_RTC_LICENSE_FIXTURE_20261112_BEGIN
        let state = AppState(
            api: makeCallEndingAPI(transport: FakeHTTPTransport(results: [])),
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: makeAuthenticatedAPIContext(imUID: "me")
        )
        // WDT_IOS1_CANCELLED_RTC_LICENSE_FIXTURE_20261112_END
        state.fileUploadConfig = callLicenseFileConfig(voiceEnabled: true, videoEnabled: true)
        let cancelledByStatus = makeUser(id: "cancelled-1", name: "Old Name", status: "cancelled")
        let cancelledByAvatar = makeUser(id: "cancelled-2", name: "Old Avatar", avatarURL: cancelledUserAvatarPath)

        XCTAssertTrue(cancelledByStatus.isCancelledUser)
        XCTAssertEqual(cancelledByStatus.displayName, cancelledUserDisplayName)
        XCTAssertEqual(cancelledByStatus.displayAvatarURL, cancelledUserAvatarPath)
        XCTAssertTrue(cancelledByAvatar.isCancelledUser)
        XCTAssertEqual(cancelledByAvatar.displayName, cancelledUserDisplayName)

        state.setCurrentUser(makeUser(id: "me", name: "Me")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [cancelledByStatus]

        XCTAssertFalse(state.canStartDirectConversation(with: cancelledByStatus))
        XCTAssertFalse(state.canStartVoiceCall(with: cancelledByStatus))
        XCTAssertEqual(state.voiceCallUnavailableReason(for: cancelledByStatus), "该用户已注销，无法发起语音通话")

        state.startOutgoingVoiceCall(to: cancelledByStatus)

        XCTAssertNil(state.activeVoiceCall)
        XCTAssertFalse(state.isStartingVoiceCall)
        XCTAssertEqual(state.toast, "该用户已注销，无法发起语音通话")
    }

    func testMainShellBootstrapTraceStateClaimsOnceAndResetsOnBegin() throws {
        let trace = MainShellBootstrapTraceState()

        trace.begin(at: 10)

        XCTAssertEqual(trace.claimAppearance(at: 10.25), 250)
        XCTAssertNil(trace.claimAppearance(at: 10.5))
        XCTAssertEqual(trace.claimInteractive(at: 10.75), 750)
        XCTAssertNil(trace.claimInteractive(at: 11))

        trace.begin(at: 20)

        XCTAssertEqual(trace.claimAppearance(at: 20.25), 250)
        XCTAssertEqual(trace.claimInteractive(at: 20.5), 500)
    }

    func testAuthFlowGenerationStateIssuesCurrentAndInvalidatesTokens() throws {
        let state = AuthFlowGenerationState()
        let initial = state.currentToken()

        XCTAssertTrue(state.isCurrent(initial))

        let first = state.issueToken()
        XCTAssertFalse(state.isCurrent(initial))
        XCTAssertTrue(state.isCurrent(first))

        let second = state.issueToken()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))

        state.invalidate()
        XCTAssertFalse(state.isCurrent(second))
        XCTAssertTrue(state.isCurrent(state.currentToken()))
    }

    func testDeviceRevocationHandlingStateClaimsUntilFinished() throws {
        let state = DeviceRevocationHandlingState()

        XCTAssertFalse(state.isHandlingRevocation)
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.isHandlingRevocation)
        XCTAssertFalse(state.begin())

        state.finish()

        XCTAssertFalse(state.isHandlingRevocation)
        XCTAssertTrue(state.begin())

        state.finish()
        XCTAssertFalse(state.isHandlingRevocation)
    }

    func testAppStateRealtimeDeviceKickedClearsCurrentDeviceSession() throws {
        IMAppPolicyLastGoodStore.clearAll()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true)
        let context = makeAuthenticatedAPIContext()
        context.save()
        defer {
            IMAPIContext.clearStoredSession(resetDeviceIdentity: true)
            IMAppPolicyLastGoodStore.clearAll()
        }

        let realtime = DeviceKickRealtimeTransport()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            apiContextOverride: context
        )

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "error",
                requestID: "kick-1",
                payload: [
                    "code": .string("device_kicked"),
                    "reason_code": .string("device_kicked"),
                    "message": .string(DeviceRevocationDetector.logoutMessage)
                ]
            )
        )

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authScreen, .accountLogin)
        XCTAssertEqual(state.toast, DeviceRevocationDetector.logoutMessage)
        XCTAssertFalse(IMAPIContext.load().hasIMSession)
        XCTAssertTrue(realtime.disconnectCalls.contains(false))
    }

    func testAppStateRealtimeResyncFullSchedulesExistingRecoveryRefresh() throws {
        let context = makeAuthenticatedAPIContext()
        let realtime = DeviceKickRealtimeTransport()
        let syncEngine = DefaultSyncEngine()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        defer { syncEngine.cancelRealtimeRecoveryTasks() }
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "resync",
                requestID: "resync-full",
                payload: [
                    "full_sync": .bool(true)
                ]
            )
        )

        XCTAssertTrue(syncEngine.hasRealtimeRecoveryTask(.refresh))
    }

    func testAppStateRealtimeResyncChannelsSchedulesExistingConversationRecovery() throws {
        let context = makeAuthenticatedAPIContext()
        let realtime = DeviceKickRealtimeTransport()
        let syncEngine = DefaultSyncEngine()
        let state = AppState(
            realtimeClient: realtime,
            voiceMediaClient: NoopVoiceMediaClient(),
            remoteSyncEngine: syncEngine,
            apiContextOverride: context
        )
        defer { syncEngine.cancelRealtimeRecoveryTasks() }
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.conversationStore.hydrateCachedConversations([
            ConversationMessageSnapshot(
                id: "group-1",
                title: "测试群",
                subtitle: "",
                kind: .group,
                lastMessage: "",
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 3,
                accentHex: 0x6677FF,
                participants: [],
                messages: []
            )
        ])

        realtime.onEnvelope?(
            RealtimeEnvelope(
                type: "resync",
                requestID: "resync-channel",
                payload: [
                    "channels": .array([
                        .object([
                            "channel_id": .string("group-1"),
                            "channel_type": .string("group")
                        ])
                    ])
                ]
            )
        )

        XCTAssertTrue(syncEngine.hasRealtimeRecoveryTask(.conversationFlush))
        XCTAssertEqual(syncEngine.drainRealtimeRecoveryConversations(), ["group-1"])
    }

    func testWorkspaceAccessClassifierDoesNotPromoteGroupMemberMissingToWorkspaceBlock() throws {
        let state = AppState()

        XCTAssertNil(state.workspaceAccessCode(from: "group_member_not_found current user is not a group member"))
        XCTAssertTrue(isGroupMemberNotFoundMessage("group_member_not_found current user is not a group member"))
        XCTAssertEqual(state.workspaceAccessCode(from: "tenant_member_not_found current enterprise membership is not found"), "tenant_member_not_found")
        XCTAssertEqual(state.workspaceAccessCode(from: "当前企业成员关系不存在，请切换其他企业"), "tenant_member_not_found")
        XCTAssertEqual(state.workspaceAccessCode(from: "workspace_switch_disabled by policy"), "workspace_switch_disabled")
        XCTAssertEqual(state.workspaceAccessCode(from: "管理员已关闭企业切换"), "workspace_switch_disabled")
        XCTAssertEqual(state.workspaceAccessCode(from: "member_projection_syncing"), "member_projection_syncing")
        XCTAssertEqual(state.workspaceAccessCode(from: "成员数据正在同步，请稍后重试"), "member_projection_syncing")
        XCTAssertEqual(state.workspaceAccessCode(from: "member_projection_failed"), "member_projection_failed")
        XCTAssertEqual(state.workspaceAccessCode(from: "成员数据同步失败，请联系管理员"), "member_projection_failed")
        XCTAssertEqual(state.workspaceAccessCode(from: "app_tenant_not_bound"), "workspace_not_found")
    }

    func testIOSAppIDNormalizesLegacyValuesAndPrioritizesCanonicalCandidate() throws {
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID(nil), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID(""), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("jht-ios-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("ios-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("web-main"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitongqiyetest.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitongim.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("com.jianhuitong.app"), IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("custom-ios-app"), "custom-ios-app")
        XCTAssertEqual(IMAPIContext.normalizedIOSAppID("custom-ios-app", allowCustomAppID: false), IMAPIContext.canonicalIOSAppID)

        let candidates = IMAPIContext.iosAppIDCandidates(preferred: "web-main")
        XCTAssertEqual(candidates.first, IMAPIContext.canonicalIOSAppID)
        XCTAssertTrue(candidates.contains("web-main"))
        XCTAssertEqual(candidates.filter { $0 == IMAPIContext.canonicalIOSAppID }.count, 1)
        XCTAssertEqual(
            IMAPIContext.iosAppIDCandidates(preferred: "custom-ios-app", allowCustomAppID: false),
            [IMAPIContext.canonicalIOSAppID]
        )
    }

    func testReleaseGuardIgnoresLocalAppIDResidue() throws {
        XCTAssertEqual(
            IMAPIContext.normalizedIOSAppID("debug-local-app", allowCustomAppID: false),
            IMAPIContext.canonicalIOSAppID
        )
        XCTAssertEqual(
            IMAPIContext.iosAppIDCandidates(preferred: "debug-local-app", allowCustomAppID: false),
            [IMAPIContext.canonicalIOSAppID]
        )
    }

    func testLegacyIOSAppIDMigrationClearsOldSession() throws {
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "jht-ios-main",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "com.jianhuitongim.app",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertTrue(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "com.jianhuitong.app",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertFalse(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: IMAPIContext.canonicalIOSAppID,
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
        XCTAssertFalse(IMAPIContext.shouldClearStoredSessionForAppIDMigration(
            storedAppID: "",
            normalizedAppID: IMAPIContext.canonicalIOSAppID
        ))
    }

    func testAppStateSyncsConfirmedConversationAttachmentsIntoFileList() throws {
        let state = AppState()
        var conversation = makeConversation(id: "g_files", kind: .group, unread: 0, lastMsgSeq: 3, lastReadSeq: 3)
        conversation.title = "产品内测群"
        var attachment = ChatMessage(
            id: "m1",
            senderId: "u_mia",
            senderName: "Mia",
            text: "risk-report.pdf",
            time: "10:00",
            channelSeq: 3,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "risk-report.pdf"
        attachment.attachmentFileID = "file-1"
        attachment.attachmentSizeBytes = 2_048
        attachment.attachmentMimeType = "application/pdf"
        attachment.attachmentMediaCategory = "pdf"
        attachment.attachmentExtension = "pdf"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentDownloadURL = "https://files.example.test/file-1/download"
        attachment.attachmentPreviewAvailable = true
        attachment.attachmentPreviewURL = "https://files.example.test/file-1/preview"

        var pending = makeMessage(id: "local_1", seq: 0, status: .sending, isOutgoing: true, text: "draft.csv", time: "刚刚", kind: .file)
        pending.attachmentFileID = "file-pending"
        pending.attachmentName = "draft.csv"
        conversation.messages = [pending, attachment]

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.id == "file-1" }))
        XCTAssertEqual(file.name, "risk-report.pdf")
        XCTAssertEqual(file.type, "PDF")
        XCTAssertEqual(file.owner, "Mia")
        XCTAssertEqual(file.source, "产品内测群")
        XCTAssertEqual(file.scope, "群文件")
        XCTAssertEqual(file.channelID, "g_files")
        XCTAssertEqual(file.channelType, "group")
        XCTAssertTrue(file.downloadAvailable)
        XCTAssertTrue(file.previewAvailable)
        XCTAssertEqual(file.downloadURL, "https://files.example.test/file-1/download")
        XCTAssertEqual(file.previewURL, "https://files.example.test/file-1/preview")
        XCTAssertEqual(state.files(for: "g_files").map(\.id), ["file-1"])
        XCTAssertFalse(state.files.contains(where: { $0.id == "file-pending" }))
    }

    func testAppStateAttachmentEndpointOnlyMessageKeepsEndpointsOutOfFinalURLs() throws {
        let state = AppState()
        var conversation = makeConversation(id: "g_endpoint_only", kind: .group, unread: 0, lastMsgSeq: 9, lastReadSeq: 9)
        conversation.title = "交易通知群"
        var attachment = ChatMessage(
            id: "m-endpoint",
            senderId: "u_chen",
            senderName: "陈星",
            text: "README.md",
            time: "03:44",
            channelSeq: 9,
            isOutgoing: false,
            status: .read,
            kind: .file,
            reactions: [],
            readBy: [],
            unreadBy: []
        )
        attachment.attachmentName = "README.md"
        attachment.attachmentFileID = "file-endpoint"
        attachment.attachmentSizeBytes = 633_000
        attachment.attachmentMimeType = "text/markdown"
        attachment.attachmentMediaCategory = "document"
        attachment.attachmentExtension = "md"
        attachment.attachmentDownloadAvailable = true
        attachment.attachmentPreviewAvailable = true
        attachment.attachmentDownloadURL = "/api/tenant/files/file-endpoint/presign-download"
        attachment.attachmentPreviewURL = "/api/tenant/files/file-endpoint"
        attachment.attachmentThumbnailURL = "/api/tenant/files/file-endpoint/thumbnail"
        conversation.messages = [attachment]

        XCTAssertNil(state.resolvedAttachmentDownloadURL(for: attachment))
        XCTAssertNil(state.resolvedAttachmentPreviewURL(for: attachment))
        XCTAssertNil(state.resolvedAttachmentThumbnailURL(for: attachment))
        XCTAssertTrue(state.attachmentCanRefreshRemoteFile(attachment))

        state.syncAttachmentFilesFromConversation(conversation)

        let file = try XCTUnwrap(state.files.first(where: { $0.id == "file-endpoint" }))
        XCTAssertEqual(file.downloadURL, "")
        XCTAssertEqual(file.previewURL, "")
        XCTAssertEqual(file.thumbnailURL, "")
        XCTAssertTrue(file.downloadAvailable)
        XCTAssertFalse(file.previewAvailable)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
