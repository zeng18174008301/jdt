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
    func applyAuthData(_ data: RemoteAuthData, registrationTenantID: String? = nil) -> Bool {
        var candidate = apiContext
        if let registrationTenantID {
            candidate.discardRegistrationIMState()
            candidate.tenantID = registrationTenantID
            candidate.platformAuthSession = nil
            candidate.sessionEpoch = UUID().uuidString
            candidate.pendingRefreshRequestID = nil
        }
        candidate.platformToken = data.platformToken
        candidate.accountID = data.account.id
        candidate.persistAuthSession(data.authSession, fallbackTokenType: "platform", fallbackTenantID: nil)
        if registrationTenantID == nil, let tenant = data.tenant, let member = data.tenantMember {
            candidate.tenantID = tenant.id
            candidate.imUID = member.imUID
        }
        guard candidate.save(sessionStore: protectedSessionStore).isCommitted else { return false }
        apiContext = candidate
        let memberAvatar = data.tenantMember?.avatar.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let memberAvatarVersion = data.tenantMember?.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let memberAvatarUpdatedAt = data.tenantMember?.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedMemberAvatar = memberAvatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(memberAvatar)
        let name = data.account.username.isEmpty ? (data.account.phone.isEmpty ? currentUser.name : data.account.phone) : data.account.username
        setCurrentUser(IMUser(
            id: data.tenantMember?.imUID ?? apiContext.imUID ?? currentUser.id,
            userID: data.tenantMember?.imUID ?? apiContext.imUID ?? currentUser.userID,
            username: data.account.username,
            name: name,
            title: "",
            department: "",
            phone: data.account.phone,
            phoneVerified: data.account.phoneVerified,
            realNameVerified: data.account.realNameVerified,
            realNameStatus: data.account.realNameStatus,
            email: currentUser.email,
            status: "在线",
            enterprise: data.tenant?.name ?? currentEnterprise.name,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: resolvedMemberAvatar,
            avatarVersion: memberAvatarVersion.isEmpty ? currentUser.avatarVersion : memberAvatarVersion,
            avatarUpdatedAt: memberAvatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : memberAvatarUpdatedAt,
            badges: currentUser.badges
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        if let memberships = data.memberships, !memberships.isEmpty {
            applyTenantMemberships(memberships)
        } else if let tenant = data.tenant, let member = data.tenantMember {
            applyTenantMemberships([RemoteTenantMembership(tenant: tenant, member: member)])
        }
        return true
    }

    func applyTenantLoginData(_ data: RemoteTenantLoginData, loginIdentifierFallback: String? = nil) -> Bool {
        let session = data.session
        let user = data.user
        let tenant = data.tenant
        let hasIMAccessToken = session?.imToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let effectiveSessionIdentity = session.flatMap {
            $0.effectiveIdentity(tenantID: tenant?.tenantID ?? "")
        }
        guard !hasIMAccessToken || effectiveSessionIdentity != nil else {
            return false
        }
        apiContext.platformToken = data.platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiContext.platformToken : data.platformToken
        apiContext.accountID = [
            data.accountID,
            data.account?.id,
            user?.accountID,
            data.userID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        apiContext.persistAuthSession(data.authSession, fallbackTokenType: "platform", fallbackTenantID: nil)
        if let session, let effectiveSessionIdentity, hasIMAccessToken {
            apiContext.tenantID = effectiveSessionIdentity.tenantID
            apiContext.imUID = session.imUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (user?.imUID ?? apiContext.imUID) : session.imUID
            apiContext.imToken = session.imToken
            apiContext.appID = IMAPIContext.normalizedIOSAppID(effectiveSessionIdentity.appID)
            apiContext.deviceID = effectiveSessionIdentity.deviceID
            apiContext.persistAuthSession(
                session.authSession,
                fallbackTokenType: "im",
                fallbackTenantID: effectiveSessionIdentity.tenantID
            )
        } else {
            apiContext.tenantID = nil
            apiContext.imUID = nil
            apiContext.imToken = nil
        }
        let persistenceResult = apiContext.save(sessionStore: protectedSessionStore)
        resetInitialSplashOverlayEvaluationState()

        let effectiveRole = user?.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user?.role ?? "" : data.role
        if let tenant, !tenant.tenantID.isEmpty {
            let enterprise = Enterprise(
                id: tenant.tenantID,
                name: tenant.name,
                code: tenant.tenantCode,
                role: effectiveRole,
                status: tenant.status,
                memberCount: 0,
                isDefault: tenant.tenantCode.uppercased() == "DEFAULT",
                accentHex: currentEnterprise.accentHex,
                logoURL: tenant.logoURL,
                logoStatus: tenant.logoStatus,
                logoVersion: tenant.logoVersion,
                logoUpdatedAt: tenant.logoUpdatedAt,
                logoCacheKey: tenant.logoCacheKey,
                logoMime: tenant.logoMime,
                logoWidth: tenant.logoWidth,
                logoHeight: tenant.logoHeight
            )
            setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        }
        if let user {
            let userPhone = user.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountPhone = data.account?.phone.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let accountPhoneVerified = data.account?.phoneVerified ?? false
            let accountPhoneBindingKnown = data.account?.phoneBindingKnown ?? false
            let nextPhoneVerified: Bool
            if user.phoneBindingKnown {
                nextPhoneVerified = user.phoneVerified
            } else if accountPhoneBindingKnown {
                nextPhoneVerified = accountPhoneVerified
            } else {
                nextPhoneVerified = !userPhone.isEmpty || !accountPhone.isEmpty
            }
            let nextPhoneCandidate = userPhone.isEmpty ? accountPhone : userPhone
            let nextPhone = nextPhoneVerified ? nextPhoneCandidate : ""
            let usernameFallback = [
                data.account?.username,
                loginIdentifierFallback
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let resolvedUsername = resolvedCurrentUserUsername(
                remoteUsername: user.username,
                fallbackUsername: usernameFallback,
                currentUsername: currentUser.username
            )
            let displayName = preferredDisplayName(
                candidates: [
                    currentProfileAuthorityDisplayNameCandidate(),
                    user.nickname,
                    data.account?.nickname,
                    resolvedUsername,
                    data.account?.username,
                    user.userID,
                    user.imUID
                ],
                identifiers: [user.imUID, user.userID, data.account?.id, data.accountID],
                fallback: user.imUID.isEmpty ? "企业成员" : user.imUID
            )
            setCurrentUser(IMUser(
                id: user.imUID,
                userID: user.userID.isEmpty ? user.imUID : user.userID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: "",
                phone: nextPhone,
                phoneVerified: nextPhoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.accountID,
                status: presenceStatusText(
                    rawStatus: user.presenceStatus,
                    online: user.onlineKnown ? user.online : nil
                ),
                lastLoginAt: resolvedLastLoginText(user.lastSeenAt),
                enterprise: tenant?.name ?? currentEnterprise.name,
                avatarSeed: stableSeed(user.imUID),
                avatarURL: user.avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(user.avatar),
                avatarVersion: user.avatarVersion,
                avatarUpdatedAt: user.avatarUpdatedAt,
                badges: []
            )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        } else if let account = data.account {
            let resolvedUsername = resolvedCurrentUserUsername(
                remoteUsername: account.username,
                fallbackUsername: loginIdentifierFallback,
                currentUsername: currentUser.username
            )
            let displayName = preferredDisplayName(
                candidates: [currentProfileAuthorityDisplayNameCandidate(), account.nickname, resolvedUsername, account.username, account.id],
                identifiers: [account.id, account.username, resolvedUsername],
                fallback: account.id.isEmpty ? "平台账号" : account.id
            )
            let accountStableID = [
                session?.imUID,
                account.id,
                resolvedUsername,
                account.username,
                account.phone
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "pending_platform_account"
            setCurrentUser(IMUser(
                id: accountStableID,
                userID: accountStableID,
                username: resolvedUsername,
                name: displayName,
                title: "",
                department: "",
                phone: account.phone,
                phoneVerified: account.phoneVerified,
                realNameVerified: account.realNameVerified,
                realNameStatus: account.realNameStatus,
                email: account.id,
                status: "在线",
                enterprise: tenant?.name ?? currentEnterprise.name,
                avatarSeed: stableSeed(accountStableID),
                avatarURL: "",
                badges: []
            )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        } else {
            let platformStableID = [
                loginIdentifierFallback,
                data.userID,
                data.accountID,
                apiContext.accountID
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let platformStableID {
                let displayName = preferredDisplayName(
                    candidates: [data.accountID, data.userID, platformStableID],
                    identifiers: [data.accountID, data.userID, platformStableID],
                    fallback: platformStableID
                )
                setCurrentUser(IMUser(
                    id: platformStableID,
                    userID: platformStableID,
                    username: resolvedCurrentUserUsername(
                        remoteUsername: "",
                        fallbackUsername: loginIdentifierFallback,
                        currentUsername: data.accountID
                    ),
                    name: displayName,
                    title: "",
                    department: "",
                    phone: "",
                    phoneVerified: false,
                    realNameVerified: false,
                    realNameStatus: "",
                    email: data.accountID,
                    status: "在线",
                    enterprise: tenant?.name ?? currentEnterprise.name,
                    avatarSeed: stableSeed(platformStableID),
                    avatarURL: "",
                    badges: []
                )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
            }
        }
        recordAccessDiagnosticsMerchantEntered()
        return persistenceResult.isCommitted
    }

    @discardableResult
    func applyVerificationStatus(
        _ status: RemoteVerificationStatus,
        preferredPhoneMasked: String = ""
    ) -> Bool {
        let projection = verificationRequirementAuthorityProjection(
            status: status,
            currentUser: currentUser
        )
        let didMatchCurrentUser = projection != nil
        if didMatchCurrentUser {
            verificationRequirementAuthorityScopeKey = remoteDataScopeKey(for: apiContext)
        } else {
            verificationRequirementAuthorityScopeKey = ""
        }
        let currentPhone = currentUser.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredPhone = preferredPhoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusPhone = status.phoneMasked.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextPhone: String
        if didMatchCurrentUser {
            nextPhone = preferredPhone.isEmpty
                ? (statusPhone.isEmpty ? currentPhone : statusPhone)
                : preferredPhone
        } else {
            // A cross-user payload is not consumed, including its masked
            // presentation fields. Requirement truth fails closed below.
            nextPhone = currentPhone
        }
        let nextUser = IMUser(
            id: currentUser.id,
            userID: currentUser.userID,
            username: currentUser.username,
            name: currentUser.name,
            title: currentUser.title,
            department: currentUser.department,
            departmentPathNames: currentUser.departmentPathNames,
            phone: nextPhone,
            phoneVerified: projection?.phoneSatisfied == true,
            realNameVerified: projection?.realNameSatisfied == true,
            realNameStatus: didMatchCurrentUser ? status.realNameStatus : currentUser.realNameStatus,
            email: currentUser.email,
            status: currentUser.status,
            enterprise: currentUser.enterprise,
            avatarSeed: currentUser.avatarSeed,
            avatarURL: currentUser.avatarURL,
            avatarVersion: currentUser.avatarVersion,
            avatarUpdatedAt: currentUser.avatarUpdatedAt,
            badges: currentUser.badges
        )
        setCurrentUser(nextUser) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        reconcileForcedAppPolicyAuthState(for: nextUser)
        return didMatchCurrentUser
    }

    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    func reconcileForcedAppPolicyAuthState(for user: IMUser) {
        guard let policy = currentAppPolicy else { return }
        let pendingRequirement = AppPolicyForcedAuthRequirement.pendingRequirement(policy: policy, user: user)
        if pendingRequirement == nil {
            cancelForcedAppPolicyAuthDestinationTransition()
            forcedAppPolicyAuthStore.clearPresentation()
        } else {
            if let pendingDestination = forcedAppPolicyAuthStore.snapshot.pendingDestination,
               pendingDestination != pendingRequirement {
                cancelForcedAppPolicyAuthDestinationTransition()
            }
            if let prompt = forcedAppPolicyAuthPrompt, prompt != pendingRequirement {
                forcedAppPolicyAuthStore.setPrompt(nil)
            }
            if let destination = forcedAppPolicyAuthDestination, destination != pendingRequirement {
                forcedAppPolicyAuthStore.setDestination(nil)
            }
        }
    }
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END

    func resetAuthenticatedRemoteData(invalidateRefresh: Bool = true, showLoading: Bool? = nil) {
        resetAppInteractionPolicy()
        bootstrapPresentationStore.sync.isLoadingMoreConversations = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isConversationSnapshotPartial = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        purgeAvatarRealtimeProjection(rebindCurrentScope: false)
        purgePresenceConnectivityProjection(rebindCurrentScope: false)
        pendingForcedRemoteSnapshotSuccessorScopes.removeAll(keepingCapacity: false)
        clearPendingRealtimeMessages(reason: "remote_data_reset")
        clearRTCTerminalCompensationsForScopeReset()
        for task in messageSequenceRecoveryRetryTasks.values {
            task.cancel()
        }
        messageSequenceRecoveryRetryTasks.removeAll()
        messageSequenceRecoveryTargets.removeAll()
        messageSequenceRecoveryAttempts.removeAll()
        stopRTCMediaStateHeartbeat(reason: "remote_data_reset")
        groupMemberProfileRefreshEpoch &+= 1
        contactsPostApplyReconciliationGeneration &+= 1
        contactsPostApplyReconciliationTask?.cancel()
        contactsPostApplyReconciliationTask = nil
        if invalidateRefresh {
            remoteSyncEngine.reset()
        }
        let shouldShowLoading = showLoading ?? (isAuthenticated && apiContext.hasIMSession)
        bootstrapPresentationStore.sync.isInitialDataLoading = shouldShowLoading // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        lastRemoteSnapshotPrimarySyncedAt = nil
        bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isSyncRetrying = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
        fileStore.favoriteAssetsCollection.invalidateVisibleItems()
        fileStore.favoriteAssetsSnapshot = FileStore.FavoriteAssetsSnapshot()
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
        fileStore.reset() // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110: also clears call license authority.
        // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_BEGIN
        groupModerationStore.reset() // Original list/settings/admin →idempotency→tokens→generations→cancel/remove tasks; sequence retained.
        // WDT_IOS1_GROUP_MODERATION_COMPLETE_STATE_FAMILY_20261111_END
        groupMemberProfileGenerationByScopedGroupKey.removeAll()
        minimumGroupMemberProfileGenerationByScopedGroupKey.removeAll()
        for task in groupMemberProfileRefreshTasks.values {
            task.cancel()
        }
        groupMemberProfileRefreshTasks.removeAll()
        groupMemberProfileRefreshEpochByScopedGroupKey.removeAll()
        retireStickerManifestRequests() // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111
        stickerStore.resetRuntime()
        stickerMessageAssetStore.reset() // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110
        resolvingStickerMessageFileAssetKeys.removeAll()
        failedStickerMessageFileAssetKeys.removeAll()
        // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112: reset clears both scoped contact identity projections before publishing.
        contactStore.reset() // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110: also clears group self profiles.
        loginLogStore.reset() // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110
        conversationStore.reset()
        enterpriseDirectoryStore.reset() // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110
        invalidateMyInviteCodeState()
        clearTenantClientPolicy()
        organizationDirectoryStore.reset() // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110
        clearTenantScopedSearchState(reason: "remote_data_reset") // WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110
        releaseCallLifecycle(as: .ended, reason: "session_reset")
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopAllCallPrompts()
        callStore.reset()
        directCallAttempts.removeAll()
        directCallResourceOwners.removeAll()
        directCallCleanupObligations.removeAll()
        rtcTerminalMarkersByCallID.removeAll()
        presentedVideoTerminalCallIDs.removeAll()
        voipPushPayloadsByCallID.removeAll()
        busyRejectedIncomingCallIDs.removeAll()
        releaseAudioSessionForVoiceCall()
    }

    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
    func refreshMyInviteCode(force: Bool = false) async {
        guard isAuthenticated, apiContext.hasIMSession else {
            invalidateMyInviteCodeState()
            return
        }
        let snapshot = inviteCodeStore.snapshot
        guard force || (!snapshot.isLoading && snapshot.code == nil && snapshot.errorMessage == nil) else {
            return
        }
        let context = apiContext
        let authority = myInviteCodeAuthorityKey(for: context)
        let requestID = inviteCodeStore.beginRefresh()
        defer { inviteCodeStore.finishRefresh(requestID) }
        do {
            let inviteCode = try await api.myInviteCode(context: context)
            guard isCurrentMyInviteCodeRequest(requestID, authority: authority) else { return }
            guard inviteCode.matchesAuthority(
                tenantID: context.tenantID ?? "",
                imUID: context.imUID ?? ""
            ) else {
                throw IMAPIError.businessForbidden(
                    code: "request_identity_mismatch",
                    message: "当前登录身份与邀请码不匹配",
                    error: nil
                )
            }
            inviteCodeStore.completeRefresh(requestID, code: inviteCode, errorMessage: nil)
        } catch {
            guard isCurrentMyInviteCodeRequest(requestID, authority: authority) else { return }
            inviteCodeStore.completeRefresh(requestID, code: nil, errorMessage: myInviteCodeUserFacingError(error))
        }
    }
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END

    func activateMyInviteCodeForCurrentSession() {
        guard isAuthenticated, apiContext.hasIMSession else {
            invalidateMyInviteCodeState()
            return
        }
        Task { [weak self] in
            await self?.refreshMyInviteCode()
        }
    }

    func reconcileMyInviteCodeAuthority(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        guard myInviteCodeAuthorityKey(for: oldContext) != myInviteCodeAuthorityKey(for: newContext) else {
            return
        }
        invalidateMyInviteCodeState()
    }

    private func invalidateMyInviteCodeState() {
        inviteCodeStore.reset() // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110
    }

    private func myInviteCodeAuthorityKey(for context: IMAPIContext) -> String {
        let storedSessionID = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionDiscriminator: String
        if !storedSessionID.isEmpty {
            sessionDiscriminator = "session=\(storedSessionID)"
        } else {
            sessionDiscriminator = "token=\((context.imToken ?? "").hashValue)"
        }
        return "\(remoteDataScopeKey(for: context))|\(sessionDiscriminator)"
    }

    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
    private func isCurrentMyInviteCodeRequest(_ requestID: UUID, authority: String) -> Bool {
        isAuthenticated
            && apiContext.hasIMSession
            && inviteCodeStore.ownsRefresh(requestID)
            && myInviteCodeAuthorityKey(for: apiContext) == authority
    }
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END

    private func myInviteCodeUserFacingError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "获取邀请码超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed:
                return "网络连接不可用，请稍后重试"
            default:
                return "网络或服务不可用，请稍后重试"
            }
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .unauthorized:
                return "登录已失效，请重新登录"
            case .forbidden:
                return "当前账号无权限读取邀请码"
            case .businessForbidden(let code, _, _) where code == "forbidden":
                return "当前账号无权限读取邀请码"
            case .businessForbidden(let code, _, _) where code == "request_identity_mismatch":
                return "当前登录身份与请求不匹配，请重新登录后再试"
            case .emptyResponse:
                return "邀请码接口未返回有效数据，请刷新重试"
            default:
                break
            }
        }
        return userFacingError(error)
    }

    private var hasAuthenticatedRemoteData: Bool {
        !conversationStore.conversations.isEmpty
            || !contacts.isEmpty
            || !groups.isEmpty
            || !inboxItems.isEmpty
    }

}

// WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
@MainActor
final class PersonalInviteCodeStore {
    struct Snapshot: Equatable {
        var code: RemoteMyInviteCode?
        var isLoading = false
        var errorMessage: String?
    }

    @Published private(set) var snapshot = Snapshot()
    private var activeRefreshID: UUID?

    func beginRefresh() -> UUID {
        let id = UUID()
        activeRefreshID = id
        if !snapshot.isLoading {
            snapshot.isLoading = true
        }
        return id
    }

    func ownsRefresh(_ id: UUID) -> Bool {
        activeRefreshID == id
    }

    func completeRefresh(_ id: UUID, code: RemoteMyInviteCode?, errorMessage: String?) {
        guard ownsRefresh(id) else { return }
        activeRefreshID = nil
        snapshot = Snapshot(code: code, errorMessage: errorMessage)
    }

    func finishRefresh(_ id: UUID) {
        guard ownsRefresh(id) else { return }
        activeRefreshID = nil
        snapshot.isLoading = false
    }

    func reset() {
        activeRefreshID = nil
        if snapshot != Snapshot() {
            snapshot = Snapshot()
        }
    }
}
// WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
