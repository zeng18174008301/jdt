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

// JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：认证资料重复 ensure 日志节流，可整体撤回
#if DEBUG
final class CertificationEnsureLogThrottle: @unchecked Sendable {
    static let shared = CertificationEnsureLogThrottle()

    private let lock = NSLock()
    private let intervalNanoseconds: UInt64 = 1_500_000_000
    private var lastLoggedAtByKey: [String: UInt64] = [:]
    private var suppressedCountByKey: [String: Int] = [:]

    func log(requested: Int, unresolved: Int, queueable: Int) {
        let key = "\(requested)|\(unresolved)|\(queueable)"
        let now = DispatchTime.now().uptimeNanoseconds
        let suppressedCount: Int

        lock.lock()
        if let lastLoggedAt = lastLoggedAtByKey[key],
           now >= lastLoggedAt,
           now - lastLoggedAt < intervalNanoseconds {
            suppressedCountByKey[key, default: 0] += 1
            lock.unlock()
            return
        }
        suppressedCount = suppressedCountByKey.removeValue(forKey: key) ?? 0
        lastLoggedAtByKey[key] = now
        lock.unlock()

        if suppressedCount > 0 {
            NSLog("[JHT Certification] stage=ensure requested=%d unresolved=%d queueable=%d suppressed=%d", requested, unresolved, queueable, suppressedCount)
        } else {
            NSLog("[JHT Certification] stage=ensure requested=%d unresolved=%d queueable=%d", requested, unresolved, queueable)
        }
    }
}
#endif
// JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束

// AppState is the MainActor boundary for UI state coordination. Keep state
// writes, Published updates, and Store mutations here; move pure parsing,
// mapping, formatting, and transport-specific helpers into Core/AppSupport.
@MainActor
final class AppState: ObservableObject {
    static let globalMutedMessage = globalMutedMessageText
    static let groupMemberMutedMessage = groupMemberMutedMessageText
#if DEBUG
    let captchaLogger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "captcha")
#endif
    @Published var avatarStage4ScreenshotScenario: AvatarStage4ScreenshotScenario?
    @Published var groupLifecycleScreenshotScenario: GroupLifecycleScreenshotScenario?
    @Published var groupHistoryVisibilityScreenshotScenario: GroupHistoryVisibilityScreenshotScenario?
    @Published var globalPolicyScreenshotScenario: GlobalPolicyScreenshotScenario?
