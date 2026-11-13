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

// WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_BEGIN
@MainActor
final class TenantDevicePolicyPresentationStore {
    @Published var multiplicity: TenantDeviceMultiplicityPolicyState = .unavailable

    var textUpdates: AnyPublisher<String, Never> {
        $multiplicity.map(\.presentationText).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Content: View>(@ViewBuilder content: @escaping (String) -> Content) -> some View {
        PublisherSnapshotView(initialValue: multiplicity.presentationText, updates: textUpdates, content: content)
    }
}
// WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_END

extension AppState {
    private func currentProfileAuthorityScope(for context: IMAPIContext) -> CurrentProfileAuthorityScope? {
        CurrentProfileAuthorityScope(
            tenantID: context.tenantID ?? "",
            actorIMUID: context.imUID ?? "",
            appID: IMAPIContext.normalizedIOSAppID(context.appID)
        )
    }

    func beginCurrentProfileRead(context: IMAPIContext) -> CurrentProfileAuthorityRequest? {
        guard let scope = currentProfileAuthorityScope(for: context),
              scope == currentProfileAuthorityScope(for: apiContext) else {
            return nil
        }
        return currentProfileAuthorityFence.beginRead(scope: scope)
    }

    func beginCurrentProfileMutation(context: IMAPIContext) -> CurrentProfileAuthorityRequest? {
        guard let scope = currentProfileAuthorityScope(for: context),
              scope == currentProfileAuthorityScope(for: apiContext) else {
            return nil
        }
        return currentProfileAuthorityFence.beginMutation(scope: scope)
    }

    func currentProfileAuthorityCheckpoint() -> CurrentProfileAuthorityCheckpoint? {
        guard let scope = currentProfileAuthorityScope(for: apiContext),
              currentProfileAuthorityFence.checkpoint?.scope == scope else {
            return nil
        }
        return currentProfileAuthorityFence.checkpoint
    }

