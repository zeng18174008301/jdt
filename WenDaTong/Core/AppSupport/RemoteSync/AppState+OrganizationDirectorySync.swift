import Combine
import IM4Stores
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
    // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
    func groupDirectoryRequestOwner(
        context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession? = nil
    ) -> GroupDirectoryRequestOwner {
        let generation = groupDirectoryRefreshGeneration.issueToken()
        let authority = context.authSessionFence
        return GroupDirectoryRequestOwner(ownsRefresh: { [weak self] in
            guard let self, self.groupDirectoryRefreshGeneration.isCurrent(generation) else { return false }
            if let refreshSession { return self.isCurrentRemoteRefresh(refreshSession, scope: scope) }
            return self.isCurrentRemoteScope(scope)
        }, ownsAuthority: { [weak self] in
            self?.isAuthenticated == true && self?.apiContext.isSameAuthAuthority(as: authority) == true
        })
    }
    // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END

    @discardableResult
    func refreshGroupDirectory(silent: Bool = true) async -> Bool {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated, context.hasIMSession, isCurrentRemoteScope(scope) else { return false }
        // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
        let owner = groupDirectoryRequestOwner(context: context, scope: scope)
        do {
            let remoteGroups = try await GroupDirectoryRequestOwner.$current.withValue(owner) {
                try await api.listGroups(context: context, scope: "all")
            }
            guard !Task.isCancelled, owner.isCurrent() else { return false }
            await applyRemoteGroupsCooperatively(remoteGroups) { owner.isCurrent() }
            return !Task.isCancelled && owner.isCurrent()
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, owner.isCurrent() else { return false }
            // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END
            logSyncEndpointFailure("/api/tenant/groups?scope=all", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "群聊数据同步失败",
                    silent: true
                )
            } else if !silent {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群列表刷新失败")
            }
            return false
        }
    }

    func refreshContactsAndNoticesInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        profileContactRevisionFence.rebind(scopeHash: scope)
        guard contactStore.beginContactsSync() else {
            print("[JHT Perf] contacts_sync_skip reason=in_flight generation=\(generation)")
            return
        }
        defer { contactStore.finishContactsSync() }
        do {
            let requests = try await api.listFriendApplications(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyFriendApplications(requests)
        } catch {
            logSyncEndpointFailure("/api/tenant/friend-applications", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "好友申请同步失败",
                    silent: true
                )
            }
        }
        do {
            let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
            let blocked = try await api.listBlacklist(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyBlacklist(blocked, readStamp: readStamp)
        } catch {
            logSyncEndpointFailure("/api/tenant/blacklist", error: error)
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "黑名单同步失败",
                    silent: true
                )
            }
        }
        do {
            let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
            let relations = try await api.listFriends(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyFriendRelations(relations, readStamp: readStamp)
            contactStore.setContactsSyncError(nil)
            print("[JHT Perf] contacts_sync_success count=\(relations.count) generation=\(generation)")
        } catch {
            logSyncEndpointFailure("/api/tenant/friends", error: error)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            contactStore.setContactsSyncError(contacts.isEmpty
                ? "通讯录同步失败，请稍后重试"
                : "通讯录同步失败，当前显示上次缓存")
            print("[JHT Perf] contacts_sync_fallback cached_count=\(contacts.count) generation=\(generation)")
            if isUnauthorizedError(error) {
                _ = await recoverDataPlaneUnauthorizedIfPossible(
                    error,
                    context: context,
                    scope: scope,
                    fallback: "通讯录同步失败",
                    silent: true
                )
            }
        }
        await refreshOrganizationDirectory(context: context, scope: scope, refreshSession: refreshSession)
        do {
            let devices = try await api.listDevices(context: context)
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyDevices(devices)
        } catch {
            logSyncEndpointFailure("/api/tenant/devices", error: error)
        }
        do {
            let inbox = try await api.listInbox(context: context)
            let announcements = (try? await api.listAnnouncementInbox(context: context)) ?? []
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            applyInbox(Self.mergedInboxEntries(inbox, announcements))
        } catch {
            logSyncEndpointFailure("/api/tenant/inbox", error: error)
        }
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_BEGIN
    func createOrganizationDepartment(parentDepartmentID: String, name: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号无部门管理权限")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入部门名称")
            return false
        }
        return await performOrganizationManagementMutation(
            context: context, success: "部门已创建", failure: "部门创建失败"
        ) {
            _ = try await api.createOrganizationDepartment(context: context, parentDepartmentID: parentDepartmentID, name: trimmedName)
        }
    }

    func updateOrganizationDepartment(departmentID: String, parentDepartmentID: String?, name: String?) async -> Bool {
        guard canManageOrganizationDepartments else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号无部门管理权限")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let normalizedID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedID != "company" else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公司为默认根节点，不能编辑")
            return false
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName?.isEmpty == true {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入部门名称")
            return false
        }
        return await performOrganizationManagementMutation(
            context: context, success: "部门已更新", failure: "部门更新失败"
        ) {
            _ = try await api.updateOrganizationDepartment(context: context, departmentID: normalizedID, parentDepartmentID: parentDepartmentID, name: trimmedName)
        }
    }

    func deleteOrganizationDepartment(departmentID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号无部门管理权限")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let normalizedID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedID != "company" else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公司为默认根节点，不能删除")
            return false
        }
        return await performOrganizationManagementMutation(
            context: context, success: "部门已删除，成员和子部门已迁移", failure: "部门删除失败"
        ) {
            try await api.deleteOrganizationDepartment(context: context, departmentID: normalizedID)
        }
    }

    func addOrganizationMember(departmentID: String, userID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号无部门管理权限")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let normalizedDepartmentID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedDepartmentID != "company" else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先选择具体部门")
            return false
        }
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择成员")
            return false
        }
        return await performOrganizationManagementMutation(
            context: context, success: "成员部门已变更", failure: "成员加入失败"
        ) {
            try await api.addOrganizationMember(context: context, departmentID: normalizedDepartmentID, userID: normalizedUserID, isPrimary: true)
        }
    }

    func removeOrganizationMember(departmentID: String, userID: String) async -> Bool {
        guard canManageOrganizationDepartments else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前账号无部门管理权限")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let normalizedDepartmentID = normalizedOrganizationDepartmentID(departmentID)
        guard normalizedDepartmentID != "company" else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公司成员没有可移除的部门归属")
            return false
        }
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择成员")
            return false
        }
        return await performOrganizationManagementMutation(
            context: context, success: "成员已移出部门", failure: "成员移除失败"
        ) {
            try await api.removeOrganizationMember(context: context, departmentID: normalizedDepartmentID, userID: normalizedUserID)
        }
    }

    private func performOrganizationManagementMutation(
        context: IMAPIContext,
        success: String,
        failure: String,
        mutation: () async throws -> Void
    ) async -> Bool {
        let scope = remoteDataScopeKey(for: context)
        let store = organizationDirectoryStore
        guard isCurrentRemoteScope(scope), let request = store.beginManagementMutation() else { return false }
        defer { store.finishManagementMutation(request) }
        func isCurrentRequest() -> Bool {
            isCurrentRemoteScope(scope) && store.ownsManagementMutation(request)
        }
        do {
            try await mutation()
            guard isCurrentRequest() else { return false }
            await refreshOrganizationDirectoryForCurrentSnapshot()
            guard isCurrentRequest() else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(success)
            return true
        } catch {
            guard isCurrentRequest() else { return false }
            handleRemoteError(error, fallback: failure)
            return false
        }
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    private func refreshOrganizationDirectory(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        let store = organizationDirectoryStore
        let previous = store.snapshot
        guard currentAppPolicy?.departmentEnabled == true || previous.tenantDepartmentEnabled || previous.tree?.departmentEnabled == true else {
            clearOrganizationDirectory()
            return
        }
        let request = store.beginRefresh()
        defer { store.finishRefresh(request) }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let authority = context.authSessionFence
        let treeOwner = ScopedListRequestOwner(ownsRequest: { [weak self] in
            guard let self else { return false }
            return authority.epoch == self.apiContext.sessionEpoch && store.ownsRefresh(request)
                && self.isCurrentRemoteRefresh(refreshSession, scope: scope)
        }, ownsAuthority: { [weak self] in
            self?.apiContext.isSameAuthAuthority(as: authority) == true
        })
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        do {
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
            let tree = try await ScopedListRequestOwner.$current.withValue(treeOwner) {
                try await api.organizationTree(context: context)
            }
            guard !Task.isCancelled, treeOwner.ownsRequest() else { return }
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
            store.applyTree(tree)
            guard tree.departmentEnabled else { return }

            // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
            let membersOwner = OrganizationMembersRequestOwner(ownsRequest: { [weak self] in
                guard let self, self.isAuthenticated else { return false }
                return store.ownsRefresh(request) && self.isCurrentRemoteRefresh(refreshSession, scope: scope)
            }, ownsAuthority: { [weak self] in
                self?.isAuthenticated == true && self?.apiContext.isSameAuthAuthority(as: authority) == true // WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111
            })
            // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END
            let departmentIDs = organizationDepartmentIDs(from: tree)
            var membersByDepartment: [String: [IMUser]] = [:]
            var memberIndex: [String: IMUser] = [:]
            for departmentID in departmentIDs {
                let normalizedID = normalizedOrganizationDepartmentID(departmentID)
                // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
                let list: RemoteOrganizationMemberList
                do {
                    list = try await OrganizationMembersRequestOwner.$current.withValue(membersOwner) {
                        try await api.organizationMembers(context: context, departmentID: normalizedID)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, membersOwner.ownsRequest() else { return }
                    if isUnauthorizedError(error) || DeviceRevocationDetector.matches(error: error) {
                        guard membersOwner.ownsAuthority() else { return }
                    }
                    throw error
                }
                guard !Task.isCancelled, membersOwner.ownsRequest() else { return }
                // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END
                if !list.departmentEnabled {
                    store.applyTree(.disabledFallback(root: tree.root))
                    return
                }
                let users = list.items.map(organizationMemberUser)
                membersByDepartment[normalizedID] = users
                for user in users {
                    for key in organizationIndexKeys(for: user) {
                        memberIndex[key] = user
                    }
                }
            }
            store.setMembers(membersByDepartment, index: memberIndex)
            reapplyAllAvatarRealtimeProjections()
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, treeOwner.ownsRequest() else { return }
            if isUnauthorizedError(error) || DeviceRevocationDetector.matches(error: error) {
                guard treeOwner.ownsAuthority() else { return }
            }
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
            store.setRefreshError(store.snapshot.membersByDepartment.isEmpty
                ? "组织架构同步失败，请稍后重试"
                : "组织架构同步失败，当前显示上次缓存")
            logSyncEndpointFailure("/api/tenant/org/tree", error: error)
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "组织架构同步失败", silent: true)
            }
        }
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

    func refreshOrganizationDirectoryForCurrentSnapshot() async {
        guard isAuthenticated, apiContext.hasIMSession else {
            clearOrganizationDirectory(disabled: true)
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        guard isDepartmentFeatureEnabled else {
            clearOrganizationDirectory(disabled: true)
            return
        }
        if let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
           isCurrentRemoteRefresh(refreshSession, scope: scope) {
            await refreshOrganizationDirectory(context: context, scope: scope, refreshSession: refreshSession)
            return
        }
        _ = await refreshRemoteSnapshot(silent: true, force: true)
    }

    private func organizationDepartmentIDs(from tree: RemoteOrganizationTree) -> [String] {
        var ids = ["company"]
        func append(_ node: RemoteDepartmentNode) {
            let id = normalizedOrganizationDepartmentID(node.departmentID)
            if !id.isEmpty && !ids.contains(id) {
                ids.append(id)
            }
            node.children.forEach(append)
        }
        if let root = tree.root {
            root.children.forEach(append)
        } else {
            tree.items.forEach(append)
        }
        return ids
    }

    private func organizationMemberUser(_ member: RemoteOrganizationMemberView) -> IMUser {
        let resolvedID = member.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUserID = member.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryID = resolvedID.isEmpty ? resolvedUserID : resolvedID
        let displayName = member.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
        let user = IMUser(
            id: primaryID.isEmpty ? member.id : primaryID,
            userID: resolvedUserID.isEmpty ? primaryID : resolvedUserID,
            name: displayName.isEmpty ? (primaryID.isEmpty ? "未命名成员" : primaryID) : displayName,
            title: member.positionName,
            department: department,
            departmentPathNames: normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department),
            phone: "",
            email: "",
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(primaryID),
            avatarURL: member.avatar.isEmpty ? "" : resolveTenantAssetURL(member.avatar),
            avatarVersion: member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt,
            badges: member.role.isEmpty ? [] : [member.role]
        )
        return presentationOverlaidUser(user)
    }

    func normalizedOrganizationDepartmentID(_ departmentID: String) -> String {
        let trimmed = departmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "__company__" || trimmed == "__root__" {
            return "company"
        }
        return trimmed
    }

    func normalizedDepartmentPathNames(_ pathNames: [String], fallbackName: String) -> [String] {
        let cleaned = pathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            return cleaned
        }
        let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? ["公司"] : [fallback]
    }

    func normalizedDepartmentName(_ departmentName: String, pathNames: [String]) -> String {
        let trimmed = departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return normalizedDepartmentPathNames(pathNames, fallbackName: "").last ?? ""
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    func departmentSummary(
        for user: IMUser,
        fullPath: Bool,
        directory: OrganizationDirectoryStore.Snapshot
    ) -> String? {
        guard directory.departmentEnabled(appPolicyEnabled: currentAppPolicy?.departmentEnabled == true) else { return nil }
        let indexed = organizationIndexKeys(for: user).compactMap { directory.memberIndex[$0] }.first
        let ownDepartment = user.department.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexedDepartment = indexed?.department.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let department = ownDepartment.isEmpty ? indexedDepartment : ownDepartment
        if fullPath {
            let sourcePath = user.departmentPathNames.isEmpty ? indexed?.departmentPathNames ?? [] : user.departmentPathNames
            return normalizedDepartmentPathNames(sourcePath, fallbackName: department).joined(separator: " / ")
        }
        return department.isEmpty ? "公司" : department
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

    private func organizationIndexKeys(for user: IMUser) -> [String] {
        var seen = Set<String>()
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    func clearOrganizationDirectory(disabled: Bool = false) {
        organizationDirectoryStore.clear(disabled: disabled) // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
    }

}

// WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111
typealias OrganizationDirectoryStore = IM4Stores.OrganizationDirectoryStore
