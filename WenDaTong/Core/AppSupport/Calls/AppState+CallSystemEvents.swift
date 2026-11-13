import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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
    func bindVoiceCallSystemIntegration() {
        voiceCallSystem.start()
        voiceCallSystemEventTask?.cancel()
        voiceCallSystemEventTask = Task { [weak self, voiceCallSystem] in
            for await event in voiceCallSystem.events {
                await MainActor.run {
                    self?.handleVoiceCallSystemEvent(event)
                }
            }
        }
    }

    func bindNotificationRuntime() {
        IOSNotificationRuntime.shared.removeObserver(notificationRuntimeObserverID)
        notificationRuntimeObserverID = IOSNotificationRuntime.shared.observe { [weak self] event in
            guard let self else { return false }
            self.handleNotificationRuntimeEvent(event)
            return true
        }
    }

    private func handleNotificationRuntimeEvent(_ event: IOSNotificationRuntimeEvent) {
        switch event {
        case .standardRegistrationChanged:
            resetStandardPushRegistrationKeys(for: apiContext)
            registerPendingStandardPushDeviceIfPossible(reason: "apns_token_changed")
        case let .standardRegistrationInvalidated(registration):
            resetStandardPushRegistrationKeys(for: apiContext)
            retireRegisteredPushTokenSlotIfPossible(
                provider: .apns,
                context: apiContext,
                fallbackRegistration: registration
            )
        case let .foregroundNotificationPresented(payload):
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(payload.title)
        case let .notificationOpened(payload):
            handleOpenedNotification(payload)
        }
    }

    private func resetStandardPushRegistrationKeys(for context: IMAPIContext) {
        let scope = remoteDataScopeKey(for: context)
        registeredStandardPushDeviceRegistrationKeys = registeredStandardPushDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
    }

    private func handleOpenedNotification(_ payload: IOSNotificationStatePayload) {
        let context = apiContext
        guard context.hasIMSession else {
            if !deferredNotificationOpenPayloads.contains(payload) {
                deferredNotificationOpenPayloads.append(payload)
            }
            return
        }
        guard let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty,
              payload.scopeKey == IOSNotificationRuntime.scopeKey(tenantID: tenantID) else {
            return
        }
        switch payload.category {
        case "voice_call", "video_call":
            guard !JHTRuntimeFeatureFlags.disableRTCRuntime else {
                activeTab = .chats
                return
            }
            activeTab = .rtc
            let scope = remoteDataScopeKey(for: context)
            Task { [weak self] in
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                await self?.refreshRTCSignalingSilently(context: context, scope: scope)
                // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            }
        default:
            activeTab = .chats
            let targetRef = payload.targetRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetRef.isEmpty else {
                // JHT_MOD_BEGIN NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改开始：缺少 target_ref 时按通知携带的 channel_id 打开会话
                guard let fallbackConversationID = notificationConversationID(fromOpenedMessagePayload: payload) else {
                    Task { [weak self] in
                        _ = await self?.refreshRemoteSnapshot(silent: true, force: true)
                    }
                    return
                }
                notificationTargetResolutionGeneration &+= 1
                let generation = notificationTargetResolutionGeneration
                let scope = remoteDataScopeKey(for: context)
                let authFence = context.authSessionFence
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    let conversationID = self.notificationConversationID(fromOpenedMessagePayload: payload) ?? fallbackConversationID
                    self.conversationListPresentationStore.snapshot.notificationOpenRequest = IOSNotificationConversationOpenRequest( // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                        conversationID: conversationID,
                        messageID: nil,
                        channelSeq: payload.channelSeq > 0 ? payload.channelSeq : nil
                    )
                }
                // JHT_MOD_END NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改结束
                return
            }
            notificationTargetResolutionGeneration &+= 1
            let generation = notificationTargetResolutionGeneration
            let scope = remoteDataScopeKey(for: context)
            let authFence = context.authSessionFence
            Task { [weak self] in
                guard let self else { return }
                do {
                    let target = try await api.resolveNotificationTarget(
                        context: context,
                        targetRef: targetRef
                    )
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    let conversationID: String
                    switch target.kind {
                    case .conversation:
                        conversationID = target.conversationID ?? ""
                        _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    case .system:
                        conversationID = target.systemDestination ?? ""
                        await self.refreshInboxSilently()
                    }
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence),
                          !conversationID.isEmpty else {
                        return
                    }
                    self.conversationListPresentationStore.snapshot.notificationOpenRequest = IOSNotificationConversationOpenRequest( // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                        conversationID: conversationID,
                        messageID: target.messageID,
                        channelSeq: target.channelSeq
                    )
                } catch {
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                }
            }
        }
    }

    // JHT_MOD_BEGIN NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改开始：通知点击兜底会话定位
    private func notificationConversationID(fromOpenedMessagePayload payload: IOSNotificationStatePayload) -> String? {
        let channelID = payload.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { return nil }
        if let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
            conversation.id == channelID
                || remoteChannelID(for: conversation).trimmingCharacters(in: .whitespacesAndNewlines) == channelID
        }) {
            return conversation.id
        }
        return channelID
    }
    // JHT_MOD_END NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改结束

    func consumeNotificationConversationOpenRequest(_ requestID: UUID) {
        // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_BEGIN
        guard conversationListPresentationStore.snapshot.notificationOpenRequest?.id == requestID else { return }
        conversationListPresentationStore.snapshot.notificationOpenRequest = nil
        // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_END
    }

    func replayDeferredNotificationOpensIfPossible() {
        guard apiContext.hasIMSession, !deferredNotificationOpenPayloads.isEmpty else { return }
        let pending = deferredNotificationOpenPayloads
        deferredNotificationOpenPayloads.removeAll()
        pending.forEach(handleOpenedNotification)
    }

    func retirePushDevices(for context: IMAPIContext) {
        guard context.hasIMSession else {
            clearPushRegistrationState()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
        registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
        let standardFallback = registeredStandardPushRegistrationsByScope[scope]
            ?? IOSNotificationRuntime.shared.standardRegistration
        let voipFallback = registeredVoIPPushRegistrationsByScope[scope]
            ?? pendingVoIPDeviceRegistration
        registeredStandardPushDeviceRegistrationKeys = registeredStandardPushDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
        registeredVoIPDeviceRegistrationKeys = registeredVoIPDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
        let previousRetirement = pushDeviceRetirementTasksByScope[scope]
        let standardRegistration = standardPushRegistrationTasksByScope[scope]
        let voipRegistration = voipPushRegistrationTasksByScope[scope]
        let retirement = Task { [weak self] in
            await previousRetirement?.value
            await standardRegistration?.value
            await voipRegistration?.value
            guard let self else { return }
            self.registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
            self.registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
            let standard = self.registeredStandardPushRegistrationsByScope.removeValue(forKey: scope)
                ?? standardFallback
            let voip = self.registeredVoIPPushRegistrationsByScope.removeValue(forKey: scope)
                ?? voipFallback
            if let fingerprint = standard?.tokenFingerprint {
                _ = try? await self.retirePushTokenWithTransientRetry(
                    context: context,
                    provider: .apns,
                    tokenFingerprint: fingerprint
                )
            }
            if let fingerprint = voip?.tokenFingerprint {
                _ = try? await self.retirePushTokenWithTransientRetry(
                    context: context,
                    provider: .apnsVoIP,
                    tokenFingerprint: fingerprint
                )
            }
        }
        pushDeviceRetirementTasksByScope[scope] = retirement
    }

    private func resetVoIPPushRegistrationKeys(for context: IMAPIContext) {
        let scope = remoteDataScopeKey(for: context)
        registeredVoIPDeviceRegistrationKeys = registeredVoIPDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
    }

    func clearPushRegistrationState() {
        registeredStandardPushDeviceRegistrationKeys.removeAll()
        registeredVoIPDeviceRegistrationKeys.removeAll()
        registeredStandardPushDeviceIDsByScope.removeAll()
        registeredVoIPPushDeviceIDsByScope.removeAll()
        registeredStandardPushRegistrationsByScope.removeAll()
        registeredVoIPPushRegistrationsByScope.removeAll()
        deferredNotificationOpenPayloads.removeAll()
        IOSNotificationRuntime.shared.resetAuthenticatedScope()
        IOSNotificationRuntime.shared.updateApplicationBadge(0)
    }

    func handleVoiceCallSystemEvent(_ event: VoiceCallSystemEvent) {
        switch event {
        case let .voipTokenUpdated(registration):
            if pendingVoIPDeviceRegistration != registration {
                resetVoIPPushRegistrationKeys(for: apiContext)
            }
            pendingVoIPDeviceRegistration = registration
            registerPendingVoIPDeviceIfPossible(reason: "voip_token")
        case .voipTokenInvalidated:
            let invalidatedRegistration = pendingVoIPDeviceRegistration
            pendingVoIPDeviceRegistration = nil
            resetVoIPPushRegistrationKeys(for: apiContext)
            retireRegisteredPushTokenSlotIfPossible(
                provider: .apnsVoIP,
                context: apiContext,
                fallbackRegistration: invalidatedRegistration
            )
        case let .voipPushPayload(payload):
            handleVoIPPushPayload(payload)
        case let .voipPushReportFailed(payload):
            voiceDebug("voip_push_callkit_report_failed call=\(Self.shortDebugID(payload.callID))")
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
        case let .voipPushContractViolation(payload):
            voiceDebug("voip_push_contract_violation event=\(payload.event) call=\(Self.shortDebugID(payload.callID))")
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
        case let .answer(callID):
            acceptVoiceCallFromSystem(callID: callID)
        case let .end(callID, reason):
            endVoiceCallFromSystem(callID: callID, reason: reason)
        case let .mute(callID, isMuted):
            setVoiceCallMutedFromSystem(callID: callID, isMuted: isMuted)
        case .audioSessionActivated:
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：保留系统音频激活顺序，辅助定位真机接听失败
            voiceCallSystemAudioSessionActive = true
            voiceCallSystemAudioSessionGeneration &+= 1
            voiceDebug("callkit_audio_session active=true gen=\(voiceCallSystemAudioSessionGeneration)")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            renderCallPromptEnvironment(.callKitAudioSessionActivated)
            // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：CallKit 交回音频会话后，恢复当前通话的 WebRTC 音频配置
            reconcileActiveCallAudioSession(reason: "callkit_audio_session_activated")
            // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束
        case .audioSessionDeactivated:
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            voiceCallSystemAudioSessionActive = false
            voiceCallSystemAudioSessionGeneration &+= 1
            voiceDebug("callkit_audio_session active=false gen=\(voiceCallSystemAudioSessionGeneration)")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            renderCallPromptEnvironment(.callKitAudioSessionDeactivated)
        case .providerReset:
            renderCallPromptEnvironment(.mediaServicesReset)
            let lifecycleSnapshot = callStore.activeLifecycleSnapshot
            let visibleCallID = (activeVoiceCall?.callID ?? incomingVoiceCall?.callID ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentCallID = visibleCallID.isEmpty
                ? (lifecycleSnapshot?.identity.callID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : visibleCallID
            let hadTruthfulOwner = lifecycleSnapshot != nil
            let wasPendingIncoming = lifecycleSnapshot.map {
                $0.direction == .incoming && $0.phase == .ringing
            } ?? (incomingVoiceCall != nil && activeVoiceCall == nil)
            let wasUnconnectedOutgoing = lifecycleSnapshot?.direction == .outgoing
                && lifecycleSnapshot?.hasEverConnected != true
            let resetContext = apiContext
            let resetScope = remoteDataScopeKey(for: resetContext)
            if !currentCallID.isEmpty {
                rtcTerminalMarkersByCallID[currentCallID] = RTCCallTerminalMarker(
                    callID: currentCallID,
                    reason: "callkit_provider_reset",
                    stateVersion: max(0, lifecycleSnapshot?.revision ?? 0)
                )
            }
            _ = callStore.releaseLifecycle(as: .failure, reason: "callkit_provider_reset")
            SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
            SystemNotificationSound.stopAllCallPrompts()
            if !visibleCallID.isEmpty {
                finishVoiceCallFromRemote(
                    status: "连接失败",
                    subtitle: "语音通话 · 系统通话服务已重置",
                    toastText: "系统通话服务已重置，通话已结束",
                    endReason: "callkit_provider_reset",
                    stateVersion: max(0, lifecycleSnapshot?.revision ?? 0),
                    expectedCallID: currentCallID,
                    lifecyclePhase: .failure,
                    lifecycleAlreadyApplied: true
                )
            } else if hadTruthfulOwner {
                cancelVoiceCallWatchdog()
                stopRTCMediaStateHeartbeat(reason: "callkit_provider_reset")
                stopVoiceMediaSession(reason: "callkit_provider_reset")
                videoMediaEventTask?.cancel()
                videoMediaEventTask = nil
                activeVideoMediaCallID = nil
                if !currentCallID.isEmpty {
                    stoppedVideoMediaCallIDs.insert(currentCallID)
                    voiceCallSystem.endCall(callID: currentCallID, reason: "callkit_provider_reset")
                    voipPushPayloadsByCallID.removeValue(forKey: currentCallID)
                    rtcPeerWaitTerminationCallIDs.remove(currentCallID)
                    releaseDirectCallTracking(callID: currentCallID)
                }
                Task { [videoMediaClient] in
                    await videoMediaClient.stop(reason: "callkit_provider_reset")
                }
                activeVoiceCall = nil
                incomingVoiceCall = nil
                isEndingActiveCall = false
                activeCallEndError = nil
                releaseAudioSessionForVoiceCall()
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通话服务已重置，通话已结束")
            }
            guard !currentCallID.isEmpty, resetContext.hasIMSession else { return }
            guard isCurrentRemoteScope(resetScope) else { return }
            enqueueRTCTerminalCompensation(
                callID: currentCallID,
                action: wasPendingIncoming ? .reject : (wasUnconnectedOutgoing ? .cancel : .hangup),
                reason: "callkit_provider_reset",
                context: resetContext
            )
        }
    }

    private func handleVoIPPushPayload(_ payload: RTCVoIPPushPayload) {
        let callID = payload.callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty, payload.isPushKitEligibleRinging else {
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
            return
        }
        voipPushPayloadsByCallID[callID] = payload
        voiceDebug("voip_push event=ringing freshness=\(String(describing: payload.deliveryFreshness())) call=\(Self.shortDebugID(callID)) room=\(Self.shortDebugID(payload.roomID))")
        receiveIncomingVoiceCall(
            from: voiceCallPeer(from: payload),
            callID: callID,
            roomID: payload.roomID,
            mediaMode: payload.callType,
            systemOwnsRingtone: voiceCallSystem.hasPresentedCall(callID: callID)
        )
        reconcileAuthoritativeRTCCallStateAfterVoIPPush()
    }

    private func reconcileAuthoritativeRTCCallStateAfterVoIPPush() {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            await self?.refreshRTCSignalingSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: true
            )
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        }
    }

    private func retireRegisteredPushTokenSlotIfPossible(
        provider: RemotePushTokenProvider,
        context: IMAPIContext,
        fallbackRegistration: RemoteDeviceRegistration? = nil
    ) {
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let previousRetirement = pushDeviceRetirementTasksByScope[scope]
        let slotRegistrationTask = provider == .apns
            ? standardPushRegistrationTasksByScope[scope]
            : voipPushRegistrationTasksByScope[scope]
        let invalidatedRegistration: RemoteDeviceRegistration?
        if provider == .apns {
            invalidatedRegistration = fallbackRegistration
                ?? registeredStandardPushRegistrationsByScope[scope]
        } else {
            invalidatedRegistration = fallbackRegistration
                ?? registeredVoIPPushRegistrationsByScope[scope]
        }
        guard let invalidatedFingerprint = invalidatedRegistration?.tokenFingerprint else { return }
        let retirement = Task { [weak self] in
            await previousRetirement?.value
            await slotRegistrationTask?.value
            guard let self, self.isCurrentRemoteScope(scope) else { return }
            if provider == .apns {
                if self.registeredStandardPushRegistrationsByScope[scope]?.tokenFingerprint == invalidatedFingerprint {
                    self.registeredStandardPushRegistrationsByScope.removeValue(forKey: scope)
                    self.registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
                }
            } else {
                if self.registeredVoIPPushRegistrationsByScope[scope]?.tokenFingerprint == invalidatedFingerprint {
                    self.registeredVoIPPushRegistrationsByScope.removeValue(forKey: scope)
                    self.registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
                }
            }
            _ = try? await self.retirePushTokenWithTransientRetry(
                context: context,
                provider: provider,
                tokenFingerprint: invalidatedFingerprint
            )
        }
        pushDeviceRetirementTasksByScope[scope] = retirement
    }

    private func retirePushTokenWithTransientRetry(
        context: IMAPIContext,
        provider: RemotePushTokenProvider,
        tokenFingerprint: String
    ) async throws -> RemotePushTokenRetirementResponse {
        do {
            return try await api.retireCurrentPushToken(
                context: context,
                provider: provider,
                tokenFingerprint: tokenFingerprint
            )
        } catch IMAPIError.httpStatus(let statusCode, _) where statusCode == 503 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return try await api.retireCurrentPushToken(
                context: context,
                provider: provider,
                tokenFingerprint: tokenFingerprint
            )
        }
    }

    func registerPendingVoIPDeviceIfPossible(reason: String) {
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: China-review build must not register VoIP/CallKit delivery.
        guard SystemCallIntegrationPolicy.isVoIPPushRegistrationEnabled else { return }
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        guard let registration = pendingVoIPDeviceRegistration else { return }
        let context = apiContext
        guard context.hasIMSession else {
            voiceDebug("voip_register_deferred reason=\(reason) context=\(Self.rtcDebugContextSummary(context))")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let key = "\(scope)|\(registration.deduplicationKey)"
        guard !registeredVoIPDeviceRegistrationKeys.contains(key) else { return }
        registeredVoIPDeviceRegistrationKeys.insert(key)
        let retirementTask = pushDeviceRetirementTasksByScope[scope]
        let previousRegistrationTask = voipPushRegistrationTasksByScope[scope]
        let registrationTask = Task { [weak self] in
            do {
                await retirementTask?.value
                await previousRegistrationTask?.value
                let device = try await self?.api.registerDevice(context: context, registration: registration)
                guard self?.isCurrentRemoteScope(scope) == true else {
                    if let fingerprint = registration.tokenFingerprint {
                        _ = try? await self?.api.retireCurrentPushToken(
                            context: context,
                            provider: .apnsVoIP,
                            tokenFingerprint: fingerprint
                        )
                    }
                    return
                }
                self?.registeredVoIPPushRegistrationsByScope[scope] = registration
                if let deviceID = device?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceID.isEmpty {
                    self?.registeredVoIPPushDeviceIDsByScope[scope, default: []].insert(deviceID)
                }
                self?.voiceDebug("voip_register_ok environment=\(registration.environment ?? "empty") bundle=\(!((registration.bundleID ?? "").isEmpty))")
            } catch {
                await MainActor.run {
                    self?.registeredVoIPDeviceRegistrationKeys.remove(key)
                    self?.voiceDebug("voip_register_failed error=\(Self.safeVoiceErrorSummary(error))")
                }
            }
        }
        voipPushRegistrationTasksByScope[scope] = registrationTask
    }

    func registerPendingStandardPushDeviceIfPossible(reason _: String) {
        guard let registration = IOSNotificationRuntime.shared.standardRegistration else { return }
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let key = "\(scope)|\(registration.deduplicationKey)"
        guard !registeredStandardPushDeviceRegistrationKeys.contains(key) else { return }
        registeredStandardPushDeviceRegistrationKeys.insert(key)
        let retirementTask = pushDeviceRetirementTasksByScope[scope]
        let previousRegistrationTask = standardPushRegistrationTasksByScope[scope]
        let registrationTask = Task { [weak self] in
            do {
                await retirementTask?.value
                await previousRegistrationTask?.value
                let device = try await self?.api.registerDevice(context: context, registration: registration)
                guard self?.isCurrentRemoteScope(scope) == true else {
                    if let fingerprint = registration.tokenFingerprint {
                        _ = try? await self?.api.retireCurrentPushToken(
                            context: context,
                            provider: .apns,
                            tokenFingerprint: fingerprint
                        )
                    }
                    return
                }
                self?.registeredStandardPushRegistrationsByScope[scope] = registration
                if let deviceID = device?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceID.isEmpty {
                    self?.registeredStandardPushDeviceIDsByScope[scope, default: []].insert(deviceID)
                }
            } catch {
                _ = await MainActor.run {
                    self?.registeredStandardPushDeviceRegistrationKeys.remove(key)
                    #if DEBUG
                    print("[JHT Push] standard_register_failed error=\(IMAPIClient.redactedSensitiveLogText(String(describing: error)))")
                    #endif
                }
            }
        }
        standardPushRegistrationTasksByScope[scope] = registrationTask
    }

    func voiceCallPeer(from payload: RTCVoIPPushPayload) -> IMUser {
        let caller = userForVoiceCall(uid: payload.callerUID)
        return voiceCallUser(
            merging: caller,
            uid: payload.callerProfile?.uid ?? payload.callerUID,
            userID: payload.callerProfile?.userID ?? "",
            displayName: payload.callerName,
            avatarURL: payload.callerAvatarURL,
            avatarVersion: payload.callerAvatarVersion,
            avatarUpdatedAt: payload.callerAvatarUpdatedAt
        )
    }

    private func acceptVoiceCallFromSystem(callID: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              !failedSystemAnsweredCallIDs.contains(normalizedCallID),
              rtcTerminalMarkersByCallID[normalizedCallID] == nil else { return }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: the app-requested action echoes through the system delegate.
        // Preserve the mode of this exact, still-authorized answer operation before
        // applying the system button's audio default. A different or invalidated
        // operation must continue through the normal ownership and license checks.
        if let operationID = callStore.incomingCallAnswerOperationID,
           incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
           directCallAttempts.values.contains(where: {
               $0.operationID == operationID && $0.callID == normalizedCallID
                   && $0.mediaMode == incomingCallAnswerMode && isCurrentDirectCallAttempt($0)
           }) {
            return
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_END
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedCallID,
           let payload = voipPushPayloadsByCallID[normalizedCallID] {
            let isVideo = payload.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            incomingVoiceCall = IncomingVoiceCall(
                id: "incoming_\(UUID().uuidString)",
                callID: normalizedCallID,
                caller: voiceCallPeer(from: payload),
                startedAt: "刚刚",
                source: isVideo ? "系统视频来电" : "系统语音来电",
                requestedMediaMode: isVideo ? "video" : "audio"
            )
        }
        if !hasTruthfulCallOwnership {
            SystemNotificationSound.setSystemOwnsIncomingRingtone(true)
            _ = claimCallLifecycle(
                callID: normalizedCallID,
                direction: .incoming,
                reason: "callkit_answer_recovered_owner"
            )
        }
        if incomingVoiceCall?.isVideo == true {
            // A CallKit answer is explicit user intent, but the system UI cannot
            // choose camera mode. Start safely as audio; the in-app video answer
            // remains the only path that requests camera permission.
            acceptIncomingVideoCall(as: "audio", fromSystem: true)
        } else {
            acceptIncomingVoiceCall(fromSystem: true)
        }
    }

    private func endVoiceCallFromSystem(callID: String, reason: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        guard voiceCallSystem.hasPresentedCall(callID: normalizedCallID) else {
            voiceDebug(
                "system_end_skip reason=not_presented call=\(Self.shortDebugID(normalizedCallID)) event=\(reason)"
            )
            return
        }
        if activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            endActiveVoiceCall()
            return
        }
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            declineIncomingVoiceCall()
            return
        }
        voiceCallSystem.clearPresentedCall(callID: normalizedCallID)
        guard apiContext.hasIMSession else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            guard let self,
                  self.isCurrentRemoteScope(scope) else { return }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            let idempotencyKey = self.stableRTCTerminalMutationIdempotencyKey(
                callID: normalizedCallID,
                action: .reject,
                reason: reason,
                context: context
            )
            do {
                try await self.api.rejectRTCCall(
                    context: context,
                    callID: normalizedCallID,
                    idempotencyKey: idempotencyKey
                )
                self.clearRTCTerminalCompensationIfMatches(
                    callID: normalizedCallID,
                    action: .reject,
                    idempotencyKey: idempotencyKey
                )
            } catch {
                guard self.isCurrentRemoteScope(scope) else { return }
                self.enqueueRTCTerminalCompensationAfterInitialFailure(
                    callID: normalizedCallID,
                    action: .reject,
                    reason: reason,
                    context: context,
                    idempotencyKey: idempotencyKey,
                    error: error
                )
            }
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        }
    }

    private func setVoiceCallMutedFromSystem(callID: String, isMuted: Bool) {
        guard activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else { return }
        setActiveVoiceCallMuted(isMuted, notifySystem: false)
    }

    private func finishVoiceCallIfMatchingSystemCall(callID: String, event: String) {
        guard activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else { return }
        switch event {
        case "canceled":
            finishVoiceCallFromRemote(status: "已取消", subtitle: "语音通话 · 已取消", toastText: "语音通话已取消", expectedCallID: callID, lifecyclePhase: .cancelled)
        case "timed_out":
            finishVoiceCallFromRemote(status: "未接通", subtitle: "语音通话 · 已超时", toastText: "语音通话已超时", expectedCallID: callID, lifecyclePhase: .timeout)
        case "answered_elsewhere":
            finishVoiceCallFromRemote(status: "已在其他设备接听", subtitle: "语音通话 · 已在其他设备接听", toastText: "已在其他设备接听", expectedCallID: callID, lifecyclePhase: .ended)
        default:
            finishVoiceCallFromRemote(status: "已结束", subtitle: "语音通话 · 通话已结束", toastText: "语音通话已结束", expectedCallID: callID, lifecyclePhase: .ended)
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
