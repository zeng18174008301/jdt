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

// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_BEGIN
extension AppState {
    var isAuthenticated: Bool { authenticationPresentationStore.authenticated } // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110

    var isAuthLoading: Bool { authenticationPresentationStore.isLoading }

    var isSessionReauthenticationPresented: Bool { sessionReauthenticationStore.snapshot.isPresented }

    var sessionReauthenticationError: String? { sessionReauthenticationStore.snapshot.errorMessage }

    var registrationResolutionState: RegistrationResolutionState? { registrationConfirmationStore.snapshot.resolution }

    var registrationConfirmationTimedOut: Bool { registrationConfirmationStore.snapshot.hasTimedOut }

    var isRegistrationSubmissionBlocked: Bool { registrationConfirmationStore.snapshot.isSubmissionBlocked(isAuthLoading: isAuthLoading) }

    var registrationConfirmationMessage: String { registrationConfirmationStore.snapshot.confirmationMessage }

    var registrationSubmitButtonTitle: String { registrationConfirmationStore.snapshot.submitButtonTitle(isAuthLoading: isAuthLoading) }

    var rememberLoginCredentialsEnabledForAuthUI: Bool { rememberLoginPresentationStore.isEnabled }

    var biometricProtectionSettings: BiometricProtectionSettings { biometricAccessStore.snapshot.settings }

    var isRestoringSession: Bool { bootstrapPresentationStore.launch.isRestoringSession }

    var isShowingLaunchSplash: Bool { bootstrapPresentationStore.launch.isShowingLaunchSplash }

    var isInitialDataLoading: Bool { bootstrapPresentationStore.sync.isInitialDataLoading }

    var isLoadingMoreConversations: Bool { bootstrapPresentationStore.sync.isLoadingMoreConversations }

    var isConversationSnapshotPartial: Bool { bootstrapPresentationStore.sync.isConversationSnapshotPartial }

    var hasLoadedRemoteSnapshot: Bool { bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot }

    var syncFailureMessage: String? { bootstrapPresentationStore.sync.syncFailureMessage }

    var isSyncRetrying: Bool { bootstrapPresentationStore.sync.isSyncRetrying }

    var authScreen: AuthScreen { authenticationPresentationStore.screen } // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110

    var activeTab: MainTab {
        get { mainTabSelection.activeTab }
        set { mainTabSelection.select(newValue, source: "app_state") }
    }

    var currentEnterprise: Enterprise { enterpriseMembershipStore.snapshot.current }

    var enterprises: [Enterprise] { enterpriseMembershipStore.snapshot.memberships }

    var batchForwardState: BatchForwardState? { batchForwardStore.draft?.state }

    var batchForwardSourceConversationID: String? { batchForwardStore.draft?.sourceConversationID }

    var conversations: [Conversation] {
        conversationStore.conversations
    }

    var contacts: [IMUser] {
        get { contactStore.contacts }
        set { contactStore.contacts = newValue.map(presentationOverlaidUser) }
    }

    var isContactsSyncing: Bool {
        contactStore.isContactsSyncing()
    }

    var contactsSyncErrorMessage: String? {
        contactStore.contactsSyncError()
    }

    var files: [FileItem] {
        get { fileStore.tenantFiles() }
        set { fileStore.replaceTenantFiles(newValue) }
    }

    var isFileSyncing: Bool {
        fileStore.isTenantFilesSyncing()
    }

    var fileSyncErrorMessage: String? {
        fileStore.tenantFilesSyncError()
    }

    var favoriteAssets: [FavoriteAssetItem] { fileStore.favoriteAssetsSnapshot.items }

    var isFavoriteAssetsSyncing: Bool { fileStore.favoriteAssetsSnapshot.isSyncing }

    var favoriteAssetsSyncErrorMessage: String? { fileStore.favoriteAssetsSnapshot.errorMessage }

    var avatarRealtimePresentationRevision: Int64 { avatarSearchPresentationStore.revision }

