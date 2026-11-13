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
    private func registerDeviceSilently(context: IMAPIContext, scope: String) async {
        guard context.hasIMSession else { return }
        _ = try? await api.registerDevice(context: context)
        guard isCurrentRemoteScope(scope) else { return }
        registerPendingStandardPushDeviceIfPossible(reason: "device_refresh")
        registerPendingVoIPDeviceIfPossible(reason: "device_refresh")
    }

    func refreshSecondarySnapshotInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        remoteSyncEngine.cancelSecondarySnapshotTasks()
        let commands = remoteSyncEngine.secondarySnapshotCommands(
            groupsDelayNs: mainShellGroupsSnapshotDelayNs,
            contactsDelayNs: mainShellContactsSnapshotDelayNs,
            profileDeviceDelayNs: mainShellSecondarySnapshotDelayNs
        )
        for command in commands {
            switch command.operation {
            case .groups:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshGroupsInBackground(context: context, scope: scope, refreshSession: refreshSession)
                }
            case .contacts:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshContactsAndNoticesInBackground(context: context, scope: scope, refreshSession: refreshSession)
                }
            case .profileDevice:
                enqueueSecondarySnapshotTask(
                    name: command.name,
                    snapshotOperation: command.operation,
                    delayNs: command.delayNs,
                    context: context,
                    scope: scope,
                    refreshSession: refreshSession
                ) { [weak self] in
                    guard let self else { return }
                    await self.refreshFileUploadConfigInBackground(context: context, scope: scope, refreshSession: refreshSession)
                    await self.refreshTenantProfileInBackground(context: context, scope: scope, refreshSession: refreshSession)
                    await self.registerDeviceSilently(context: context, scope: scope)
                }
            }
        }
        print("[JHT Perf] secondary_queue_scheduled count=\(commands.count) generation=\(generation)")
    }

    private func enqueueSecondarySnapshotTask(
        name: String,
        snapshotOperation: SecondarySnapshotOperation,
        delayNs: UInt64,
        context: IMAPIContext,
        scope: String,
        refreshSession: RemoteSnapshotRefreshSession,
        operation: @escaping @MainActor () async -> Void
    ) {
        let generation = refreshSession.generation
        let syncEngine = remoteSyncEngine
        guard syncEngine.claimSecondarySnapshotTask(snapshotOperation) else { return }
        let task = Task { [weak self, syncEngine] in
            defer {
                syncEngine.finishSecondarySnapshotTask(snapshotOperation)
            }
            guard let self else { return }
            do {
                if delayNs > 0 {
                    try await Task.sleep(nanoseconds: delayNs)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isCurrentRemoteRefresh(refreshSession, scope: scope),
                  context.hasIMSession else {
                print("[JHT Perf] secondary_queue_drop name=\(name) reason=stale generation=\(generation)")
                return
            }
            print("[JHT Perf] secondary_queue_running name=\(name) delay_ms=\(Int(Double(delayNs) / 1_000_000)) generation=\(generation)")
            await operation()
            print("[JHT Perf] secondary_queue_finished name=\(name) generation=\(generation)")
        }
        syncEngine.attachSecondarySnapshotTask(snapshotOperation, task: task)
    }

    private func refreshFileUploadConfigInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        _ = try? await fetchScopedFileUploadConfig(context: context, scope: scope)
    }

    func refreshTenantProfileInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        guard let devicePolicyAuthority = beginTenantDevicePolicyRequest(context: context) else { return }
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        let api = self.api
        let profileDiagnostic = SyncFailureDiagnostic.HTTPObservation(.tenantProfile)
        let contextDiagnostic = SyncFailureDiagnostic.HTTPObservation(.tenantContext)
        let meDiagnostic = SyncFailureDiagnostic.HTTPObservation(.meProfile)
        let workspacesDiagnostic = SyncFailureDiagnostic.HTTPObservation(.workspaces)
        let profileTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(profileDiagnostic) {
                defer { profileDiagnostic.finish() }
                return try await profileDiagnostic.perform { try await api.tenantProfile(context: context) }
            }
        }
        let tenantContextTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(contextDiagnostic) {
                defer { contextDiagnostic.finish() }
                return try await contextDiagnostic.perform { try await api.tenantContext(context: context) }
            }
        }
        let meProfileTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(meDiagnostic) {
                defer { meDiagnostic.finish() }
                return try await meDiagnostic.perform { try await api.meProfile(context: context) }
            }
        }
        let workspacesTask = Task {
            try await SyncFailureDiagnostic.$httpObservation.withValue(workspacesDiagnostic) {
                defer { workspacesDiagnostic.finish() }
                return try await workspacesDiagnostic.perform { try await api.listWorkspaces(context: context) }
            }
        }
        defer {
            profileTask.cancel()
            tenantContextTask.cancel()
            meProfileTask.cancel()
            workspacesTask.cancel()
        }

        do {
            let tenantContext = try await tenantContextTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .tenantContext)
            guard applyTenantContext(
                tenantContext,
                devicePolicyAuthority: devicePolicyAuthority,
                profileAuthorityRequest: profileAuthorityRequest
            ) else { return }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled,
                  isCurrentRemoteRefresh(refreshSession, scope: scope),
                  isCurrentTenantDevicePolicyRequest(devicePolicyAuthority) else { return }
            recordSyncFailureDiagnostic(error, endpoint: .tenantContext, httpFailure: contextDiagnostic.failure)
            markGroupMemberCountPolicyUnresolved(scope: scope)
            markTenantDevicePolicyUnavailable(authority: devicePolicyAuthority)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=tenant_context generation=\(generation)")
        }

        do {
            let workspaces = try await workspacesTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .workspaces)
            applyWorkspaces(workspaces)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .workspaces, httpFailure: workspacesDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=workspaces generation=\(generation)")
        }

        do {
            let profile = try await profileTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .tenantProfile)
            applyTenantProfile(profile)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .tenantProfile, httpFailure: profileDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=tenant_profile generation=\(generation)")
        }

        do {
            let meProfile = try await meProfileTask.value
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            clearSyncFailureDiagnostics(for: .meProfile)
            applyMeProfile(meProfile, authorityRequest: profileAuthorityRequest)
        } catch {
            recordSyncFailureDiagnostic(error, endpoint: .meProfile, httpFailure: meDiagnostic.failure)
            print("[JHT Perf] tenant_profile_soft_fail endpoint=me_profile generation=\(generation)")
        }
    }

    @discardableResult
    func refreshCurrentEnterpriseProfile(silent: Bool = true) async -> Bool {
        guard isAuthenticated, apiContext.hasIMSession else { return false }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return false }
        guard let devicePolicyAuthority = beginTenantDevicePolicyRequest(context: context) else { return false }
        let profileAuthorityRequest = beginCurrentProfileRead(context: context)
        var updated = false
        let api = self.api
        let workspacesTask = Task { try await api.listWorkspaces(context: context) }
        let tenantContextTask = Task { try await api.tenantContext(context: context) }
        let profileTask = Task { try await api.tenantProfile(context: context) }
        defer {
            workspacesTask.cancel()
            tenantContextTask.cancel()
            profileTask.cancel()
        }
        if let tenantContext = try? await tenantContextTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            guard applyTenantContext(
                tenantContext,
                devicePolicyAuthority: devicePolicyAuthority,
                profileAuthorityRequest: profileAuthorityRequest
            ) else { return false }
            updated = true
        } else {
            markTenantDevicePolicyUnavailable(authority: devicePolicyAuthority)
        }
        if let workspaces = try? await workspacesTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            applyWorkspaces(workspaces)
            updated = true
        }
        if let profile = try? await profileTask.value {
            guard isCurrentRemoteScope(scope) else { return false }
            applyTenantProfile(profile)
            updated = true
        }
        if !updated && !silent {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("企业资料刷新失败")
        }
        return updated
    }

    private func refreshGroupsInBackground(context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession) async {
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
        let owner = groupDirectoryRequestOwner(context: context, scope: scope, refreshSession: refreshSession)
        do {
            let remoteGroups = try await GroupDirectoryRequestOwner.$current.withValue(owner) {
                try await api.listGroups(context: context, scope: "all")
            }
            guard !Task.isCancelled, owner.isCurrent() else { return }
            await applyRemoteGroupsCooperatively(remoteGroups) { owner.isCurrent() }
            guard !Task.isCancelled, owner.isCurrent() else { return }
            refreshInitialGroupBundles(remoteGroups, scope: scope, refreshSession: refreshSession)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, owner.isCurrent() else { return }
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
            }
        }
    }

    private func refreshInitialGroupBundles(_ remoteGroups: [RemoteUserGroup], scope: String, refreshSession: RemoteSnapshotRefreshSession) {
        let generation = refreshSession.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.mainShellGroupBundleDelayNs)
            } catch {
                return
            }
            let preloadGroups = Array(remoteGroups.prefix(2))
            guard !preloadGroups.isEmpty else { return }
            print("[JHT Perf] initial_group_bundle_preload_start count=\(preloadGroups.count) secondary=false generation=\(generation)")
            for group in preloadGroups {
                guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                await self.refreshGroupBundle(groupID: group.groupID, silent: true, includeSecondaryData: false)
            }
        }
    }

}
