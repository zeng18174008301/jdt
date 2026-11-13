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

// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_BEGIN


// AppState is the MainActor boundary for UI state coordination. Keep state
// writes, Published updates, and Store mutations here; move pure parsing,
// mapping, formatting, and transport-specific helpers into Core/AppSupport.
@MainActor
final class AppState: ObservableObject {
    // Stable ObservableObject identity; Store updates are observed by their consumers.
    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher() // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    static let globalMutedMessage = globalMutedMessageText
    static let groupMemberMutedMessage = groupMemberMutedMessageText
#if DEBUG
    let captchaLogger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "captcha")
#endif
    // WDT_IOS1_REFACTOR_SCREENSHOT_LAUNCH_FIXTURES_20261110_BEGIN
    // Screenshot scenarios are selected before the root view is created.
    var avatarStage4ScreenshotScenario: AvatarStage4ScreenshotScenario?
    var groupLifecycleScreenshotScenario: GroupLifecycleScreenshotScenario?
    var groupHistoryVisibilityScreenshotScenario: GroupHistoryVisibilityScreenshotScenario?
    var globalPolicyScreenshotScenario: GlobalPolicyScreenshotScenario?
#if DEBUG
    var licenseQuotaScreenshotScenario: LicenseQuotaScreenshotScenario?
    var registrationResolutionScreenshotScenario: RegistrationResolutionScreenshotScenario?
    // WDT_IOS1_REFACTOR_SCREENSHOT_LAUNCH_FIXTURES_20261110_END

    // WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110: unchanged DEBUG computed facade moved to AppState+StoreFacades.swift.

