import IM4Features
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

// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
@MainActor
final class EnterpriseMembershipPresentationStore {
    struct Selection: Equatable {
        let memberships: [Enterprise]
        let currentID: String
    }

    struct Snapshot: Equatable {
        var current = Enterprise(id: "pending", name: "正在同步企业", code: "", role: "", status: "同步中", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)
        var memberships: [Enterprise] = []

        var selection: Selection { Selection(memberships: memberships, currentID: current.id) }
    }

    @Published fileprivate(set) var snapshot = Snapshot()

    func setInitialCurrent(_ enterprise: Enterprise) {
        snapshot.current = enterprise
    }

    func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}
// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
private struct EnterpriseDisplayNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var enterpriseDisplayName: String? {
        get { self[EnterpriseDisplayNameKey.self] }
        set { self[EnterpriseDisplayNameKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

extension AppState {
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    func setCurrentEnterprise(_ enterprise: Enterprise) {
        let oldValue = currentEnterprise
        enterpriseMembershipStore.snapshot.current = enterprise
        // WDT_RECEIPT_DETAIL_SCOPE_20261023: role/tenant changes invalidate personnel details, not read ACKs.
        if oldValue.id != currentEnterprise.id || oldValue.role != currentEnterprise.role {
            invalidateReadReceiptDetailAuthorities()
        }
        syncIOSRiskTelemetrySession()
    }

    func setEnterprises(_ memberships: [Enterprise]) {
        enterpriseMembershipStore.snapshot.memberships = memberships
    }

    func updateEnterprises(_ update: (inout [Enterprise]) -> Void) {
        var memberships = enterprises
        update(&memberships)
        setEnterprises(memberships)
    }
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END

    func applyTenantMemberships(_ memberships: [RemoteTenantMembership]) {
        let scopedMemberships = memberships.filter { $0.isVisibleInAppScope(currentAppID) }
        guard !scopedMemberships.isEmpty else {
            setEnterprises([]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setCurrentEnterprise(Enterprise(id: "pending_workspace_selection", name: "请选择企业", code: "", role: "", status: "待选择", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            return
        }
        let mapped = scopedMemberships.enumerated().map { index, membership in
            enterprise(from: membership, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
        }
        setEnterprises(mapped) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        if let remoteCurrent = mapped.first(where: { $0.id == apiContext.tenantID && $0.isWorkspaceJoined && $0.isWorkspaceEnterable })
            ?? mapped.first(where: { $0.isWorkspaceJoined && $0.isWorkspaceEnterable }) {
            setCurrentEnterprise(remoteCurrent) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
    }

    private func resolvedEnterpriseLogoURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return resolveTenantAssetURL(trimmed)
    }

    func enterprise(from membership: RemoteTenantMembership, fallbackAccent: UInt) -> Enterprise {
        let joinStatus = membership.joinStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? membership.member.status : membership.joinStatus
        let resolvedRole = authoritativeTenantRole(forTenantID: membership.tenant.id) ?? membership.member.role
        let pendingOrRejected = Enterprise(
            id: membership.tenant.id,
            name: membership.tenant.name,
            code: membership.tenant.tenantCode,
            role: resolvedRole,
            status: membership.member.status,
            memberCount: 0,
            isDefault: membership.tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(membership.tenant.logoURL),
            logoStatus: membership.tenant.logoStatus,
            logoVersion: membership.tenant.logoVersion,
            logoUpdatedAt: membership.tenant.logoUpdatedAt,
            logoCacheKey: membership.tenant.logoCacheKey,
            logoMime: membership.tenant.logoMime,
            logoWidth: membership.tenant.logoWidth,
            logoHeight: membership.tenant.logoHeight,
            joinStatus: joinStatus,
            applicationID: membership.applicationID,
            applicationStatus: membership.applicationStatus,
            approvalRequired: membership.approvalRequired,
            canSwitch: membership.canSwitch ?? true,
            enterable: membership.enterable,
            accountStatus: "",
            tenantStatus: membership.tenant.status,
            memberStatus: membership.member.status,
            disabledReason: membership.disabledReason
        )
        let blockedByApplication = pendingOrRejected.isWorkspaceJoinPending || pendingOrRejected.isWorkspaceJoinRejected
        return Enterprise(
            id: membership.tenant.id,
            name: membership.tenant.name,
            code: membership.tenant.tenantCode,
            role: resolvedRole,
            status: membership.member.status,
            memberCount: 0,
            isDefault: membership.tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(membership.tenant.logoURL),
            logoStatus: membership.tenant.logoStatus,
            logoVersion: membership.tenant.logoVersion,
            logoUpdatedAt: membership.tenant.logoUpdatedAt,
            logoCacheKey: membership.tenant.logoCacheKey,
            logoMime: membership.tenant.logoMime,
            logoWidth: membership.tenant.logoWidth,
            logoHeight: membership.tenant.logoHeight,
            joinStatus: joinStatus,
            applicationID: membership.applicationID,
            applicationStatus: membership.applicationStatus,
            approvalRequired: membership.approvalRequired,
            canSwitch: blockedByApplication ? false : (membership.canSwitch ?? true),
            enterable: blockedByApplication ? false : membership.enterable,
            tenantStatus: membership.tenant.status,
            memberStatus: membership.member.status,
            disabledReason: blockedByApplication && membership.disabledReason.isEmpty ? (pendingOrRejected.isWorkspaceJoinPending ? "pending" : "rejected") : membership.disabledReason
        )
    }

    func applyWorkspaces(_ workspaces: [RemoteWorkspaceTenant]) {
        let mapped = workspaces.enumerated().map { index, workspace in
            enterprise(from: workspace, fallbackAccent: [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7][index % 4])
        }
        if enterprises != mapped {
            setEnterprises(mapped) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        handleWorkspaceApplicationStatus(mapped)
        if let remoteCurrent = mapped.first(where: { ($0.isCurrent || $0.id == apiContext.tenantID) && $0.isWorkspaceJoined && $0.isWorkspaceEnterable })
            ?? mapped.first(where: { $0.isWorkspaceJoined && $0.isWorkspaceEnterable }) {
            if currentEnterprise != remoteCurrent {
                setCurrentEnterprise(remoteCurrent) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            }
        }
    }

    func handleWorkspaceApplicationStatus(_ items: [Enterprise]) {
        let rejectedIDs = Set(items.filter { $0.isWorkspaceJoinRejected }.map(\.id))
        guard !rejectedIDs.isEmpty else { return }
        enterpriseDirectoryStore.projectSearchResults { existing in // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110
            if let updated = items.first(where: { $0.id == existing.id }) {
                return updated
            }
            return existing
        }
        if items.contains(where: { rejectedIDs.contains($0.id) }) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知：入企申请已被拒绝")
        }
    }

    // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110: search results are upserted by EnterpriseDirectoryStore.
    func upsertEnterprise(_ enterprise: Enterprise) {
        if let index = enterprises.firstIndex(where: { $0.id == enterprise.id }) {
            updateEnterprises { $0[index] = enterprise } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        } else {
            updateEnterprises { $0.append(enterprise) } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
    }

    func enterprise(from tenant: RemoteTenant, fallbackAccent: UInt) -> Enterprise {
        Enterprise(
            id: tenant.id,
            name: tenant.name,
            code: tenant.tenantCode,
            role: "",
            status: tenant.status,
            memberCount: 0,
            isDefault: tenant.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(tenant.logoURL),
            logoStatus: tenant.logoStatus,
            logoVersion: tenant.logoVersion,
            logoUpdatedAt: tenant.logoUpdatedAt,
            logoCacheKey: tenant.logoCacheKey,
            logoMime: tenant.logoMime,
            logoWidth: tenant.logoWidth,
            logoHeight: tenant.logoHeight,
            searchEntryType: tenant.entryType,
            searchInviterName: [tenant.inviterNickname, tenant.inviterDisplayName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        )
    }

    func enterprise(from workspace: RemoteWorkspaceTenant, fallbackAccent: UInt, role overrideRole: String? = nil) -> Enterprise {
        Enterprise(
            id: workspace.id,
            name: workspace.name,
            code: workspace.tenantCode,
            role: overrideRole ?? authoritativeTenantRole(forTenantID: workspace.id) ?? workspace.memberRole,
            status: workspace.status,
            memberCount: 0,
            isDefault: workspace.tenantCode.uppercased() == "DEFAULT",
            accentHex: fallbackAccent,
            logoURL: resolvedEnterpriseLogoURL(workspace.logoURL),
            logoStatus: workspace.logoStatus,
            logoVersion: workspace.logoVersion,
            logoUpdatedAt: workspace.logoUpdatedAt,
            logoCacheKey: workspace.logoCacheKey,
            logoMime: workspace.logoMime,
            logoWidth: workspace.logoWidth,
            logoHeight: workspace.logoHeight,
            joinStatus: workspace.joinStatus,
            applicationID: workspace.applicationID,
            applicationStatus: workspace.applicationStatus,
            approvalRequired: workspace.approvalRequired,
            canSwitch: workspace.canSwitch,
            enterable: workspace.enterable,
            isCurrent: workspace.current,
            accountStatus: workspace.accountStatus,
            tenantStatus: workspace.tenantStatus,
            memberStatus: workspace.memberStatus,
            disabledReason: workspace.disabledReason
        )
    }

    private func authoritativeTenantRole(forTenantID rawTenantID: String) -> String? {
        guard let authority = tenantContextRoleAuthority else { return nil }
        let tenantID = rawTenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentIMUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tenantID.isEmpty,
              authority.appID == currentAppID,
              authority.tenantID == tenantID,
              authority.tenantID == currentTenantID,
              authority.imUID == currentIMUID,
              !authority.role.isEmpty else {
            return nil
        }
        return authority.role
    }

    func enterprise(_ source: Enterprise, replacingRole role: String) -> Enterprise {
        guard source.role != role else { return source }
        return Enterprise(
            id: source.id,
            name: source.name,
            code: source.code,
            role: role,
            status: source.status,
            memberCount: source.memberCount,
            isDefault: source.isDefault,
            accentHex: source.accentHex,
            logoURL: source.logoURL,
            logoStatus: source.logoStatus,
            logoVersion: source.logoVersion,
            logoUpdatedAt: source.logoUpdatedAt,
            logoCacheKey: source.logoCacheKey,
            logoMime: source.logoMime,
            logoWidth: source.logoWidth,
            logoHeight: source.logoHeight,
            joinStatus: source.joinStatus,
            applicationID: source.applicationID,
            applicationStatus: source.applicationStatus,
            approvalRequired: source.approvalRequired,
            canSwitch: source.canSwitch,
            enterable: source.enterable,
            isCurrent: source.isCurrent,
            accountStatus: source.accountStatus,
            tenantStatus: source.tenantStatus,
            memberStatus: source.memberStatus,
            disabledReason: source.disabledReason,
            searchEntryType: source.searchEntryType,
            searchInviterName: source.searchInviterName
        )
    }

    private func applyTenantContextRoleAuthority(_ user: RemoteIMUser, context: RemoteTenantContext) {
        let role = user.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let tenantID = [context.tenantID, context.tenant.tenantID, apiContext.tenantID ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let contextIMUID = context.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let userIMUID = user.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIMUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imUID = [userIMUID, contextIMUID, currentIMUID].first { !$0.isEmpty } ?? ""
        let contextAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = IMAPIContext.normalizedIOSAppID(contextAppID.isEmpty ? apiContext.appID : contextAppID)
        let currentTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !role.isEmpty,
              !tenantID.isEmpty,
              !imUID.isEmpty,
              tenantID == currentTenantID,
              imUID == currentIMUID,
              (userIMUID.isEmpty || userIMUID == currentIMUID),
              (contextIMUID.isEmpty || contextIMUID == currentIMUID),
              appID == currentAppID else {
            tenantContextRoleAuthority = nil
            return
        }
        tenantContextRoleAuthority = TenantContextRoleAuthority(
            appID: appID,
            tenantID: tenantID,
            imUID: imUID,
            role: role
        )
        let nextCurrent = enterprise(currentEnterprise, replacingRole: role)
        if nextCurrent != currentEnterprise {
            setCurrentEnterprise(nextCurrent) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        setEnterprises(enterprises.map { item in
            item.id == tenantID ? enterprise(item, replacingRole: role) : item
        }) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
    }

    func reconcileTenantContextRoleAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard tenantContextRoleAuthority != nil else { return }
        let oldBinding = [
            IMAPIContext.normalizedIOSAppID(oldContext.appID),
            oldContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            oldContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        let newBinding = [
            IMAPIContext.normalizedIOSAppID(newContext.appID),
            newContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            newContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        if oldBinding != newBinding {
            tenantContextRoleAuthority = nil
        }
    }

    func applyTenantProfile(_ profile: RemoteTenantProfile) {
        let tenantID = profile.tenantID.isEmpty ? (apiContext.tenantID ?? currentEnterprise.id) : profile.tenantID
        let tenantCode = profile.tenantCode.isEmpty ? currentEnterprise.code : profile.tenantCode
        let currentName = currentEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameCurrentEnterprise = !tenantID.isEmpty && tenantID == currentEnterprise.id
        let tenantName = sameCurrentEnterprise && !currentName.isEmpty ? currentName : (profile.name.isEmpty ? currentEnterprise.name : profile.name)
        let status = profile.status.isEmpty ? currentEnterprise.status : profile.status
        let profileLogoStatus = profile.logoStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogoStatus = profileLogoStatus.lowercased()
        let logoCleared = ["empty", "unsafe", "cleared", "removed"].contains(normalizedLogoStatus)
        let rawLogoURL = profile.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let logoURL = rawLogoURL.isEmpty ? (logoCleared ? "" : currentEnterprise.logoURL) : resolvedEnterpriseLogoURL(rawLogoURL)
        let logoStatus = profileLogoStatus.isEmpty ? (logoCleared ? "empty" : currentEnterprise.logoStatus) : profileLogoStatus
        let logoVersion = profile.logoVersion.isEmpty ? (logoCleared ? "" : currentEnterprise.logoVersion) : profile.logoVersion
        let logoUpdatedAt = profile.logoUpdatedAt.isEmpty ? (logoCleared ? "" : currentEnterprise.logoUpdatedAt) : profile.logoUpdatedAt
        let logoCacheKey = profile.logoCacheKey.isEmpty ? (logoCleared ? "" : currentEnterprise.logoCacheKey) : profile.logoCacheKey
        let logoMime = profile.logoMime.isEmpty ? (logoCleared ? "" : currentEnterprise.logoMime) : profile.logoMime
        let logoWidth = profile.logoWidth ?? (logoCleared ? nil : currentEnterprise.logoWidth)
        let logoHeight = profile.logoHeight ?? (logoCleared ? nil : currentEnterprise.logoHeight)
        let enterprise = Enterprise(
            id: tenantID,
            name: tenantName,
            code: tenantCode,
            role: currentEnterprise.role,
            status: status,
            memberCount: currentEnterprise.memberCount,
            isDefault: currentEnterprise.isDefault || tenantCode.uppercased() == "DEFAULT",
            accentHex: currentEnterprise.accentHex,
            logoURL: logoURL,
            logoStatus: logoStatus,
            logoVersion: logoVersion,
            logoUpdatedAt: logoUpdatedAt,
            logoCacheKey: logoCacheKey,
            logoMime: logoMime,
            logoWidth: logoWidth,
            logoHeight: logoHeight,
            joinStatus: currentEnterprise.joinStatus,
            applicationID: currentEnterprise.applicationID,
            applicationStatus: currentEnterprise.applicationStatus,
            approvalRequired: currentEnterprise.approvalRequired,
            canSwitch: currentEnterprise.canSwitch,
            enterable: currentEnterprise.enterable,
            isCurrent: currentEnterprise.isCurrent,
            accountStatus: currentEnterprise.accountStatus,
            tenantStatus: currentEnterprise.tenantStatus,
            memberStatus: currentEnterprise.memberStatus,
            disabledReason: currentEnterprise.disabledReason
        )
        if currentEnterprise != enterprise {
            setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        if let index = enterprises.firstIndex(where: { $0.id == enterprise.id }) {
            if enterprises[index] != enterprise {
                updateEnterprises { $0[index] = enterprise } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            }
        } else {
            updateEnterprises { $0.insert(enterprise, at: 0) } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        if currentUser.id == apiContext.imUID, currentUser.enterprise != enterprise.name {
            setCurrentUser(IMUser(
                id: currentUser.id,
                userID: currentUser.userID,
                username: currentUser.username,
                name: currentUser.name,
                title: "",
                department: "",
                phone: currentUser.phone,
                phoneVerified: currentUser.phoneVerified,
                realNameVerified: currentUser.realNameVerified,
                realNameStatus: currentUser.realNameStatus,
                email: currentUser.email,
                status: currentUser.status,
                enterprise: enterprise.name,
                avatarSeed: currentUser.avatarSeed,
                avatarURL: currentUser.avatarURL,
                avatarVersion: currentUser.avatarVersion,
                avatarUpdatedAt: currentUser.avatarUpdatedAt,
                badges: []
            )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        }
    }

    static func validateAuthenticatedTenantContextBinding(
        _ context: RemoteTenantContext,
        expected: IMAPIContext
    ) -> AuthenticatedTenantContextBindingValidation {
        guard expected.hasIMSession else { return .incomplete }
        let expectedTenantID = expected.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedIMUID = expected.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedAppID = IMAPIContext.normalizedIOSAppID(expected.appID)
        let expectedDeviceID = expected.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedAccountID = expected.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let tenantIDs = [context.tenantID, context.tenant.tenantID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let imUIDs = [context.imUID, context.user?.imUID ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let responseAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedTenantID.isEmpty,
              !expectedIMUID.isEmpty,
              !expectedAppID.isEmpty,
              !tenantIDs.isEmpty,
              !imUIDs.isEmpty,
              !responseAppID.isEmpty else {
            return .incomplete
        }
        guard tenantIDs.allSatisfy({ $0 == expectedTenantID }),
              imUIDs.allSatisfy({ $0 == expectedIMUID }),
              IMAPIContext.normalizedIOSAppID(responseAppID) == expectedAppID else {
            return .mismatch
        }
        let responseDeviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseDeviceID.isEmpty, responseDeviceID != expectedDeviceID {
            return .mismatch
        }
        let responseAccountID = context.user?.accountID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedAccountID.isEmpty,
           !responseAccountID.isEmpty,
           responseAccountID != expectedAccountID {
            return .mismatch
        }
        return .verified
    }

    @discardableResult
    func applyTenantContext(_ context: RemoteTenantContext) -> Bool {
        applyTenantContext(context, devicePolicyAuthority: nil)
    }

    @discardableResult
    func applyTenantContext(
        _ context: RemoteTenantContext,
        devicePolicyAuthority: TenantDevicePolicyRequestAuthority?,
        profileAuthorityRequest: CurrentProfileAuthorityRequest? = nil
    ) -> Bool {
        switch Self.validateAuthenticatedTenantContextBinding(context, expected: apiContext) {
        case .verified:
            break
        case .incomplete:
            print("[JHT Auth] tenant_context_ignored reason=incomplete_binding")
            return false
        case .mismatch:
            handleVerifiedTenantContextBindingMismatch()
            return false
        }
        // A coalesced tenant-context response can still carry valid profile,
        // workspace and ordinary client-policy data after a newer device-policy
        // refresh has taken authority.  Fence only the multi-device projection;
        // dropping the whole response makes the older refresh report a false
        // failure and discards unrelated authoritative context.
        let applicableDevicePolicyAuthority: TenantDevicePolicyRequestAuthority?
        if let devicePolicyAuthority,
           isCurrentTenantDevicePolicyRequest(devicePolicyAuthority),
           tenantContextMatchesDevicePolicyAuthority(
                context,
                authority: devicePolicyAuthority
           ) {
            applicableDevicePolicyAuthority = devicePolicyAuthority
        } else {
            applicableDevicePolicyAuthority = nil
        }
        let previousTenantID = apiContext.tenantID
        let previousIMUID = apiContext.imUID
        if !context.tenantID.isEmpty {
            apiContext.tenantID = context.tenantID
        }
        if !context.imUID.isEmpty {
            apiContext.imUID = context.imUID
        }
        if !context.appID.isEmpty {
            apiContext.appID = IMAPIContext.normalizedIOSAppID(context.appID)
        }
        if !context.deviceID.isEmpty {
            apiContext.deviceID = context.deviceID
        }
        apiContext.save(sessionStore: protectedSessionStore)
        let didChangeInviteAuthority = previousTenantID != apiContext.tenantID || previousIMUID != apiContext.imUID
        if didChangeInviteAuthority {
            resetAuthenticatedRemoteData(invalidateRefresh: false, showLoading: true)
        }
        applyTenantClientPolicy(
            context.clientPolicy,
            context: apiContext,
            devicePolicyAuthority: applicableDevicePolicyAuthority
        )
        if let departmentEnabled = context.departmentEnabled {
            organizationDirectoryStore.setTenantDepartmentEnabled(departmentEnabled) // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
        }
        applyTenantProfile(context.tenant)
        if let user = context.user {
            applyTenantContextRoleAuthority(user, context: context)
            if let profileAuthorityRequest {
                let snapshot = currentProfileAuthoritySnapshot(
                    from: user,
                    context: context,
                    request: profileAuthorityRequest
                )
                guard acceptsCurrentProfileAuthority(snapshot, request: profileAuthorityRequest) else {
                    if didChangeInviteAuthority {
                        activateMyInviteCodeForCurrentSession()
                    }
                    return true
                }
            }
            let resolvedIMUID = user.imUID.isEmpty ? currentUser.id : user.imUID
            let resolvedUserID = user.userID.isEmpty ? (user.imUID.isEmpty ? currentUser.userID : user.imUID) : user.userID
            let resolvedUsername = resolvedCurrentUserUsername(remoteUsername: user.username, currentUsername: currentUser.username)
            let displayName = preferredDisplayName(
                candidates: [currentProfileAuthorityDisplayNameCandidate(), user.nickname, currentUser.name, resolvedUsername, user.userID, user.imUID],
                identifiers: [resolvedIMUID, resolvedUserID, currentUser.id, currentUser.userID],
                fallback: currentUser.name.isEmpty ? resolvedIMUID : currentUser.name
            )
            let userPhone = user.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextPhone = user.phoneBindingKnown
                ? (user.phoneVerified ? userPhone : "")
                : (userPhone.isEmpty ? currentUser.phone : userPhone)
            let nextPhoneVerified = user.phoneBindingKnown ? user.phoneVerified : currentUser.phoneVerified
            setCurrentUser(IMUser(
                id: resolvedIMUID,
                userID: resolvedUserID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: normalizedDepartmentName(user.departmentName, pathNames: user.departmentPathNames),
                departmentPathNames: normalizedDepartmentPathNames(user.departmentPathNames, fallbackName: user.departmentName),
                phone: nextPhone,
                phoneVerified: nextPhoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.accountID.isEmpty ? currentUser.email : user.accountID,
                status: presenceStatusText(
                    rawStatus: user.presenceStatus,
                    online: user.onlineKnown ? user.online : nil
                ),
                lastLoginAt: resolvedLastLoginText(user.lastSeenAt),
                enterprise: currentEnterprise.name,
                avatarSeed: stableSeed(user.imUID.isEmpty ? currentUser.id : user.imUID),
                avatarURL: user.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(user.avatar),
                avatarVersion: user.avatarVersion.isEmpty ? currentUser.avatarVersion : user.avatarVersion,
                avatarUpdatedAt: user.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : user.avatarUpdatedAt,
                badges: currentUser.badges
            )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        }
        if didChangeInviteAuthority {
            activateMyInviteCodeForCurrentSession()
        }
        return true
    }

    private func handleVerifiedTenantContextBindingMismatch() {
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .chats
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        disableAccessDiagnosticsOverlay()
        apiContext.clearSession(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录身份校验不一致，请重新登录")
    }

}