    func currentProfileAuthorityDisplayNameCandidate() -> String? {
        currentProfileAuthorityCheckpoint()?.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hydrateCurrentProfileAuthority(from checkpoint: CurrentProfileAuthorityCheckpoint?) {
        currentProfileAuthorityFence.hydrate(
            checkpoint,
            for: currentProfileAuthorityScope(for: apiContext)
        )
    }

    func reconcileCurrentProfileAuthorityScope(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard currentProfileAuthorityScope(for: oldContext) != currentProfileAuthorityScope(for: newContext) else {
            return
        }
        let restored = IMCurrentUserIdentityCache.load( // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
            context: newContext, defaults: currentUserIdentityDefaults
        )?.authorityCheckpoint
        currentProfileAuthorityFence.hydrate(restored, for: currentProfileAuthorityScope(for: newContext))
    }

    func acceptsCurrentProfileAuthority(
        _ snapshot: CurrentProfileAuthoritySnapshot,
        request: CurrentProfileAuthorityRequest
    ) -> Bool {
        switch currentProfileAuthorityFence.consume(snapshot, request: request) {
        case .acceptVersioned, .acceptLegacy:
            return true
        case .rejectPreMutationResponse,
             .rejectScopeMismatch,
             .rejectMalformed,
             .rejectDowngrade,
             .rejectRevisionConflict,
             .rejectLegacyAfterMutation:
            return false
        }
    }

    func currentProfileAuthoritySnapshot(
        from profile: RemoteMeProfile,
        request: CurrentProfileAuthorityRequest
    ) -> CurrentProfileAuthoritySnapshot {
        let isVersioned = profile.userRevision != nil || profile.identityGeneration != nil
        return CurrentProfileAuthoritySnapshot(
            tenantID: isVersioned ? profile.tenantID : (profile.tenantID.isEmpty ? request.scope.tenantID : profile.tenantID),
            imUID: isVersioned ? profile.imUID : (profile.imUID.isEmpty ? request.scope.actorIMUID : profile.imUID),
            appID: request.scope.appID,
            userRevision: profile.userRevision,
            identityGeneration: profile.identityGeneration,
            nickname: profile.nickname,
            avatar: profile.avatar
        )
    }

    func currentProfileAuthoritySnapshot(
        from user: RemoteIMUser,
        context: RemoteTenantContext,
        request: CurrentProfileAuthorityRequest
    ) -> CurrentProfileAuthoritySnapshot {
        let isVersioned = user.userRevision != nil || user.identityGeneration != nil
        let tenantID = user.tenantID.isEmpty ? context.tenantID : user.tenantID
        let appID = context.appID.isEmpty ? request.scope.appID : IMAPIContext.normalizedIOSAppID(context.appID)
        return CurrentProfileAuthoritySnapshot(
            tenantID: isVersioned ? tenantID : (tenantID.isEmpty ? request.scope.tenantID : tenantID),
            imUID: isVersioned ? user.imUID : (user.imUID.isEmpty ? request.scope.actorIMUID : user.imUID),
            appID: appID,
            userRevision: user.userRevision,
            identityGeneration: user.identityGeneration,
            nickname: user.nickname,
            avatar: user.avatar
        )
    }

        func callRecordDataScopeKey(for context: IMAPIContext) -> String {
            [
                // v2 could contain rows copied from an app-wide mirror. Keep
                // that archive intact, but never present its unowned rows.
                "v3",
                "bundle=\(Self.callRecordScopeComponent(Bundle.main.bundleIdentifier ?? ""))",
                "app=\(Self.callRecordScopeComponent(IMAPIContext.normalizedIOSAppID(context.appID)))",
                "account=\(Self.callRecordScopeComponent(context.accountID ?? ""))",
                "tenant=\(Self.callRecordScopeComponent(context.tenantID ?? ""))",
                "im=\(Self.callRecordScopeComponent(context.imUID ?? ""))"
            ].joined(separator: "|")
        }

        private func legacyCallRecordDataScopeKey(for context: IMAPIContext) -> String {
            [
                "v1",
                "app=\(Self.callRecordScopeComponent(IMAPIContext.normalizedIOSAppID(context.appID)))",
                "account=\(Self.callRecordScopeComponent(context.accountID ?? ""))",
                "tenant=\(Self.callRecordScopeComponent(context.tenantID ?? ""))",
                "im=\(Self.callRecordScopeComponent(context.imUID ?? ""))"
            ].joined(separator: "|")
        }

        private static func callRecordScopeComponent(_ value: String) -> String {
            Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }

    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
    func callRecordRuntimeScope(for context: IMAPIContext) -> LocalMessageScope? {
        guard context.hasIMSession else { return nil }
        return try? LocalMessageScope(context: context)
    }

    func bindCallRecordPersistence(for context: IMAPIContext) {
        let runtimeScope = callRecordRuntimeScope(for: context)
        guard runtimeScope == callRecordRuntimeScope(for: apiContext) else { return }
        guard let runtimeScope else {
            callStore.clearCallRecordPersistenceBinding()
            return
        }
        callStore.bindCallRecordPersistence(
            scope: callRecordDataScopeKey(for: context),
            fallbackScopes: [
                legacyCallRecordDataScopeKey(for: context),
                remoteDataScopeKey(for: context)
            ],
            runtimeScope: runtimeScope
        )
    }

    func ensureCallRecordPersistenceBindingIfNeeded() {
        guard let runtimeScope = callRecordRuntimeScope(for: apiContext) else {
            if callStore.hasCallRecordPersistenceBinding { callStore.clearCallRecordPersistenceBinding() }
            return
        }
        guard !callStore.hasCallRecordPersistenceBinding(for: runtimeScope) else { return }
        bindCallRecordPersistence(for: apiContext)
    }
    // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END

	    func beginTenantDevicePolicyRequest(
        context: IMAPIContext
    ) -> TenantDevicePolicyRequestAuthority? {
        guard let scope = TenantDevicePolicyAuthorityScope(context: context),
              scope == TenantDevicePolicyAuthorityScope(context: apiContext) else {
            return nil
        }
        tenantDevicePolicyRequestGeneration &+= 1
        tenantDevicePolicyPresentationStore.multiplicity = .unavailable // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110
        return TenantDevicePolicyRequestAuthority(
            scope: scope,
            generation: tenantDevicePolicyRequestGeneration
        )
    }

    func isCurrentTenantDevicePolicyRequest(
        _ authority: TenantDevicePolicyRequestAuthority
    ) -> Bool {
        tenantDevicePolicyRequestGeneration == authority.generation
            && TenantDevicePolicyAuthorityScope(context: apiContext) == authority.scope
    }

    func markTenantDevicePolicyUnavailable(
        authority: TenantDevicePolicyRequestAuthority
    ) {
        guard isCurrentTenantDevicePolicyRequest(authority) else { return }
        tenantDevicePolicyPresentationStore.multiplicity = .unavailable // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110
    }

    private func applyTenantDevicePolicy(
        _ policy: RemoteTenantClientPolicy?,
        authority: TenantDevicePolicyRequestAuthority
    ) {
        guard isCurrentTenantDevicePolicyRequest(authority),
              let policy,
              policy.multiDevicePolicyPresent,
              policy.multiDevicePolicyAuthoritative,
              policy.multiDeviceContractVersion == 1 else {
            markTenantDevicePolicyUnavailable(authority: authority)
            return
        }
        // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_BEGIN
        tenantDevicePolicyPresentationStore.multiplicity = policy.multiDeviceEnabled
            ? .multipleDevices
            : .singleDevice
        // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_END
    }

    func reconcileTenantDevicePolicyAuthority(
        from previousContext: IMAPIContext,
        to nextContext: IMAPIContext
    ) {
        guard TenantDevicePolicyAuthorityScope(context: previousContext)
                != TenantDevicePolicyAuthorityScope(context: nextContext) else {
            return
        }
        invalidateTenantDevicePolicyState()
    }

    private func invalidateTenantDevicePolicyState() {
        tenantDevicePolicyRequestGeneration &+= 1
        tenantDevicePolicyPresentationStore.multiplicity = .unavailable // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110
    }

    func tenantContextMatchesDevicePolicyAuthority(
        _ context: RemoteTenantContext,
        authority: TenantDevicePolicyRequestAuthority
    ) -> Bool {
        let tenantID = context.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let viewerID = context.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return tenantID == authority.scope.tenantID
            && viewerID == authority.scope.viewerID
            && appID == authority.scope.appID
            && deviceID == authority.scope.deviceID
    }

    func applyTenantClientPolicy(
        _ policy: RemoteTenantClientPolicy?,
        context: IMAPIContext,
        devicePolicyAuthority: TenantDevicePolicyRequestAuthority? = nil,
        groupCountDefaults: UserDefaults = .standard // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111
    ) {
        guard context.hasIMSession else {
            clearTenantClientPolicy()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        refreshAppInteractionPolicy()
        let incoming = policy ?? RemoteTenantClientPolicy(
            showGroupMemberCount: false,
            groupMemberCountPolicyAuthoritative: false,
            groupMemberCountPolicyPresent: false
        )
        let minimumGeneration = minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0
        let satisfiesPendingInvalidation =
            incoming.groupMemberCountPolicyGeneration >= minimumGeneration
        let decision = resolveGroupMemberCountVisibility(
            storedAuthoritative: GroupMemberCountVisibilityStore.load(scope: scope, defaults: groupCountDefaults), // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111
            incoming: incoming
        )
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110: publish policy and resolution together below.
        if let devicePolicyAuthority {
            applyTenantDevicePolicy(
                policy,
                authority: devicePolicyAuthority
            )
        }
        let resolution: GroupMemberCountPolicyResolutionState = // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            policy?.groupMemberCountPolicyPresent == true &&
            (policy?.groupMemberCountContractVersion ?? 0) >= 1 &&
            policy?.groupMemberCountPolicyAuthoritative == true &&
            satisfiesPendingInvalidation
            ? .authoritative(
                scope: scope,
                generation: policy?.groupMemberCountPolicyGeneration ?? 0
            )
            : .unresolved(
                scope: scope,
                minimumGeneration: minimumGeneration
            )
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
        tenantClientPolicyStore.snapshot = .init(
            activeScope: remoteDataScopeKey(for: apiContext),
            policyScope: scope,
            policy: decision.effectivePolicy,
            groupCountResolution: resolution
        )
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        if case .authoritative(_, _) = resolution {
            minimumGroupMemberCountPolicyGenerationByScope.removeValue(forKey: scope)
        }
        if let record = decision.authoritativeRecordToPersist {
            GroupMemberCountVisibilityStore.save(record, scope: scope, defaults: groupCountDefaults) // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111
        }
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: scope, clearSearchState: true)
        }
        if !decision.effectivePolicy.showOnlineStatus || !decision.effectivePolicy.showLastLoginTime {
            scrubHiddenPresenceState()
        }
        if decision.effectivePolicy.showOnlineStatus || decision.effectivePolicy.showLastLoginTime {
            reapplyAllPresenceConnectivityProjections()
        }
    }

