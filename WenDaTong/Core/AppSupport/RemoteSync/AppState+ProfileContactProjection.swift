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
    func reapplyAllAvatarRealtimeProjections() {
        guard avatarRealtimeProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !avatarRealtimeProjection.values.isEmpty else {
            reapplyAllPresenceConnectivityProjections()
            return
        }
        applyResolvedAvatarRealtimeProjections(resolvedAvatarRealtimeProjectionMap())
        reapplyAllPresenceConnectivityProjections()
    }

    func reapplyAllPresenceConnectivityProjections() {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              !presenceConnectivityProjection.values.isEmpty else {
            return
        }
        let projections = presenceConnectivityProjection.values.reduce(
            into: [String: PresenceConnectivityProjectionValue]()
        ) { result, projection in
            result[projection.uid] = projection
        }
        applyPresenceConnectivityProjections(projections)
    }

    private func avatarRealtimeOverlaidUser(_ user: IMUser) -> IMUser {
        guard let resolved = resolvedAvatarRealtimeProjection(forExactUID: user.id) else {
            return user
        }
        return AvatarRealtimeSurfaceProjector.user(
            user,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    private func presenceConnectivityOverlaidUser(_ user: IMUser) -> IMUser {
        guard let projection = resolvedPresenceConnectivityProjection(for: user) else {
            return user
        }
        let status = presenceStatusText(
            rawStatus: projection.presenceStatus,
            online: projection.online
        )
        let lastLoginAt = projection.lastSeenAt.isEmpty
            ? user.lastLoginAt
            : resolvedLastLoginText(projection.lastSeenAt)
        return userWithPresenceStatus(user, status: status, lastLoginAt: lastLoginAt)
    }

    func presentationOverlaidUser(_ user: IMUser) -> IMUser {
        presenceConnectivityOverlaidUser(avatarRealtimeOverlaidUser(user))
    }

    func avatarRealtimeOverlaidFriendRequest(_ request: FriendRequest) -> FriendRequest {
        guard let resolved = resolvedAvatarRealtimeProjection(
            forExactUID: request.userID
        ) else {
            return request
        }
        return AvatarRealtimeSurfaceProjector.friendRequest(
            request,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func avatarRealtimeOverlaidGroupJoinRequest(
        _ request: GroupJoinRequest
    ) -> GroupJoinRequest {
        guard let resolved = resolvedAvatarRealtimeProjection(
            forExactUID: request.applicantUID
        ) else {
            return request
        }
        return AvatarRealtimeSurfaceProjector.groupJoinRequest(
            request,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func avatarRealtimeOverlaidCallRecord(_ record: CallRecord) -> CallRecord {
        guard let uid = AvatarRealtimeSurfaceProjector.authorityUID(for: record),
              let resolved = resolvedAvatarRealtimeProjection(forExactUID: uid) else {
            return record
        }
        return AvatarRealtimeSurfaceProjector.callRecord(
            record,
            projection: resolved.value,
            resolvedURL: resolved.url
        )
    }

    func projectAvatarRealtime(_ results: [UserSearchResult]) -> [UserSearchResult] {
        results.map { result in
            guard let resolved = resolvedAvatarRealtimeProjection(
                forExactUID: result.id
            ) else { return result }
            return AvatarRealtimeSurfaceProjector.userSearchResult(
                result,
                projection: resolved.value,
                resolvedURL: resolved.url
            )
        }
    }

    func projectPresenceConnectivity(_ result: UserSearchResult) -> UserSearchResult {
        guard presenceConnectivityProjection.tenantID
                == apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              presenceConnectivityProjection.viewerID
                == (apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return result
        }
        let identifiers = [result.imUID, result.userID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let projection = identifiers.lazy.compactMap({
            self.presenceConnectivityProjection.value(forExactUID: $0)
        }).first else {
            return result
        }
        return UserSearchResult(
            imUID: result.imUID,
            userID: result.userID,
            nickname: result.nickname,
            phone: result.phone,
            avatarURL: result.avatarURL,
            status: result.status,
            presenceStatus: presenceStatusText(
                rawStatus: projection.presenceStatus,
                online: projection.online
            ),
            relationStatus: result.relationStatus,
            canApplyFriend: result.canApplyFriend,
            reason: result.reason,
            friendAction: result.friendAction,
            friendFlow: result.friendFlow,
            requiresTenantReview: result.requiresTenantReview,
            requiresTargetApproval: result.requiresTargetApproval
        )
    }

	    func remoteDataScopeKey(for context: IMAPIContext) -> String {
	        messageStore.scopeKey(for: context)
	    }

    func profileContactKey(_ kind: String, identifier: String) -> String {
        "\(kind):\(identifier.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func profileContactKeys(kind: String, identifiers: [String]) -> Set<String> {
        Set(identifiers
            .map { profileContactKey(kind, identifier: $0) }
            .filter { !$0.hasSuffix(":") })
    }

    func profileContactMutationKeys(for user: IMUser, kinds: [String]) -> Set<String> {
        let identifiers = userIdentityCandidates(for: user)
        return kinds.reduce(into: Set<String>()) { result, kind in
            result.formUnion(profileContactKeys(kind: kind, identifiers: identifiers))
        }
    }

    func persistProfileContactProjectionIfPossible(
        scope: String,
        revision: UInt64,
        reason: String
    ) {
        guard isCurrentRemoteScope(scope),
              profileContactRevisionFence.scopeHash == scope,
              let ticket = localMessageTicket else { return }
        // JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：联系人/资料投影构造放到后台，AppState 只捕获当前值快照和执行持久化
        let contactSnapshot = contacts
        let remarkSnapshot = contactRemarks
        let blacklistSnapshot = blacklist
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
        let originalNameSnapshot = contactStore.contactCardOriginalNames(in: scope)
        Task {
            let projection = await ProfileContactProjectionBuilder.projectionOffMain(
                revision: revision,
                contacts: contactSnapshot,
                remarks: remarkSnapshot,
                blacklist: blacklistSnapshot,
                originalNames: originalNameSnapshot
            )
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
            do {
                try await messagePersistence.persistProfileContactProjection(
                    ticket: ticket,
                    projection: projection
                )
            } catch LocalMessageDatabaseError.staleSession {
                // A newer mutation/projection already won this scope.
            } catch LocalMessageDatabaseError.staleWriter {
                // Login or account scope changed while this best-effort write was queued.
            } catch {
                logSyncEndpointFailure("local/profile-contact/\(reason)", error: error)
            }
        }
        // JHT_MOD_END PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改结束
    }

    func commitAuthoritativeProfileContactProjection(scope: String, reason: String) {
        guard let revision = profileContactRevisionFence.acceptAuthoritativeProjection(scopeHash: scope) else {
            return
        }
        persistProfileContactProjectionIfPossible(scope: scope, revision: revision, reason: reason)
    }

    func applyCachedProfileContactProjection(
        _ projection: LocalProfileContactProjection?,
        scope: String,
        readStamp: ProfileContactReadStamp?
    ) {
        guard let projection,
              profileContactRevisionFence.acceptPersistedProjection(
                scopeHash: scope,
                readStamp: readStamp,
                revision: projection.revision
              ) else { return }
        contacts = projection.contacts.map(\.model)
        contactRemarks = projection.remarks
        blacklist = projection.blacklist.map(\.model)
        contactStore.restoreContactCardOriginalNames(projection.originalNames, in: scope) // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112
        contactStore.markFriendRelationsLoaded()
        refreshDirectConversationDisplayNames()
        pruneNonFriendDirectConversations()
    }

}
