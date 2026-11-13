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
    func groupInfo(from remote: RemoteUserGroup, detail: RemoteGroupDetail? = nil, summary: RemoteGroupSummary? = nil, existing: GroupInfo?) -> GroupInfo {
        let settings = detail?.settings ?? summary?.settings
        let incomingGroupRevision = max(remote.groupRevision, settings?.groupRevision ?? 0)
        let acceptsRevisionedProfile = existing == nil
            || (existing?.groupRevision ?? 0) <= 0
            || incomingGroupRevision >= (existing?.groupRevision ?? 0)
        let owner = detail?.owner ?? summary?.owner
        let summaryAdmins = summary?.memberPreview
            .filter { $0.isAdmin || $0.role == "admin" || $0.role == "owner" }
            .map { groupMemberUser(from: $0) }
        let admins = detail?.admins.map { groupMemberUser(from: $0) } ?? summaryAdmins ?? existing?.admins ?? []
        let groupID = remote.groupID.isEmpty ? existing?.id ?? "" : remote.groupID
        let notice: String
        if let announcements = groupAnnouncements[groupID] {
            // Unversioned group summary/detail fields cannot supersede the
            // revision-ordered publication cache, including known empty state.
            let latest = orderedGroupAnnouncements(announcements).first
            notice = latest.map { $0.content.isEmpty ? $0.summary : $0.content } ?? ""
        } else {
            notice = remote.notice.isEmpty
                ? (detail?.currentAnnouncement?.content ?? existing?.notice ?? "暂无群公告")
                : remote.notice
        }
        let groupName = acceptsRevisionedProfile
            ? (remote.name.isEmpty ? existing?.name ?? "" : remote.name)
            : existing?.name ?? remote.name
        let groupDescription = settings?.groupDescription
            ?? remote.groupDescription
            ?? existing?.groupDescription
            ?? ""
        let ownerID = owner.map { $0.imUID.isEmpty ? $0.userID : $0.imUID }.flatMap { $0.isEmpty ? nil : $0 } ?? (remote.ownerUID.isEmpty ? existing?.ownerID ?? "" : remote.ownerUID)
        let ownerDisplayName = owner.map { groupMemberUser(from: $0).name }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // WDT_APP_CONTRACT_20261021_05: only server aggregates describe a total, never preview sizes.
        let reportedMemberCount = detail?.memberCount ?? summary?.memberCount
            ?? summary?.counts.memberCount ?? remote.memberCount
        let memberCount = acceptsRevisionedProfile || incomingGroupRevision == 0
            ? reportedMemberCount ?? existing?.memberCount
            : existing?.memberCount
        let historyVisibleFromSeq = max(1, detail?.historyVisibleFromSeq ?? summary?.historyVisibleFromSeq ?? remote.historyVisibleFromSeq)
        let historyLimited = detail?.historyLimited ?? summary?.historyLimited ?? remote.historyLimited
        let resolvedRole = detail?.myRole ?? summary?.myRole ?? remote.myRole
        let fallbackCanManageMuteList = resolvedRole == "owner" || resolvedRole == "admin"
        let canManageMuteList = detail?.canManageMuteList
            ?? summary?.canManageMuteList
            ?? remote.canManageMuteList
            ?? settings?.canManageMuteList
            ?? existing?.canManageMuteList
            ?? fallbackCanManageMuteList
        let muteListCount = detail?.muteListCount
            ?? summary?.muteListCount
            ?? remote.muteListCount
            ?? settings?.muteListCount
            ?? existing?.muteListCount
        let groupMute = resolvedGroupMuteFields(
            allMuted: settings?.allMuted ?? remote.allMuted,
            modeRawValue: {
                let value = settings?.allMutedMode ?? ""
                return value.isEmpty ? remote.allMutedMode : value
            }(),
            active: settings?.allMutedActive ?? remote.allMutedActive,
            startAtRawValue: settings?.allMutedStartAt ?? remote.allMutedStartAt,
            endAtRawValue: settings?.allMutedEndAt ?? remote.allMutedEndAt,
            serverTimeRawValue: settings?.serverTime ?? remote.serverTime,
            nextBoundaryRawValue: settings?.nextBoundaryAt ?? remote.nextBoundaryAt,
            updatedAt: settings?.allMutedUpdatedAt ?? remote.allMutedUpdatedAt,
            repairRequired: (settings?.allMutedRepairRequired ?? false) || remote.allMutedRepairRequired
        )
        let normalizedAvatarSource = remote.avatarSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let authorityRequiresPlaceholder = normalizedAvatarSource == "group_default"
            || normalizedAvatarSource == "system_default"
            || isDefaultGroupAvatarURL(remote.avatar)
        var authoritativeAvatarURL = existing?.avatarURL ?? ""
        var authoritativeAvatarVersion = existing?.avatarVersion ?? ""
        var authoritativeAvatarUpdatedAt = existing?.avatarUpdatedAt ?? ""
        if acceptsRevisionedProfile && (remote.avatarProvided || authorityRequiresPlaceholder) {
            let stablePath = authorityRequiresPlaceholder ? "" : authoritativeGroupAvatarPath(remote.avatar)
            if stablePath.isEmpty {
                authoritativeAvatarURL = ""
                authoritativeAvatarVersion = ""
                authoritativeAvatarUpdatedAt = ""
            } else {
                let isSameAsset = stablePath == existing?.avatarURL
                authoritativeAvatarURL = stablePath
                authoritativeAvatarVersion = remote.avatarVersion.isEmpty && isSameAsset
                    ? existing?.avatarVersion ?? ""
                    : remote.avatarVersion
                authoritativeAvatarUpdatedAt = remote.avatarUpdatedAt.isEmpty && isSameAsset
                    ? existing?.avatarUpdatedAt ?? ""
                    : remote.avatarUpdatedAt
            }
        }
        return GroupInfo(
            id: groupID,
            name: groupName,
            groupRevision: max(incomingGroupRevision, existing?.groupRevision ?? 0),
            avatarURL: authoritativeAvatarURL,
            avatarVersion: authoritativeAvatarVersion,
            avatarUpdatedAt: authoritativeAvatarUpdatedAt,
            notice: notice,
            groupDescription: groupDescription,
            owner: ownerDisplayName ?? (remote.ownerName.isEmpty ? existing?.owner ?? remote.ownerUID : remote.ownerName),
            ownerID: ownerID,
            members: existing?.members ?? [],
            admins: admins,
            membersPartial: existing?.membersPartial ?? false,
            membersLoadedCount: existing?.membersLoadedCount ?? existing?.members.count ?? 0,
            membersNextOffset: existing?.membersNextOffset,
            membersNextCursor: existing?.membersNextCursor,
            muted: settings?.muted ?? remote.muted,
            allMuted: groupMute.allMuted,
            allMuteStart: groupMute.startAt,
            allMuteEnd: groupMute.endAt,
            allMuteMode: groupMute.mode,
            allMuteActive: groupMute.active,
            allMuteServerTime: groupMute.serverTime,
            allMuteNextBoundary: groupMute.nextBoundaryAt,
            allMuteRepairRequired: groupMute.repairRequired,
            allMuteUpdatedAt: groupMute.updatedAt,
            myRole: resolvedRole,
            memberCount: shouldShowGroupMemberCount ? memberCount : nil,
            adminCount: shouldShowGroupMemberCount ? summary?.counts.adminCount : nil,
            memberFriendApplyEnabled: acceptsRevisionedProfile
                ? detail?.memberFriendApplyEnabled ?? summary?.memberFriendApplyEnabled ?? remote.memberFriendApplyEnabled ?? existing?.memberFriendApplyEnabled
                : existing?.memberFriendApplyEnabled,
            memberPreview: summary.map { $0.memberPreview.map { groupMemberUser(from: $0) } }
                ?? existing?.memberPreview ?? [],
            presentedRole: detail?.explicitMyRole ?? summary?.explicitMyRole ?? remote.explicitMyRole,
            inviteConfirmRequired: settings?.inviteConfirmRequired ?? remote.inviteConfirmRequired,
            pendingJoinRequestCount: settings?.pendingJoinRequestCount ?? summary?.counts.pendingJoinRequestCount ?? existing?.pendingJoinRequestCount ?? 0,
            fileCount: settings?.fileCount ?? summary?.counts.fileCount ?? existing?.fileCount ?? 0,
            blacklistCount: settings?.blacklistCount ?? existing?.blacklistCount ?? 0,
            historyVisible: settings?.historyVisible ?? existing?.historyVisible ?? true,
            historyVisibleFromSeq: historyVisibleFromSeq,
            historyLimited: historyLimited,
            groupMuted: detail?.groupMuted ?? summary?.groupMuted ?? remote.groupMuted,
            canManageMuteList: canManageMuteList,
            muteListCount: muteListCount
        )
    }

    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
    func group(for conversation: ConversationMessageSnapshot) -> GroupInfo? {
        guard conversation.kind == .group else { return nil }
        return groups.first(where: groupSelector(for: conversation).matches)
    }

    func groupObservationSelectors(conversationID: String) -> [ContactStore.GroupSelector] {
        let exact = ContactStore.GroupSelector(id: conversationID)
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return [exact] }
        guard conversation.kind == .group else { return [] }
        return [exact, groupSelector(for: conversation)]
    }

    private func groupSelector(for conversation: ConversationMessageSnapshot) -> ContactStore.GroupSelector {
        ContactStore.GroupSelector(id: conversation.id, channelID: remoteChannelID(for: conversation), title: conversation.title)
    }
    // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END

    func fallbackUser(for member: RemoteUserGroupMember, existingMembers: [IMUser]) -> IMUser? {
        let identifiers = [member.imUID, member.userID, member.accountID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return nil }
        if identifiers.contains(where: { self.user(currentUser, matchesIdentifier: $0) }) {
            return currentUser
        }
        if let existing = existingMembers.first(where: { existing in
            identifiers.contains { self.user(existing, matchesIdentifier: $0) }
        }) {
            return existing
        }
        return contacts.first { contact in
            identifiers.contains { self.user(contact, matchesIdentifier: $0) }
        }
    }

    func groupMemberUser(from member: RemoteUserGroupMember, fallback: IMUser? = nil) -> IMUser {
        let avatar = member.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = member.imUID.isEmpty ? (fallback?.id ?? member.userID) : member.imUID
        let resolvedUserID = member.userID.isEmpty ? (fallback?.userID ?? resolvedID) : member.userID
        let resolvedUsername = member.accountID.isEmpty ? (fallback?.username ?? "") : member.accountID
        let identifiers = [resolvedID, resolvedUserID, resolvedUsername]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let isCurrentUser = identifiers.contains(where: { isCurrentUserIdentity($0) })
        let localRemark = isCurrentUser ? nil : contactRemarkValue(matching: identifiers)
        let globalNickname = [
            member.rawNickname,
            member.nickname,
            fallback?.name,
            resolvedUsername,
            resolvedUserID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let displayName = GroupMemberDisplayNameResolver.resolve(
            authoritativeDisplayName: member.displayName,
            viewerRemarks: [member.remark, localRemark],
            groupNickname: member.groupNickname,
            globalNickname: globalNickname,
            stableIdentifier: resolvedID,
            isCurrentUser: isCurrentUser
        )
        let resolvedAvatarURL = avatar.isEmpty ? fallback?.avatarURL ?? "" : resolveTenantAssetURL(avatar)
        let memberDepartmentName = member.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentPath = member.departmentPathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasMemberDepartment = !memberDepartmentName.isEmpty || !memberDepartmentPath.isEmpty
        let department = hasMemberDepartment
            ? normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
            : fallback?.department ?? ""
        let departmentPathNames = hasMemberDepartment
            ? normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department)
            : fallback?.departmentPathNames ?? []
        let user = IMUser(
            id: resolvedID,
            userID: resolvedUserID,
            username: resolvedUsername,
            name: displayName,
            title: "",
            department: department,
            departmentPathNames: departmentPathNames,
            phone: member.visiblePhone,
            email: "",
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: fallback?.avatarSeed ?? stableSeed(resolvedID),
            avatarURL: resolvedAvatarURL,
            avatarVersion: member.avatarVersion.isEmpty ? fallback?.avatarVersion ?? "" : member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt.isEmpty ? fallback?.avatarUpdatedAt ?? "" : member.avatarUpdatedAt,
            badges: fallback?.badges ?? []
        )
        return presentationOverlaidUser(user)
    }

    func applyCurrentUser(member: RemoteUserGroupMember) {
        let avatar = member.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentName = member.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentPath = member.departmentPathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasMemberDepartment = !memberDepartmentName.isEmpty || !memberDepartmentPath.isEmpty
        let department = hasMemberDepartment
            ? normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
            : currentUser.department
        let departmentPathNames = hasMemberDepartment
            ? normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department)
            : currentUser.departmentPathNames
        setCurrentUser(IMUser(
            id: member.imUID.isEmpty ? currentUser.id : member.imUID,
            userID: member.userID.isEmpty ? currentUser.userID : member.userID,
            username: currentUser.username,
            name: currentUser.name,
            title: "",
            department: department,
            departmentPathNames: departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(member.imUID.isEmpty ? currentUser.id : member.imUID),
            avatarURL: avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(avatar),
            avatarVersion: member.avatarVersion.isEmpty ? currentUser.avatarVersion : member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : member.avatarUpdatedAt,
            badges: []
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    }

    func groupAnnouncement(
        from remote: RemoteGroupAnnouncement,
        fallbackGroupID: String = "",
        requestPrivacyEpoch: UInt64? = nil
    ) -> GroupAnnouncement {
        let mapped = GroupAnnouncement(
            id: remote.id,
            groupID: remote.groupID.isEmpty ? fallbackGroupID : remote.groupID,
            title: remote.title.isEmpty ? "群公告" : remote.title,
            content: remote.content,
            summary: remote.summary.isEmpty ? remote.content : remote.summary,
            createdBy: remote.createdBy,
            status: remote.status,
            createdAt: displayTime(remote.createdAt),
            updatedAt: remote.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            publishedAt: displayTime(remote.publishedAt ?? remote.createdAt),
            unread: remote.unread,
            readAt: remote.readAt,
            displayPosition: remote.displayPosition,
            readAction: remote.readAction,
            readCount: remote.readCount,
            unreadCount: remote.unreadCount,
            recipientCount: remote.recipientCount,
            canViewReadCounts: remote.canViewReadCounts
        )
        guard let requestPrivacyEpoch else { return mapped }
        return GroupAnnouncementPrivacyProjection.sanitize(
            mapped,
            requestEpoch: requestPrivacyEpoch,
            currentEpoch: groupAnnouncementPrivacyEpoch
        )
    }

    func upsertGroupAnnouncement(_ announcement: GroupAnnouncement, markCurrentRead: Bool) {
        guard !announcement.id.isEmpty else { return }
        var items = groupAnnouncements[announcement.groupID] ?? []
        let accepted = items.first(where: { $0.id == announcement.id })
            .map { preferredGroupAnnouncement(existing: $0, incoming: announcement) }
            ?? announcement
        items.removeAll { $0.id == announcement.id }
        items.insert(accepted, at: 0)
        let ordered = orderedGroupAnnouncements(items)
        groupAnnouncements[announcement.groupID] = ordered
        if let latest = ordered.first {
            updateGroupNotice(groupID: announcement.groupID, notice: latest.content.isEmpty ? latest.summary : latest.content)
        }
        if markCurrentRead || !accepted.unread {
            if currentGroupAnnouncements[accepted.groupID]?.id == accepted.id {
                currentGroupAnnouncements[accepted.groupID] = nil
            }
        } else {
            currentGroupAnnouncements[accepted.groupID] = accepted
        }
    }

    func preferredGroupAnnouncement(existing: GroupAnnouncement, incoming: GroupAnnouncement) -> GroupAnnouncement {
        GroupAnnouncementRevisionProjection.preferred(
            existing: existing,
            incoming: incoming,
            existingRevision: parseRemoteDate(existing.updatedAt),
            incomingRevision: parseRemoteDate(incoming.updatedAt)
        )
    }

    func orderedGroupAnnouncements(_ announcements: [GroupAnnouncement]) -> [GroupAnnouncement] {
        // current means latest unread, not latest published/edited. Keep that
        // banner selection independent from the list and editor's latest item.
        announcements.enumerated().sorted { left, right in
            let leftRevision = parseRemoteDate(left.element.updatedAt) ?? .distantPast
            let rightRevision = parseRemoteDate(right.element.updatedAt) ?? .distantPast
            return leftRevision == rightRevision ? left.offset < right.offset : leftRevision > rightRevision
        }.map(\.element)
    }

    func clearGroupAnnouncementReadCounts(groupID: String? = nil) {
        groupAnnouncementPrivacyEpoch &+= 1
        for key in Array(groupAnnouncements.keys) where groupID == nil || key == groupID {
            groupAnnouncements[key] = groupAnnouncements[key]?.map { $0.scrubbingReadCounts() }
        }
        for key in Array(currentGroupAnnouncements.keys) where groupID == nil || key == groupID {
            currentGroupAnnouncements[key] = currentGroupAnnouncements[key]?.scrubbingReadCounts()
        }
    }

    func groupJoinRequest(from remote: RemoteGroupJoinRequest) -> GroupJoinRequest {
        GroupJoinRequest(
            id: remote.id,
            groupID: remote.groupID,
            applicantUID: remote.applicantUID,
            applicantName: remote.applicantName.isEmpty ? remote.applicantUID : remote.applicantName,
            applicantAvatarURL: resolveTenantAssetURL(remote.applicantAvatar),
            inviterAvatarURL: resolveTenantAssetURL(remote.inviterAvatar),
            inviterName: remote.inviterName,
            status: remote.status,
            message: remote.message.isEmpty ? "申请加入群聊" : remote.message,
            createdAt: displayTime(remote.createdAt)
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
