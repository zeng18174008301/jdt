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

// WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
@MainActor
final class AvatarSearchPresentationStore {
    @Published var revision: Int64 = 0
}
// WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END

extension AppState {
    func reconcileAvatarRealtimeScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        let previousTenantID = previousContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextTenantID = nextContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard previousTenantID != nextTenantID
                || previousContext.hasIMSession != nextContext.hasIMSession else {
            return
        }
        purgeAvatarRealtimeProjection(rebindCurrentScope: nextContext.hasIMSession)
    }

    func purgeAvatarRealtimeProjection(rebindCurrentScope: Bool) {
        avatarAuthorityRequestSequence &+= 1
        avatarAuthorityRefreshTask?.cancel()
        avatarAuthorityRefreshTask = nil
        pendingAvatarAuthorityUIDs.removeAll(keepingCapacity: false)
        avatarRealtimeProjection.purge()
        avatarLocalCommitAuthorityFence.purge()
        if rebindCurrentScope,
           let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tenantID.isEmpty {
            avatarRealtimeProjection.bind(tenantID: tenantID)
            avatarLocalCommitAuthorityFence.bind(tenantID: tenantID)
        }
    }

    func reconcilePresenceConnectivityScope(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        let previousTenantID = previousContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextTenantID = nextContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previousViewerID = previousContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextViewerID = nextContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard previousTenantID != nextTenantID
                || previousViewerID != nextViewerID
                || previousContext.hasIMSession != nextContext.hasIMSession else {
            return
        }
        purgePresenceConnectivityProjection(rebindCurrentScope: nextContext.hasIMSession)
    }

    func purgePresenceConnectivityProjection(rebindCurrentScope: Bool) {
        presenceConnectivityProjection.purge()
        if rebindCurrentScope,
           let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tenantID.isEmpty,
           let viewerID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !viewerID.isEmpty {
            presenceConnectivityProjection.bind(
                tenantID: tenantID,
                viewerID: viewerID
            )
        }
        // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110: Rebinding has no separate presentation revision.
    }

    func handleAvatarRealtimeOutcomes(_ outcomes: [AvatarRealtimeProjectionOutcome]) {
        var projections: [AvatarRealtimeProjectionValue] = []
        for outcome in outcomes {
            switch outcome {
            case .applied(let projection):
                projections.append(projection)
            case .refetch(let uids, _):
                queueAvatarAuthorityRefetch(uids.isEmpty ? visibleAvatarAuthorityUIDs() : uids)
            case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
                break
            }
        }
        applyAvatarRealtimeProjections(projections)
    }

    func handleAvatarRealtimeOutcome(_ outcome: AvatarRealtimeProjectionOutcome) {
        switch outcome {
        case .applied(let projection):
            applyAvatarRealtimeProjection(projection)
        case .refetch(let uids, _):
            queueAvatarAuthorityRefetch(uids.isEmpty ? visibleAvatarAuthorityUIDs() : uids)
        case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
            break
        }
    }

    func handlePresenceConnectivityOutcome(
        _ outcome: PresenceConnectivityProjectionOutcome
    ) {
        switch outcome {
        case .applied, .refetch, .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
            break
        }
    }

    func queueAvatarAuthorityRefetch(_ rawUIDs: Set<String>) {
        guard isAuthenticated, apiContext.hasIMSession else { return }
        let uids = Set(CertificationProfileUIDBatch.normalizedAll(rawUIDs))
        guard !uids.isEmpty else { return }
        pendingAvatarAuthorityUIDs.formUnion(uids)
        scheduleAvatarAuthorityRefreshIfNeeded()
    }

    func visibleAvatarAuthorityUIDs() -> Set<String> {
        var uids: Set<String> = []
        func insert(_ user: IMUser) {
            let uid = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        let sessionUID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sessionUID.isEmpty {
            uids.insert(sessionUID)
        } else if currentUser.id != "pending" {
            insert(currentUser)
        }
        let authorityCurrentUID = sessionUID.isEmpty
            ? currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines)
            : sessionUID
        contacts.forEach(insert)
        friendRequests.forEach { request in
            let uid = request.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        groupJoinRequests.values.joined().forEach { request in
            let uid = request.applicantUID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        calls.forEach { record in
            if let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record) {
                uids.insert(uid)
            }
        }
        groupModerationStore.cachedListItems.values.joined().forEach { item in // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110
            let uid = item.targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty { uids.insert(uid) }
        }
        groups.forEach { group in
            group.members.forEach(insert)
            group.admins.forEach(insert)
        }
        let lookup = makeConversationUserLookup()
        conversationStore.conversationMessageSnapshots().forEach { conversation in
            conversation.participants.forEach(insert)
            if conversation.kind == .direct,
               let peerUID = AvatarRealtimeSurfaceProjector.directPeerUID(
                    conversationID: conversation.id,
                    remoteChannelID: remoteChannelID(for: conversation, lookup: lookup),
                    participantUIDs: conversation.participants.map(\.id),
                    currentUID: authorityCurrentUID
               ) {
                uids.insert(peerUID)
            }
            conversation.messages.forEach { message in
                let uid = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !uid.isEmpty { uids.insert(uid) }
            }
        }
        if let incomingVoiceCall { insert(incomingVoiceCall.caller) }
        if let activeVoiceCall { insert(activeVoiceCall.peer) }
        return uids
    }

    private func scheduleAvatarAuthorityRefreshIfNeeded() {
        guard avatarAuthorityRefreshTask == nil,
              !pendingAvatarAuthorityUIDs.isEmpty else { return }
        let requestSequence = avatarAuthorityRequestSequence
        avatarAuthorityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            for attempt in 0..<5 where !Task.isCancelled {
                await self.flushAvatarAuthorityBatch(requestSequence: requestSequence)
                guard !self.pendingAvatarAuthorityUIDs.isEmpty else { break }
                if attempt < 4 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }
            guard self.avatarAuthorityRequestSequence == requestSequence else { return }
            self.avatarAuthorityRefreshTask = nil
            if !self.pendingAvatarAuthorityUIDs.isEmpty {
                self.scheduleRealtimeRecoveryRefresh(reason: "avatar_authority_incomplete")
            }
        }
    }

    // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
    func fetchUserProfiles(context: IMAPIContext, exactUIDs: [String]) async throws -> RemoteUserProfilesResponse {
        let authority = context.authSessionFence
        return try await UserProfilesRequestAuthority.$isCurrent.withValue({ [weak self] in
            guard let self, self.isAuthenticated, self.apiContext.hasIMSession else { return false }
            return self.apiContext.isSameAuthAuthority(as: authority)
        }) {
            try UserProfilesRequestAuthority.check()
            let response: RemoteUserProfilesResponse
            do {
                response = try await api.userProfiles(context: context, exactUIDs: exactUIDs)
            } catch {
                try UserProfilesRequestAuthority.check()
                throw error
            }
            try UserProfilesRequestAuthority.check()
            return response
        }
    }
    // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

    private func flushAvatarAuthorityBatch(requestSequence: Int64) async {
        guard avatarAuthorityRequestSequence == requestSequence,
              isAuthenticated,
              apiContext.hasIMSession,
              let tenantID = apiContext.tenantID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty else { return }
        let batch = CertificationProfileUIDBatch.normalized(
            pendingAvatarAuthorityUIDs.sorted()
        )
        guard !batch.isEmpty else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let avatarCommitEpochAtRequest = avatarLocalCommitAuthorityFence.epoch
        pendingAvatarAuthorityUIDs.subtract(batch)
        do {
            let requestStartedAt = DispatchTime.now().uptimeNanoseconds
            let response = try await fetchUserProfiles(context: context, exactUIDs: batch) // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
            guard !Task.isCancelled,
                  avatarAuthorityRequestSequence == requestSequence,
                  isCurrentRemoteScope(scope),
                  apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) == tenantID else {
                return
            }
            let requestedUIDs = Set(batch)
            guard avatarLocalCommitAuthorityFence.epoch == avatarCommitEpochAtRequest else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            guard AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: requestStartedAt,
                completedAt: DispatchTime.now().uptimeNanoseconds
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            guard AvatarRealtimeSurfaceProjector.hasExactAuthorityCoverage(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            var summaries: [UserSummaryV2] = []
            summaries.reserveCapacity(response.items.count)
            var allItemsAuthoritative = true
            for item in response.items {
                switch item.userSummaryProjection {
                case .authoritative(let summary):
                    summaries.append(summary)
                case .authoritativeOmission, .malformed:
                    allItemsAuthoritative = false
                }
            }
            guard AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: requestedUIDs,
                itemUIDs: response.items.map(\.imUID),
                missingUIDs: response.missingUIDs,
                allItemsAuthoritative: allItemsAuthoritative
            ) else {
                pendingAvatarAuthorityUIDs.formUnion(requestedUIDs)
                return
            }
            let outcomes = avatarRealtimeProjection.applyAuthorityBatch(
                summaries: summaries,
                subjectTenantID: tenantID
            )
            var projections: [AvatarRealtimeProjectionValue] = []
            for outcome in outcomes {
                switch outcome {
                case .applied(let projection):
                    projections.append(projection)
                case .refetch(let uids, _):
                    pendingAvatarAuthorityUIDs.formUnion(uids)
                case .unrelated, .ignoredForeignTenant, .ignoredStale, .idempotent:
                    break
                }
            }
            applyAvatarRealtimeProjections(projections)
        } catch {
            guard !Task.isCancelled, isAuthenticated, // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111
                  avatarAuthorityRequestSequence == requestSequence,
                  isCurrentRemoteScope(scope) else { return }
            pendingAvatarAuthorityUIDs.formUnion(batch)
        }
    }

    func resolvedAvatarRealtimeProjection(
        _ projection: AvatarRealtimeProjectionValue
    ) -> ResolvedAvatarRealtimeProjection? {
#if DEBUG
        avatarRealtimeAssetResolutionCountForTesting &+= 1
#endif
        let resolvedURL = resolveTenantAssetURL(projection.url)
        guard !resolvedURL.isEmpty,
              avatarLocalCommitAuthorityFence.allows(
                projection,
                resolvedProjectionURL: resolvedURL
              ) else { return nil }
        return ResolvedAvatarRealtimeProjection(value: projection, url: resolvedURL)
    }

    func resolvedAvatarRealtimeProjection(
        forExactUID rawUID: String
    ) -> ResolvedAvatarRealtimeProjection? {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty,
              let projection = avatarRealtimeProjection.value(forExactUID: uid) else {
            return nil
        }
        return resolvedAvatarRealtimeProjection(projection)
    }

    func resolvedAvatarRealtimeProjectionMap()
        -> [String: ResolvedAvatarRealtimeProjection] {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return [:]
        }
        var result: [String: ResolvedAvatarRealtimeProjection] = [:]
        result.reserveCapacity(avatarRealtimeProjection.values.count)
        for projection in avatarRealtimeProjection.values {
            if let resolved = resolvedAvatarRealtimeProjection(projection) {
                result[projection.uid] = resolved
            }
        }
        return result
    }

    private func applyAvatarRealtimeProjection(_ projection: AvatarRealtimeProjectionValue) {
        applyAvatarRealtimeProjections([projection])
    }

    func applyAvatarRealtimeProjections(_ projections: [AvatarRealtimeProjectionValue]) {
        var resolvedByUID: [String: ResolvedAvatarRealtimeProjection] = [:]
        for projection in projections {
            guard apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == projection.tenantID else { continue }
            let resolvedURL = resolveTenantAssetURL(projection.url)
            guard !resolvedURL.isEmpty else { continue }
            guard avatarLocalCommitAuthorityFence.consumeIfAuthoritative(
                projection,
                resolvedProjectionURL: resolvedURL
            ) else {
                queueAvatarAuthorityRefetch([projection.uid])
                continue
            }
            // Authority batches have unique UIDs. Preserve sequential field fallback
            // semantics if a caller ever supplies multiple updates for the same UID.
            if resolvedByUID[projection.uid] != nil {
                applyResolvedAvatarRealtimeProjections(resolvedByUID)
                resolvedByUID.removeAll(keepingCapacity: true)
            }
            resolvedByUID[projection.uid] = ResolvedAvatarRealtimeProjection(
                value: projection,
                url: resolvedURL
            )
        }
        applyResolvedAvatarRealtimeProjections(resolvedByUID)
    }

    func applyResolvedAvatarRealtimeProjections(
        _ projections: [String: ResolvedAvatarRealtimeProjection]
    ) {
        guard !projections.isEmpty else { return }
        var didChange = false

        func projected(_ user: IMUser) -> IMUser {
            guard let resolved = projections[user.id] else { return user }
            return AvatarRealtimeSurfaceProjector.user(
                user,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ request: FriendRequest) -> FriendRequest {
            guard let resolved = projections[request.userID] else { return request }
            return AvatarRealtimeSurfaceProjector.friendRequest(
                request,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ request: GroupJoinRequest) -> GroupJoinRequest {
            guard let resolved = projections[request.applicantUID] else { return request }
            return AvatarRealtimeSurfaceProjector.groupJoinRequest(
                request,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ record: CallRecord) -> CallRecord {
            guard let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record),
                  let resolved = projections[uid] else {
                return record
            }
            return AvatarRealtimeSurfaceProjector.callRecord(
                record,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
        func projected(_ item: GroupMuteListItem) -> GroupMuteListItem {
            guard let resolved = projections[item.targetUID] else { return item }
            return AvatarRealtimeSurfaceProjector.groupMuteListItem(
                item,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }

        let nextCurrentUser = projected(currentUser)
        if nextCurrentUser != currentUser {
            setCurrentUser(nextCurrentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            didChange = true
        }

        let nextContacts = contactStore.contacts.map(projected)
        if nextContacts != contactStore.contacts {
            contactStore.contacts = nextContacts
            didChange = true
        }

        let nextGroups = contactStore.groups.map { group in
            var next = group
            next.members = group.members.map(projected)
            next.admins = group.admins.map(projected)
            return next
        }
        if nextGroups != contactStore.groups {
            contactStore.groups = nextGroups
            didChange = true
        }

        if organizationDirectoryStore.projectMembers(projected) { // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
            didChange = true
        }
        if contactStore.groupSelfProfiles.projectMembers(projected) { // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
            didChange = true
        }

        let sessionUID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUID = sessionUID.isEmpty
            ? currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines)
            : sessionUID
        let lookup = makeConversationUserLookup()
        // JHT_MOD_BEGIN APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改开始：会话/消息头像投影改为命中式应用，避免主线程整表深比较
        let conversationProjectionMap = projections.mapValues {
            ConversationStore.AvatarRealtimeConversationProjection(
                uid: $0.value.uid,
                url: $0.url,
                cacheVersion: $0.value.cacheVersion,
                updatedAt: $0.value.updatedAt
            )
        }
        let conversationProjectionResult = conversationStore.applyAvatarRealtimeProjectionsToConversations(
            conversationProjectionMap,
            currentUID: currentUID,
            channelIDForConversation: { [self] conversation in
                remoteChannelID(for: conversation, lookup: lookup)
            },
            projectParticipant: projected
        )
        if conversationProjectionResult.didChange {
            didChange = true
        }
        #if DEBUG
        if conversationProjectionResult.didChange {
            print("[JHT Perf] avatar_projection_conversation_apply conversations=\(conversationProjectionResult.conversationsChanged) participants=\(conversationProjectionResult.participantsChanged) messages=\(conversationProjectionResult.messagesChanged)")
        }
        #endif
        // JHT_MOD_END APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改结束

        if var incoming = callStore.incomingVoiceCall {
            let nextCaller = projected(incoming.caller)
            if nextCaller != incoming.caller {
                incoming.caller = nextCaller
                callStore.incomingVoiceCall = incoming
                didChange = true
            }
        }
        if var active = callStore.activeVoiceCall {
            let nextPeer = projected(active.peer)
            if nextPeer != active.peer {
                active.peer = nextPeer
                callStore.activeVoiceCall = active
                didChange = true
            }
        }
        if var preview = callStore.videoCallPreview {
            let nextPeer = projected(preview.peer)
            if nextPeer != preview.peer {
                preview.peer = nextPeer
                callStore.videoCallPreview = preview
                didChange = true
            }
        }

        let nextFriendRequests = contactStore.friendRequests.map(projected)
        if nextFriendRequests != contactStore.friendRequests {
            contactStore.friendRequests = nextFriendRequests
            didChange = true
        }
        let nextGroupJoinRequests = contactStore.groupJoinRequests.mapValues { $0.map(projected) }
        if nextGroupJoinRequests != contactStore.groupJoinRequests {
            contactStore.groupJoinRequests = nextGroupJoinRequests
            didChange = true
        }
        let nextCalls = callStore.calls.map(projected)
        if nextCalls != callStore.calls, hasCurrentCallRecordBinding() {
            callStore.calls = nextCalls
            didChange = true
        }
        // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
        if groupModerationStore.projectListItems(projected) {
            didChange = true
        }
        // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

        if didChange {
            avatarSearchPresentationStore.revision &+= 1 // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110
        }
    }

    private func applyPresenceConnectivityProjection(
        _ projection: PresenceConnectivityProjectionValue
    ) {
        guard apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
                == projection.tenantID else {
            return
        }
        applyPresenceConnectivityProjections([projection.uid: projection])
    }

    // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
    func applyPresenceConnectivityProjections(
        _ projections: [String: PresenceConnectivityProjectionValue]
    ) {
        guard !projections.isEmpty else { return }

        func projected(_ user: IMUser) -> IMUser {
            guard let projection = presenceConnectivityProjection(for: user, in: projections) else {
                return user
            }
            let status = presenceStatusText(
                rawStatus: projection.presenceStatus,
                online: projection.online
            )
            let lastLoginAt = projection.lastSeenAt.isEmpty
                ? user.lastLoginAt
                : resolvedLastLoginText(projection.lastSeenAt)
            return userWithPresenceStatus(
                user,
                status: status,
                lastLoginAt: lastLoginAt
            )
        }

        let nextCurrentUser = projected(currentUser)
        if nextCurrentUser != currentUser {
            setCurrentUser(nextCurrentUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        }

        let nextContacts = contactStore.contacts.map(projected)
        if nextContacts != contactStore.contacts {
            contactStore.contacts = nextContacts
        }

        let nextGroups = contactStore.groups.map { group in
            var next = group
            next.members = group.members.map(projected)
            next.admins = group.admins.map(projected)
            return next
        }
        if nextGroups != contactStore.groups {
            contactStore.groups = nextGroups
        }

        _ = organizationDirectoryStore.projectMembers(projected) // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
        _ = contactStore.groupSelfProfiles.projectMembers(projected) // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
        _ = conversationStore.updateConversationParticipants(projected)

        if var incoming = callStore.incomingVoiceCall {
            let nextCaller = projected(incoming.caller)
            if nextCaller != incoming.caller {
                incoming.caller = nextCaller
                callStore.incomingVoiceCall = incoming
            }
        }
        if var active = callStore.activeVoiceCall {
            let nextPeer = projected(active.peer)
            if nextPeer != active.peer {
                active.peer = nextPeer
                callStore.activeVoiceCall = active
            }
        }
        if var preview = callStore.videoCallPreview {
            let nextPeer = projected(preview.peer)
            if nextPeer != preview.peer {
                preview.peer = nextPeer
                callStore.videoCallPreview = preview
            }
        }
    }
    // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END

    func presenceConnectivityProjection(
        for user: IMUser,
        in projections: [String: PresenceConnectivityProjectionValue]
    ) -> PresenceConnectivityProjectionValue? {
        var seen = Set<String>()
        let keys = [user.id, user.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        for key in keys {
            if let projection = projections[key] {
                return projection
            }
        }
        return nil
    }

    func resolvedPresenceConnectivityProjection(
        for user: IMUser
    ) -> PresenceConnectivityProjectionValue? {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return nil
        }
        var seen = Set<String>()
        let keys = [user.id, user.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        for key in keys {
            if let projection = presenceConnectivityProjection.value(forExactUID: key) {
                return projection
            }
        }
        return nil
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
