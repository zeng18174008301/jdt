import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
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
    @discardableResult
    private func handleCertificationRealtimeInvalidation(
        _ envelope: RealtimeEnvelope
    ) -> Bool {
        let supportedEvents: Set<String> = [
            "certification.assignment.updated",
            "certification.label.updated"
        ]
        let outerType = envelope.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let event = payloadString(
            envelope.payload,
            ["event"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventType = payloadString(
            envelope.payload,
            ["event_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCandidate = [outerType, event, eventType].contains {
            $0.hasPrefix("certification.")
        }
        guard isCandidate else { return false }

        guard isAuthenticated,
              apiContext.hasIMSession,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ) else {
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return true
        }
        if certificationIdentityRoot.scope != activeScope {
            _ = certificationIdentityRoot.bind(activeScope)
            certificationProfileRequestFence.bind(activeScope)
            certificationPresentationStore.advance(scopeChanged: true) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        } else if certificationProfileRequestFence.scope != activeScope {
            certificationProfileRequestFence.bind(activeScope)
        }

        let tenantID = payloadString(
            envelope.payload,
            ["tenant_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tenantID.isEmpty, tenantID != activeScope.tenantID {
            return true
        }
        let subjectUID = payloadString(
            envelope.payload,
            ["subject_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectType = payloadString(
            envelope.payload,
            ["subject_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generationFamily = payloadString(
            envelope.payload,
            ["generation_family"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventID = payloadString(
            envelope.payload,
            ["event_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let occurredAt = payloadString(
            envelope.payload,
            ["occurred_at"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = payloadInt64(
            envelope.payload,
            ["generation"]
        ) ?? 0
        let revision = payloadInt64(
            envelope.payload,
            ["revision"]
        ) ?? 0
        let hasChangedList: Bool
        if case .array? = envelope.payload["changed"] {
            hasChangedList = true
        } else {
            hasChangedList = false
        }
        let validEvent = supportedEvents.contains(event)
            && eventType == event
            && (outerType == "notification"
                || supportedEvents.contains(outerType))
            && tenantID == activeScope.tenantID
            && subjectType == "user"
            && !subjectUID.isEmpty
            && generationFamily == "certification"
            && generation > 0
            && revision > 0
            && !eventID.isEmpty
            && !occurredAt.isEmpty
            && hasChangedList

        guard validEvent else {
            let affectedUIDs = subjectUID.isEmpty
                ? certificationIdentityRoot.exactUIDs
                : [subjectUID]
            certificationProfileRequestFence.invalidate(affectedUIDs)
            if !affectedUIDs.isEmpty {
                _ = certificationIdentityRoot.markMalformedForRefetch(
                    exactUIDs: affectedUIDs
                )
                ensureCertificationPresentations(
                    forExactUIDs: affectedUIDs
                )
            }
            return true
        }

        certificationProfileRequestFence.invalidate([subjectUID])
        let outcome = certificationIdentityRoot.invalidate(
            exactUID: subjectUID,
            tenantID: tenantID,
            generation: generation,
            revision: revision
        )
        if certificationPresentationOutcomeChangesUI(outcome) {
            certificationPresentationStore.advance() // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }
        if outcome == .invalidated || outcome == .purgedForRefetch {
            ensureCertificationPresentations(forExactUIDs: [subjectUID])
        }
        return true
    }

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    func handleRealtimeEnvelope(_ envelope: RealtimeEnvelope) {
        let diagnostic = (realtimeClient as? RealtimeClient)?.currentEnvelopeDiagnostic
        // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_BEGIN
        let flow = diagnostic?.takeMessageFlow() ?? RealtimeMessageFlowSignpost.arrival(type: envelope.type)
        defer { flow?.finishIfNotHandedOff() }
        // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_END
        var handling: RealtimeConnectionDiagnostic.Handling = .appCallbackReturned
        defer { diagnostic?.event.handling = handling }
        guard beginRealtimeEnvelope(envelope, diagnostic: diagnostic) else { handling = .deviceRevoked; return }
        dispatchRealtimeEnvelope(envelope, diagnostic: diagnostic, diagnosticHandling: &handling, usesWorker: false, flow: flow)
    }
    func beginRealtimeEnvelope(_ envelope: RealtimeEnvelope, diagnostic: RealtimeEnvelopeDiagnosticObservation?) -> Bool {
        if DeviceRevocationDetector.matches(envelope: envelope) {
            clearPendingRealtimeMessages(reason: "device_revoked")
            disconnectRealtime(shouldReconnect: false)
            logSyncEndpointFailure("/im/ws", error: IMAPIError.unauthorized(DeviceRevocationDetector.logoutMessage))
            handleCurrentDeviceRevoked()
            diagnostic?.event.handlingCode = .deviceRevoked
            return false
        }
        let activeTenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let activeViewerID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        handleAvatarRealtimeOutcome(
            avatarRealtimeProjection.consume(
                envelope,
                activeTenantID: activeTenantID
            )
        )
        handlePresenceConnectivityOutcome(
            presenceConnectivityProjection.consume(
                envelope,
                activeTenantID: activeTenantID,
                activeViewerID: activeViewerID
            )
        )
        return true
    }
    func dispatchRealtimeEnvelope(_ envelope: RealtimeEnvelope, diagnostic: RealtimeEnvelopeDiagnosticObservation?,
                                  diagnosticHandling: inout RealtimeConnectionDiagnostic.Handling, usesWorker: Bool, flow: RealtimeMessageFlowSignpost?) {
        switch envelope.type {
        case "connect_ack":
            schedulePersistedMessageSequenceRecoveries(reason: "realtime_connect")
            scheduleDeliveryAcksForPersistedMessages()
            if let ticket = localMessageTicket {
                scheduleDurableReadAckRecovery(ticket: ticket, runImmediately: true)
            }
            for conversation in conversationStore.conversationMessageSnapshots() where conversation.kind != .system {
                syncReadReceiptsIfNeeded(conversation.id)
            }
        case "pong", "subscribe_ack":
            break
        case "message", "message_push":
            if let remote = decodeRealtimeMessage(envelope) {
                diagnosticHandling = enqueueRealtimeMessage(remote, usesWorker: usesWorker, signpost: flow)
            } else {
                flushPendingRealtimeMessagesIfNeeded(reason: "message_decode_fallback")
                refreshRealtimeFallback(envelope)
                diagnosticHandling = .fallbackScheduled
            }
        case "send_ack":
            if !usesWorker { flushPendingRealtimeMessagesIfNeeded(reason: "before_send_ack") }
            if let remote = decodeRealtimeMessage(envelope) {
                flow?.accept(messageID: remote.messageID)
                if usesWorker { enqueueRealtimeAcknowledgement(remote, diagnostic: diagnostic, signpost: flow) }
                else { applyRemoteMessages([remote], channelID: remote.channelID, channelType: remote.channelType, fromRealtime: true, realtimeSignposts: flow.map { [$0] } ?? []) }
            } else { refreshRealtimeFallback(envelope) }
        case "message_extra":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_message_extra")
            handleRealtimeMessageExtra(envelope)
        case "message_receipt":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_message_receipt")
            if let receipt = decodeRealtimeReceipt(envelope) { // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111
                applyRealtimeMessageReceipt(receipt)
            } else {
                refreshRealtimeFallback(envelope)
            }
        case "conversation_read":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_conversation_read")
            handleConversationReadWatermark(envelope)
        case "conversation_update":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_conversation_update")
            scheduleRealtimeRecoveryRefresh(reason: "conversation_update")
        case "resync":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_resync")
            handleRealtimeResync(envelope)
        case "group_left", "group_dissolved", "group_member_left":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_lifecycle")
            let groupID = realtimeGroupID(from: envelope)
            applyGroupLifecycleEvent(event: envelope.type, groupID: groupID)
        case "group_announcement.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_announcement")
            refreshGroupAnnouncementFromRealtime(envelope)
        case "group.member.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_member_profile")
            handleGroupMemberProfileRealtime(envelope)
        case "group.settings.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_settings")
            handleGroupSettingsUpdatedRealtime(envelope)
        case "group.owner.transferred":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_owner_transfer")
            handleGroupOwnerTransferredRealtime(envelope)
        case "tenant.policy.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_tenant_policy_update")
            refreshGroupMemberCountPolicyAfterRealtimeInvalidation(envelope: envelope)
        case "certification.assignment.updated",
             "certification.label.updated":
            flushPendingRealtimeMessagesIfNeeded(
                reason: "before_certification_invalidation"
            )
            handleCertificationRealtimeInvalidation(envelope)
        case "friend_application.created",
             "friend_application.reviewed",
             "friend_application.rejected",
             "friend_application.approved",
             "friend_application.updated",
             "friend_application.suppressed",
             "friend_application.cancelled",
             "friend_relation.established":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_friend_relation")
            Task {
                await refreshFriendApplicationsFromRealtime(
                    event: envelope.type,
                    envelope: envelope
                )
            }
        case "profile_updated",
             "profile.updated",
             "blacklist.updated",
             "blacklist.added",
             "blacklist.removed",
             "friend_remark.updated",
             "contact.remark.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_profile_contact_invalidation")
            scheduleProfileContactRealtimeReconcile(event: envelope.type)
        case "rtc.call.ringing", "rtc.call.accepted", "rtc.call.rejected", "rtc.call.canceled", "rtc.call.ended", "rtc.call.timed_out", "rtc.call.busy", "rtc_call":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_rtc_event")
            handleRTCCallEvent(envelope)
        case "notification":
            if envelope.isRTCCallNotification {
                ensureRTCSignalingRefreshActive(reason: "realtime_rtc_notification")
            }
            flushPendingRealtimeMessagesIfNeeded(reason: "before_notification")
            _ = handleCertificationRealtimeInvalidation(envelope)
            let event = friendRealtimePayloadString(
                envelope,
                keys: ["event", "event_type", "notification_type", "notice_type"]
            ).lowercased()
            let kind = friendRealtimePayloadString(
                envelope,
                keys: ["kind", "notification_kind"]
            ).lowercased()
            let senderUID = (envelope.payload["sender_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if event == "group_announcement.updated" || kind == "group_announcement" {
                refreshGroupAnnouncementFromRealtime(envelope)
            }
            if event == "group.member.updated" {
                handleGroupMemberProfileRealtime(envelope)
            }
            if event == "group.settings.updated" || event == "group_settings_updated" {
                handleGroupSettingsUpdatedRealtime(envelope)
            }
            if event == "group.owner.transferred" || event == "group_owner_transferred" {
                handleGroupOwnerTransferredRealtime(envelope)
            }
            if event == "tenant.policy.updated" || event == "tenant_policy_updated" {
                refreshGroupMemberCountPolicyAfterRealtimeInvalidation(envelope: envelope)
            }
            if event == "group_left" || event == "group_dissolved" || event == "group_member_left" {
                applyGroupLifecycleEvent(event: event, groupID: realtimeGroupID(from: envelope))
            }
            if Self.isFriendRelationRealtimeEvent(event: event, kind: kind) {
                Task { await refreshFriendApplicationsFromRealtime(event: event, envelope: envelope) }
            }
            if [
                "profile_updated",
                "profile.updated",
                "blacklist.updated",
                "blacklist.added",
                "blacklist.removed",
                "friend_remark.updated",
                "contact.remark.updated"
            ].contains(event) {
                scheduleProfileContactRealtimeReconcile(event: event)
            }
            if event == "inbox.updated"
                || kind == "friend_sensitive_notice"
                || senderUID == "system_notification"
                || senderUID == "system_message" {
                Task { await refreshInboxSilently() }
            }
        case "error":
            #if DEBUG
            if authPolicyScreenshotModeEnabled {
                diagnosticHandling = .screenshotIgnored
                return
            }
            #endif
            let code = realtimeErrorString(from: envelope, keys: ["code", "reason_code", "reasonCode"])
            let message = realtimeErrorString(from: envelope, keys: ["message", "reason", "reason_text"])
            diagnostic?.event.serverCode = .init(code: code)
            diagnosticHandling = .errorUnhandled
            if isNotFriendsForbiddenMessage("\(code) \(message)") {
                handleRealtimeNotFriendsError(envelope)
                diagnostic?.event.handlingCode = .notFriends
                diagnosticHandling = .notFriendsHandled
                return
            }
            if code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "security_blocked" {
                let info = securityBlockedInfo(from: envelope)
                handleSecurityBlocked(info)
                logSyncEndpointFailure("/im/ws", error: IMAPIError.securityBlocked(info))
                diagnostic?.event.handlingCode = .securityBlocked
                diagnosticHandling = .securityBlockedHandled
                return
            }
            if let quotaCode = IMAPIClient.licenseQuotaErrorCode(code) {
                // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023: one group's capacity does not invalidate the session.
                if quotaCode == "group_member_quota_exceeded" {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(IMAPIClient.licenseQuotaUserMessage(for: quotaCode))
                    diagnostic?.event.handlingCode = .groupMemberQuotaExceeded
                    diagnosticHandling = .operationRejected
                    return
                }
                disconnectRealtime(shouldReconnect: false)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(IMAPIClient.licenseQuotaUserMessage(for: quotaCode))
                logSyncEndpointFailure(
                    "/im/ws",
                    error: IMAPIError.businessForbidden(
                        code: quotaCode,
                        message: IMAPIClient.licenseQuotaUserMessage(for: quotaCode),
                        error: nil
                    )
                )
                diagnostic?.event.handlingCode = .init(code: quotaCode)
                diagnosticHandling = .quotaDisconnected
                return
            }
            if let accessCode = workspaceAccessCode(from: "\(code) \(message)") {
                let affectsCurrent = markWorkspaceAccessBlocked(accessCode)
                disconnectRealtime(shouldReconnect: false)
                if affectsCurrent {
                    bootstrapPresentationStore.sync.syncFailureMessage = workspaceAccessMessage(for: accessCode) // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                    forceWorkspaceSelectionForCurrentAccessBlock(accessCode)
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceAccessMessage(for: accessCode))
                logSyncEndpointFailure("/im/ws", error: IMAPIError.forbidden(accessCode))
                diagnostic?.event.handlingCode = .init(code: accessCode)
                diagnosticHandling = affectsCurrent ? .workspaceSelectionForced : .workspaceDisconnected
                return
            }
            // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_BEGIN
            let connectionFailure = RealtimeErrorScopePolicy.isConnectionFailure(
                code: code, envelope: envelope,
                matchesConnectRequest: (realtimeClient as? RealtimeClient)?.matchesActiveConnectRequest(envelope.requestID) == true
            )
            if code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "forbidden", !connectionFailure {
                diagnostic?.event.handlingCode = .forbidden
                diagnosticHandling = .operationRejected
                logSyncEndpointFailure("/im/ws", error: IMAPIError.businessForbidden(code: "forbidden", message: "会话操作无权限", error: nil))
                return
            }
            // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_END
            if connectionFailure {
                disconnectRealtime(shouldReconnect: false)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("实时连接暂不可用，聊天数据会继续同步")
                logSyncEndpointFailure("/im/ws", error: IMAPIError.server("websocket_\(code)"))
                diagnostic?.event.handlingCode = .init(code: code)
                diagnosticHandling = .authDisconnected
            }
        default:
            if envelope.type
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("certification.") {
                flushPendingRealtimeMessagesIfNeeded(
                    reason: "before_malformed_certification_invalidation"
                )
                _ = handleCertificationRealtimeInvalidation(envelope)
            }
        }
    }
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

    private func scheduleProfileContactRealtimeReconcile(event: String) {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        profileContactRealtimeRefreshTask?.cancel()
        profileContactRealtimeRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            if normalizedEvent == "profile_updated" || normalizedEvent == "profile.updated" {
                let authorityRequest = self.beginCurrentProfileRead(context: context)
                if let profile = try? await self.api.meProfile(context: context),
                   self.isCurrentRemoteScope(scope) {
                    _ = self.applyMeProfile(profile, authorityRequest: authorityRequest)
                }
            }
            guard !Task.isCancelled, self.isCurrentRemoteScope(scope) else { return }
            await self.refreshFriendApplicationsAndRelations(context: context, scope: scope)
            if self.isCurrentRemoteScope(scope) {
                self.profileContactRealtimeRefreshTask = nil
            }
        }
    }

    private func handleRealtimeResync(_ envelope: RealtimeEnvelope) {
        let requiresFullSync = envelope.payload["full_sync"]?.boolValue
            ?? envelope.payload["fullSync"]?.boolValue
            ?? envelope.payload["reset"]?.boolValue
            ?? false
        if requiresFullSync {
            scheduleRealtimeRecoveryRefresh(reason: "realtime_resync_full")
            return
        }
        guard case .array(let values)? = envelope.payload["channels"], !values.isEmpty else {
            refreshRealtimeFallback(envelope)
            return
        }
        var scheduledAny = false
        var hasUnknownChannel = false
        for value in values {
            let channelID: String
            let channelType: String
            switch value {
            case .object(let object):
                channelID = payloadString(object, ["channel_id", "channelID", "conversation_id", "conversationID", "id"])
                channelType = payloadString(object, ["channel_type", "channelType", "type"])
            case .string(let id):
                channelID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                channelType = ""
            default:
                hasUnknownChannel = true
                continue
            }
            let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType)
            guard !normalizedID.isEmpty else {
                hasUnknownChannel = true
                continue
            }
            if let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == normalizedID || remoteChannelID(for: $0) == normalizedID }) {
                scheduleRealtimeRecoveryConversationSync(conversation.id, reason: "realtime_resync_channel")
                scheduledAny = true
            } else {
                hasUnknownChannel = true
            }
        }
        if hasUnknownChannel || !scheduledAny {
            scheduleRealtimeRecoveryRefresh(reason: hasUnknownChannel ? "realtime_resync_unknown_channel" : "realtime_resync_empty")
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END