#if DEBUG
    @Published var licenseQuotaScreenshotScenario: LicenseQuotaScreenshotScenario?
    @Published var registrationResolutionScreenshotScenario: RegistrationResolutionScreenshotScenario?

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

    // MARK: - Published State

    @Published var isAuthenticated = false {
        didSet {
            if isAuthenticated {
                abandonRegistrationConfirmationForAuthenticatedSession()
            }
            // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
            syncAccessDiagnosticsActivationScope()
            // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
            syncIOSRiskTelemetrySession()
            if !isAuthenticated {
                cancelSessionReauthentication()
                postLoginWorkbenchAdmission.reset()
                emojiPickerCatalogRuntime.reset()
                stopRTCMediaStateHeartbeat(reason: "logout")
                resetRTCDeviceCapabilityReportState()
            } else {
                scheduleRTCDeviceCapabilitiesReportIfNeeded()
            }
        }
    }
    @Published var isAuthLoading = false
    @Published var isSessionReauthenticationPresented = false
    @Published var isSessionReauthenticating = false
    @Published var sessionReauthenticationError: String?
    var sessionReauthenticationID: UUID?
    var sessionReauthenticationContext: IMAPIContext?
    // Synchronous, exact old/new authority pair; never held across an await.
    var sessionReauthenticationCommit: (old: IMAuthSessionFence, new: IMAuthSessionFence)?
    @Published var registrationResolutionState: RegistrationResolutionState?
    @Published var registrationConfirmationTimedOut = false

    // Block the active submission and confirmation, not an expired or historical receipt.
    var isRegistrationSubmissionBlocked: Bool {
        isAuthLoading || (registrationResolutionState == .pending && !registrationConfirmationTimedOut)
    }

    var registrationConfirmationMessage: String {
        registrationConfirmationTimedOut
            ? RegistrationConfirmationPolicy.timeoutMessage
            : RegistrationConfirmationPolicy.pendingMessage
    }

    var registrationSubmitButtonTitle: String {
        if isAuthLoading { return "正在注册…" }
        return isRegistrationSubmissionBlocked ? "正在确认…" : "注册并继续"
    }
    @Published var rememberLoginCredentialsEnabledForAuthUI = false
    @Published var isClearingApplicationCache = false
    @Published var biometricProtectionSettings: BiometricProtectionSettings = .disabled
    @Published var biometricAccessRevision: UInt64 = 0
    @Published var biometricAuthorizedAccessTokens: [BiometricProtectedSurface: String] = [:]
    // Changes only when the authenticated/settings identity changes. Scene lifecycle is
    // intentionally excluded because presenting LocalAuthentication makes the scene inactive.
    var biometricAuthorizationRevision: UInt64 = 0
    @Published var isRestoringSession = false
    @Published var isShowingLaunchSplash = false
    @Published var isInitialDataLoading = false
    @Published var isLoadingMoreConversations = false
    @Published var isConversationSnapshotPartial = false
    @Published var hasLoadedRemoteSnapshot = false
    @Published var authScreen: AuthScreen = .welcome {
        didSet {
            normalizeAuthScreenForCurrentAppPolicy()
            if (oldValue == .accountRegister || oldValue == .phoneRegister),
               authScreen != .accountRegister, authScreen != .phoneRegister {
                cancelRegistrationSessionRecovery()
            }
            // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：挑战页被路由切走时废弃临时凭据并围栏迟到响应
            if oldValue == .tenantCodeChallenge,
               authScreen != .tenantCodeChallenge,
               loginTenantCodeChallenge != nil {
                retireLoginTenantCodeChallenge(invalidateGeneration: true)
            }
            // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
            // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
            if oldValue != authScreen {
                AccessDiagnostics.shared.resetLogoTapSequence(entry: .loggedOutLoginLogo)
            }
            // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        }
    }
    @Published var preAuthEnterpriseContext: PreAuthEnterpriseContext?
    @Published var isResolvingEnterpriseContext = false
    @Published var enterpriseContextErrorMessage: String?
    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：同名多商户登录挑战只暴露 UI 必需状态，密码仅保留在私有内存态
    @Published var isLoginTenantCodeChallengeActive = false
    @Published var loginTenantCodeChallengeIdentifier = ""
    @Published var loginTenantCodeChallengeErrorMessage: String?
    @Published var isSubmittingLoginTenantCodeChallenge = false
    var loginTenantCodeChallenge: LoginTenantCodeChallenge?
    // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
    @Published var loginWorkspaceSelectionMessage: String?
    @Published var loginDefaultWorkspaceID = ""
    @Published var slideCaptchaPrompt: RemoteSlideCaptchaChallenge?
    let mainTabSelection = MainTabSelectionState()
    var activeTab: MainTab {
        get { mainTabSelection.activeTab }
        set { mainTabSelection.select(newValue, source: "app_state") }
    }
    /// 退群/解散群成功后递增;会话列表监听该值,关闭当前会话页与其上的
    /// 所有操作弹窗,直接回到会话列表。
    @Published var conversationListReturnToken = 0
    @Published var notificationConversationOpenRequest: IOSNotificationConversationOpenRequest?
    @Published var currentEnterprise: Enterprise = Enterprise(id: "pending", name: "正在同步企业", code: "", role: "", status: "同步中", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF) {
        didSet {
            syncIOSRiskTelemetrySession()
        }
    }
    @Published var enterprises: [Enterprise] = []
    let conversationStore: ConversationStore
    let contactStore = ContactStore()
    let fileStore = FileStore()
    let stickerStore = StickerStore()
    let callStore = CallStore()
    var emojiPickerCatalogRuntime = EmojiPickerCatalogRuntimeState()
    @Published var batchForwardState: BatchForwardState?
    @Published var batchForwardSourceConversationID: String?
    @Published var forwardingTenantFileIDs: Set<String> = []
    var tenantFileForwardClientMessageIDs: [String: String] = [:]
    var batchForwardSubmissionTask: Task<Void, Never>?
    var batchForwardSubmissionGeneration: UInt64 = 0
    @Published var playingVoiceMessageID: String?
    @Published var voiceMessagePlaybackState: VoiceMessagePlaybackState?
    var voiceMessagePlayer: AVAudioPlayer?
    var voiceMessagePlayerDelegate: VoiceMessageAudioPlayerDelegate?
    var voiceMessagePlaybackTimer: Timer?
    var voiceMessagePlayerMessageID: String?
    var voiceMessagePlaybackGeneration: UInt64 = 0
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
    @Published var favoriteAssets: [FavoriteAssetItem] = []
    @Published var isFavoriteAssetsSyncing = false
    @Published var favoriteAssetsSyncErrorMessage: String?
    var favoriteAssetsCollection = FavoriteAssetsCollectionState()
    @Published private(set) var mediaNetworkRecoveryGeneration = 0
    @Published var groupMuteListItemsByGroupID: [String: [GroupMuteListItem]] = [:]
    @Published var groupMuteListLoadingIDs: Set<String> = []
    @Published var groupMuteListMutatingKeys: Set<String> = []
    @Published var groupMuteListErrorMessages: [String: String] = [:]
    @Published var groupMuteMutatingIDs: Set<String> = []
    @Published var groupMuteErrorMessages: [String: String] = [:]
    @Published var cancellingFriendRequestIDs: Set<String> = []
    @Published var groupDescriptionMutatingIDs: Set<String> = []
    @Published var groupOwnerTransferMutatingIDs: Set<String> = []
    var groupOwnerTransferIdempotencyState = GroupOwnerTransferIdempotencyState()
    var groupAnnouncementPrivacyEpoch: UInt64 = 0
    @Published var avatarRealtimePresentationRevision: Int64 = 0
    @Published var presenceConnectivityPresentationRevision: Int64 = 0
    @Published var myGroupNicknamesByScopedGroupKey: [String: String] = [:]
    @Published var myGroupMemberProjectionsByScopedGroupKey: [String: IMUser] = [:]
    var groupMemberProfileGenerationByScopedGroupKey: [String: Int64] = [:]
    var minimumGroupMemberProfileGenerationByScopedGroupKey: [String: Int64] = [:]
    var groupMemberProfileRefreshTasks: [String: Task<Void, Never>] = [:]
    var groupMemberProfileRefreshEpoch: UInt64 = 0
    var groupMemberProfileRefreshEpochByScopedGroupKey: [String: UInt64] = [:]
    let groupDirectoryRefreshGeneration = AuthFlowGenerationState()
    var fileUploadConfig: FileUploadConfig {
        get { fileStore.currentUploadConfig() }
        set {
            let previous = fileStore.currentUploadConfig()
            fileStore.replaceUploadConfig(newValue)
            authoritativeCallLicenseScopeKey = callLicenseScopeKey(for: apiContext)
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
    var contactCardOriginalNamesByScopedUserKey: [String: String] = [:]
    var canonicalFriendUIDsByIdentity: [FriendIdentityKey: Set<String>] = [:]
    var canonicalFriendUIDIdentityScope = ""
    var inboxItems: [InboxItem] {
        get { contactStore.inboxItems }
        set { contactStore.inboxItems = newValue }
    }
    @Published var governanceItems: [GovernanceItem] = []
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
    @Published var enterpriseSearchResults: [Enterprise] = []
    @Published var enterpriseSearchMessage: String?
    @Published var isEnterpriseSearching = false
    @Published var joiningEnterpriseKeys: Set<String> = []
    /// Advances only after an in-app enterprise switch has completed every
    /// generation and remote-scope fence. The presenting chooser owns its
    /// dismissal and observes this success-only signal.
    @Published var enterpriseSwitchCompletionRevision: UInt64 = 0
    @Published var toast: String? {
        didSet {
            scheduleToastDismiss()
        }
    }
    @Published var activeSplashOverlay: SplashOverlayPresentation?
    @Published var splashOverlayRemainingSeconds = 0
    @Published var isSplashOverlaySkippable = false
    var hasMainShellBecomeInteractive = false
    @Published var realNameSubmissionErrorMessage = ""
    @Published var currentAppPolicy: RemoteAppCurrentPolicy?
    @Published var currentAppPolicyErrorMessage: String?
    @Published var hasResolvedCurrentAppPolicyForAuthUI = false
    @Published var isPhoneAuthDisabledByServer = false
    @Published var legalDocManifest: RemoteLegalDocManifest?
    @Published var legalDocErrorMessage: String?
    @Published var isLegalDocRefreshing = false
    @Published var myInviteCode: RemoteMyInviteCode?
    @Published var isMyInviteCodeLoading = false
    @Published var myInviteCodeErrorMessage: String?
    @Published var tenantDepartmentEnabled = false
    @Published var tenantClientPolicy: RemoteTenantClientPolicy?
    @Published var tenantDeviceMultiplicityPolicyState: TenantDeviceMultiplicityPolicyState = .unavailable
    @Published var organizationTree: RemoteOrganizationTree?
    @Published var organizationMembersByDepartmentID: [String: [IMUser]] = [:]
    @Published var isOrganizationSyncing = false
    @Published var isOrganizationManagementSaving = false
    @Published var organizationSyncErrorMessage: String?
    @Published var forcedAppPolicyAuthPrompt: AppPolicyForcedAuthRequirement?
    @Published var forcedAppPolicyAuthDestination: AppPolicyForcedAuthRequirement?
    // MARK: - Private Runtime State

    private var storeCancellables: Set<AnyCancellable> = []
    // JHT_MOD_BEGIN APPSTATE_DOMAIN_STORE_CHANGE_COALESCE_PERF_20260912 - 修改开始：合并子 Store 通知，减少 AppState 全局重算压力
    private var domainStoreObjectWillChangeForwardScheduled = false
    // JHT_MOD_END APPSTATE_DOMAIN_STORE_CHANGE_COALESCE_PERF_20260912 - 修改结束
    var callAudioLifecycleObserverTokens: [NSObjectProtocol] = []
    var forcedAppPolicyAuthScopeKey = ""
    var verificationRequirementAuthorityScopeKey = ""
    var forcedAppPolicyAuthPresentationFence = ForcedAppPolicyAuthPresentationFence()
    var forcedAppPolicyAuthDestinationTransitionTask: Task<Void, Never>?
    var tenantClientPolicyScopeKey = ""
    var groupMemberCountPolicyResolution: GroupMemberCountPolicyResolutionState =
        .unresolved(scope: "", minimumGeneration: 0)
    var groupMemberCountPolicyCheckpoint: ScopedResponseCheckpoint?
    var groupMemberCountPolicyRequestSequence: Int64 = 0
    var groupMemberCountPolicyRefreshTask: Task<Void, Never>?
    var minimumGroupMemberCountPolicyGenerationByScope: [String: Int64] = [:]
    var tenantDevicePolicyRequestGeneration: UInt64 = 0
    var groupMuteMutationSequence: UInt64 = 0
    var groupMuteMutationTokensByScope: [String: UInt64] = [:]
    var groupMuteRealtimeGenerationByScope: [String: Int64] = [:]
    var groupMuteBoundaryRefreshTasks: [String: Task<Void, Never>] = [:]
    @Published var networkBannerVisible = true
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
    @Published var syncFailureMessage: String?
    @Published var isSyncRetrying = false
    @Published var searchInvalidationRevision = 0
    @Published var latestSearchInvalidation: SearchInvalidationEvent?
    @Published var certificationPresentationRevision = 0
    @Published var certificationPresentationScopeRevision = 0

    var suppressCurrentUserIdentityPersistence = false
    @Published var currentUser: IMUser = IMUser(id: "pending", name: "正在同步", title: "", department: "", phone: "", email: "", status: "同步中", enterprise: "正在同步企业", avatarSeed: 0x5D6BFF, badges: []) {
        didSet {
            let overlaid = presentationOverlaidUser(currentUser)
            if overlaid != currentUser {
                currentUser = overlaid
            }
            if !suppressCurrentUserIdentityPersistence {
                persistCurrentUserIdentityIfPossible()
            }
        }
    }
    let tenantPolicy = TenantPolicy(
        messageRetention: "按后台策略",
        fileLimit: "按后台策略",
        groupLimit: "按后台策略",
        deviceLimit: "同步中",
        rateLimit: "按后台策略",
        sensitiveAudit: "按后台策略"
    )
    @Published var loginLogs: [LoginLog] = []
    @Published var isLoginLogsLoading = false
    @Published var loginLogsLoadFailed = false

    var isDepartmentFeatureEnabled: Bool {
        if let organizationEnabled = organizationTree?.departmentEnabled {
            return organizationEnabled
        }
        return currentAppPolicy?.departmentEnabled == true
            || tenantDepartmentEnabled
    }

    func departmentSummary(for user: IMUser, fullPath: Bool = false) -> String? {
        guard isDepartmentFeatureEnabled else { return nil }
        let enriched = departmentEnrichedUser(user)
        if fullPath {
            let path = normalizedDepartmentPathNames(enriched.departmentPathNames, fallbackName: enriched.department)
            if !path.isEmpty {
                return path.joined(separator: " / ")
            }
        }
        let name = enriched.department.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "公司" : name
    }

    func organizationMembers(for departmentID: String) -> [IMUser] {
        organizationMembersByDepartmentID[normalizedOrganizationDepartmentID(departmentID)] ?? []
    }

    let api: IMAPIProtocol
    let registrationNow: @MainActor () -> TimeInterval
    let registrationSleep: @Sendable (TimeInterval) async throws -> Void
    let pendingRegistrationReceiptStore: PendingRegistrationReceiptStore
    var registrationConfirmationTask: Task<Void, Never>?
    var registrationConfirmationGeneration: UInt64 = 0
    var registrationRecoveryReceipt: PendingRegistrationReceipt?
    var registrationRecoveryEntryCode: String?
    var registrationSubmissionTask: Task<Void, Never>?
    var registrationSubmissionID: UUID?
    let biometricAuthenticator: any LocalBiometricAuthenticating
    let biometricDefaults: UserDefaults
    let attachmentDownloadSessionFactory: AttachmentDownloadSessionFactory
    let iosRiskTelemetry: IOSRiskTelemetryController
    let iosSceneCaptureMonitor = IOSSceneCaptureMonitor()
    var iosRiskTelemetrySceneIsActive = false
    var iosRiskTelemetryContextSyncTask: Task<Void, Never>?
    let accessDiscovery: AccessDiscoveryManaging
    var accessDiscoveryRefreshTask: Task<AccessDiscoveryRefreshOutcome, Never>?
    var accessDiscoveryRefreshScope: String?
    var accessDiscoveryRealtimeStartTask: Task<Void, Never>?
    var accessDiscoveryRealtimeStartScope: String?
    var organizationMemberIndex: [String: IMUser] = [:]
    let slideCaptchaService = SlideCaptchaService()
    var slideCaptchaContinuation: CheckedContinuation<SlideCaptchaTicket, Error>?
    let realtimeClient: any RealtimeTransporting
    let voiceMediaClient: any VoiceMediaClient
    let videoMediaClient: any VideoMediaClient
    var voiceMediaEventTask: Task<Void, Never>?
    var videoMediaEventTask: Task<Void, Never>?
    let voiceCallSystem: any VoiceCallSystemIntegrating
    var voiceCallSystemEventTask: Task<Void, Never>?
    var notificationRuntimeObserverID: UUID?
    var deferredNotificationOpenPayloads: [IOSNotificationStatePayload] = []
    var notificationTargetResolutionGeneration: UInt64 = 0
    var registeredStandardPushDeviceRegistrationKeys: Set<String> = []
    var pendingVoIPDeviceRegistration: RemoteDeviceRegistration?
    var registeredVoIPDeviceRegistrationKeys: Set<String> = []
    var registeredStandardPushDeviceIDsByScope: [String: Set<String>] = [:]
    var registeredVoIPPushDeviceIDsByScope: [String: Set<String>] = [:]
    var registeredStandardPushRegistrationsByScope: [String: RemoteDeviceRegistration] = [:]
    var registeredVoIPPushRegistrationsByScope: [String: RemoteDeviceRegistration] = [:]
    var pushDeviceRetirementTasksByScope: [String: Task<Void, Never>] = [:]
    var standardPushRegistrationTasksByScope: [String: Task<Void, Never>] = [:]
    var voipPushRegistrationTasksByScope: [String: Task<Void, Never>] = [:]
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：记录 CallKit 音频会话激活状态，便于判断接听与媒体启动顺序
    var voiceCallSystemAudioSessionActive = false
    var voiceCallSystemAudioSessionGeneration: UInt64 = 0
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    var voipPushPayloadsByCallID: [String: RTCVoIPPushPayload] = [:]
    var busyRejectedIncomingCallIDs: Set<String> = []
    var failedSystemAnsweredCallIDs: Set<String> = []
    var coldLaunchUnsupportedCallIDs: Set<String> = []
    var pendingRTCTerminalCompensations: [String: PendingRTCTerminalCompensation] = [:]
    var rtcTerminalCompensationsInFlight: Set<String> = []
    var rtcTerminalCompensationRetryRequested: Set<String> = []
    var rtcTerminalCompensationGeneration: UInt64 = 0
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    var rtcTerminalCompensationTimerTask: Task<Void, Never>?
    var rtcTerminalCompensationTimerTaskID: UUID?
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    var activeVoiceMediaCallID: String?
    var activeVideoMediaCallID: String?
    var pendingVoiceMediaJoinCallID: String?
    var rtcPeerWaitTerminationCallIDs: Set<String> = []
    var rtcTerminalMarkersByCallID: [String: RTCCallTerminalMarker] = [:]
    var presentedVideoTerminalCallIDs: Set<String> = []
    var stoppedVideoMediaCallIDs: Set<String> = []
    var isApplicationBackgroundedForRTC = false
    var rtcMediaHeartbeatSession: RTCMediaHeartbeatSession?
    var rtcQualityReportingSession: RTCQualityReportingSession?
    var rtcMediaHeartbeatTimerTask: Task<Void, Never>?
    var rtcMediaHeartbeatRenewalTask: Task<Void, Never>?
    var rtcMediaHeartbeatGeneration: UInt64 = 0
    var rtcMediaHeartbeatRenewalGeneration: UInt64?
    var rtcMediaHeartbeatPendingImmediateRenewal = false
    var rtcDeviceCapabilitiesReportedSessionKey: String?
    var rtcDeviceCapabilitiesReportInFlightKeys: Set<String> = []
    var authoritativeCallLicenseScopeKey: String?
    @Published var rtcCapabilityAlertMessage: String?
    var videoPreviewMediaTask: Task<Void, Never>?
    var videoPreviewMediaOwnerID: String?
    var directCallCapabilityGenerations: [DirectCallCapabilityKind: UInt64] = [:]
    var directCallAttempts: [DirectCallCapabilityKind: DirectCallAttempt] = [:]
    var directCallResourceOwners: [String: DirectCallAttempt] = [:]
    var directCallCleanupObligations: [String: DirectCallCleanupObligation] = [:]
    var pendingPhoneBindingChallenge: PendingPhoneBindingChallenge?
    var phoneBindingChallengeIssueGeneration: UInt64 = 0
    let rtcMediaHeartbeatIntervalNanoseconds: UInt64
    let rtcMediaHeartbeatNow: @MainActor () -> Date
    let rtcMediaHeartbeatSleep: @Sendable (UInt64) async throws -> Void
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    let rtcRequestNowNanoseconds: @MainActor () -> UInt64
    let rtcRequestSleep: @Sendable (UInt64) async throws -> Void
    let rtcDiscoveryFailureDelayNanoseconds: [UInt64]
    let rtcTerminalCompensationFailureDelayNanoseconds: [UInt64]
    let rtcTerminalCompensationMaximumAttempts: Int
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    let microphonePermissionDecisionOverride: (() async -> Bool)?
    let videoPermissionDecisionOverride: (() async -> Bool)?
    let remoteSyncEngine: any SyncEngine
    // Finite closed-value set: identical failures do not produce an unbounded
    // new log stream. A successful endpoint result permits a later incident.
    private var reportedSyncFailures = Set<SyncFailureDiagnostic>()
#if DEBUG
    var syncFailureDiagnosticObserverForTesting: ((SyncFailureDiagnostic) -> Void)?

    func refreshTenantProfileForSyncDiagnosticsTesting() async {
        guard let session = remoteSyncEngine.currentRemoteSnapshotRefreshSession() else { return }
        await refreshTenantProfileInBackground(
            context: apiContext, scope: remoteDataScopeKey(for: apiContext), refreshSession: session
        )
    }
#endif

    func recordSyncFailureDiagnostic(
        _ error: Error, endpoint: SyncFailureDiagnostic.Endpoint,
        recovery: SyncFailureDiagnostic.Recovery = .notApplicable,
        httpFailure: SyncFailureDiagnostic.Failure? = nil
    ) {
        let classified = SyncFailureDiagnostic.Failure(error: error)
        let event = SyncFailureDiagnostic(endpoint: endpoint, failure: classified == .other ? (httpFailure ?? classified) : classified, recovery: recovery)
        guard reportedSyncFailures.insert(event).inserted else { return }
        event.persist()
#if DEBUG
        syncFailureDiagnosticObserverForTesting?(event)
#endif
    }

    func clearSyncFailureDiagnostics(for endpoint: SyncFailureDiagnostic.Endpoint) {
        reportedSyncFailures = reportedSyncFailures.filter { $0.endpoint != endpoint }
    }
    let rememberedLoginCredentialStore: any RememberedLoginCredentialPersisting
    let rememberedLoginPreferenceStore: any RememberedLoginPreferencePersisting
    let protectedSessionStore: any IMProtectedSessionStoring
    let registrationSessionStore: any IMProtectedSessionStoring
    var coldLaunchSessionRecoveryTask: Task<Void, Never>?
    var foregroundAuthSessionRefreshSchedulerTask: Task<Void, Never>?
    var apiContext: IMAPIContext {
        didSet {
            if oldValue.hasIMSession != apiContext.hasIMSession
                || callRecordDataScopeKey(for: oldValue) != callRecordDataScopeKey(for: apiContext) {
                // Detach before any new-principal callback can persist old rows.
                callStore.clearCallRecordPersistenceBinding()
            }
            if IMAPIContext.normalizedIOSAppID(oldValue.appID) != IMAPIContext.normalizedIOSAppID(apiContext.appID)
                || oldValue.deviceID != apiContext.deviceID {
                cancelRegistrationSessionRecovery()
            }
            biometricAccessRevision &+= 1
            biometricAuthorizationRevision &+= 1
            revokeBiometricProtectedAccess()
            biometricProtectionSettings = BiometricProtectionStore.load(
                context: apiContext,
                defaults: biometricDefaults
            )
            reconcileTenantContextRoleAuthority(from: oldValue, to: apiContext)
            reconcileTenantDevicePolicyAuthority(from: oldValue, to: apiContext)
            reconcileMyInviteCodeAuthority(from: oldValue, to: apiContext)
            reconcileCertificationIdentityScope(from: oldValue, to: apiContext)
            reconcileAvatarRealtimeScope(from: oldValue, to: apiContext)
            reconcilePresenceConnectivityScope(from: oldValue, to: apiContext)
            reconcileCurrentProfileAuthorityScope(from: oldValue, to: apiContext)
            reconcileLocalMessageScope(from: oldValue, to: apiContext)
            if sessionReauthenticationCommit == nil,
               oldValue.authSessionFence != apiContext.authSessionFence,
               isSessionReauthenticationPresented {
                cancelSessionReauthentication()
            }
            if RememberedLoginCredentialScope(context: oldValue) != RememberedLoginCredentialScope(context: apiContext) {
                pendingRememberedLoginAttempt = nil
                reloadRememberedLoginCredentialsForCurrentScope()
            }
            let previousPhoneBindingScope = PhoneBindingChallengeSessionScope(context: oldValue)
            let currentPhoneBindingScope = PhoneBindingChallengeSessionScope(context: apiContext)
            if previousPhoneBindingScope != currentPhoneBindingScope {
                invalidatePhoneBindingChallenge(ownedBy: previousPhoneBindingScope)
            }
            // WDT_RTC_IOS1_AUTODROP_20260921_BEGIN: refresh cleanup credentials before direct-call invalidation checks.
            reconcileDirectCallCleanupContexts(from: oldValue, to: apiContext)
            // WDT_RTC_IOS1_AUTODROP_20260921_END
            if DirectCallContextBinding(context: oldValue) != DirectCallContextBinding(context: apiContext) {
                if oldValue.accountID != apiContext.accountID
                    || oldValue.sessionEpoch != apiContext.sessionEpoch
                    || callLicenseScopeKey(for: oldValue) != callLicenseScopeKey(for: apiContext) {
                    authoritativeCallLicenseScopeKey = nil
                }
                rtcCapabilityAlertMessage = nil
                advanceDirectCallCapabilityGeneration(
                    for: .voice,
                    reason: "call_session_changed"
                )
                advanceDirectCallCapabilityGeneration(
                    for: .video,
                    reason: "call_session_changed"
                )
                resetRTCDeviceCapabilityReportState()
                scheduleIOSRiskTelemetryContextSync()
            }
            reconcileRTCMediaStateHeartbeatContextChange(from: oldValue, to: apiContext)
            // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
            syncAccessDiagnosticsActivationScope()
            // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        }
    }
    var certificationIdentityRoot = CertificationIdentityRoot()
    var certificationSessionGeneration: Int64 = 0
    let certificationRealtimeGeneration: Int64 = 0
    var certificationProfileRequestSequence: Int64 = 0
    var pendingCertificationProfileUIDs: Set<String> = []
    var certificationProfileRefreshTask: Task<Void, Never>?
    var certificationProfileRequestFence = CertificationProfileRequestFence()
    var avatarRealtimeProjection = AvatarRealtimeProjection()
    var avatarLocalCommitAuthorityFence = AvatarLocalCommitAuthorityFence()
    var presenceConnectivityProjection = PresenceConnectivityProjection()
    var pendingAvatarAuthorityUIDs: Set<String> = []
    var avatarAuthorityRefreshTask: Task<Void, Never>?
    var avatarAuthorityRequestSequence: Int64 = 0
    var contactsPostApplyReconciliationTask: Task<Void, Never>?
    var contactsPostApplyReconciliationGeneration: UInt64 = 0
#if DEBUG
    var avatarRealtimeAssetResolutionCountForTesting = 0
#endif
    var currentAppPolicyExpiresAt: Date?
    var myInviteCodeRequestSequence: UInt64 = 0
    var myInviteCodeLoadingRequestSequence: UInt64?
    var tenantContextRoleAuthority: TenantContextRoleAuthority?
    var currentProfileAuthorityFence = CurrentProfileAuthorityFence()
    var groupMemberPageLoadingKeys: Set<String> = []
    var pendingForcedRemoteSnapshotSuccessorScopes: Set<String> = []
    var realtimeIngestBuffer = RealtimeMessageIngestBuffer()
    var realtimeIngestFlushTask: Task<Void, Never>?
    var deliveryAckHighWaterByScope: [String: Int64] = [:]
    var deliveryAckTasksByScope: [String: Task<Void, Never>] = [:]
    // JHT_MOD_BEGIN DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改开始：送达回执全量扫描改为可取消分片，避免主线程连续卡顿
    var deliveryAckSweepTask: Task<Void, Never>?
    var deliveryAckSweepGeneration: UInt64 = 0
    // JHT_MOD_END DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改结束
    var messageSequenceRecoveryTargets: [String: ConversationStore.MessageSequenceRecoveryTarget] = [:]
    var messageSequenceRecoveryRetryTasks: [String: Task<Void, Never>] = [:]
    var messageSequenceRecoveryAttempts: [String: Int] = [:]
    var isFlushingRealtimeIngest = false
    var groupHistoryBoundaryGenerationTracker = GroupHistoryBoundaryGenerationTracker()

    var currentAppID: String {
        IMAPIContext.normalizedIOSAppID(apiContext.appID)
    }

    var avatarImageRouteContext: AvatarImageRouteContext? {
        guard let client = api as? IMAPIClient,
              let route = client.runtimeTenantBinaryRouteContext(context: apiContext) else {
            return nil
        }
        let capturedContext = apiContext
        let authorityID = "\(route.appID)|\(route.tenantID)"
        let routeBases = route.activeBases + route.standbyBases
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak client] in
            guard let self, let client,
                  self.apiContext.appID == route.appID,
                  self.apiContext.tenantID == route.tenantID,
                  let current = client.runtimeTenantBinaryRouteContext(context: self.apiContext) else {
                return false
            }
            return current.appID == route.appID
                && current.tenantID == route.tenantID
                && current.revision == route.revision
        }
        return AvatarImageRouteContext(
            authorityID: authorityID,
            revision: route.revision,
            routeBases: routeBases,
            fetcher: { [weak client] relativePath in
                guard let client, isCurrent() else { throw CancellationError() }
                let result = try await client.fetchRuntimeTenantBinary(
                    relativePath,
                    context: capturedContext
                )
                guard isCurrent() else { throw CancellationError() }
                return result.data
            },
            authorityCheck: isCurrent
        )
    }

    func groupAvatarCacheKey(
        groupID: String,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) -> String {
        guard let request = TenantRelativeImageURLResolver.request(
            avatarURL,
            routeContext: avatarImageRouteContext
        ), case let .tenantRelative(path) = request else {
            return ""
        }
        let memberID = (apiContext.imUID ?? currentUser.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupAvatarCacheIdentity.cacheKey(
            groupID: groupID,
            memberID: memberID,
            stableAssetIdentity: path,
            version: avatarVersion,
            updatedAt: avatarUpdatedAt
        )
    }

    func groupAvatarCacheKey(for conversation: Conversation) -> String {
        let channelID = remoteChannelID(for: conversation)
        return groupAvatarCacheKey(
            groupID: channelID.isEmpty ? conversation.id : channelID,
            avatarURL: conversation.avatarURL,
            avatarVersion: conversation.avatarVersion,
            avatarUpdatedAt: conversation.avatarUpdatedAt
        )
    }

    func disableAccessDiagnosticsOverlay() {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        AccessDiagnostics.shared.disablePreservingAllowedPolicy()
    }

    func forceDisableAccessDiagnosticsOverlay() {
        AccessDiagnostics.shared.forceDisable()
    }

    private func prepareAccessDiagnosticsOverlayForLaunch() {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let appID = currentAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else {
            forceDisableAccessDiagnosticsOverlay()
            return
        }
        if let entry = IMAppPolicyLastGoodStore.usable(appID: appID) {
            applyAccessDiagnosticsPolicy(entry.policy, source: "last-good")
            return
        }
        forceDisableAccessDiagnosticsOverlay()
        beginAccessDiagnosticsPolicyFetch(appID: appID)
    }

    func beginAccessDiagnosticsPolicyFetch(appID: String) {
        AccessDiagnostics.shared.record(
            .bootstrapFetching(
                appID: appID,
                bootstrapHost: accessDiagnosticsBootstrapHost,
				fallbackHost: accessDiagnosticsBootstrapFallbackHost
            )
        )
    }

    func applyAccessDiagnosticsPolicy(_ policy: RemoteAppCurrentPolicy, source: String) {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let effectiveAppID = accessDiagnosticsAppID(for: policy)
        AccessDiagnostics.shared.applyPolicy(
            AccessDiagnosticsPolicy(
                appID: effectiveAppID,
                overlayConfiguration: policy.accessDiagnosticsOverlayConfiguration,
                copyEnabled: policy.accessDiagnosticsCopyEnabled
            )
        )
        AccessDiagnostics.shared.record(
            .bootstrapSucceeded(
                appID: effectiveAppID,
                bootstrapHost: accessDiagnosticsBootstrapHost,
				fallbackHost: accessDiagnosticsBootstrapFallbackHost,
                source: source
            )
        )
        (api as? IMAPIClient)?.publishAccessDiagnosticsDomainState()
        if apiContext.hasIMSession {
            recordAccessDiagnosticsMerchantEntered()
        }
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private var currentAccessDiagnosticsActivationScope: AccessDiagnosticsActivationScope? {
        let appID = currentAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return nil }
        guard isAuthenticated, apiContext.hasIMSession else {
            return AccessDiagnosticsActivationScope(
                appID: appID,
                tenantID: nil,
                authPhase: .loggedOut,
                sessionGeneration: 0
            )
        }
        return AccessDiagnosticsActivationScope(
            appID: appID,
            accountID: apiContext.accountID ?? apiContext.imUID ?? currentUser.id,
            tenantID: apiContext.tenantID,
            authPhase: .authenticated,
            sessionGeneration: apiContext.authSessionFence.sessionGeneration,
            deviceID: apiContext.deviceID,
            sessionEpoch: apiContext.sessionEpoch
        )
    }

    private func syncAccessDiagnosticsActivationScope() {
        AccessDiagnostics.shared.updateScope(currentAccessDiagnosticsActivationScope)
    }

    func registerAccessDiagnosticsLogoTap(entry: AccessDiagnosticsActivationEntry) {
        syncAccessDiagnosticsActivationScope()
        guard accessDiagnosticsEntryIsAllowed(entry),
              let scope = currentAccessDiagnosticsActivationScope else {
            AccessDiagnostics.shared.resetLogoTapSequence(entry: entry)
            return
        }
        let transition = AccessDiagnostics.shared.registerLogoTap(entry: entry, scope: scope)
        if transition == .opened {
            replayAccessDiagnosticsCurrentState()
        }
    }

    func resetAccessDiagnosticsLogoTapSequence(entry: AccessDiagnosticsActivationEntry) {
        AccessDiagnostics.shared.resetLogoTapSequence(entry: entry)
    }

    private func accessDiagnosticsEntryIsAllowed(_ entry: AccessDiagnosticsActivationEntry) -> Bool {
        switch entry {
        case .loggedOutLoginLogo:
            return !isAuthenticated
                && [.welcome, .phoneLogin, .accountLogin, .phoneRegister, .accountRegister].contains(authScreen)
        case .loggedInAboutLogo:
            return isAuthenticated && apiContext.hasIMSession
        }
    }

    private func replayAccessDiagnosticsCurrentState() {
        guard AccessDiagnostics.shared.isVisible else { return }
        if let policy = currentAppPolicy {
            applyAccessDiagnosticsPolicy(policy, source: "cache")
        } else {
            beginAccessDiagnosticsPolicyFetch(appID: currentAppID)
            (api as? IMAPIClient)?.publishAccessDiagnosticsDomainState()
            if apiContext.hasIMSession {
                recordAccessDiagnosticsMerchantEntered()
            }
        }
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    private func accessDiagnosticsAppID(for policy: RemoteAppCurrentPolicy) -> String {
        let reportedAppID = policy.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reportedAppID.isEmpty else { return "" }
        return IMAPIContext.normalizedIOSAppID(reportedAppID, allowCustomAppID: true)
    }

	private var accessDiagnosticsBootstrapHost: String {
		if let client = api as? IMAPIClient,
		   let primary = client.configuredAppBootstrapPrimaryBase {
			return primary.host ?? primary.absoluteString
		}
		return api.platformBase.host ?? api.platformBase.absoluteString
    }

	private var accessDiagnosticsBootstrapFallbackHost: String? {
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		guard let client = api as? IMAPIClient else { return nil }
		let candidates = client.configuredAppBootstrapBases.dropFirst().map { base in
			base.host ?? base.absoluteString
		}
		return candidates.isEmpty ? nil : candidates.joined(separator: "、")
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
	}

    private func accessDiagnosticsTenantAPIHost(for context: IMAPIContext? = nil) -> String {
        if let context,
           let url = IMAPIClient.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL) {
            return url.host ?? url.absoluteString
        }
        if let url = IMAPIClient.normalizedTenantAPIBaseURL(apiContext.tenantAPIBaseURL) {
            return url.host ?? url.absoluteString
        }
        return api.tenantBase.host ?? api.tenantBase.absoluteString
    }

    func recordAccessDiagnosticsMerchantResolving(name: String = "当前商户") {
        AccessDiagnostics.shared.record(
            .merchantResolving(name: name, tenantAPIHost: accessDiagnosticsTenantAPIHost())
        )
    }

    func recordAccessDiagnosticsMerchantEntered() {
        let merchantName = currentEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        AccessDiagnostics.shared.record(
            .merchantEntered(
                name: merchantName.isEmpty ? "当前商户" : merchantName,
                tenantAPIHost: accessDiagnosticsTenantAPIHost()
            )
        )
    }

    func recordAccessDiagnosticsDiscoveryFetching(context: IMAPIContext) {
        guard context.hasIMSession else { return }
        AccessDiagnostics.shared.record(.discoveryFetching(tenantAPIHost: accessDiagnosticsTenantAPIHost(for: context)))
    }

    func recordAccessDiagnosticsDiscoveryOutcome(_ outcome: AccessDiscoveryRefreshOutcome) {
        AccessDiagnostics.shared.record(.discoveryOutcome(outcome))
    }

    func recordAccessDiagnosticsRealtimeRequest(_ request: RealtimeConnectionRequest?, context: IMAPIContext) {
        guard context.hasIMSession else { return }
        guard let request else {
            AccessDiagnostics.shared.record(.failed(reason: "实时连接地址不可用"))
            return
        }
        AccessDiagnostics.shared.record(
            .connectionComparing(
                fallbackURL: request.url,
                quicHost: request.quicRequest?.host
            )
        )
    }

    func redactedRealtimeURLSummary(_ url: URL?) -> String {
        guard let url else { return "unavailable" }
        return IMAPIClient.redactedURLString(url, redactAllQueryValues: true)
    }

    func usesLocalRealtimeFallback(context: IMAPIContext) -> Bool {
        Self.isLocalRealtimeFallbackURL(api.webSocketURL(context: context))
    }

    static func isLocalRealtimeFallbackURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else { return false }
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") else {
            return false
        }
        return url.path == "/im/ws"
    }

    private func recordAccessDiagnosticsRealtimeConnected() {
        let snapshot = AccessDiagnostics.shared.snapshot
        AccessDiagnostics.shared.record(
            .connectionSelected(
                currentHost: snapshot.imCurrentHost,
                protocolName: snapshot.connectionProtocol,
                reason: "主链路可用"
            )
        )
    }

    private func recordAccessDiagnosticsRealtimeFallback(context: IMAPIContext, reason: String) {
        let fallbackHost = api.webSocketURL(context: context)?.host ?? api.imBase.host ?? api.imBase.absoluteString
        AccessDiagnostics.shared.record(
            .connectionFallback(
                currentHost: fallbackHost,
                protocolName: "WSS",
                reason: reason
            )
        )
    }

    let authFlowGeneration = AuthFlowGenerationState()
    var postLoginWorkbenchAdmission = PostLoginWorkbenchAdmissionState()
    var pendingRememberedLoginAttempt: PendingRememberedLoginAttempt?
    let enterpriseContextGeneration = AuthFlowGenerationState()
    var lastPreferredEnterpriseCodeAttempt = ""
    let workspaceSwitchGeneration = AuthFlowGenerationState()
    let conversationHistoryLoadThrottleInterval: TimeInterval = 0.85
    /// 每个 historyKey 只允许一次“坏窗口恢复同步”,避免 oldestSeq 始终不可用时
    /// 反复强制拉取最新窗口形成循环。
    var historyWindowRecoverySyncAttemptedKeys: Set<String> = []
    private let toastDismissTasks = ToastDismissTaskStore()
    let launchSplashDismissTasks = LaunchSplashDismissTaskStore()
    var splashOverlayDismissTask: Task<Void, Never>?
    var splashConfigurationRefreshTask: Task<Void, Never>?
    let splashConfigurationRefreshGeneration = AuthFlowGenerationState()
    var didEvaluateInitialSplashOverlay = false
    var didPresentSplashInCurrentActivation = false
    var pendingInitialSplashOverlayEvaluation = false
    var initialSplashOverlayEvaluationStartedAt: Date?
    let splashWarmThresholdSeconds: TimeInterval = 60
    let splashColdEquivalentThresholdSeconds: TimeInterval = 30 * 60
    let initialSplashOverlayRetryWindowSeconds: TimeInterval = 60
    let realtimeReconnectNoticeDelayNanoseconds: UInt64
    let realtimeReconnectNoticeThrottleInterval: TimeInterval
    let realtimeEndpointStableConfirmationDelay: TimeInterval = 30
    var realtimeReconnectNoticeTask: Task<Void, Never>?
    var activeRealtimeConversationRecoveryTask: Task<Void, Never>?
    var realtimeStableConnectionGeneration = 0
    var activeRealtimeConversationID: String? {
        get { remoteSyncEngine.currentActiveRealtimeConversationID() }
        set { remoteSyncEngine.updateActiveRealtimeConversationID(newValue) }
    }
    var conversationSelectionEpochFence = ConversationSelectionEpochFence()
    var appliedSearchInvalidations: [String: SearchInvalidationStamp] = [:]
    var isRealtimeConnected: Bool {
        get { remoteSyncEngine.isRealtimeConnectionActive() }
        set { remoteSyncEngine.updateRealtimeConnectionState(isConnected: newValue) }
    }
    let deviceRevocationHandling = DeviceRevocationHandlingState()
    let realtimeDecoder = JSONDecoder()
    let messageStore: any MessageStore
    let messagePersistence: MessagePersistenceCoordinator
    var localMessageTicket: LocalMessageSessionTicket?
    var durableOutboxRecoveryTask: Task<Void, Never>?
    var attachmentUploadOperations: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    // JHT_MOD_BEGIN ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改开始：前后台切换时恢复图片/文件附件上传任务
    var attachmentForegroundResumeTask: Task<Void, Never>?
    var attachmentForegroundResumeGeneration: UInt64 = 0
    // JHT_MOD_END ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改结束
    var durableReadAckRecoveryTask: Task<Void, Never>?
    var durableReadAckRecoveryGeneration: UInt64 = 0
    var durableReadAckRecoveryRestartRequested = false
    var localMessageSessionGeneration: UInt64 = 1
    var localMessageProjectionRevision: Int64 = 0
    var profileContactRevisionFence = ProfileContactRevisionFence()
    var profileContactRealtimeRefreshTask: Task<Void, Never>?
    var rtcCallRefreshTask: Task<Void, Never>?
    var rtcSignalingRefreshInFlightScope: String?
    var rtcSignalingRefreshPendingScope: String?
    var rtcSignalingWakeTask: Task<Void, Never>?
    var rtcSignalingWakeTaskID: UUID?
    var rtcCallsRefreshInFlightScope: String?
    var rtcEventsRefreshInFlightScope: String?
    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    var rtcRefreshGeneration: UInt64 = 0
    var rtcDiscoveryCallsBackoff = RTCDiscoveryEndpointBackoff()
    var rtcDiscoveryEventsBackoff = RTCDiscoveryEndpointBackoff()
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    let activeRTCCallRefreshIntervalNanoseconds: UInt64 = 1_000_000_000
    let idleRTCCallRefreshIntervalNanoseconds: UInt64 = 20_000_000_000
    var stickerManifestPollTask: Task<Void, Never>?
    var stickerMessageFileAssets: [String: StickerResolvedFileAsset] = [:]
    var resolvingStickerMessageFileAssetKeys: Set<String> = []
    var failedStickerMessageFileAssetKeys: Set<String> = []
    let latestConversationMessageWindowLimit = 20
    let defaultVoiceCallTimeoutSeconds = 60
    let voiceMediaClientUnavailableReason = "当前 iOS 版本暂未接入真实语音媒体，暂不能使用语音通话"
    let videoMediaClientUnavailableReason = "当前设备暂不支持视频通话"
    #if DEBUG
    var voiceMediaClientAvailableOverride: Bool?
    var authPolicyScreenshotModeEnabled = false
    #endif
    var isVoiceMediaClientAvailable: Bool {
        #if DEBUG
        if let voiceMediaClientAvailableOverride {
            return voiceMediaClientAvailableOverride
        }
        #endif
        return voiceMediaClient.isAvailable
    }
    let mainShellSecondarySnapshotDelayNs: UInt64 = 2_200_000_000
    let mainShellGroupsSnapshotDelayNs: UInt64 = 700_000_000
    let mainShellContactsSnapshotDelayNs: UInt64 = 1_300_000_000
    let mainShellHistoryPrefetchDelayNs: UInt64 = 3_000_000_000
    let mainShellGroupBundleDelayNs: UInt64 = 4_500_000_000
    let realtimeRecoveryRecentSnapshotCooldownSeconds: TimeInterval = 3
    var lastRemoteSnapshotPrimarySyncedAt: Date?
    let mainShellBootstrapTrace = MainShellBootstrapTraceState()

    // MARK: - Bootstrap and Common State

    var canUseEnterpriseDirectory: Bool {
        apiContext.hasIMSession
    }

    var hasActiveIMSession: Bool {
        apiContext.hasIMSession
    }

    var visibleForcedAppPolicyAuthPrompt: AppPolicyForcedAuthRequirement? {
        guard isAuthenticated,
              apiContext.hasIMSession,
              forcedAppPolicyAuthDestination == nil,
              forcedAppPolicyAuthPresentationFence.canExposePrompt else { return nil }
        return forcedAppPolicyAuthPrompt
    }

    var visibleForcedAppPolicyAuthDestination: AppPolicyForcedAuthRequirement? {
        guard isAuthenticated, apiContext.hasIMSession else { return nil }
        return forcedAppPolicyAuthDestination
    }

    func updateVisibleForcedAppPolicyAuthPrompt(_ requirement: AppPolicyForcedAuthRequirement?) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        if let requirement {
            presentForcedAppPolicyAuthPrompt(requirement)
        } else {
            forcedAppPolicyAuthPrompt = nil
        }
    }

    @discardableResult
    func beginForcedAppPolicyAuthPromptDeferral() -> UUID {
        let token = forcedAppPolicyAuthPresentationFence.beginPromptDeferral()
        objectWillChange.send()
        return token
    }

    func endForcedAppPolicyAuthPromptDeferral(_ token: UUID) {
        guard forcedAppPolicyAuthPresentationFence.endPromptDeferral(token) else { return }
        objectWillChange.send()
    }

    func updateVisibleForcedAppPolicyAuthDestination(_ requirement: AppPolicyForcedAuthRequirement?) {
        guard isAuthenticated, apiContext.hasIMSession else {
            resetForcedAppPolicyAuthState()
            return
        }
        forcedAppPolicyAuthDestination = requirement
    }

    var isRegistrationTenantCodeRequired: Bool {
        currentAppPolicy?.enterpriseCodeFirst == true
            || currentAppPolicy?.allowDefaultTenantJoin == false
    }

    var isRegistrationEnabledForAuthUI: Bool {
        hasResolvedCurrentAppPolicyForAuthUI && currentAppPolicy?.registrationEnabled == true
    }

    var isEnterpriseCodeFirstForAuthUI: Bool {
        currentAppPolicy?.enterpriseCodeFirst == true
    }

    var hasUsablePreAuthEnterpriseContext: Bool {
        preAuthEnterpriseContext?.matchesIdentity(
            appID: apiContext.appID,
            deviceID: apiContext.deviceID
        ) == true
    }

    var preAuthEnterpriseLogoURL: String {
        guard let context = preAuthEnterpriseContext else { return "" }
        let rawValue = context.tenantLogoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return "" }
        if let absolute = URL(string: rawValue), absolute.scheme != nil {
            return rawValue
        }
        guard let route = Self.freshRuntimeEndpoint(context.runtimeRoutes, service: .tenantAPI),
              let base = URL(string: route),
              let resolved = URL(string: rawValue, relativeTo: base)?.absoluteURL else {
            return ""
        }
        return resolved.absoluteString
    }

    var isPhoneAuthEnabledForAuthUI: Bool {
        PhoneAuthPresentationPolicy.isEnabled(
            policyValue: currentAppPolicy?.phoneAuthEnabled,
            hasResolvedPolicy: hasResolvedCurrentAppPolicyForAuthUI,
            disabledByServer: isPhoneAuthDisabledByServer
        )
    }

    func normalizeAuthScreenForCurrentAppPolicy() {
        if hasResolvedCurrentAppPolicyForAuthUI, !isPhoneAuthEnabledForAuthUI {
            clearRememberedPhoneLoginCredentialsForCurrentPolicy()
        }
        let phoneNormalized = PhoneAuthPresentationPolicy.normalizedScreen(
            authScreen,
            phoneAuthEnabled: isPhoneAuthEnabledForAuthUI
        )
        let normalized: AuthScreen
        if isAuthenticated || apiContext.hasIMSession {
            normalized = phoneNormalized
        } else {
            normalized = EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                phoneNormalized,
                enterpriseCodeFirst: isEnterpriseCodeFirstForAuthUI,
                registrationEnabled: isRegistrationEnabledForAuthUI,
                hasUsableContext: hasUsablePreAuthEnterpriseContext
            )
        }
        if authScreen != normalized {
            authScreen = normalized
        }
    }

    func normalizeAuthScreenForPhoneAuthPolicy() {
        normalizeAuthScreenForCurrentAppPolicy()
    }

    func applyCurrentAppAuthRouting(
        _ policy: RemoteAppCurrentPolicy,
        allowPreferredAutoResolve _: Bool
    ) {
        if !policy.enterpriseCodeFirst {
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        }
        normalizeAuthScreenForCurrentAppPolicy()
        // Enterprise-code-first is an explicit trust boundary. Never acquire or
        // resolve the server's preferred code on behalf of the user.
    }

    var registrationTenantCodeRequirementText: String {
        if isEnterpriseCodeFirstForAuthUI {
            return "当前企业由已验证的企业码上下文绑定，无需再次填写。"
        }
        if isRegistrationTenantCodeRequired {
            return "注册时必须填写企业编码或邀请码"
        }
        if currentAppPolicy == nil {
            return "正在读取应用策略；提交前会自动校验。"
        }
//        return "输入企业编码或邀请码加入已有企业；留空将进入演示企业，立即体验完整功能"
        return "输入企业编码或邀请码加入已有企业；未填写时将进入示例企业，可使用主要功能"
    }

    var isRegistrationTenantCodeRequirementEmphasized: Bool {
        isRegistrationTenantCodeRequired || currentAppPolicy != nil
    }

    var isWorkspaceSwitchDisabledByPolicy: Bool {
        currentAppPolicy?.allowWorkspaceSwitch == false
    }

    func canOpenEnterpriseSwitcher(for enterprise: Enterprise) -> Bool {
        !isWorkspaceSwitchDisabledByPolicy
            && enterprise.canSwitch
            && enterprise.isWorkspaceEnterable
    }

    func enterpriseSwitchDisabledMessage(for enterprise: Enterprise) -> String {
        if isWorkspaceSwitchDisabledByPolicy {
            return "管理员已关闭企业切换"
        }
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enterprise.canSwitch {
            return reason.isEmpty ? "该企业暂不可切换，请联系管理员确认成员状态" : reason
        }
        if !enterprise.isWorkspaceEnterable {
            return reason.isEmpty ? "该企业暂不可进入，请联系管理员确认状态" : reason
        }
        return ""
    }

    var enterpriseDirectoryStatusText: String {
        canUseEnterpriseDirectory ? "企业列表来自服务端企业工作区。" : "请先登录后再搜索、加入或切换企业。"
    }

    func isEnterpriseJoinInProgress(_ enterprise: Enterprise) -> Bool {
        joiningEnterpriseKeys.contains(enterpriseJoinKey(enterprise))
    }

    var canCreateGroupChat: Bool {
        Self.canCreateGroupChat(role: currentEnterprise.role, policy: resolvedTenantClientPolicy)
    }

    nonisolated static func enterpriseRoleCanCreateGroup(_ rawRole: String) -> Bool {
        privilegedRoleCanManageOrganization(rawRole)
    }

    nonisolated static func privilegedRoleCanManageOrganization(_ rawRole: String) -> Bool {
        let normalized = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let compact = normalized.replacingOccurrences(of: "_", with: "")
        let creatableRoles: Set<String> = [
            "internal", "staff", "employee", "admin", "administrator", "manager",
            "super_admin", "superadmin",
            "owner", "creator",
            "tenant_owner", "tenant_admin", "tenant_manager", "tenant_staff",
            "merchant_owner", "merchant_admin", "merchant_manager", "merchant_staff",
            "internal_admin", "internal_staff",
            "platform_admin", "platform_internal",
            "workspace_owner", "workspace_admin",
            "enterprise_owner", "enterprise_admin",
            "company_owner", "company_admin",
            "管理员", "内部人员", "超级管理员", "企业管理员", "商户管理员", "负责人", "所有者"
        ]
        return creatableRoles.contains(normalized) || creatableRoles.contains(compact)
    }

    nonisolated static func canCreateGroupChat(role: String, policy: RemoteTenantClientPolicy?) -> Bool {
        if privilegedRoleCanManageOrganization(role) {
            return true
        }
        return policy?.allowMemberGroupCreation == true
    }

    var canManageOrganizationDepartments: Bool {
        guard isDepartmentFeatureEnabled else { return false }
        if organizationTree?.canManage == true || organizationTree?.canManageDepartment == true {
            return true
        }
        return Self.privilegedRoleCanManageOrganization(currentEnterprise.role)
    }

    nonisolated static func friendApplyResolution(
        outcome: String,
        relationStatus: String,
        status: String,
        directlyEstablished: Bool
    ) -> FriendApplyResolution {
        if directlyEstablished {
            return .established
        }
        let establishedValues: Set<String> = [
            "friend",
            "accepted",
            "established",
            "friendship_established",
            "already_friend"
        ]
        let normalizedValues = [outcome, relationStatus, status].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if normalizedValues.contains(where: establishedValues.contains) {
            return .established
        }
        let terminalValues: Set<String> = [
            "suppressed",
            "application_suppressed",
            "rejected",
            "application_rejected",
            "cancelled",
            "canceled",
            "application_cancelled",
            "expired",
            "application_expired"
        ]
        return normalizedValues.contains(where: terminalValues.contains) ? .terminal : .pending
    }

    nonisolated static func friendApplyResolution(_ result: RemoteFriendApplyResult) -> FriendApplyResolution {
        friendApplyResolution(
            outcome: result.outcome,
            relationStatus: result.relationStatus,
            status: result.status,
            directlyEstablished: result.directlyEstablished
        )
    }

    nonisolated static func isFriendRelationChangedConflictCode(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "friend_relation_changed"
    }

    nonisolated static func isFriendRelationRealtimeEvent(event: String, kind: String) -> Bool {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedKind == "friend_application"
            || normalizedKind == "friend_request"
            || normalizedKind == "friend_relation"
            || normalizedKind == "friend"
            || normalizedEvent == "friend_application.created"
            || normalizedEvent == "friend_application.reviewed"
            || normalizedEvent == "friend_application.rejected"
            || normalizedEvent == "friend_application.approved"
            || normalizedEvent == "friend_application.updated"
            || normalizedEvent == "friend_application.suppressed"
            || normalizedEvent == "friend_application.cancelled"
            || normalizedEvent == "friend_relation.established"
            || normalizedEvent == "friend_application_created"
            || normalizedEvent == "friend_application_reviewed"
            || normalizedEvent == "friend_application_rejected"
            || normalizedEvent == "friend_application_suppressed"
            || normalizedEvent == "friend_application_cancelled"
            || normalizedEvent == "friend_relation_established"
            || normalizedEvent == "friend.request.created"
            || normalizedEvent == "friend_request.created"
    }

    nonisolated static func isSuppressedFriendApplication(status: String, outcome: String) -> Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStatus == "suppressed" || normalizedOutcome == "application_suppressed"
    }

    // JHT_MOD_BEGIN APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改开始：媒体缓存扩展需要读取原有租户策略解析结果
    var resolvedTenantClientPolicy: RemoteTenantClientPolicy? {
        guard tenantClientPolicyScopeKey == remoteDataScopeKey(for: apiContext) else { return nil }
        return tenantClientPolicy
    }
    // JHT_MOD_END APPSTATE_MEDIA_CACHE_EXTENSION_SPLIT_20260913 - 修改结束

    var tenantDeviceLimitPresentationText: String {
        tenantDeviceMultiplicityPolicyState.presentationText
    }

    var shouldShowGroupMemberCount: Bool {
        groupMemberCountPolicyResolution.permitsVisibleTotal(
            currentScope: remoteDataScopeKey(for: apiContext),
            policy: resolvedTenantClientPolicy
        )
    }

    func visibleGroupMemberCount(_ candidates: Int?...) -> Int? {
        guard shouldShowGroupMemberCount else { return nil }
        return candidates.compactMap { $0 }.max().flatMap { $0 > 0 ? $0 : nil }
    }

    var canCurrentUserInitiateFriendRequest: Bool {
        Self.canInitiateFriendRequest(
            role: currentEnterprise.role,
            policy: resolvedTenantClientPolicy
        )
    }

    nonisolated static func canInitiateFriendRequest(
        role rawRole: String,
        policy: RemoteTenantClientPolicy?
    ) -> Bool {
        let normalizedRole = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedRole {
        case "internal", "staff", "内部用户", "admin", "管理员", "super_admin", "system", "service":
            return true
        default:
            return policy?.clientFriendRequests == true
        }
    }

    nonisolated static func canInitiateFriendRequestFromSearch(pairCanApply: Bool) -> Bool {
        pairCanApply
    }

    var shouldShowLastLoginTime: Bool {
        resolvedTenantClientPolicy?.showLastLoginTime == true
    }

    func visibleLastLoginText(for user: IMUser) -> String? {
        Self.lastLoginPresentationText(rawValue: user.lastLoginAt, policy: resolvedTenantClientPolicy)
    }

    nonisolated static func lastLoginPresentationText(
        rawValue: String,
        policy: RemoteTenantClientPolicy?
    ) -> String? {
        nil
    }

    func resolvedLastLoginText(_ rawValue: String?) -> String {
        Self.lastLoginPresentationText(rawValue: rawValue ?? "", policy: resolvedTenantClientPolicy) ?? ""
    }

    var organizationManagementCandidateUsers: [IMUser] {
        var byID: [String: IMUser] = [:]
        func insert(_ user: IMUser) {
            let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            byID[id] = user
        }
        insert(currentUser)
        contacts.forEach(insert)
        organizationMemberIndex.values.forEach(insert)
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var systemNoticeAvatarURL: String {
        resolveTenantAssetURL("/avatars/system-notice-logo-96.png")
    }

    func copyUserID(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            toast = "暂无可复制ID"
            return
        }
        UIPasteboard.general.string = normalized
        syncIOSRiskTelemetrySession()
        iosRiskTelemetry.recordClipboardCopy(
            characterCount: normalized.count,
            resourceType: "user",
            resourceID: normalized
        )
        toast = "已复制用户ID"
    }

    var shouldPollActiveConversation: Bool {
        !isRealtimeConnected
    }

    func isConversationMessageSyncInFlight(_ conversationID: String) -> Bool {
        conversationPollingPlan(for: conversationID).isMessageSyncInFlight
    }

    func shouldPollConversation(_ conversationID: String) -> Bool {
        conversationPollingPlan(for: conversationID).shouldPoll
    }

    private func conversationPollingPlan(for conversationID: String) -> ConversationStore.ConversationPollingPlan {
        conversationStore.conversationPollingPlan(
            conversationID: conversationID,
            shouldPollActiveConversation: shouldPollActiveConversation,
            historyKeyForConversation: { conversationHistoryStateKey(for: $0) }
        )
    }

    var activeConversationHistoryScope: String {
        activeConversationScopedStateKeyContext(for: "").scope
    }

    func rememberedConversationBottomSeq(for conversationID: String) -> Int64 {
        conversationStore.rememberedConversationBottomSeq(stateKey: conversationBottomStateKey(conversationID))
    }

    func rememberConversationBottomSeq(_ seq: Int64, for conversationID: String) {
        conversationStore.rememberConversationBottomSeq(seq, stateKey: conversationBottomStateKey(conversationID))
    }

    private func conversationBottomStateKey(_ conversationID: String) -> String {
        activeConversationScopedStateKeyContext(for: conversationID).stateKey
    }

    func activeConversationScopedStateKeyContext(for conversationID: String) -> ConversationStore.ActiveConversationScopedStateKeyContext {
        conversationStore.activeConversationScopedStateKeyContext(
            tenantID: apiContext.tenantID,
            imUID: apiContext.imUID,
            conversationID: conversationID
        )
    }

    func enterpriseLogoCacheKey(for enterprise: Enterprise) -> String {
        enterprise.logoImageCacheKey(scope: enterpriseLogoScopeKey(for: enterprise))
    }

    func workspaceSelectionLogoPrefetchSignature(for enterprises: [Enterprise]) -> String {
        enterprises
            .prefix(8)
            .map { enterprise in
                [
                    enterprise.id,
                    enterprise.logoURL,
                    enterprise.logoStatus,
                    enterprise.logoVersion,
                    enterprise.logoUpdatedAt,
                    enterprise.logoCacheKey,
                    enterprise.logoMime,
                    enterprise.logoWidth.map(String.init) ?? "",
                    enterprise.logoHeight.map(String.init) ?? "",
                    enterpriseLogoScopeKey(for: enterprise)
                ]
                .joined(separator: "#")
            }
            .joined(separator: "|")
    }

    func prefetchWorkspaceSelectionLogos(_ enterprises: [Enterprise]) async {
        let candidates = enterprises.prefix(8).compactMap { enterprise -> (url: String, cacheKey: String)? in
            let raw = enterprise.logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enterprise.isLogoRenderable,
                  !raw.hasPrefix("data:image"),
                  let url = URL(string: raw),
                  url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return (url.absoluteString, enterpriseLogoCacheKey(for: enterprise))
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            _ = await AvatarImageCache.shared.remoteImage(
                for: candidate.url,
                routeContext: avatarImageRouteContext,
                cacheKey: candidate.cacheKey
            )
        }
    }

    private func enterpriseLogoScopeKey(for enterprise: Enterprise) -> String {
        [
            apiContext.accountID ?? "",
            enterprise.id,
            apiContext.imUID ?? "",
            apiContext.appID,
            apiContext.deviceID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    deinit {
        let notificationObserverID = notificationRuntimeObserverID
        Task { @MainActor in
            IOSNotificationRuntime.shared.removeObserver(notificationObserverID)
        }
        voiceCallSystemEventTask?.cancel()
        voiceMediaEventTask?.cancel()
        videoMediaEventTask?.cancel()
        registrationConfirmationTask?.cancel()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        rtcTerminalCompensationTimerTask?.cancel()
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    }

    init(
        api: IMAPIProtocol = IMAPIClient(),
        registrationNow: @escaping @MainActor () -> TimeInterval = {
            Date().timeIntervalSince1970
        },
        registrationSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        pendingRegistrationReceiptStore: PendingRegistrationReceiptStore = PendingRegistrationReceiptStore(defaults: .standard),
        accessDiscovery: AccessDiscoveryManaging = AccessDiscoveryManager(),
        realtimeClient: any RealtimeTransporting = RealtimeClient(),
        voiceMediaClient: any VoiceMediaClient = JHTRuntimeFeatureFlags.disableRTCRuntime ? NoopVoiceMediaClient() : WebRTCVoiceMediaClient(),
        videoMediaClient: any VideoMediaClient = JHTRuntimeFeatureFlags.disableRTCRuntime ? NoopVideoMediaClient() : WebRTCVideoMediaClient(),
        voiceCallSystem: any VoiceCallSystemIntegrating = NoopVoiceCallSystemIntegration(),
        conversationStore: ConversationStore = ConversationStore(),
        messageStore: any MessageStore = SnapshotCache(),
        messagePersistence: MessagePersistenceCoordinator = .shared,
        remoteSyncEngine: any SyncEngine = DefaultSyncEngine(),
        realtimeReconnectNoticeDelayNanoseconds: UInt64 = 10_000_000_000,
        realtimeReconnectNoticeThrottleInterval: TimeInterval = 60,
        rtcMediaHeartbeatIntervalNanoseconds: UInt64 = RTCMediaStateHeartbeatFailurePolicy.defaultIntervalNanoseconds,
        rtcMediaHeartbeatNow: @escaping @MainActor () -> Date = Date.init,
        rtcMediaHeartbeatSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        rtcRequestNowNanoseconds: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        rtcRequestSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        rtcDiscoveryFailureDelayNanoseconds: [UInt64] = RTCRequestBackoffPolicy.discoveryFailureDelayNanoseconds,
        rtcTerminalCompensationFailureDelayNanoseconds: [UInt64] = RTCRequestBackoffPolicy.terminalFailureDelayNanoseconds,
        rtcTerminalCompensationMaximumAttempts: Int = RTCRequestBackoffPolicy.maximumTerminalAttempts,
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        microphonePermissionDecisionOverride: (() async -> Bool)? = nil,
        videoPermissionDecisionOverride: (() async -> Bool)? = nil,
        biometricAuthenticator: any LocalBiometricAuthenticating = SystemLocalBiometricAuthenticator(),
        biometricDefaults: UserDefaults = .standard,
        rememberedLoginCredentialStore: any RememberedLoginCredentialPersisting = KeychainRememberedLoginCredentialStore(),
        rememberedLoginPreferenceStore: any RememberedLoginPreferencePersisting = UserDefaultsRememberedLoginPreferenceStore(),
        protectedSessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore(),
        registrationSessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore(registrationRecovery: true),
        apiContextOverride: IMAPIContext? = nil,
        iosRiskTelemetry: IOSRiskTelemetryController? = nil,
        attachmentDownloadSessionFactory: @escaping AttachmentDownloadSessionFactory = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
    ) {
        self.api = api
        self.registrationNow = registrationNow
        self.registrationSleep = registrationSleep
        self.pendingRegistrationReceiptStore = pendingRegistrationReceiptStore
        self.biometricAuthenticator = biometricAuthenticator
        self.biometricDefaults = biometricDefaults
        self.rememberedLoginCredentialStore = rememberedLoginCredentialStore
        self.rememberedLoginPreferenceStore = rememberedLoginPreferenceStore
        self.protectedSessionStore = protectedSessionStore
        self.registrationSessionStore = registrationSessionStore
        self.attachmentDownloadSessionFactory = attachmentDownloadSessionFactory
        self.iosRiskTelemetry = iosRiskTelemetry ?? IOSRiskTelemetryController { context, events in
            try await api.postRiskActivityEvents(context: context, events: events)
        }
        self.accessDiscovery = accessDiscovery
        self.realtimeClient = realtimeClient
        self.voiceMediaClient = voiceMediaClient
        self.videoMediaClient = videoMediaClient
        self.voiceCallSystem = voiceCallSystem
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.messagePersistence = messagePersistence
        self.remoteSyncEngine = remoteSyncEngine
        self.realtimeReconnectNoticeDelayNanoseconds = realtimeReconnectNoticeDelayNanoseconds
        self.realtimeReconnectNoticeThrottleInterval = realtimeReconnectNoticeThrottleInterval
        self.rtcMediaHeartbeatIntervalNanoseconds = rtcMediaHeartbeatIntervalNanoseconds
        self.rtcMediaHeartbeatNow = rtcMediaHeartbeatNow
        self.rtcMediaHeartbeatSleep = rtcMediaHeartbeatSleep
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        self.rtcRequestNowNanoseconds = rtcRequestNowNanoseconds
        self.rtcRequestSleep = rtcRequestSleep
        self.rtcDiscoveryFailureDelayNanoseconds = rtcDiscoveryFailureDelayNanoseconds
        self.rtcTerminalCompensationFailureDelayNanoseconds = rtcTerminalCompensationFailureDelayNanoseconds
        self.rtcTerminalCompensationMaximumAttempts = rtcTerminalCompensationMaximumAttempts
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        self.microphonePermissionDecisionOverride = microphonePermissionDecisionOverride
        self.videoPermissionDecisionOverride = videoPermissionDecisionOverride
        self.apiContext = apiContextOverride ?? IMAPIContext.load(sessionStore: protectedSessionStore)
        biometricProtectionSettings = BiometricProtectionStore.load(
            context: apiContext,
            defaults: biometricDefaults
        )
        reloadRememberedLoginCredentialsForCurrentScope()
        isShowingLaunchSplash = self.apiContext.hasIMSession
        if let cachedPolicy = IMAppPolicyLastGoodStore.usable(appID: self.apiContext.appID) {
            currentAppPolicy = cachedPolicy.policy
            currentAppPolicyExpiresAt = cachedPolicy.isOnlineFresh
                ? Date(timeIntervalSince1970: cachedPolicy.onlineExpiresAt)
                : Date().addingTimeInterval(60)
            hasResolvedCurrentAppPolicyForAuthUI = true
            isPhoneAuthDisabledByServer = !cachedPolicy.policy.phoneAuthEnabled
        }
        normalizeAuthScreenForCurrentAppPolicy()
        configureForcedAppPolicyRequestGate()
        bindDomainStores()
        bindDeviceRevocationNotifications()
        configureRealtimeClient()
        disableAccessDiagnosticsOverlay()
        bindNotificationRuntime()
        if JHTRuntimeFeatureFlags.disableRTCRuntime {
            print("[JHT RTC] runtime_disabled_for_thread_diagnostics")
        } else {
            bindVoiceCallSystemIntegration()
            bindCallAudioLifecycleNotifications()
        }
        if isShowingLaunchSplash {
            scheduleLaunchSplashDismiss()
        }
        restorePendingRegistrationReceiptIfNeeded()
        let launchArguments = ProcessInfo.processInfo.arguments
        let shouldResetAuthOnLaunch: Bool
        #if DEBUG
        shouldResetAuthOnLaunch = launchArguments.contains("--reset-auth")
        #else
        shouldResetAuthOnLaunch = launchArguments.contains("--reset-auth")
        #endif
        let environment = ProcessInfo.processInfo.environment
        let isRunningUnitTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
            || launchArguments.contains { $0.contains(".xctest") || $0.contains("BlueStoneIMTests") }
            || Bundle.allBundles.contains { $0.bundlePath.contains(".xctest") }

        if isRunningUnitTests {
            launchSplashDismissTasks.cancel()
            isShowingLaunchSplash = false
            // Preserve committed platform-session recovery in focused tests.
            if registrationResolutionState != .pending { authScreen = .accountLogin }
            return
        }

#if DEBUG
        if configureRegistrationResolutionScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureLicenseQuotaScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureGlobalPolicyScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureAuthPolicyScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureAvatarStage4ScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureGroupLifecycleScreenshotScenarioIfRequested(launchArguments) {
            return
        }
        if configureGroupHistoryVisibilityScreenshotScenarioIfRequested(launchArguments) {
            return
        }
#endif

        prepareAccessDiagnosticsOverlayForLaunch()

        if shouldResetAuthOnLaunch {
            // Auth reset clears credentials and active views only. Scoped content caches stay on disk.
            clearRememberedLoginCredentials()
            IMAPIContext.clearStoredSession(sessionStore: protectedSessionStore)
            apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
            resetAuthenticatedRemoteData(showLoading: false)
            isAuthenticated = false
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
            authScreen = .accountLogin
            prepareAccessDiagnosticsOverlayForLaunch()
            Task { [weak self] in
                await self?.refreshCurrentAppPolicyForAuthUI(force: true)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshCurrentAppPolicyForAuthUI(force: !self.apiContext.hasIMSession)
        }
	        if apiContext.hasIMSession {
	            let restoringContext = apiContext
	            let restoringScope = remoteDataScopeKey(for: restoringContext)
	            isRestoringSession = true
	            resetAuthenticatedRemoteData(showLoading: true)
	            restoreCurrentUserFromSession()
            let restoringEnterprise = Enterprise(
                id: restoringContext.tenantID ?? "restoring_tenant",
                name: "正在同步企业",
                code: "",
                role: "",
                status: "同步中",
                memberCount: 0,
                isDefault: false,
                accentHex: 0x5D6BFF,
                logoURL: ""
            )
            currentEnterprise = restoringEnterprise
            enterprises = [restoringEnterprise]
            beginMainShellBootstrapTrace(reason: "restore_session")
            _ = postLoginWorkbenchAdmission.consume(
	                hasIMSession: restoringContext.hasIMSession,
	                scope: restoringScope
		            )
		            bindCallRecordPersistence(for: restoringContext)
		            isAuthenticated = true
		            activateMyInviteCodeForCurrentSession()
		            activeTab = .chats
            startSplashConfigurationRefresh(
                context: restoringContext,
                intent: .coldLaunch,
                reason: "restore_session"
            )
            toast = "正在恢复登录状态"
            Task {
                guard isCurrentRemoteScope(restoringScope) else { return }
                if await applyCachedRemoteSnapshotIfAvailable(context: restoringContext) {
                    guard isCurrentRemoteScope(restoringScope) else { return }
                    isRestoringSession = false
                    toast = "已加载本地会话，正在更新"
                }
                guard isCurrentRemoteScope(restoringScope) else { return }
                startInboxRefreshLoop()
                startRTCCallRefreshLoop()
                _ = await refreshStoredAuthSessionIfNeeded(
                    reason: "cold_launch",
                    silent: true,
                    context: restoringContext,
                    scope: restoringScope
                )
                let refreshedContext = apiContext
                guard refreshedContext.hasIMSession,
                      isCurrentRemoteScope(restoringScope) else { return }
                startRealtimeConnection(context: refreshedContext)
                let synced = await refreshRemoteSnapshot(silent: false, force: true)
                await completeColdLaunchSessionRestore(
                    restoringContext: restoringContext,
                    synced: synced
                )
            }
        }
    }

    func completeColdLaunchSessionRestore(
        restoringContext: IMAPIContext,
        synced: Bool
    ) async {
        let restoringScope = remoteDataScopeKey(for: restoringContext)
        guard isCurrentRemoteScope(restoringScope) else { return }
        guard isAuthenticated else {
            isRestoringSession = false
            return
        }
        if hasLoadedRemoteSnapshot {
            toast = synced ? "已恢复登录状态" : "登录状态已恢复，部分数据同步失败"
            isRestoringSession = false
            await evaluateForcedAppPolicyAuthIfNeeded(
                forceRefreshVerification: true,
                reason: "restore_session"
            )
        } else {
            isRestoringSession = false
            isInitialDataLoading = false
            toast = "登录状态已保留，数据同步失败，请稍后重试"
            scheduleColdLaunchSessionRecovery(restoringContext: restoringContext)
        }
    }

    private func scheduleColdLaunchSessionRecovery(restoringContext: IMAPIContext) {
        guard coldLaunchSessionRecoveryTask == nil else { return }
        let restoringScope = remoteDataScopeKey(for: restoringContext)
        coldLaunchSessionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.coldLaunchSessionRecoveryTask = nil }
            let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000]
            for delay in retryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard self.isAuthenticated,
                      self.isCurrentRemoteScope(restoringScope) else { return }
                if await self.refreshRemoteSnapshot(silent: true, force: true) {
                    guard self.isAuthenticated,
                          self.isCurrentRemoteScope(restoringScope) else { return }
                    self.toast = "已恢复登录状态"
                    return
                }
            }
        }
    }

    private func bindDomainStores() {
        conversationStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDomainStoreObjectWillChangeForward()
                }
            }
            .store(in: &storeCancellables)
        contactStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDomainStoreObjectWillChangeForward()
                }
            }
            .store(in: &storeCancellables)
        fileStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDomainStoreObjectWillChangeForward()
                }
            }
            .store(in: &storeCancellables)
        stickerStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDomainStoreObjectWillChangeForward()
                }
            }
            .store(in: &storeCancellables)
        callStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDomainStoreObjectWillChangeForward()
                }
            }
            .store(in: &storeCancellables)
    }

    // JHT_MOD_BEGIN APPSTATE_DOMAIN_STORE_CHANGE_COALESCE_PERF_20260912 - 修改开始：同一轮子 Store 变化只转发一次，避免聊天/会话页面重复刷新
    private func scheduleDomainStoreObjectWillChangeForward() {
        guard !domainStoreObjectWillChangeForwardScheduled else { return }
        domainStoreObjectWillChangeForwardScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.domainStoreObjectWillChangeForwardScheduled = false
            self.objectWillChange.send()
        }
    }
    // JHT_MOD_END APPSTATE_DOMAIN_STORE_CHANGE_COALESCE_PERF_20260912 - 修改结束

    private func bindDeviceRevocationNotifications() {
        NotificationCenter.default.publisher(for: .imCurrentDeviceRevoked)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleCurrentDeviceRevoked()
            }
            .store(in: &storeCancellables)
    }

    private func configureRealtimeClient() {
        realtimeClient.canReconnect = { [weak self] in
            guard let self else { return false }
            return self.iosRiskTelemetrySceneIsActive
                && self.isAuthenticated
                && self.apiContext.hasIMSession
        }
        realtimeClient.connectionRequestProvider = { [weak self] in
            guard let self,
                  self.isAuthenticated else {
                return nil
            }
            let context = self.apiContext
            let scope = self.remoteDataScopeKey(for: context)
            guard context.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  let request = self.realtimeConnectionRequest(context: context) else {
                return nil
            }
            return request
        }
        realtimeClient.onConnectionUnavailable = { [weak self] in
            #if DEBUG
            if self?.authPolicyScreenshotModeEnabled == true { return }
            #endif
            self?.toast = "实时连接地址不可用"
        }
        realtimeClient.onConnectionStateChanged = { [weak self] connected in
            self?.isRealtimeConnected = connected
        }
        realtimeClient.onConnected = { [weak self] in
            guard let self else { return }
			(self.api as? IMAPIClient)?.recordRuntimeRealtimeConnected(context: self.apiContext)
            self.handleAvatarRealtimeOutcome(
                self.avatarRealtimeProjection.requireAuthorityAfterReconnect()
            )
            self.queueAvatarAuthorityRefetch(self.visibleAvatarAuthorityUIDs())
            self.mediaNetworkRecoveryGeneration &+= 1
            self.accessDiscovery.markActiveRealtimeEndpointConnected()
            self.scheduleRealtimeEndpointStableConfirmation()
            self.recordAccessDiagnosticsRealtimeConnected()
            print("[JHT Realtime] app_connect_ack fallback=\(self.redactedRealtimeURLSummary(self.api.webSocketURL(context: self.apiContext)))")
            self.clearRealtimeReconnectNotice()
            self.resubscribeRealtimeChannels()
            if let ticket = self.localMessageTicket {
                self.scheduleDurableReadAckRecovery(ticket: ticket, runImmediately: true)
            }
            self.scheduleRealtimeRecoveryRefresh(reason: "connect_ack")
            self.scheduleActiveConversationRecoveryAfterRealtimeConnected(reason: "connect_ack")
        }
        realtimeClient.onDisconnected = { [weak self] in
            #if DEBUG
            if self?.authPolicyScreenshotModeEnabled == true { return }
            #endif
            self?.invalidateRealtimeEndpointStableConfirmation()
            self?.accessDiscovery.markActiveRealtimeEndpointFailed()
            self?.scheduleRealtimeReconnectToastIfNeeded()
        }
        if let concreteRealtimeClient = realtimeClient as? RealtimeClient {
            AccessDiagnostics.shared.bindConnectionDiagnostics(to: concreteRealtimeClient)
			concreteRealtimeClient.onRouteFailure = { [weak self] error in
				guard let self, let api = self.api as? IMAPIClient else { return }
				api.recordRuntimeRealtimeFailure(error, context: self.apiContext)
			}
            concreteRealtimeClient.onQUICFallbackToWebSocket = { [weak self] _ in
                guard let self else { return }
                self.invalidateRealtimeEndpointStableConfirmation()
                self.accessDiscovery.markActiveRealtimeEndpointFailed()
                self.recordAccessDiagnosticsRealtimeFallback(context: self.apiContext, reason: "QUIC 失败，回落 WSS")
            }
        }
        realtimeClient.onReconnectAttempt = { [weak self] in
            guard let self else { return }
            if !self.usesLocalRealtimeFallback(context: self.apiContext) {
                self.scheduleAccessDiscoveryRefresh(context: self.apiContext, reason: "reconnect")
            }
            self.scheduleRealtimeRecoveryRefresh(reason: "reconnect")
        }
        realtimeClient.onEnvelope = { [weak self] envelope in
            self?.handleRealtimeEnvelope(envelope)
        }
    }

    private func scheduleToastDismiss() {
        guard let toast, !toast.isEmpty else {
            toastDismissTasks.cancel()
            return
        }
        #if DEBUG
        if licenseQuotaScreenshotScenario != nil || registrationResolutionScreenshotScenario != nil {
            toastDismissTasks.cancel()
            return
        }
        #endif
        let currentToast = toast
        toastDismissTasks.replace(with: Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.toast == currentToast else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.toast = nil
                }
            }
        })
    }

    private func scheduleLaunchSplashDismiss() {
        launchSplashDismissTasks.replace(with: Task { [weak self] in
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    self.isShowingLaunchSplash = false
                }
            }
        })
    }

    private func restoreCurrentUserFromSession() {
        guard let imUID = apiContext.imUID, !imUID.isEmpty else { return }
        if let cachedIdentity = IMCurrentUserIdentityCache.load(context: apiContext) {
            hydrateCurrentProfileAuthority(from: cachedIdentity.authorityCheckpoint)
            currentUser = cachedIdentity.makeUser(
                fallbackEnterprise: currentEnterprise.name,
                fallbackSeed: stableSeed(imUID)
            )
            return
        }
        currentUser = IMUser(
            id: imUID,
            userID: imUID,
            username: "USERNAME_PLACEHOLDER",
            name: imUID,
            title: "",
            department: "",
            phone: "",
            email: apiContext.accountID ?? "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(imUID),
            badges: []
        )
    }

    private func persistCurrentUserIdentityIfPossible() {
        IMCurrentUserIdentityCache.save(
            currentUser,
            context: apiContext,
            profileAuthorityCheckpoint: currentProfileAuthorityCheckpoint()
        )
    }

    var pendingFriendRequestCount: Int {
        friendRequests.filter(\.isPendingIncoming).count
    }

}