#endif

    // MARK: - Published State

    // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
    let authenticationPresentationStore = AuthenticationPresentationStore()
    // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
    let sessionReauthenticationStore = SessionReauthenticationStore()
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
    // Synchronous, exact old/new authority pair; never held across an await.
    var sessionReauthenticationCommit: (old: IMAuthSessionFence, new: IMAuthSessionFence)?
    // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_BEGIN
    let registrationConfirmationStore = RegistrationConfirmationPresentationStore()
    // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_BEGIN
    let rememberLoginPresentationStore = RememberLoginPresentationStore()
    // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110_END
    var isClearingApplicationCache = false // WDT_IOS1_REFACTOR_CACHE_CLEARING_RUNTIME_FLAG_20261110
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
    let biometricAccessStore = BiometricAccessStore()
    // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
    let bootstrapPresentationStore = BootstrapPresentationStore()
    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END
    let preAuthEnterpriseContextStore = PreAuthEnterpriseContextStore() // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：同名多商户登录挑战只暴露 UI 必需状态，密码仅保留在私有内存态
    let loginTenantCodeChallengeStore = LoginTenantCodeChallengeStore() // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110
    // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
    let loginWorkspacePresentationStore = LoginWorkspacePresentationStore() // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
    let slideCaptchaPresentationStore = SlideCaptchaPresentationStore() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
    let mainTabSelection = MainTabSelectionState()
    /// 退群/解散群成功后递增;会话列表监听该值,关闭当前会话页与其上的
    /// 所有操作弹窗,直接回到会话列表。
    let conversationListPresentationStore = ConversationListPresentationStore() // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    let enterpriseMembershipStore = EnterpriseMembershipPresentationStore()
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
    let conversationStore: ConversationStore
    let contactStore = ContactStore()
    let fileStore = FileStore()
    let stickerStore = StickerStore()
    let callStore: CallStore // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111
    var emojiPickerCatalogRuntime = EmojiPickerCatalogRuntimeState()
    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
    let batchForwardStore = BatchForwardPresentationStore()
    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END
    var forwardingTenantFileIDs: Set<String> = [] // WDT_IOS1_REFACTOR_FILE_FORWARD_RUNTIME_FLAG_20261110
    var tenantFileForwardClientMessageIDs: [String: String] = [:]
    var batchForwardSubmissionTask: Task<Void, Never>?
    var batchForwardSubmissionGeneration: UInt64 = 0
    // WDT_IOS1_REFACTOR_VOICE_PLAYBACK_OBSERVATION_20261110
    let voiceMessagePlaybackStore = VoiceMessagePlaybackStore()
    var voiceMessagePlayer: AVAudioPlayer?
    var voiceMessagePlayerDelegate: VoiceMessageAudioPlayerDelegate?
    var voiceMessagePlaybackTimer: Timer?
    var voiceMessagePlayerMessageID: String?
    var voiceMessagePlaybackGeneration: UInt64 = 0
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_BEGIN
    // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110: reconnect publishes through FileStore.
    let groupModerationStore = GroupModerationStore() // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110: cancellation state lives in ContactStore.
    var groupAnnouncementPrivacyEpoch: UInt64 = 0
    // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_BEGIN
    let avatarSearchPresentationStore = AvatarSearchPresentationStore()
    // Presence projections already publish through the stores that own changed users.
    // WDT_IOS1_REFACTOR_AVATAR_PRESENCE_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110: self profiles are published by ContactStore.groupSelfProfiles.
    var groupMemberProfileGenerationByScopedGroupKey: [String: Int64] = [:]
    var minimumGroupMemberProfileGenerationByScopedGroupKey: [String: Int64] = [:]
    var groupMemberProfileRefreshTasks: [String: Task<Void, Never>] = [:]
    var groupMemberProfileRefreshEpoch: UInt64 = 0
    var groupMemberProfileRefreshEpochByScopedGroupKey: [String: UInt64] = [:]
    let groupDirectoryRefreshGeneration = AuthFlowGenerationState()
    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112: ContactStore owns scoped card names and canonical friend identity.
    // WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110: removed the write-only governance placeholder.
    let enterpriseDirectoryStore = EnterpriseDirectoryStore() // WDT_IOS1_REFACTOR_ENTERPRISE_DIRECTORY_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_BEGIN
    let toastPresentationStore = ToastPresentationStore()
    // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
    let splashOverlayStore = SplashOverlayStore()
    // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END
    var hasMainShellBecomeInteractive = false
    // WDT_IOS1_REFACTOR_REAL_NAME_FORM_OBSERVATION_20261110: submission errors belong to the requesting form.
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
    let appPolicyPresentationStore = AppPolicyPresentationStore()
    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_BEGIN
    #if DEBUG
    let appPolicyLastGoodDefaults = IMAppPolicyLastGoodStore.defaultsForNewState
    #else
    var appPolicyLastGoodDefaults: UserDefaults { .standard }
    #endif
    // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112_END
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_LEGAL_DOCUMENT_OBSERVATION_20261110: load outcomes belong to the presenting legal document.
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
    let inviteCodeStore = PersonalInviteCodeStore()
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110: department authority is owned by the directory store.
    let tenantClientPolicyStore = TenantClientPolicyPresentationStore() // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
    // WDT_APP_CONTRACT_20261021_01_08: current-session UI permissions, independent of RTC capabilities.
    let tenantInteractionStore = TenantInteractionPresentationStore() // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    var interactionPolicyGeneration = UUID()
    var interactionPolicyRefreshTask: Task<Void, Never>?
    var interactionPolicyRefreshedAt: Date?
    // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_BEGIN
    let tenantDevicePolicyPresentationStore = TenantDevicePolicyPresentationStore()
    // WDT_IOS1_REFACTOR_DEVICE_POLICY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    let organizationDirectoryStore = OrganizationDirectoryStore()
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
    let forcedAppPolicyAuthStore = ForcedAppPolicyAuthStore()
    // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END
    // MARK: - Private Runtime State

    var storeCancellables: Set<AnyCancellable> = []
    var callAudioLifecycleObserverTokens: [NSObjectProtocol] = []
    var forcedAppPolicyAuthScopeKey = ""
    var verificationRequirementAuthorityScopeKey = ""
    var forcedAppPolicyAuthDestinationTransitionTask: Task<Void, Never>?
    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110: policy scope and count authority are published atomically by tenantClientPolicyStore.
    var groupMemberCountPolicyCheckpoint: ScopedResponseCheckpoint?
    var groupMemberCountPolicyRequestSequence: Int64 = 0
    var groupMemberCountPolicyRefreshTask: Task<Void, Never>?
    var minimumGroupMemberCountPolicyGenerationByScope: [String: Int64] = [:]
    var tenantDevicePolicyRequestGeneration: UInt64 = 0
    let searchInvalidationStore = SearchInvalidationStore() // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110
    let tenantSearchRequests = TenantSearchRequests() // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
    let tenantSearchHistory: TenantSearchHistoryStore // WDT_IOS1_SEARCH_HISTORY_20261113
    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
    let certificationPresentationStore = CertificationPresentationStore()
    // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_BEGIN
    private(set) lazy var certificationPillSource: CertificationPillSource = {
        // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
        CertificationPillSource(
            changes: certificationPresentationStore.changes,
            scopeRevision: { [weak self] in self?.certificationPresentationStore.scopeRevision ?? 0 },
            // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END
            presentation: { [weak self] uid in self?.certificationPresentation(forExactUID: uid) },
            ensure: { [weak self] uid in self?.ensureCertificationPresentations(forExactUIDs: [uid]) }
        )
    }()
    // WDT_IOS1_REFACTOR_CERTIFICATION_OBSERVATION_20261110_END

    var suppressCurrentUserIdentityPersistence = false
    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
    let currentUserPresentationStore = CurrentUserPresentationStore()
    // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END
    let tenantPolicy = TenantPolicy(
        messageRetention: "按后台策略",
        fileLimit: "按后台策略",
        groupLimit: "按后台策略",
        deviceLimit: "同步中",
        rateLimit: "按后台策略",
        sensitiveAudit: "按后台策略"
    )
    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_BEGIN
    let loginLogStore = LoginLogStore()
    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN


    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

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
    let currentUserIdentityDefaults: UserDefaults // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
    let attachmentDownloadSessionFactory: AttachmentDownloadSessionFactory
    let iosRiskTelemetry: IOSRiskTelemetryController
    let iosSceneCaptureMonitor = IOSSceneCaptureMonitor()
    var iosRiskTelemetrySceneIsActive = false
    // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_BEGIN — Retain the actual constructor-owned restore task.
    var coldLaunchSessionRestoreTask: Task<Void, Never>? // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_END
    // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_BEGIN
    var pendingColdLaunchRealtimeAdmission: (scope: String, authority: IMAuthSessionFence)?
    // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_END
    var iosRiskTelemetryContextSyncTask: Task<Void, Never>?
    let accessDiscovery: AccessDiscoveryManaging
    var accessDiscoveryRefreshTask: Task<AccessDiscoveryRefreshOutcome, Never>?
    var accessDiscoveryRefreshScope: String?
    var accessDiscoveryRealtimeStartTask: Task<Void, Never>?
    var accessDiscoveryRealtimeStartScope: String?
    let slideCaptchaService = SlideCaptchaService()
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
    // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110: call license authority is owned by FileStore.
    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_BEGIN
    let rtcCapabilityAlertStore = RTCCapabilityAlertStore()
    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_END
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
    // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
    let chatBubbleSessionIdentitySource = ChatBubbleSessionIdentitySource()
    var apiContext: IMAPIContext {
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        willSet {
            if apiContext.authSessionFence != newValue.authSessionFence
                || apiContext.imToken != newValue.imToken || apiContext.imAPIBaseURL != newValue.imAPIBaseURL {
                (api as? IMAPIClient)?.runtimeRouteStore.invalidateOutgoingConfirmation()
            }
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        didSet {
            let previous = chatBubbleSessionIdentity(context: oldValue)
            reconcileAPIContextChange(from: oldValue)
            publishChatBubbleSessionIdentity(ifDifferentFrom: previous)
        }
    }
    // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
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
    var tenantContextRoleAuthority: TenantContextRoleAuthority?
    var currentProfileAuthorityFence = CurrentProfileAuthorityFence()
    var groupMemberPageLoadingKeys: Set<String> = []
    var pendingForcedRemoteSnapshotSuccessorScopes: Set<String> = []
    var realtimeIngestBuffer = RealtimeMessageIngestBuffer()
    let realtimeComputeRuntime = RealtimeComputeRuntime() // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
    var realtimeIngestFlushTask: Task<Void, Never>?
    var realtimeResubscriptionTask: Task<Void, Never>?
    var isConversationListUserInteracting = false
    var isContactDirectoryUserInteracting = false
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
    var conversationSelectionEpochFence = ConversationSelectionEpochFence()
    let deviceRevocationHandling = DeviceRevocationHandlingState()
    let realtimeDecoder = JSONDecoder()
    let messageStore: any MessageStore
    let messagePersistence: MessagePersistenceCoordinator
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    var localMessageTicket: LocalMessageSessionTicket? {
        willSet {
            if localMessageTicket != newValue {
                (api as? IMAPIClient)?.runtimeRouteStore.invalidateOutgoingConfirmation()
            }
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    var pendingMessageDeletions: Set<String> = []
    var durableOutboxRecoveryTask: Task<Void, Never>?
    var outgoingConfirmationReads: Set<OutgoingConfirmationRead> = [] // WDT_IOS1_HTTP_ROUTE_V5_20261113
    var attachmentUploadOperations: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    // JHT_MOD_BEGIN ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改开始：前后台切换时恢复图片/文件附件上传任务
    var attachmentForegroundResumeTask: Task<Void, Never>?
    var attachmentForegroundResumeGeneration: UInt64 = 0
    // JHT_MOD_END ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改结束
    var durableReadAckRecoveryTask: Task<Void, Never>?
    var durableReadAckRecoveryGeneration: UInt64 = 0
    var durableReadAckRecoveryRestartRequested = false
    // WDT_RECEIPT_DETAIL_SCOPE_20261023_BEGIN
    let readReceiptAuthorityStore = ReadReceiptDetailAuthorityStore() // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
    var resolvedMediaCacheScope: (scope: LocalMessageScope, context: IOSMediaCacheScopeContext)?
    var localMessageSessionGeneration: UInt64 = 1 {
        didSet {
            // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
            if oldValue != localMessageSessionGeneration {
                invalidateReadReceiptDetailAuthorities()
                chatBubbleSessionIdentitySource.replace(chatBubbleSessionIdentity)
            }
            // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
        }
    }
    // WDT_RECEIPT_DETAIL_SCOPE_20261023_END
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
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    var stickerManifestBindingGeneration = UUID()
    var stickerManifestOperation: StickerManifestOperation? // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    let stickerAssetDownload: @Sendable (URLRequest) async throws -> (URL, URLResponse) // WDT_IOS1_STICKER_MANIFEST_R2_20261111
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END
    // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
    let stickerMessageAssetStore = StickerMessageAssetStore()
    // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END
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
    let mainShellSecondarySnapshotDelayNs: UInt64 = 2_200_000_000
    let mainShellGroupsSnapshotDelayNs: UInt64 = 700_000_000
    let mainShellContactsSnapshotDelayNs: UInt64 = 1_300_000_000
    let mainShellHistoryPrefetchDelayNs: UInt64 = 3_000_000_000
    let mainShellGroupBundleDelayNs: UInt64 = 4_500_000_000
    let realtimeRecoveryRecentSnapshotCooldownSeconds: TimeInterval = 30
    var lastRemoteSnapshotPrimarySyncedAt: Date?
    let mainShellBootstrapTrace = MainShellBootstrapTraceState()

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
        callStore: CallStore = CallStore(), // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111
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
        currentUserIdentityDefaults: UserDefaults = .standard, // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
        rememberedLoginCredentialStore: any RememberedLoginCredentialPersisting = KeychainRememberedLoginCredentialStore(),
        tenantSearchHistory: TenantSearchHistoryStore? = nil, // WDT_IOS1_SEARCH_HISTORY_20261113
        rememberedLoginPreferenceStore: any RememberedLoginPreferencePersisting = UserDefaultsRememberedLoginPreferenceStore(),
        protectedSessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore(),
        registrationSessionStore: any IMProtectedSessionStoring = IMKeychainSessionStore(registrationRecovery: true),
        apiContextOverride: IMAPIContext? = nil,
        // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_BEGIN — nil preserves actual host detection; tests may run the real normal branch.
        launchUnitTestOverride: Bool? = nil, // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_END
        iosRiskTelemetry: IOSRiskTelemetryController? = nil,
        attachmentDownloadSessionFactory: @escaping AttachmentDownloadSessionFactory = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        },
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        stickerAssetDownload: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { request in
            try await URLSession.shared.download(for: request)
        }
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
    ) {
        self.api = api
        self.registrationNow = registrationNow
        self.registrationSleep = registrationSleep
        self.pendingRegistrationReceiptStore = pendingRegistrationReceiptStore
        self.biometricAuthenticator = biometricAuthenticator
        self.biometricDefaults = biometricDefaults
        self.currentUserIdentityDefaults = currentUserIdentityDefaults // WDT_IOS1_M17_CALL_ARCHIVE_PROCESS_RESTART_20261112
        self.rememberedLoginCredentialStore = rememberedLoginCredentialStore
        self.tenantSearchHistory = tenantSearchHistory ?? TenantSearchHistoryStore() // WDT_IOS1_SEARCH_HISTORY_20261113
        self.rememberedLoginPreferenceStore = rememberedLoginPreferenceStore
        self.protectedSessionStore = protectedSessionStore
        self.registrationSessionStore = registrationSessionStore
        self.attachmentDownloadSessionFactory = attachmentDownloadSessionFactory
        self.stickerAssetDownload = stickerAssetDownload // WDT_IOS1_STICKER_MANIFEST_R2_20261111
        self.iosRiskTelemetry = iosRiskTelemetry ?? IOSRiskTelemetryController { context, events in
            try await api.postRiskActivityEvents(context: context, events: events)
        }
        self.accessDiscovery = accessDiscovery
        self.realtimeClient = realtimeClient
        self.voiceMediaClient = voiceMediaClient
        self.videoMediaClient = videoMediaClient
        self.voiceCallSystem = voiceCallSystem
        self.conversationStore = conversationStore
        self.callStore = callStore // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111
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
        // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
        conversationStore.bindMessageScope(try? LocalMessageScope(context: apiContext), preservesMessages: true)
        // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
        tenantClientPolicyStore.setActiveScope(remoteDataScopeKey(for: apiContext)) // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        updateTenantInteractionPresentationScope() // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
        biometricAccessStore.replaceSettings(BiometricProtectionStore.load(
            context: apiContext,
            defaults: biometricDefaults
        ))
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
        reloadRememberedLoginCredentialsForCurrentScope()
        bootstrapPresentationStore.launch.isShowingLaunchSplash = self.apiContext.hasIMSession // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
        if let cachedPolicy = IMAppPolicyLastGoodStore.usable(appID: self.apiContext.appID, defaults: appPolicyLastGoodDefaults) {
            appPolicyPresentationStore.snapshot.currentAppPolicy = cachedPolicy.policy // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            currentAppPolicyExpiresAt = cachedPolicy.isOnlineFresh
                ? Date(timeIntervalSince1970: cachedPolicy.onlineExpiresAt)
                : Date().addingTimeInterval(60)
            appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            appPolicyPresentationStore.snapshot.isPhoneAuthDisabledByServer = !cachedPolicy.policy.phoneAuthEnabled // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        }
        normalizeAuthScreenForCurrentAppPolicy()
        configureForcedAppPolicyRequestGate()
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
        let isRunningUnitTests = launchUnitTestOverride ?? (environment["XCTestConfigurationFilePath"] != nil // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_BEGIN
            || environment["XCInjectBundleInto"] != nil
            || launchArguments.contains { $0.contains(".xctest") || $0.contains("WenDaTongTests") /* WDT_IOS1_WENDATONG_TARGET_NAMES_20261113 */ }
            || Bundle.allBundles.contains { $0.bundlePath.contains(".xctest") }) // WDT_IOS1_COLD_RESTORE_PRODUCER_SEAM_20261111_END

        if isRunningUnitTests {
            launchSplashDismissTasks.cancel()
            bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            // Preserve committed platform-session recovery in focused tests.
            if registrationResolutionState != .pending { authenticationPresentationStore.setInitialScreen(.accountLogin) } // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
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
            authenticationPresentationStore.setInitialAuthentication(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            invalidatePreAuthEnterpriseContext(normalizeScreen: false)
            authenticationPresentationStore.setInitialScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
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
	            bootstrapPresentationStore.launch.isRestoringSession = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
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
            enterpriseMembershipStore.setInitialCurrent(restoringEnterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setEnterprises([restoringEnterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            beginMainShellBootstrapTrace(reason: "restore_session")
            _ = postLoginWorkbenchAdmission.consume(
	                hasIMSession: restoringContext.hasIMSession,
	                scope: restoringScope
		            )
		            bindCallRecordPersistence(for: restoringContext)
		            authenticationPresentationStore.setInitialAuthentication(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
		            activateMyInviteCodeForCurrentSession()
		            activeTab = .chats
            startSplashConfigurationRefresh(
                context: restoringContext,
                intent: .coldLaunch,
                reason: "restore_session"
            )
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在恢复登录状态")
            // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_BEGIN — Same normal constructor producer, owned by this lifecycle.
            coldLaunchSessionRestoreTask = makeColdLaunchSessionRestoreTask(
                restoringContext: restoringContext, restoringScope: restoringScope)
            // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_END
        }
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
// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