    var fileUploadConfig: FileUploadConfig {
        get { fileStore.currentUploadConfig() }
        set {
            let previous = fileStore.currentUploadConfig()
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_BEGIN
            fileStore.applyAuthoritativeUploadConfig(newValue, callLicenseScopeKey: callLicenseScopeKey(for: apiContext))
            // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110_END
            if previous.voiceCallEnabled != newValue.voiceCallEnabled
                || previous.voiceCallLicenseKnown != newValue.voiceCallLicenseKnown {
                if currentDirectCallAttempt(for: .voice) != nil {
                    _ = guardCallLicenseForAction(.voice)
                }
                advanceDirectCallCapabilityGeneration(
                    for: .voice,
                    reason: "voice_license_changed"
                )
                if currentDirectCallAttempt(for: .video)?.mediaMode == "audio" {
                    _ = guardCallLicenseForAction(.voice)
                    advanceDirectCallCapabilityGeneration(for: .video, reason: "audio_answer_license_changed")
                }
            }
            if previous.videoCallEnabled != newValue.videoCallEnabled
                || previous.videoCallLicenseKnown != newValue.videoCallLicenseKnown {
                if currentDirectCallAttempt(for: .video)?.mediaMode != "audio",
                   currentDirectCallAttempt(for: .video) != nil || videoCallPreview != nil {
                    _ = guardCallLicenseForAction(.video)
                }
                advanceDirectCallCapabilityGeneration(
                    for: .video,
                    reason: "video_license_changed"
                )
            }
            if previous.voiceCallEnabled, !newValue.voiceCallEnabled {
                clearPendingIncomingCallForLicenseRevocation(kind: .voice)
            }
            if !newValue.videoCallEnabled {
                if previous.videoCallEnabled {
                    clearPendingIncomingCallForLicenseRevocation(kind: .video)
                }
                clearPendingVideoCallForLicenseRevocation()
            }
        }
    }

    var myStickers: [StickerLibraryItem] {
        stickerStore.myStickers
    }

    var officialStickerPacks: [StickerPackItem] {
        stickerStore.officialPacks
    }

    var isStickerManifestRefreshing: Bool {
        stickerStore.isManifestRefreshing
    }

    var stickerManifestErrorMessage: String? {
        stickerStore.manifestErrorMessage
    }

    var stickerOfficialErrorMessage: String? {
        stickerStore.officialErrorMessage
    }

    var isStickerUploading: Bool {
        stickerStore.isUploading
    }

    var stickerUploadProgress: Double? {
        stickerStore.uploadProgress
    }

    var stickerUploadMessage: String? {
        stickerStore.uploadMessage
    }

    var friendRequests: [FriendRequest] {
        get { contactStore.friendRequests }
        set { contactStore.friendRequests = newValue.map(avatarRealtimeOverlaidFriendRequest) }
    }

    var blacklist: [BlacklistItem] {
        get { contactStore.blacklist }
        set { contactStore.blacklist = newValue }
    }

    var contactRemarks: [String: String] {
        get { contactStore.remarks }
        set { contactStore.remarks = newValue }
    }

    var inboxItems: [InboxItem] {
        get { contactStore.inboxItems }
        set { contactStore.inboxItems = newValue }
    }

    var deviceSessions: [DeviceSession] {
        get { contactStore.deviceSessions }
        set { contactStore.deviceSessions = newValue }
    }

    var groups: [GroupInfo] {
        get { contactStore.groups }
        set {
            contactStore.groups = newValue.map { group in
                var next = group
                next.members = group.members.map(presentationOverlaidUser)
                next.admins = group.admins.map(presentationOverlaidUser)
                return next
            }
        }
    }

    var groupAnnouncements: [String: [GroupAnnouncement]] {
        get { contactStore.groupAnnouncements }
        set { contactStore.groupAnnouncements = newValue }
    }

    var currentGroupAnnouncements: [String: GroupAnnouncement] {
        get { contactStore.currentGroupAnnouncements }
        set { contactStore.currentGroupAnnouncements = newValue }
    }

    var groupJoinRequests: [String: [GroupJoinRequest]] {
        get { contactStore.groupJoinRequests }
        set {
            contactStore.groupJoinRequests = newValue.mapValues {
                $0.map(avatarRealtimeOverlaidGroupJoinRequest)
            }
        }
    }

