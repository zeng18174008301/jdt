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
    func normalizedReadWatermarkChannelType(channelID: String, channelType: String) -> String {
        apiChannelType(for: conversationKind(from: channelType, channelID: channelID))
    }

    func currentReadWatermarkScope(
        channelID rawChannelID: String,
        channelType rawChannelType: String,
        context: IMAPIContext? = nil,
        lookup: ConversationUserLookup? = nil
    ) -> ConversationStore.ReadWatermarkScope? {
        let resolvedContext = context ?? apiContext
        let normalizedChannelID = normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType, lookup: lookup)
        let normalizedChannelType = normalizedReadWatermarkChannelType(
            channelID: normalizedChannelID,
            channelType: rawChannelType
        )
        return ConversationStore.ReadWatermarkScope(
            tenantID: resolvedContext.tenantID ?? "",
            imUID: resolvedContext.imUID ?? "",
            appID: resolvedContext.appID,
            channelID: normalizedChannelID,
            channelType: normalizedChannelType
        )
    }

    private func readWatermark(
        from remote: RemoteConversationReadWatermark,
        context: IMAPIContext
    ) -> ConversationStore.ReadWatermark? {
        let activeTenantID = (context.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeIMUID = (context.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTenantID = remote.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteIMUID = remote.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAppID = remote.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventID = remote.eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteChannelType = remote.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !activeTenantID.isEmpty,
              !activeIMUID.isEmpty,
              !activeAppID.isEmpty,
              !eventID.isEmpty,
              ["direct", "group", "system"].contains(remoteChannelType),
              remoteTenantID == activeTenantID,
              remoteIMUID == activeIMUID,
              remoteAppID == activeAppID else {
            return nil
        }
        let normalizedChannelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType)
        let normalizedChannelType = normalizedReadWatermarkChannelType(
            channelID: normalizedChannelID,
            channelType: remote.channelType
        )
        return ConversationStore.ReadWatermark(
            eventID: eventID,
            tenantID: remoteTenantID,
            imUID: remoteIMUID,
            appID: remoteAppID,
            channelID: normalizedChannelID,
            channelType: normalizedChannelType,
            lastReadSeq: remote.lastReadSeq,
            occurredAt: remote.occurredAt
        )
    }

    func cancelLocalNotifications(for scope: ConversationStore.ReadWatermarkScope, throughSeq: Int64) {
        guard let watermark = IOSNotificationReadWatermark(
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: throughSeq
        ) else {
            return
        }
        IOSNotificationRuntime.shared.cancelLocalNotifications(matching: watermark)
    }

    func handleConversationReadWatermark(_ envelope: RealtimeEnvelope) {
        let context = apiContext
        guard context.hasIMSession else { return }
        guard let remote = decodeRealtimePayload(RemoteConversationReadWatermark.self, key: "read_watermark", envelope: envelope)
                ?? decodeRealtimeEnvelopePayload(RemoteConversationReadWatermark.self, envelope: envelope),
              let watermark = readWatermark(from: remote, context: context) else {
            return
        }
        let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
        cancelLocalNotifications(for: watermark.scope, throughSeq: effectiveReadSeq)
        if let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
            conversation.id == watermark.scope.channelID
                || normalizedRemoteChannelID(
                    remoteChannelID(for: conversation),
                    channelType: watermark.scope.channelType
                ) == watermark.scope.channelID
        }) {
            conversationStore.advanceRead(conversationID: conversation.id, through: effectiveReadSeq)
            scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: context), source: .realtime)
        }
        scheduleRealtimeRecoveryRefresh(reason: "conversation_read")
    }

    func refreshRealtimeFallback(_ envelope: RealtimeEnvelope) {
        flushPendingRealtimeMessagesIfNeeded(reason: "before_realtime_fallback")
        let channelID = envelope.payload["channel_id"]?.stringValue ?? ""
        let channelType = envelope.payload["channel_type"]?.stringValue ?? ""
        if !channelID.isEmpty, !channelType.isEmpty {
            if let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) {
                scheduleRealtimeRecoveryConversationSync(conversation.id, reason: "realtime_fallback_channel")
            } else {
                scheduleRealtimeRecoveryRefresh(reason: "realtime_fallback_unknown_channel")
            }
            return
        }
        scheduleRealtimeRecoveryRefresh(reason: "realtime_fallback")
    }

    func realtimeGroupID(from envelope: RealtimeEnvelope) -> String {
        let keys = ["group_id", "groupId", "channel_id", "channelID", "id"]
        for key in keys {
            if let value = envelope.payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let payload = envelope.payload["payload"]?.objectValue {
            for key in keys {
                if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    func handleGroupSettingsUpdatedRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_settings_missing_group")
            return
        }
        func refreshAuthoritativeState() {
            Task {
                await refreshGroupBundle(
                    groupID: groupID,
                    silent: true,
                    includeSecondaryData: false,
                    queueAfterInFlight: true
                )
            }
        }
        let payload = envelope.payload["payload"]?.objectValue ?? envelope.payload
        let changedValue = payload["changed"] ?? envelope.payload["changed"]
        var changedFields: [String] = []
        if case .array(let values)? = changedValue {
            changedFields = values.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        guard let settingsValue = payload["settings"] ?? envelope.payload["settings"],
              let data = try? JSONSerialization.data(withJSONObject: settingsValue.anyValue),
              let settings = try? realtimeDecoder.decode(RemoteGroupSettings.self, from: data) else {
            refreshAuthoritativeState()
            return
        }

        let context = apiContext
        let scopeKey = groupMuteScopeKey(groupID: groupID, context: context)
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            refreshAuthoritativeState()
            return
        }
        let incomingGroupRevision = max(
            settings.groupRevision,
            (payload["group_revision"] ?? envelope.payload["group_revision"])?
                .stringValue
                .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        )
        let currentGroupRevision = groups[index].groupRevision
        if incomingGroupRevision > 0 {
            guard incomingGroupRevision > currentGroupRevision else { return }
            // WDT_APP_CONTRACT_20261021_09: invalidate only this group's friend-apply setting.
            if changedFields.contains("web_member_friend_apply_enabled") {
                groups[index].memberFriendApplyEnabled = nil
                refreshAuthoritativeState()
                return
            }
            if changedFields.contains("name") || changedFields.contains("avatar") {
                refreshAuthoritativeState()
                return
            }
            groups[index].groupRevision = incomingGroupRevision
            groups[index].groupDescription = settings.groupDescription ?? groups[index].groupDescription
            groups[index].inviteConfirmRequired = settings.inviteConfirmRequired
            groups[index].historyVisible = settings.historyVisible
            let carriesMuteMutation = changedFields.contains { field in
                field == "all_muted" || field == "all_muted_mode"
                    || field == "all_muted_start_at" || field == "all_muted_end_at"
                    || field == "all_muted_active" || field == "all_muted_updated_at"
            }
            if !carriesMuteMutation { return }
        } else if currentGroupRevision > 0 {
            refreshAuthoritativeState()
            return
        } else if changedFields.contains("description") {
            refreshAuthoritativeState()
        }
        let generationValue = ["generation", "revision"]
            .compactMap { payload[$0] ?? envelope.payload[$0] }
            .first
        let generation = generationValue?.stringValue.flatMap {
            Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if generationValue != nil, generation == nil || (generation ?? 0) <= 0 {
            refreshAuthoritativeState()
            return
        }
        let currentGeneration = groupModerationStore.muteRealtimeGeneration(scopeKey: scopeKey)
        let generationIsFresh = generation.map { $0 > currentGeneration }

        let incomingUpdatedAtRaw = settings.allMutedUpdatedAt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUpdatedAtRaw = groups[index].allMuteUpdatedAt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingUpdatedAt = incomingUpdatedAtRaw.isEmpty ? nil : parseRemoteDate(incomingUpdatedAtRaw)
        let currentUpdatedAt = currentUpdatedAtRaw.isEmpty ? nil : parseRemoteDate(currentUpdatedAtRaw)
        if (!incomingUpdatedAtRaw.isEmpty && incomingUpdatedAt == nil)
            || (!currentUpdatedAtRaw.isEmpty && currentUpdatedAt == nil) {
            refreshAuthoritativeState()
            return
        }
        let updatedAtIsFresh: Bool? = incomingUpdatedAt.map { incoming in
            guard let currentUpdatedAt else { return true }
            return incoming > currentUpdatedAt
        }
        if let generationIsFresh,
           let updatedAtIsFresh,
           generationIsFresh != updatedAtIsFresh {
            refreshAuthoritativeState()
            return
        }
        if generationIsFresh == false || updatedAtIsFresh == false {
            return
        }
        guard generationIsFresh == true || updatedAtIsFresh == true else {
            refreshAuthoritativeState()
            return
        }
        if let generation {
            groupModerationStore.recordMuteRealtimeGeneration(generation, scopeKey: scopeKey)
        }

        groupModerationStore.retireMuteMutation(scopeKey: scopeKey)
        groupModerationStore.setSettingsMutation(groupID: groupID, isMutating: false) // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110
        let projection = resolvedGroupMuteFields(
            allMuted: settings.allMuted,
            modeRawValue: settings.allMutedMode,
            active: settings.allMutedActive,
            startAtRawValue: settings.allMutedStartAt,
            endAtRawValue: settings.allMutedEndAt,
            serverTimeRawValue: settings.serverTime,
            nextBoundaryRawValue: settings.nextBoundaryAt,
            updatedAt: settings.allMutedUpdatedAt,
            repairRequired: settings.allMutedRepairRequired
        )
        groups[index].allMuted = projection.allMuted
        groups[index].allMuteMode = projection.mode
        groups[index].allMuteActive = projection.active
        groups[index].allMuteStart = projection.startAt
        groups[index].allMuteEnd = projection.endAt
        groups[index].allMuteServerTime = projection.serverTime
        groups[index].allMuteNextBoundary = projection.nextBoundaryAt
        groups[index].allMuteRepairRequired = projection.repairRequired
        groups[index].allMuteUpdatedAt = projection.updatedAt.isEmpty
            ? currentUpdatedAtRaw
            : projection.updatedAt
        scheduleGroupMuteBoundaryRefresh(for: groups[index], context: context)
    }

    func handleGroupOwnerTransferredRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            clearGroupAnnouncementReadCounts()
            scheduleRealtimeRecoveryRefresh(reason: "group_owner_transfer_missing_group")
            return
        }
        clearGroupAnnouncementReadCounts(groupID: groupID)
        Task {
            await refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            await refreshGroupAnnouncements(groupID: groupID, silent: true)
        }
    }

    func refreshFriendApplicationsFromRealtime(event: String, envelope: RealtimeEnvelope) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated,
              context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        let beforePendingCount = pendingFriendRequestCount
        await refreshFriendApplicationsAndRelations(context: context, scope: scope)
        guard isCurrentRemoteScope(scope) else { return }
        if shouldShowIncomingFriendApplicationToast(
            event: event,
            envelope: envelope,
            beforePendingCount: beforePendingCount
        ) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("收到新的好友申请")
        }
        await refreshInboxSilently()
    }

    private func shouldShowIncomingFriendApplicationToast(event: String, envelope: RealtimeEnvelope, beforePendingCount: Int) -> Bool {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEvent == "friend_application.created"
                || normalizedEvent == "friend_application.approved"
                || normalizedEvent == "friend.request.created"
                || normalizedEvent == "friend_request.created" else { return false }
        let status = friendRealtimePayloadString(envelope, keys: ["status", "application_status"])
        let outcome = friendRealtimePayloadString(envelope, keys: ["outcome"])
        guard !Self.isSuppressedFriendApplication(status: status, outcome: outcome) else {
            return false
        }
        let targetUID = (envelope.payload["target_uid"]?.stringValue
            ?? envelope.payload["targetUid"]?.stringValue
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !targetUID.isEmpty {
            guard isCurrentRealtimeIdentity(targetUID) else { return false }
        }
        let applicantUID = (envelope.payload["applicant_uid"]?.stringValue
            ?? envelope.payload["applicantUid"]?.stringValue
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicantUID.isEmpty, isCurrentRealtimeIdentity(applicantUID) {
            return false
        }
        return pendingFriendRequestCount > beforePendingCount
    }

    func friendRealtimePayloadString(_ envelope: RealtimeEnvelope, keys: [String]) -> String {
        for key in keys {
            if let value = envelope.payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let nested = envelope.payload["payload"]?.objectValue {
            for key in keys {
                if let value = nested[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    private func isCurrentRealtimeIdentity(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let candidates = [
            apiContext.imUID,
            apiContext.accountID,
            currentUser.id,
            currentUser.userID,
            currentUser.username,
            currentUser.email,
        ]
        return candidates.contains { candidate in
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == token
        }
    }

    func refreshGroupAnnouncementFromRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = envelope.payload["group_id"]?.stringValue
            ?? envelope.payload["groupID"]?.stringValue
            ?? envelope.payload["channel_id"]?.stringValue
            ?? envelope.payload["channelId"]?.stringValue
            ?? ""
        let trimmedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGroupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_announcement_missing_group")
            return
        }
        Task { await refreshGroupAnnouncements(groupID: trimmedGroupID, silent: true) }
    }

    func handleGroupMemberProfileRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_member_profile_missing_group")
            return
        }
        let nestedPayload = envelope.payload["payload"]?.objectValue ?? [:]
        let changedValue = envelope.payload["changed"] ?? nestedPayload["changed"]
        if case .array(let changed)? = changedValue {
            let fields = changed.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard fields.contains("group_nickname") else { return }
        }
        let generation = payloadInt64(
            envelope.payload,
            ["group_membership_generation", "generation", "revision"]
        ) ?? payloadInt64(
            nestedPayload,
            ["group_membership_generation", "generation", "revision"]
        ) ?? 0
        let key = groupMemberProfileCacheKey(groupID: groupID)
        let highestKnownGeneration = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
        if generation > 0, generation <= highestKnownGeneration {
            return
        }
        if generation > 0 {
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] = generation
        }
        groupMemberProfileRefreshTasks[key]?.cancel()
        let scope = remoteDataScopeKey(for: apiContext)
        groupMemberProfileRefreshTasks[key] = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            await self.refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            self.groupMemberProfileRefreshTasks[key] = nil
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
