import IM4Features
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
    @discardableResult
    func applyMeProfile(
        _ profile: RemoteMeProfile,
        authorityRequest: CurrentProfileAuthorityRequest? = nil,
        usernameFallback: String? = nil,
        nicknameFallback: String? = nil
    ) -> Bool {
        if let authorityRequest {
            let snapshot = currentProfileAuthoritySnapshot(from: profile, request: authorityRequest)
            guard acceptsCurrentProfileAuthority(snapshot, request: authorityRequest) else {
                return false
            }
        }
        let resolvedIMUID = profile.imUID.isEmpty ? currentUser.id : profile.imUID
        let resolvedUserID = profile.userID.isEmpty ? (profile.imUID.isEmpty ? currentUser.userID : profile.imUID) : profile.userID
        let resolvedUsername = resolvedCurrentUserUsername(
            remoteUsername: profile.username,
            fallbackUsername: usernameFallback,
            currentUsername: currentUser.username
        )
        let profilePhone = profile.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextPhone = profile.phoneBindingKnown
            ? (profile.phoneVerified ? profilePhone : "")
            : (profilePhone.isEmpty ? currentUser.phone : profilePhone)
        let nextPhoneVerified = profile.phoneBindingKnown
            ? profile.phoneVerified
            : (currentUser.phoneVerified || !nextPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let displayName = preferredDisplayName(
            candidates: [currentProfileAuthorityDisplayNameCandidate(), profile.nickname, nicknameFallback, currentUser.name, resolvedUsername, profile.userID, profile.imUID],
            identifiers: [resolvedIMUID, resolvedUserID, currentUser.id, currentUser.userID],
            fallback: currentUser.name.isEmpty ? resolvedIMUID : currentUser.name
        )
        let nextUser = IMUser(
            id: resolvedIMUID,
            userID: resolvedUserID,
            username: resolvedUsername,
            name: displayName,
            title: "",
            department: normalizedDepartmentName(profile.departmentName, pathNames: profile.departmentPathNames),
            departmentPathNames: normalizedDepartmentPathNames(profile.departmentPathNames, fallbackName: profile.departmentName),
            phone: nextPhone,
            phoneVerified: nextPhoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: presenceStatusText(
                rawStatus: profile.presenceStatus,
                online: profile.onlineKnown ? profile.online : nil
            ),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(profile.imUID.isEmpty ? currentUser.id : profile.imUID),
            avatarURL: profile.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(profile.avatar),
            avatarVersion: profile.avatarVersion.isEmpty ? currentUser.avatarVersion : profile.avatarVersion,
            avatarUpdatedAt: profile.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : profile.avatarUpdatedAt,
            badges: currentUser.badges
        )
        replaceCurrentUserAndProject(nextUser)
        reconcileForcedAppPolicyAuthState(for: nextUser)
        return true
    }

    func applyFriendRelations(
        _ relations: [RemoteFriendRelation],
        readStamp: ProfileContactReadStamp?
    ) {
        let applyStart = CFAbsoluteTimeGetCurrent()
        DebugConsoleDiagnostics.trace("[JHT Perf] contacts_apply_start input=\(relations.count) existing=\(contacts.count) blacklist=\(blacklist.count)")
        let existing = contacts.reduce(into: [String: IMUser]()) { result, user in
            let key = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = user
        }
        let existingByUserID = contacts.reduce(into: [String: IMUser]()) { result, user in
            let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userID.isEmpty, result[userID] == nil {
                result[userID] = user
            }
        }
        let blockedIDs = Set(
            blacklist
                .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var nextRemarks: [String: String] = [:]
        let scope = remoteDataScopeKey(for: apiContext)
        let presencePolicy = resolvedTenantClientPolicy
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
        let currentOriginalNames = contactStore.contactCardOriginalNames(in: scope)
        var nextContactCardOriginalNames: [String: String] = [:]
        var nextCanonicalFriendUIDsByIdentity: [ContactStore.FriendIdentityKey: Set<String>] = [:]
        func recordCanonicalFriendUID(_ canonicalFriendUID: String, for key: ContactStore.FriendIdentityKey) {
            let normalizedUID = canonicalFriendUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedUID.isEmpty else { return }
            var values = nextCanonicalFriendUIDsByIdentity[key] ?? []
            values.insert(normalizedUID)
            nextCanonicalFriendUIDsByIdentity[key] = values
        }
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
        var seenFriendUIDs: Set<String> = []
        var droppedDuplicateCount = 0
        var nextContacts: [IMUser] = relations.compactMap { relation in
            let friendUID = relation.friendUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !friendUID.isEmpty, !blockedIDs.contains(friendUID) else { return nil }
            guard seenFriendUIDs.insert(friendUID).inserted else {
                droppedDuplicateCount += 1
                return nil
            }
            let rawNickname = relation.rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = preferredDisplayName(
                candidates: [relation.remark, relation.displayName, rawNickname, relation.friendNickname, relation.friendUserID],
                identifiers: [friendUID, relation.friendUserID],
                fallback: relation.friendUID
            )
            if let remark = relation.remark?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                nextRemarks[friendUID] = remark
            }
            if let canonicalFriendUID = relation.authoritativeFriendUID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonicalFriendUID.isEmpty,
               canonicalFriendUID == friendUID {
                recordCanonicalFriendUID(canonicalFriendUID, for: .imUID(canonicalFriendUID))
                let friendUserID = relation.authoritativeFriendUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !friendUserID.isEmpty {
                    recordCanonicalFriendUID(canonicalFriendUID, for: .userID(friendUserID))
                }
            }
            let remoteDisplayNameSource = relation.displayNameSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let remoteDisplayName = remoteDisplayNameSource.contains("remark")
                ? nil
                : relation.displayName
            let originalName = preferredDisplayName(
                candidates: [rawNickname, relation.friendNickname, remoteDisplayName, relation.friendUserID],
                identifiers: [friendUID, relation.friendUserID],
                fallback: relation.friendUID
            )
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
            ContactStore.cacheContactCardOriginalName(
                originalName, identifiers: [friendUID, relation.friendUserID], in: &nextContactCardOriginalNames
            )
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
            let existingUser = existing[friendUID] ?? existingByUserID[relation.friendUserID]
            let avatar = relation.friendAvatar.isEmpty ? existingUser?.avatarURL ?? "" : resolveTenantAssetURL(relation.friendAvatar)
            let relationDepartmentName = relation.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let relationDepartmentPath = relation.departmentPathNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hasRelationDepartment = !relationDepartmentName.isEmpty || !relationDepartmentPath.isEmpty
            let department = hasRelationDepartment
                ? normalizedDepartmentName(relation.departmentName, pathNames: relation.departmentPathNames)
                : existingUser?.department ?? ""
            let departmentPathNames = hasRelationDepartment
                ? normalizedDepartmentPathNames(relation.departmentPathNames, fallbackName: department)
                : existingUser?.departmentPathNames ?? []
            return IMUser(
                id: friendUID,
                userID: relation.friendUserID.isEmpty ? friendUID : relation.friendUserID,
                name: displayName,
                title: "",
                department: department,
                departmentPathNames: departmentPathNames,
                phone: relation.visiblePhone,
                email: "",
                status: Self.presenceStatusText(
                    rawStatus: relation.friendStatus,
                    online: relation.friendOnlineKnown ? relation.friendOnline : nil,
                    policy: presencePolicy
                ),
                lastLoginAt: Self.lastLoginPresentationText(rawValue: relation.friendLastSeenAt ?? "", policy: presencePolicy) ?? "",
                enterprise: currentEnterprise.name,
                avatarSeed: existingUser?.avatarSeed ?? stableSeed(friendUID),
                avatarURL: avatar,
                avatarVersion: relation.friendAvatarVersion.isEmpty ? existingUser?.avatarVersion ?? "" : relation.friendAvatarVersion,
                avatarUpdatedAt: relation.friendAvatarUpdatedAt.isEmpty ? existingUser?.avatarUpdatedAt ?? "" : relation.friendAvatarUpdatedAt,
                badges: existingUser?.badges ?? []
            )
        }
        let currentContacts = contacts
        for current in currentContacts {
            let identifiers = userIdentityCandidates(for: current)
            let wasMutated = identifiers.contains { identifier in
                profileContactRevisionFence.wasMutated(
                    profileContactKey("contact", identifier: identifier),
                    after: readStamp
                ) || profileContactRevisionFence.wasMutated(
                    profileContactKey("remark", identifier: identifier),
                    after: readStamp
                )
            }
            guard wasMutated else { continue }
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
            for identifier in identifiers {
                let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                nextContactCardOriginalNames[key] = currentOriginalNames[key]
            }
            // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
            let isBlocked = blockedIDs.contains { blockedID in
                identifiers.contains(blockedID)
            }
            if isBlocked {
                nextContacts.removeAll { candidate in
                    identifiers.contains { user(candidate, matchesIdentifier: $0) }
                }
            } else if let index = nextContacts.firstIndex(where: { candidate in
                identifiers.contains { user(candidate, matchesIdentifier: $0) }
            }) {
                nextContacts[index] = current
            } else {
                nextContacts.append(current)
            }
        }
        nextContacts.removeAll { candidate in
            let identifiers = userIdentityCandidates(for: candidate)
            let wasMutated = identifiers.contains { identifier in
                profileContactRevisionFence.wasMutated(
                    profileContactKey("contact", identifier: identifier),
                    after: readStamp
                ) || profileContactRevisionFence.wasMutated(
                    profileContactKey("remark", identifier: identifier),
                    after: readStamp
                )
            }
            guard wasMutated else { return false }
            return !currentContacts.contains { current in
                identifiers.contains { user(current, matchesIdentifier: $0) }
            }
        }
        let remarkKeys = Set(nextRemarks.keys).union(contactRemarks.keys)
        for key in remarkKeys where profileContactRevisionFence.wasMutated(
            profileContactKey("remark", identifier: key),
            after: readStamp
        ) {
            if let current = contactRemarks[key] {
                nextRemarks[key] = current
            } else {
                nextRemarks.removeValue(forKey: key)
            }
        }
        if droppedDuplicateCount > 0 {
            DebugConsoleDiagnostics.trace("[JHT Perf] contacts_sync_dedupe dropped=\(droppedDuplicateCount) input=\(relations.count)")
        }
        let mapMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        DebugConsoleDiagnostics.trace("[JHT Perf] contacts_apply_rows_ready count=\(nextContacts.count) map_ms=\(mapMs)")
        contacts = nextContacts
        contactRemarks = nextRemarks
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
        contactStore.replaceFriendIdentityProjection(
            originalNames: nextContactCardOriginalNames, canonicalUIDs: nextCanonicalFriendUIDsByIdentity, in: scope
        )
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
        contactStore.markFriendRelationsLoaded()
        DebugConsoleDiagnostics.trace("[JHT Perf] contacts_apply_store_updated count=\(contacts.count)")
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        DebugConsoleDiagnostics.trace("[JHT Perf] contacts_apply_done count=\(contacts.count) total_ms=\(totalMs)")
        scheduleContactsPostApplyReconciliation(reason: "contacts_sync")
        commitAuthoritativeProfileContactProjection(scope: scope, reason: "friends_read")
    }

    private func scheduleContactsPostApplyReconciliation(reason: String) {
        let scope = remoteDataScopeKey(for: apiContext)
        contactsPostApplyReconciliationGeneration &+= 1
        let generation = contactsPostApplyReconciliationGeneration
        contactsPostApplyReconciliationTask?.cancel()
        contactsPostApplyReconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self else { return }
            do { try await self.waitForDirectoryOrConversationScrollToEnd(scope: scope) }
            catch { return }
            guard !Task.isCancelled,
                  self.contactsPostApplyReconciliationGeneration == generation,
                  self.isCurrentRemoteScope(scope),
                  self.contactStore.friendRelationsLoaded() else {
                return
            }
            let start = CFAbsoluteTimeGetCurrent()
            // JHT_MOD_BEGIN CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改开始：联系人后处理分段让出主线程，避免三段重计算连续压帧
            var phaseStart = CFAbsoluteTimeGetCurrent()
            self.refreshDirectConversationDisplayNames()
            self.logContactsPostApplyReconciliationPhase("refresh_direct_conversation_display_names", startedAt: phaseStart, reason: reason)
            guard await self.pauseContactsPostApplyReconciliationSlice(generation: generation, scope: scope) else { return }
            phaseStart = CFAbsoluteTimeGetCurrent()
            self.pruneNonFriendDirectConversations()
            self.logContactsPostApplyReconciliationPhase("prune_non_friend_direct_conversations", startedAt: phaseStart, reason: reason)
            guard await self.pauseContactsPostApplyReconciliationSlice(generation: generation, scope: scope) else { return }
            phaseStart = CFAbsoluteTimeGetCurrent()
            self.reapplyAllAvatarRealtimeProjections()
            self.logContactsPostApplyReconciliationPhase("reapply_avatar_realtime_projections", startedAt: phaseStart, reason: reason)
            // JHT_MOD_END CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改结束
            let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            DebugConsoleDiagnostics.trace("[JHT Perf] contacts_post_apply_reconcile_done reason=\(reason) contacts=\(self.contacts.count) conversations=\(self.conversationStore.conversations.count) total_ms=\(totalMs)")
            if self.contactsPostApplyReconciliationGeneration == generation {
                self.contactsPostApplyReconciliationTask = nil
            }
        }
    }

    // JHT_MOD_BEGIN CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改开始：联系人后处理异步分片工具
    private func pauseContactsPostApplyReconciliationSlice(generation: UInt64, scope: String) async -> Bool {
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 16_000_000)
            try await waitForDirectoryOrConversationScrollToEnd(scope: scope)
        } catch {
            return false
        }
        return !Task.isCancelled
            && contactsPostApplyReconciliationGeneration == generation
            && isCurrentRemoteScope(scope)
            && contactStore.friendRelationsLoaded()
    }

    private func logContactsPostApplyReconciliationPhase(_ phase: String, startedAt: CFAbsoluteTime, reason: String) {
        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        DebugConsoleDiagnostics.trace("[JHT Perf] contacts_post_apply_reconcile_phase phase=\(phase) reason=\(reason) elapsed_ms=\(elapsedMs)")
        #endif
    }
    // JHT_MOD_END CONTACTS_POST_APPLY_RECONCILE_ASYNC_SLICE_PERF_20260912 - 修改结束

    func refreshDirectConversationDisplayNames() {
        let lookup = makeConversationUserLookup()
        conversationStore.refreshDirectConversationProfiles(
            channelIDForConversation: { [self] conversation in
                remoteChannelID(for: conversation, lookup: lookup)
            },
            titleForChannel: { [self] channelID in
                titleForRemoteConversation(channelID: channelID, kind: .direct, lookup: lookup)
            },
            participantsForChannel: { [self] channelID in
                participantsForRemoteConversation(channelID: channelID, kind: .direct, lookup: lookup)
            }
        )
    }

    func applyBlacklist(
        _ relations: [RemoteBlacklistRelation],
        readStamp: ProfileContactReadStamp?
    ) {
        let contactByID = contacts.reduce(into: [String: IMUser]()) { result, user in
            let key = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = user
        }
        let existingByID = blacklist.reduce(into: [String: BlacklistItem]()) { result, item in
            let key = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = item
        }
        var seenBlockedUIDs: Set<String> = []
        var droppedDuplicateCount = 0
        var nextBlacklist: [BlacklistItem] = relations.compactMap { relation -> BlacklistItem? in
            let blockedUID = relation.blockedUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !blockedUID.isEmpty else { return nil }
            guard seenBlockedUIDs.insert(blockedUID).inserted else {
                droppedDuplicateCount += 1
                return nil
            }
            let fallbackName = blockedUID.isEmpty ? "未知用户" : blockedUID
            let name = preferredDisplayName(
                candidates: [
                    contactByID[blockedUID]?.name,
                    existingByID[blockedUID]?.name,
                    directConversationSnapshotDisplayName(forBlockedUID: blockedUID)
                ],
                identifiers: [blockedUID],
                fallback: fallbackName
            )
            return BlacklistItem(
                id: blockedUID,
                name: name,
                reason: relation.reason.isEmpty ? "已拉黑" : relation.reason
            )
        }
        let identifiers = Set(nextBlacklist.map { $0.id }).union(blacklist.map { $0.id })
        for identifier in identifiers where profileContactRevisionFence.wasMutated(
            profileContactKey("blacklist", identifier: identifier),
            after: readStamp
        ) {
            nextBlacklist.removeAll { $0.id == identifier }
            if let current = blacklist.first(where: { $0.id == identifier }) {
                nextBlacklist.append(current)
            }
        }
        blacklist = nextBlacklist
        if droppedDuplicateCount > 0 {
            DebugConsoleDiagnostics.trace("[JHT Perf] blacklist_sync_dedupe dropped=\(droppedDuplicateCount) input=\(relations.count)")
        }
        let scope = remoteDataScopeKey(for: apiContext)
        commitAuthoritativeProfileContactProjection(scope: scope, reason: "blacklist_read")
    }

    func userSearchResult(_ remote: RemoteUserSearchItem) -> UserSearchResult {
        let friendAction = remote.friendAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canApplyFriend = remote.canApplyFriend && friendAction != "none"
        return UserSearchResult(
            imUID: remote.imUID,
            userID: remote.userID,
            nickname: preferredDisplayName(
                candidates: [remote.remark, remote.displayName, remote.rawNickname, remote.nickname, remote.userID, remote.imUID],
                identifiers: [remote.imUID, remote.userID],
                fallback: remote.userID.isEmpty ? remote.imUID : remote.userID
            ),
            phone: remote.visiblePhone,
            avatarURL: resolveTenantAssetURL(remote.avatar),
            status: remote.status,
            presenceStatus: presenceStatusText(
                rawStatus: remote.presenceStatus,
                online: remote.onlineKnown ? remote.online : nil
            ),
            relationStatus: remote.relationStatus,
            canApplyFriend: canApplyFriend,
            reason: remote.reason,
            friendAction: remote.friendAction,
            friendFlow: remote.friendFlow,
            requiresTenantReview: remote.requiresTenantReview,
            requiresTargetApproval: remote.requiresTargetApproval
        )
    }

    func userSearchBlockedMessage(_ result: UserSearchResult) -> String {
        if result.isCancelledUser {
            return "该用户已注销，无法添加好友"
        }
        let reason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch result.relationStatus {
        case "friend":
            return "你们已经是好友"
        case "pending_out":
            return FriendAddPresentation.sentMessage
        case "pending_in":
            return "对方已申请添加你，请到新朋友处理"
        case "blocked":
            return "当前用户不可添加"
        case "self":
            return "不能添加自己为好友"
        default:
            if reason == "user_disabled"
                || reason == "target_user_disabled"
                || reason == "account_disabled" {
                return "该用户已停用，无法添加"
            }
            if reason.contains("blacklist") || reason.contains("blocked") {
                return "当前用户不可添加"
            }
            if reason.contains("cross_tenant") || reason.contains("target_type") || reason.contains("not_allowed") {
                return "当前账号暂不支持添加好友"
            }
            return "当前关系状态不可申请好友"
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