    var groupInviteApprovalProcessingIDs: Set<String> {
        contactStore.processingGroupInviteApprovalIDs()
    }

    var conversationHistoryLoadingIDs: Set<String> {
        conversationStore.historyLoadingConversationIDs()
    }

    var conversationHistoryMessages: [String: String] {
        conversationStore.historyMessagesByConversationID()
    }

    var directConversationDisabledMessages: [String: String] {
        conversationStore.directDisabledMessagesByConversationID()
    }

    var applyingFriendFromConversationIDs: Set<String> {
        conversationStore.applyingFriendConversationIDs()
    }

    var enterpriseSwitchCompletionRevision: UInt64 { loginWorkspacePresentationStore.switchCompletionRevision } // WDT_IOS1_REFACTOR_ENTERPRISE_SWITCH_COMPLETION_OBSERVATION_20261110

    var toast: String? { toastPresentationStore.message } // WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110

    var activeSplashOverlay: SplashOverlayPresentation? { splashOverlayStore.snapshot.presentation }

    var currentAppPolicy: RemoteAppCurrentPolicy? { appPolicyPresentationStore.snapshot.currentAppPolicy }

    var currentAppPolicyErrorMessage: String? { appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage }

    var hasResolvedCurrentAppPolicyForAuthUI: Bool { appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI }

    var isPhoneAuthDisabledByServer: Bool { appPolicyPresentationStore.snapshot.isPhoneAuthDisabledByServer }

    var myInviteCode: RemoteMyInviteCode? { inviteCodeStore.snapshot.code }

    var isMyInviteCodeLoading: Bool { inviteCodeStore.snapshot.isLoading }

    var myInviteCodeErrorMessage: String? { inviteCodeStore.snapshot.errorMessage }

    var tenantDeviceMultiplicityPolicyState: TenantDeviceMultiplicityPolicyState { tenantDevicePolicyPresentationStore.multiplicity }

    var organizationTree: RemoteOrganizationTree? { organizationDirectoryStore.snapshot.tree }

    var organizationSyncErrorMessage: String? { organizationDirectoryStore.snapshot.errorMessage }

    var isOrganizationManagementSaving: Bool { organizationDirectoryStore.isManagementSaving } // WDT_IOS1_REFACTOR_ORGANIZATION_MANAGEMENT_OBSERVATION_20261110

    var forcedAppPolicyAuthPrompt: AppPolicyForcedAuthRequirement? { forcedAppPolicyAuthStore.snapshot.prompt }

    var forcedAppPolicyAuthDestination: AppPolicyForcedAuthRequirement? { forcedAppPolicyAuthStore.snapshot.destination }

    var incomingVoiceCall: IncomingVoiceCall? {
        get { callStore.incomingVoiceCall }
        set {
            let previousCallID = callStore.incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var next = newValue
            if var value = next {
                value.caller = presentationOverlaidUser(value.caller)
                next = value
            }
            let nextCallID = next?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if next == nil || nextCallID != previousCallID || next?.id != callStore.incomingVoiceCall?.id {
                callStore.incomingCallAnswerMode = nil
                callStore.incomingCallAnswerOperationID = nil
            }
            callStore.incomingVoiceCall = next
        }
    }

    var incomingCallAnswerMode: String? {
        get { callStore.incomingCallAnswerMode }
        set { callStore.incomingCallAnswerMode = newValue }
    }

    var activeVoiceCall: VoiceCallSession? {
        get { callStore.activeVoiceCall }
        set {
            var nextValue = newValue
            if var value = nextValue {
                value.peer = presentationOverlaidUser(value.peer)
                nextValue = value
            }
            let currentCallID = callStore.activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextCallID = nextValue?.callID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if nextCallID == nil || currentCallID != nextCallID {
                callStore.isEndingActiveCall = false
                callStore.activeCallEndError = nil
                stopRTCMediaStateHeartbeat(reason: nextCallID == nil ? "call_cleared" : "call_changed")
            }
            callStore.activeVoiceCall = nextValue
        }
    }