    func clearTenantClientPolicy() {
        let previousScope = tenantClientPolicyStore.snapshot.policyScope // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        invalidateTenantDevicePolicyState()
        let scopeToScrub = previousScope.isEmpty
            ? remoteDataScopeKey(for: apiContext)
            : previousScope
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
        tenantClientPolicyStore.snapshot = .init(
            activeScope: remoteDataScopeKey(for: apiContext),
            groupCountResolution: .unresolved(
                scope: scopeToScrub,
                minimumGeneration: minimumGroupMemberCountPolicyGenerationByScope[scopeToScrub] ?? 0
            )
        )
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        groupMemberCountPolicyCheckpoint = nil
        groupMemberCountPolicyRefreshTask?.cancel()
        groupMemberCountPolicyRefreshTask = nil
        scrubHiddenGroupMemberTotals(scope: scopeToScrub, clearSearchState: true)
        scrubHiddenPresenceState()
    }

    func markGroupMemberCountPolicyUnresolved(
        scope: String,
        minimumGeneration: Int64? = nil
    ) {
        guard !scope.isEmpty else { return }
        let nextMinimumGeneration = max(
            minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0,
            max(0, minimumGeneration ?? 0)
        )
        tenantClientPolicyStore.snapshot.groupCountResolution = .unresolved( // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            scope: scope,
            minimumGeneration: nextMinimumGeneration
        )
        if let minimumGeneration {
            minimumGroupMemberCountPolicyGenerationByScope[scope] = max(
                minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0,
                max(0, minimumGeneration)
            )
        }
        scrubHiddenGroupMemberTotals(scope: scope, clearSearchState: true)
    }

