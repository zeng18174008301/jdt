import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

extension AppState {
    var localVideoCapabilities: RTCDeviceCapabilities {
        RTCDeviceCapabilities(
            version: RTCDeviceCapabilities.protocolVersion,
            audio: true,
            video: videoMediaClient.isAvailable,
            cameraAvailable: videoMediaClient.cameraAvailable,
        )
    }

    static func normalizedRTCMediaMode(_ rawValue: String, fallback: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "video" || normalized == "audio" {
            return normalized
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" ? "video" : "audio"
    }

    private func rtcDeviceCapabilityReportSessionKey(for context: IMAPIContext) -> String? {
        guard context.hasIMSession else { return nil }
        let sessionDiscriminator = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDiscriminator = context.imToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedDiscriminator = sessionDiscriminator?.isEmpty == false
            ? sessionDiscriminator!
            : fallbackDiscriminator
        guard !resolvedDiscriminator.isEmpty else { return nil }
        return [
            remoteDataScopeKey(for: context),
            context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
            String(resolvedDiscriminator.hashValue)
        ].joined(separator: "|")
    }

    func resetRTCDeviceCapabilityReportState() {
        rtcDeviceCapabilitiesReportedSessionKey = nil
        rtcDeviceCapabilitiesReportInFlightKeys.removeAll()
    }

    func scheduleRTCDeviceCapabilitiesReportIfNeeded() {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        let context = apiContext
        guard isAuthenticated,
              context.hasIMSession,
              fileUploadConfig.videoCallEnabled,
              let sessionKey = rtcDeviceCapabilityReportSessionKey(for: context),
              rtcDeviceCapabilitiesReportedSessionKey != sessionKey,
              !rtcDeviceCapabilitiesReportInFlightKeys.contains(sessionKey) else {
            return
        }
        let capabilities = localVideoCapabilities
        rtcDeviceCapabilitiesReportInFlightKeys.insert(sessionKey)
        Task { [weak self, api, context, sessionKey, capabilities] in
            defer {
                self?.rtcDeviceCapabilitiesReportInFlightKeys.remove(sessionKey)
            }
            do {
                try await api.updateRTCDeviceCapabilities(context: context, capabilities: capabilities)
                guard let self,
                      self.isAuthenticated,
                      self.rtcDeviceCapabilityReportSessionKey(for: self.apiContext) == sessionKey else {
                    return
                }
                self.rtcDeviceCapabilitiesReportedSessionKey = sessionKey
            } catch {
                // Capability presence only optimizes reachability checks. Login and chat must stay available.
            }
        }
    }

    func presentVideoCallPreview(to peer: IMUser, channelID: String? = nil) {
        guard guardCallLicenseForAction(.video) else { return }
        guard !hasTruthfulCallOwnership else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先处理当前通话")
            return
        }
        if let reason = videoCallUnavailableReason(for: peer) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        videoCallTerminalResult = nil
        let previewID = "video-preview-\(UUID().uuidString)"
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let capabilityGeneration = callLicenseActionGeneration(for: .video)
        let binding = DirectCallContextBinding(context: context)
        if let previousID = videoCallPreview?.id {
            queueVideoPreviewCleanup(id: previousID, reason: "preview_replaced")
        }
        videoCallPreview = VideoCallPreview(
            id: previewID,
            peer: peer,
            channelID: channelID,
            cameraEnabled: videoMediaClient.cameraAvailable,
            isPreparing: true,
            unavailableReason: videoMediaClient.cameraAvailable ? nil : "未检测到摄像头，将以关闭摄像头方式呼叫"
        )
        Task { [weak self, videoMediaClient] in
            guard let self else { return }
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled
                    && self.isCurrentVideoCallPreview(id: previewID, peerID: peer.id, scope: scope)
                    && DirectCallContextBinding(context: self.apiContext) == binding
                    && self.callLicenseActionGeneration(for: .video) == capabilityGeneration
                    && !self.hasTruthfulCallOwnership
            }
            defer {
                if !isCurrent(), self.videoCallPreview?.id == previewID {
                    self.videoCallPreview = nil
                    self.queueVideoPreviewCleanup(id: previewID, reason: "preview_stale")
                }
            }
            guard isCurrent() else { return }
            do {
                _ = try await self.currentFileUploadConfig(
                    context: try self.currentDirectCallRequestContext(context),
                    scope: scope
                )
                guard isCurrent() else { return }
                let provider = try await self.currentRTCProvider(
                    context: try self.currentDirectCallRequestContext(context),
                    media: .video,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }
                try self.requireVideoProviderCapabilities(provider)
            } catch {
                guard isCurrent() else { return }
                self.videoCallPreview = nil
                self.queueVideoPreviewCleanup(id: previewID, reason: "preview_provider_unavailable")
                self.handleRemoteError(error, fallback: "视频通话服务暂不可用", rtcMedia: .video)
                return
            }
            guard isCurrent() else { return }
            let cameraGranted = await self.ensureVideoPermission()
            guard isCurrent() else { return }
            if cameraGranted {
                // Serialize only capture/cleanup, not permission prompts. A new
                // preview or call must never race an older preview's stop.
                let predecessor = self.videoPreviewMediaTask
                let preparation = Task { @MainActor [weak self, videoMediaClient] in
                    await predecessor?.value
                    guard let self, isCurrent() else { return }
                    if let previousOwner = self.videoPreviewMediaOwnerID, previousOwner != previewID {
                        await self.stopVideoPreviewMediaIfOwned(id: previousOwner, reason: "preview_replaced")
                    }
                    guard isCurrent() else { return }
                    self.videoPreviewMediaOwnerID = previewID
                    do {
                        try await videoMediaClient.preparePreview(preferFrontCamera: true)
                        guard isCurrent() else {
                            await self.stopVideoPreviewMediaIfOwned(id: previewID, reason: "preview_stale")
                            return
                        }
                        self.videoCallPreview?.cameraEnabled = true
                    } catch {
                        if isCurrent() {
                            self.videoCallPreview?.cameraEnabled = false
                            self.videoCallPreview?.unavailableReason = "摄像头暂不可用，可关闭摄像头继续"
                        }
                        await self.stopVideoPreviewMediaIfOwned(id: previewID, reason: "preview_prepare_failed")
                    }
                }
                self.videoPreviewMediaTask = preparation
                await preparation.value
                guard isCurrent() else { return }
            } else {
                self.videoCallPreview?.cameraEnabled = false
                self.videoCallPreview?.unavailableReason = "未开启摄像头权限，可关闭摄像头继续"
            }
            if isCurrent() {
                self.videoCallPreview?.isPreparing = false
            }
        }
    }

    private func isCurrentVideoCallPreview(
        id: String,
        peerID: String,
        scope: String
    ) -> Bool {
        isVideoCallLicensedForCurrentTenant
            && isCurrentRemoteScope(scope)
            && videoCallPreview?.id == id
            && videoCallPreview?.peer.id == peerID
    }

    private func stopVideoPreviewMediaIfOwned(id: String, reason: String) async {
        guard videoPreviewMediaOwnerID == id, activeVideoMediaCallID == nil else { return }
        await videoMediaClient.stop(reason: reason)
        if videoPreviewMediaOwnerID == id { videoPreviewMediaOwnerID = nil }
    }

    private func queueVideoPreviewCleanup(id: String, reason: String) {
        let predecessor = videoPreviewMediaTask
        videoPreviewMediaTask = Task { @MainActor [weak self] in
            await predecessor?.value
            await self?.stopVideoPreviewMediaIfOwned(id: id, reason: reason)
        }
    }

    func clearPendingVideoCallForLicenseRevocation() {
        let hadPendingVideoStart = videoCallPreview != nil
            || callStore.videoCallStartGeneration != nil
            || isStartingVideoCall
        guard hadPendingVideoStart else { return }
        let previewID = videoCallPreview?.id
        let peer = videoCallPreview?.peer
        callStore.videoCallStartGeneration = nil
        isStartingVideoCall = false
        videoCallPreview = nil
        if let peer {
            presentVideoCallTerminal(peer: peer, reason: "license_revoked", fallback: "视频通话不可用")
        }
        if let previewID {
            queueVideoPreviewCleanup(id: previewID, reason: "video_license_revoked")
        }
    }

    func dismissVideoCallPreview() {
        let previewID = videoCallPreview?.id
        if callStore.videoCallStartGeneration != nil {
            callStore.videoCallStartGeneration = nil
            isStartingVideoCall = false
        }
        videoCallPreview = nil
        if let previewID { queueVideoPreviewCleanup(id: previewID, reason: "preview_cancelled") }
    }

    func setVideoPreviewCameraEnabled(_ enabled: Bool) {
        guard !enabled || guardCallLicenseForAction(.video) else { return }
        guard videoCallPreview?.isStartingCall != true else { return }
        videoCallPreview?.cameraEnabled = enabled
        let generation = callLicenseActionGeneration(for: .video)
        Task { [weak self, videoMediaClient] in
            guard let self, self.callLicenseActionGeneration(for: .video) == generation,
                  !enabled || self.guardCallLicenseForAction(.video) else { return }
            try? await videoMediaClient.setCameraEnabled(enabled)
        }
    }

    func startOutgoingVideoCallFromPreview() {
        guard let preview = videoCallPreview else { return }
        guard !preview.isPreparing else { return }
        startOutgoingVideoCall(
            to: preview.peer,
            channelID: preview.channelID,
            cameraEnabled: preview.cameraEnabled,
            previewID: preview.id
        )
    }

    // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：识别并清理聊天页直发视频的轻量占位会话
    func pendingOutgoingVideoCallPresentation(for attempt: DirectCallAttempt) -> VoiceCallSession? {
        guard attempt.kind == .video,
              let call = activeVoiceCall,
              call.direction == "呼出",
              call.isVideoCall,
              normalizedDirectCallID(call.callID ?? "").isEmpty,
              call.peer.id.trimmingCharacters(in: .whitespacesAndNewlines) == attempt.peerID,
              call.mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == attempt.mediaMode else {
            return nil
        }
        return call
    }

    private func clearPendingOutgoingVideoCallPresentation(for attempt: DirectCallAttempt) {
        guard pendingOutgoingVideoCallPresentation(for: attempt) != nil else { return }
        activeVoiceCall = nil
    }
    // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束

    func startOutgoingVideoCall(
        to target: IMUser,
        channelID: String? = nil,
        cameraEnabled: Bool = true,
        previewID: String? = nil,
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：仅聊天页直发视频使用，避免把网络/权限等待压在聊天页
        presentImmediately: Bool = false
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
    ) {
        guard guardCallLicenseForAction(.video) else { return }
        discardUnownedLegacyCallViews(reason: "outgoing_video_truth_reconcile")
        guard !isStartingVideoCall, !hasTruthfulCallOwnership else {
            if let previewID,
               videoCallPreview?.id == previewID,
               isStartingVideoCall {
                videoCallPreview?.isStartingCall = true
                videoCallPreview?.startError = nil
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先处理当前通话")
            }
            return
        }
        if let reason = videoCallUnavailableReason(for: target) {
            if let previewID, videoCallPreview?.id == previewID {
                videoCallPreview?.startError = reason
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            }
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            if let previewID, videoCallPreview?.id == previewID {
                videoCallPreview?.startError = "登录会话不可用，请重新登录"
            } else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let startedAt = Date()
        let generation = UUID()
        var attempt = beginDirectCallAttempt(
            kind: .video,
            context: context,
            peerID: target.id,
            mediaMode: "video"
        )
        callStore.videoCallStartGeneration = generation
        isStartingVideoCall = true
        if let previewID, videoCallPreview?.id == previewID {
            videoCallPreview?.isStartingCall = true
            videoCallPreview?.startError = nil
        }
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：聊天页直接点视频时先展示轻量通话页，真实 callID 回来后再补齐权威会话数据
        if presentImmediately, previewID == nil {
            activeVoiceCall = VoiceCallSession(
                id: "video-call-\(UUID().uuidString)",
                callID: nil,
                roomID: "",
                rtcToken: "",
                mediaBaseURL: "",
                peer: target,
                direction: "呼出",
                startedAt: "刚刚",
                statusText: "正在发起视频通话",
                mediaState: .preparing,
                isMuted: false,
                speakerOn: true,
                startedAtDate: startedAt,
                connectedAt: nil,
                requestedMediaMode: "video",
                mediaMode: "video",
                localCameraEnabled: false,
                stateVersion: 0,
                requiresAcceptedDeviceBeforeJoin: false
            )
        }
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
        Task {
            defer {
                finishVideoCallStartAttempt(generation: generation, previewID: previewID)
                finishDirectCallAttemptSetup(attempt)
            }
            var createdCallID = ""
            var createdCallContext = context
            do {
                let provider = try await ensureRTCProviderReadyForVideoCall(
                    context: context,
                    scope: scope,
                    attempt: attempt
                )
                try await awaitDirectCallStage(attempt) {
                    try await api.updateRTCDeviceCapabilities(
                        context: currentDirectCallRequestContext(context, attempt: attempt),
                        capabilities: localVideoCapabilities
                    )
                }
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else {
                    throw IMAPIError.server("麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风")
                }
                let cameraAvailable = videoMediaClient.cameraAvailable
                let cameraAuthorized = cameraEnabled && cameraAvailable
                    ? try await awaitDirectCallStage(attempt) {
                        await ensureVideoPermission()
                    }
                    : false
                let effectiveCameraEnabled = cameraEnabled && cameraAvailable && cameraAuthorized
                if RTCCallRecordRedialFreshnessContext.requiredCallType == .video,
                   !effectiveCameraEnabled {
                    throw IMAPIError.server("摄像头不可用，未发起视频通话")
                }
                if cameraEnabled, !effectiveCameraEnabled {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(cameraAvailable
                        ? "未开启摄像头权限，已关闭摄像头继续视频通话"
                        : "摄像头暂不可用，已关闭摄像头继续视频通话") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
                }
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let response = try await awaitDirectCallStage(attempt) {
                    let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                    createdCallContext = requestContext
                    return try await api.createRTCVideoCall(
                        context: requestContext,
                        calleeUID: target.id,
                        channelID: voiceCallChannelID(for: target, requestedChannelID: channelID),
                        capabilities: localVideoCapabilities
                    )
                }
                createdCallID = response.call.id
                attempt = try rebindDirectCallAttempt(
                    attempt,
                    callID: response.call.id
                )
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let joined = try await initialOutgoingRoomJoin(
                    response: response, context: createdCallContext, attempt: attempt
                )
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let remoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                let initialMediaMode = Self.normalizedRTCMediaMode(remoteCall.mediaMode, fallback: "video")
                if initialMediaMode != attempt.mediaMode {
                    attempt = try rebindDirectCallAttempt(attempt, mediaMode: initialMediaMode)
                }
                let remoteStatus = response.call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard claimCallLifecycle(
                    callID: remoteCall.id,
                    direction: .outgoing,
                    stateVersion: remoteCall.stateVersion,
                    reason: "outgoing_video_created"
                ) else {
                    throw IMAPIError.server("视频通话状态已变化，请重试")
                }
                voiceCallSystem.reportOutgoingCallStarted(
                    callID: remoteCall.id,
                    peerName: target.name,
                    isVideo: true
                )
                if remoteStatus == "ringing" {
                    _ = advanceCallLifecycle(
                        callID: remoteCall.id,
                        to: .ringing,
                        stateVersion: remoteCall.stateVersion,
                        reason: "remote_ringing"
                    )
                }
                // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：沿用占位通话页 id，避免 fullScreenCover 重新弹出造成卡顿
                let pendingPresentation = pendingOutgoingVideoCallPresentation(for: attempt)
                var nextActiveCall = VoiceCallSession(
                    id: pendingPresentation?.id ?? "video-call-\(UUID().uuidString)",
                    callID: remoteCall.id,
                    roomID: remoteCall.roomID,
                    rtcToken: response.rtcToken,
                    mediaBaseURL: joined?.media.owtBaseURL ?? "",
                    peer: target,
                    direction: "呼出",
                    startedAt: "刚刚",
                    statusText: remoteStatus == "accepted" ? "连接中" : "等待对方接听",
                    mediaState: .preparing,
                    isMuted: pendingPresentation?.isMuted ?? false,
                    speakerOn: pendingPresentation?.speakerOn ?? true,
                    startedAtDate: startedAt,
                    connectedAt: nil,
                    requestedMediaMode: "video",
                    mediaMode: initialMediaMode,
                    localCameraEnabled: initialMediaMode == "video" && effectiveCameraEnabled,
                    stateVersion: remoteCall.stateVersion,
                    requiresAcceptedDeviceBeforeJoin: joined == nil
                )
                nextActiveCall.isMinimized = pendingPresentation?.isMinimized ?? false
                activeVoiceCall = nextActiveCall
                // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
                if previewID == nil || videoCallPreview?.id == previewID {
                    videoCallPreview = nil
                }
                if remoteStatus == "accepted", let joined {
                    let readyRoom = try await joinedRoomReadyForVoiceStart(
                        call: remoteCall,
                        joinedRoom: joined,
                        context: createdCallContext,
                        roomID: remoteCall.roomID,
                        rtcToken: response.rtcToken,
                        scope: scope,
                        attempt: attempt
                    )
                    guard isCurrentDirectCallAttempt(attempt),
                          directCallResourceIsOwned(callID: remoteCall.id, by: attempt),
                          activeVoiceCall?.callID == remoteCall.id else { return }
                    if initialMediaMode == "video" {
                        startVideoMediaSession(
                            call: remoteCall,
                            joinedRoom: readyRoom,
                            direction: "呼出",
                            peer: target,
                            cameraEnabled: effectiveCameraEnabled,
                            scope: scope,
                            attempt: attempt
                        )
                    } else {
                        startVoiceMediaSession(
                            call: remoteCall,
                            joinedRoom: readyRoom,
                            direction: "呼出",
                            peer: target,
                            scope: scope,
                            attempt: attempt
                        )
                    }
                } else {
                    scheduleOutgoingVoiceCallWatchdog(callID: remoteCall.id, scope: scope, timeoutSeconds: provider.callTimeoutSeconds)
                }
                if joined == nil {
                    ensureRTCSignalingRefreshActive(reason: "outgoing_policy_wait")
                    if remoteStatus == "accepted" {
                        startVoiceMediaSessionFromActiveCall(scope: scope, authoritativeCall: remoteCall)
                    }
                }
                if !cameraEnabled || effectiveCameraEnabled {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
                }
            } catch {
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut || isCurrentRemoteScope(scope) {
                        return
                    }
                }
                if !createdCallID.isEmpty {
                    enqueueRTCTerminalCompensation(
                        callID: createdCallID,
                        action: .cancel,
                        reason: "video_start_failed",
                        context: createdCallContext
                    )
                }
                // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：发起失败时清理提前展示的空 callID 通话页，避免卡在视频页
                clearPendingOutgoingVideoCallPresentation(for: attempt)
                // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
                guard callStore.videoCallStartGeneration == generation,
                      isCurrentDirectCallAttempt(attempt) else { return }
                if !createdCallID.isEmpty,
                   activeVoiceCall?.callID == createdCallID {
                    finishVoiceCallFromRemote(
                        status: "连接失败",
                        subtitle: "视频通话 · 发起失败",
                        toastText: "视频通话发起失败",
                        endReason: "video_start_failed",
                        expectedCallID: createdCallID,
                        lifecyclePhase: .failure
                    )
                }
                if let previewID, videoCallPreview?.id == previewID {
                    videoCallPreview?.startError = videoCallPreviewStartErrorMessage(for: error)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
                } else if isCurrentRemoteScope(scope) {
                    handleRemoteError(error, fallback: "视频通话服务暂不可用", rtcMedia: .video)
                }
            }
        }
    }

    private func ensureVideoCallStartIsCurrent(
        generation: UUID,
        previewID: String?,
        scope: String,
        attempt: DirectCallAttempt
    ) throws {
        guard callStore.videoCallStartGeneration == generation,
              isCurrentRemoteScope(scope),
              isCurrentDirectCallAttempt(attempt) else {
            throw CancellationError()
        }
        if let previewID, videoCallPreview?.id != previewID {
            throw CancellationError()
        }
    }

    private func finishVideoCallStartAttempt(generation: UUID, previewID: String?) {
        guard callStore.videoCallStartGeneration == generation else { return }
        callStore.videoCallStartGeneration = nil
        isStartingVideoCall = false
        if let previewID, videoCallPreview?.id == previewID {
            videoCallPreview?.isStartingCall = false
        }
    }

    private func videoCallPreviewStartErrorMessage(for error: Error) -> String {
        if error is CancellationError {
            return "登录状态已变化，请重新打开视频通话"
        }
        if let capabilityMessage = capabilityUserMessage(from: error, rtcMedia: .video) {
            return capabilityMessage
        }
        let detail = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "视频服务暂不可用，请稍后重试" }
        let normalizedDetail = detail.lowercased()
        if detail.contains("视频服务暂不可用")
            || detail.contains("服务不可用")
            || normalizedDetail.contains("service unavailable")
            || normalizedDetail.contains("provider unavailable")
            || normalizedDetail.contains("rtc_provider_unavailable") {
            return "视频服务暂不可用，请稍后重试"
        }
        if detail.contains("视频通话") || detail.contains("麦克风") || detail.contains("摄像头") {
            return detail
        }
        return "无法发起视频通话：\(detail)"
    }

}