// MARK: - Authentication, Profile, and Workspace

// Authentication, profile, and workspace orchestration is split to Core/AppSupport/AccountSession/AppState+AuthenticationProfileWorkspace.swift.

// MARK: - Voice Calls

// Voice call orchestration is split to Core/AppSupport/Calls/AppState+VoiceCalls.swift.

// MARK: - Remote Registration and Snapshot Sync

// Remote registration, snapshot refresh, cache recovery, and sync diagnostics are split to Core/AppSupport/RemoteSync/AppState+RemoteRegistrationSnapshotSync.swift.

// MARK: - Tenant Switching and Remote Mapping

// Tenant switching and tenant-scoped remote mapping are split to Core/AppSupport/TenantSession/AppState+TenantSwitchingRemoteMapping.swift.

// MARK: - Remote Group and File Mapping

// Remote group/file mapping is split to Core/AppSupport/GroupFileMapping/AppState+RemoteGroupFileMapping.swift.

// MARK: - Identity, Receipts, and Message Mapping

// Message identity, receipt, sidecar, and remote message state mapping are split to Core/AppSupport/MessageMapping/AppState+RemoteMessageStateMapping.swift.

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private extension URL {
    var normalizedAPIBaseKey: String {
        let scheme = (self.scheme ?? "").lowercased()
        let host = (self.host ?? "").lowercased()
        let port = self.port.map { ":\($0)" } ?? ""
        let normalizedPath = self.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if normalizedPath.isEmpty {
            return "\(scheme)://\(host)\(port)"
        }
        return "\(scheme)://\(host)\(port)/\(normalizedPath)"
    }
}

struct IOSNotificationConversationOpenRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: String
    let messageID: String?
    let channelSeq: Int64?

    init(conversationID: String, messageID: String?, channelSeq: Int64?) {
        id = UUID()
        self.conversationID = conversationID
        self.messageID = messageID
        self.channelSeq = channelSeq
    }

    var jumpTarget: RemoteTenantSearchJumpTarget? {
        guard messageID != nil || channelSeq != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelSeq: channelSeq,
            messageID: messageID
        )
    }
}