    var presentedCallSession: VoiceCallSession? {
        get {
            guard let call = activeVoiceCall else { return nil }
            if call.isVideoCall, call.isMinimized {
                return nil
            }
            return call
        }
        set {
            if newValue == nil,
               activeVoiceCall?.isVideoCall == true,
               activeVoiceCall?.isMinimized == true {
                return
            }
            activeVoiceCall = newValue
        }
    }

    var videoCallPreview: VideoCallPreview? {
        get { callStore.videoCallPreview }
        set {
            var next = newValue
            if var value = next {
                value.peer = presentationOverlaidUser(value.peer)
                next = value
            }
            callStore.videoCallPreview = next
        }
    }

    var videoCallTerminalResult: VideoCallTerminalResult? {
        get { callStore.videoCallTerminalResult }
        set { callStore.videoCallTerminalResult = newValue }
    }

    var calls: [CallRecord] {
        get { callStore.calls }
        set {
            ensureCallRecordPersistenceBindingIfNeeded()
            guard hasCurrentCallRecordBinding() else { return }
            callStore.calls = newValue.map(avatarRealtimeOverlaidCallRecord)
        }
    }

    var isStartingVoiceCall: Bool {
        get { callStore.isStartingVoiceCall }
        set { callStore.isStartingVoiceCall = newValue }
    }

    var isStartingVideoCall: Bool {
        get { callStore.isStartingVideoCall }
        set { callStore.isStartingVideoCall = newValue }
    }

    var isEndingActiveCall: Bool {
        get { callStore.isEndingActiveCall }
        set { callStore.isEndingActiveCall = newValue }
    }

    var activeCallEndError: String? {
        get { callStore.activeCallEndError }
        set { callStore.activeCallEndError = newValue }
    }

    var certificationPresentationRevision: Int { certificationPresentationStore.contentRevision }

    var currentUser: IMUser { currentUserPresentationStore.user }

    var loginLogs: [LoginLog] { loginLogStore.logs }

    var isLoginLogsLoading: Bool { loginLogStore.isLoading }

    var loginLogsLoadFailed: Bool { loginLogStore.loadFailed }

    var isDepartmentFeatureEnabled: Bool {
        organizationDirectoryStore.snapshot.departmentEnabled(appPolicyEnabled: currentAppPolicy?.departmentEnabled == true)
    }

    func departmentSummary(for user: IMUser, fullPath: Bool = false) -> String? {
        departmentSummary(for: user, fullPath: fullPath, directory: organizationDirectoryStore.snapshot)
    }

    func organizationMembers(for departmentID: String) -> [IMUser] {
        organizationDirectoryStore.snapshot.members(for: normalizedOrganizationDepartmentID(departmentID))
    }

    var rtcCapabilityAlertMessage: String? { rtcCapabilityAlertStore.message }

    var activeRealtimeConversationID: String? {
        get { remoteSyncEngine.currentActiveRealtimeConversationID() }
        set { remoteSyncEngine.updateActiveRealtimeConversationID(newValue) }
    }

    var isRealtimeConnected: Bool {
        get { remoteSyncEngine.isRealtimeConnectionActive() }
        set { remoteSyncEngine.updateRealtimeConnectionState(isConnected: newValue) }
    }

    var stickerMessageFileAssets: [String: StickerResolvedFileAsset] { stickerMessageAssetStore.snapshot.files }

    var isVoiceMediaClientAvailable: Bool {
        #if DEBUG
        if let voiceMediaClientAvailableOverride {
            return voiceMediaClientAvailableOverride
        }
        #endif
        return voiceMediaClient.isAvailable
    }

    var pendingFriendRequestCount: Int {
        friendRequests.filter(\.isPendingIncoming).count
    }
    // WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110_BEGIN
#if DEBUG
    var licenseQuotaRegistrationPrefill: LicenseQuotaRegistrationPrefill? {
        guard licenseQuotaScreenshotScenario == .registration
                || registrationResolutionScreenshotScenario == .pending
                || registrationResolutionScreenshotScenario == .timeout else { return nil }
        return LicenseQuotaRegistrationPrefill(
            enterpriseCode: "WXT900033",
            account: "ACCOUNT_PLACEHOLDER",
            password: "PASSWORD_PLACEHOLDER"
        )
    }
#endif
    // WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110_END
}
// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_END