    private func groupMemberCountPolicyFenceScope(
        context: IMAPIContext
    ) -> ScopedResponseScope? {
        guard context.hasIMSession else { return nil }
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewerID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = storedSessionID.isEmpty ? context.deviceID : storedSessionID
        return ScopedResponseScope(
            tenantID: tenantID,
            viewerID: viewerID,
            appID: appID,
            featureKey: "show_group_member_count",
            subjectType: "tenant",
            subjectID: tenantID,
            sessionID: sessionID,
            sessionGeneration: 0,
            capabilityFingerprint: "tenant-policy-v1"
        )
    }

    func refreshGroupMemberCountPolicyAfterRealtimeInvalidation(
        envelope: RealtimeEnvelope
    ) {
        let context = apiContext
        guard context.hasIMSession else {
            clearTenantClientPolicy()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let eventTenantID = payloadString(envelope.payload, ["tenant_id", "tenantId"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard eventTenantID.isEmpty || eventTenantID == currentTenantID else { return }
        let generationFamily = payloadString(
            envelope.payload,
            ["generation_family", "generationFamily"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventGeneration = max(
            0,
            payloadInt64(
                envelope.payload,
                ["tenant_policy_generation", "generation"]
            ) ?? 0
        )
        markGroupMemberCountPolicyUnresolved(
            scope: scope,
            minimumGeneration: eventGeneration
        )
        clearGroupAnnouncementReadCounts()
        guard generationFamily.isEmpty || generationFamily == ScopedGenerationFamily.tenantPolicy.rawValue,
              let activeFenceScope = groupMemberCountPolicyFenceScope(context: context) else {
            groupMemberCountPolicyCheckpoint = nil
            return
        }
        if let currentGeneration = groupMemberCountPolicyCheckpoint?
            .version.familyGenerations[.tenantPolicy],
           eventGeneration > currentGeneration + 1 {
            groupMemberCountPolicyCheckpoint = nil
        }
        groupMemberCountPolicyRequestSequence += 1
        let requestSequence = groupMemberCountPolicyRequestSequence
        groupMemberCountPolicyRefreshTask?.cancel()
        groupMemberCountPolicyRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await self.api.tenantContext(context: context)
                guard !Task.isCancelled,
                      self.isCurrentRemoteScope(scope) else {
                    return
                }
                guard let refreshedPolicy = refreshed.clientPolicy,
                      refreshedPolicy.groupMemberCountPolicyPresent,
                      refreshedPolicy.groupMemberCountContractVersion >= 1,
                      refreshedPolicy.groupMemberCountPolicyAuthoritative,
                      refreshedPolicy.groupMemberCountPolicyGeneration >= eventGeneration else {
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                    return
                }
                let incoming = ScopedResponseCheckpoint(
                    scope: activeFenceScope,
                    version: ScopedResponseVersion(
                        contractVersion: ScopedResponseVersion.currentContractVersion,
                        revision: refreshedPolicy.groupMemberCountPolicyGeneration,
                        familyGenerations: [
                            .tenantPolicy: refreshedPolicy.groupMemberCountPolicyGeneration
                        ],
                        requestSequence: requestSequence
                    )
                )
                let outcome = ScopedResponseFence.evaluate(
                    current: self.groupMemberCountPolicyCheckpoint,
                    activeScope: self.groupMemberCountPolicyFenceScope(context: self.apiContext),
                    activeRequestSequence: requestSequence,
                    incoming: incoming
                )
                switch outcome {
                case .apply(let checkpoint):
                    self.groupMemberCountPolicyCheckpoint = checkpoint
                    self.applyTenantClientPolicy(refreshedPolicy, context: context)
                case .ignoreIdempotent:
                    self.applyTenantClientPolicy(refreshedPolicy, context: context)
                case .purge, .purgeAndRefetch:
                    self.groupMemberCountPolicyCheckpoint = nil
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                case .ignoreStale, .ignoreInactiveRequest, .ignoreForeign:
                    self.markGroupMemberCountPolicyUnresolved(
                        scope: scope,
                        minimumGeneration: eventGeneration
                    )
                }
            } catch {
                guard self.isCurrentRemoteScope(scope) else { return }
                self.markGroupMemberCountPolicyUnresolved(
                    scope: scope,
                    minimumGeneration: eventGeneration
                )
            }
        }
    }

    func scrubHiddenGroupMemberTotals(scope: String, clearSearchState: Bool = false) {
        let scrubbed = clientStateScrubbingGroupMemberTotals(
            groups: groups,
            conversations: conversationStore.conversationMessageSnapshots(),
            clearSearchState: clearSearchState
        )
        groups = scrubbed.groups
        conversationStore.commitConversationSnapshots(scrubbed.conversations)
        if !scope.isEmpty {
            messageStore.remove(scope: scope)
        }
        if scrubbed.clearsTenantScopedSearchState {
            clearTenantScopedSearchState(reason: "group_member_count_hidden")
        }
    }

    @discardableResult
    func removeRemoteSnapshotCache(for context: IMAPIContext) -> Bool {
        guard context.hasIMSession else { return true }
        var didScheduleLocalCleanup = true
        let retiredGeneration = localMessageSessionGeneration
        localMessageSessionGeneration &+= 1
        localMessageTicket = nil
        let scope = remoteDataScopeKey(for: context)
        messageStore.remove(scope: scope)
        if let scopeHash = try? LocalMessageScope(context: context).scopeHash {
            do {
                _ = try messagePersistence.schedulePurgeExactScope(
                    context: context,
                    through: retiredGeneration,
                    beforePurge: {
                        _ = await IOSMediaCacheStoreRegistry.shared.invalidate(
                            scopeHash: scopeHash,
                            through: retiredGeneration
                        )
                    }
                )
            } catch {
                didScheduleLocalCleanup = false
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("本机数据安全清理失败，已阻止旧作用域缓存访问")
            }
        }
        AttachmentDownloadCachePolicy.purgeLegacyDownloads()
        AttachmentDownloadCachePolicy.purgeTransientStaging()
        FilesPreviewCacheAdapter.purgeLegacyScope(scope)
        SystemPreviewLoader.purgeAllTransientFiles()
        AvatarImageCache.shared.removeAllImages()
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
        fileStore.favoriteAssetsCollection.purge(scope: scope)
        fileStore.publishFavoriteAssets(isSyncing: false)
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
        return didScheduleLocalCleanup
    }

    func isCurrentRemoteScope(_ scope: String) -> Bool {
        apiContext.hasIMSession && remoteDataScopeKey(for: apiContext) == scope
    }

    func isCurrentRemoteRefresh(_ session: RemoteSnapshotRefreshSession, scope: String) -> Bool {
        remoteSyncEngine.isCurrentRemoteSnapshotRefresh(session) && isCurrentRemoteScope(scope)
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
