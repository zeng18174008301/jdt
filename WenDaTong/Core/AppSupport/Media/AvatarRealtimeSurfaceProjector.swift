import IM4Domain
import Foundation

enum AvatarRealtimeSurfaceProjector {
    static func hasExactAuthorityCoverage(
        requestedUIDs: Set<String>,
        itemUIDs: [String],
        missingUIDs: [String]
    ) -> Bool {
        let itemSet = Set(itemUIDs)
        let missingSet = Set(missingUIDs)
        return itemUIDs.count == itemSet.count
            && missingUIDs.count == missingSet.count
            && itemSet.union(missingSet) == requestedUIDs
            && itemSet.isDisjoint(with: missingSet)
    }

    static func isCompleteAvatarAuthorityBatch(
        requestedUIDs: Set<String>,
        itemUIDs: [String],
        missingUIDs: [String],
        allItemsAuthoritative: Bool
    ) -> Bool {
        missingUIDs.isEmpty
            && allItemsAuthoritative
            && itemUIDs.count == requestedUIDs.count
            && Set(itemUIDs) == requestedUIDs
    }

    static func shouldMaintainAuthorityLoop(
        certificationUIDs: Set<String>,
        certificationScopeMatches: Bool,
        avatarUIDs: Set<String>
    ) -> Bool {
        (!certificationUIDs.isEmpty && certificationScopeMatches) || !avatarUIDs.isEmpty
    }

    static func user(
        _ user: IMUser,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> IMUser {
        guard user.id == projection.uid else { return user }
        return IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            lastLoginAt: user.lastLoginAt,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: resolvedURL,
            avatarVersion: projection.cacheVersion,
            avatarUpdatedAt: projection.updatedAt.isEmpty
                ? user.avatarUpdatedAt
                : projection.updatedAt,
            badges: user.badges
        )
    }

    static func authorityUID(for record: CallRecord) -> String? {
        let peerID = record.peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !peerID.isEmpty { return peerID }
        let fallback = record.peerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    static func isDirectPeerEvent(
        conversationID: String,
        remoteChannelID: String,
        participantUIDs: [String],
        currentUID: String,
        eventUID: String
    ) -> Bool {
        directPeerUID(
            conversationID: conversationID,
            remoteChannelID: remoteChannelID,
            participantUIDs: participantUIDs,
            currentUID: currentUID
        ) == eventUID && eventUID != currentUID
    }

    static func directPeerUID(
        conversationID: String,
        remoteChannelID: String,
        participantUIDs: [String],
        currentUID: String
    ) -> String? {
        ConversationDirectPeerIdentity.directPeerUID(conversationID: conversationID, remoteChannelID: remoteChannelID, participantUIDs: participantUIDs, currentUID: currentUID)
    }

    static func friendRequest(
        _ request: FriendRequest,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> FriendRequest {
        guard request.userID == projection.uid else { return request }
        return FriendRequest(
            id: request.id,
            name: request.name,
            userID: request.userID,
            avatarURL: resolvedURL,
            source: request.source,
            message: request.message,
            status: request.status,
            direction: request.direction,
            tenantReviewStatus: request.tenantReviewStatus,
            peerReviewStatus: request.peerReviewStatus,
            canRespond: request.canRespond,
            outcome: request.outcome,
            relationStatus: request.relationStatus,
            friendAction: request.friendAction,
            friendFlow: request.friendFlow,
            directlyEstablished: request.directlyEstablished,
            requiresTenantReview: request.requiresTenantReview,
            requiresTargetApproval: request.requiresTargetApproval,
            resolutionMode: request.resolutionMode,
            accepted: request.accepted
        )
    }

    static func groupJoinRequest(
        _ request: GroupJoinRequest,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> GroupJoinRequest {
        guard request.applicantUID == projection.uid else { return request }
        return GroupJoinRequest(
            id: request.id,
            groupID: request.groupID,
            applicantUID: request.applicantUID,
            applicantName: request.applicantName,
            applicantAvatarURL: resolvedURL,
            inviterAvatarURL: request.inviterAvatarURL,
            inviterName: request.inviterName,
            status: request.status,
            message: request.message,
            createdAt: request.createdAt
        )
    }

    static func callRecord(
        _ record: CallRecord,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> CallRecord {
        guard record.peerID == projection.uid || record.peerUserID == projection.uid else {
            return record
        }
        return CallRecord(
            id: record.id,
            callID: record.callID,
            peerID: record.peerID,
            peerUserID: record.peerUserID,
            peerAvatarURL: resolvedURL,
            peerAvatarVersion: projection.cacheVersion,
            peerAvatarUpdatedAt: projection.updatedAt.isEmpty
                ? record.peerAvatarUpdatedAt
                : projection.updatedAt,
            peerAvatarSource: record.peerAvatarSource,
            title: record.title,
            subtitle: record.subtitle,
            time: record.time,
            status: record.status,
            direction: record.direction,
            callType: record.callType,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            endReason: record.endReason,
            stateVersion: record.stateVersion
        )
    }

    static func userSearchResult(
        _ result: UserSearchResult,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> UserSearchResult {
        guard result.imUID == projection.uid || result.userID == projection.uid else {
            return result
        }
        return UserSearchResult(
            imUID: result.imUID,
            userID: result.userID,
            nickname: result.nickname,
            phone: result.phone,
            avatarURL: resolvedURL,
            status: result.status,
            presenceStatus: result.presenceStatus,
            relationStatus: result.relationStatus,
            canApplyFriend: result.canApplyFriend,
            reason: result.reason,
            friendAction: result.friendAction,
            friendFlow: result.friendFlow,
            requiresTenantReview: result.requiresTenantReview,
            requiresTargetApproval: result.requiresTargetApproval
        )
    }

    static func groupMuteListItem(
        _ item: GroupMuteListItem,
        projection: AvatarRealtimeProjectionValue,
        resolvedURL: String
    ) -> GroupMuteListItem {
        guard item.targetUID == projection.uid else { return item }
        return GroupMuteListItem(
            groupID: item.groupID,
            targetUID: item.targetUID,
            targetUserID: item.targetUserID,
            targetUsername: item.targetUsername,
            targetNickname: item.targetNickname,
            targetAvatarURL: resolvedURL,
            targetRole: item.targetRole,
            operatorUID: item.operatorUID,
            operatorName: item.operatorName,
            reason: item.reason,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            createdAtText: item.createdAtText,
            updatedAtText: item.updatedAtText
        )
    }
}
