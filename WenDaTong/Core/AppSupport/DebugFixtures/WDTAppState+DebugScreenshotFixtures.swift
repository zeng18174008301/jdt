import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit

#if DEBUG
// WDT_APPSTATE_DEBUG_FIXTURES_SPLIT_20260924_BEGIN: DEBUG screenshot fixtures moved out of AppState.swift without behavior changes.
@MainActor
extension AppState {
    func configureRegistrationResolutionScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        configureRegistrationResolutionScreenshotScenarioIfRequested(launchArguments, fixtureDefaults: .standard)
    }

    func configureRegistrationResolutionScreenshotScenarioIfRequested(
        _ launchArguments: [String], fixtureDefaults: UserDefaults
    ) -> Bool {
        let prefix = "--registration-resolution-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = RegistrationResolutionScreenshotScenario(rawValue: rawScenario),
              configureAuthPolicyScreenshotScenarioIfRequested([
                "--auth-policy-screenshot=contact-email"
              ]) else {
            return false
        }

        registrationResolutionScreenshotScenario = scenario
        appPolicyPresentationStore.snapshot.hasResolvedCurrentAppPolicyForAuthUI = true // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        registrationConfirmationStore.snapshot.hasTimedOut = scenario == .timeout // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        switch scenario {
        case .pending, .timeout:
            resetForcedAppPolicyAuthState()
            apiContext.clearSession(defaults: fixtureDefaults, sessionStore: protectedSessionStore)
            setEnterprises([]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            activeTab = .chats
            registrationConfirmationStore.snapshot.resolution = .pending // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(scenario == .timeout
                ? RegistrationConfirmationPolicy.timeoutMessage
                : RegistrationConfirmationPolicy.pendingMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
        case .success:
            registrationConfirmationStore.snapshot.resolution = .success // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("注册成功，已自动登录")
        }
        return true
    }

    // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_BEGIN
    func configureLicenseQuotaScreenshotScenarioIfRequested(
        _ launchArguments: [String], fixtureDefaults: UserDefaults = .standard
    ) -> Bool {
        // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_END
        let prefix = "--license-quota-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = LicenseQuotaScreenshotScenario(rawValue: rawScenario) else {
            return false
        }

        switch scenario {
        case .registration:
            guard configureAuthPolicyScreenshotScenarioIfRequested([
                "--auth-policy-screenshot=contact-email"
            ]) else {
                return false
            }
            licenseQuotaScreenshotScenario = scenario
            resetForcedAppPolicyAuthState()
            apiContext.clearSession(defaults: fixtureDefaults, sessionStore: protectedSessionStore) // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111
            setEnterprises([]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            setAuthScreen(.accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            activeTab = .chats
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(IMAPIClient.licenseQuotaUserMessage(for: "registered_user_quota_exceeded"))

        case .onlineLimit, .onlineServiceUnavailable:
            // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_BEGIN
            guard configureGlobalPolicyScreenshotScenarioIfRequested(
                ["--global-policy-screenshot=member-on"], groupCountDefaults: fixtureDefaults
            ) else {
                // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_END
                return false
            }
            licenseQuotaScreenshotScenario = scenario
            globalPolicyScreenshotScenario = nil
            let code = scenario == .onlineLimit
                ? "online_quota_exceeded"
                : "online_quota_service_unavailable"
            authPolicyScreenshotModeEnabled = false
            handleRealtimeEnvelope(RealtimeEnvelope(
                type: "error",
                requestID: "license-quota-screenshot",
                payload: [
                    "code": .string(code),
                    "message": .string("license quota screenshot fixture")
                ]
            ))
            authPolicyScreenshotModeEnabled = true

        case .group:
            guard configureGroupLifecycleScreenshotScenarioIfRequested([
                "--group-lifecycle-screenshot=member"
            ]) else {
                return false
            }
            licenseQuotaScreenshotScenario = scenario
            authPolicyScreenshotModeEnabled = false
            handleRemoteError(
                IMAPIError.conflict(
                    code: "group_member_quota_exceeded",
                    message: "license quota screenshot fixture"
                ),
                fallback: "加入群聊失败"
            )
            authPolicyScreenshotModeEnabled = true
        }
        return true
    }

    // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_BEGIN
    func configureGlobalPolicyScreenshotScenarioIfRequested(
        _ launchArguments: [String], groupCountDefaults: UserDefaults = .standard
    ) -> Bool {
        // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111_END
        let prefix = "--global-policy-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = GlobalPolicyScreenshotScenario(rawValue: rawScenario) else {
            return false
        }

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .contacts
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        slideCaptchaPresentationStore.clearScreenshotFixturePrompt() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
        dismissSplashOverlay(reason: "debug_fixture", cancelTask: true) // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110
        globalPolicyScreenshotScenario = scenario
        avatarStage4ScreenshotScenario = nil
        groupLifecycleScreenshotScenario = nil
        groupHistoryVisibilityScreenshotScenario = nil

        let role = scenario == .adminOff ? "tenant_admin" : "member"
        apiContext = IMAPIContext(
            platformToken: "debug-platform-token",
            accountID: "debug-account-global-policy",
            tenantID: "tenant-global-policy",
            imUID: "im-global-policy-me",
            imToken: "debug-im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-global-policy-screenshot"
        )
        let enterprise = Enterprise(
            id: "tenant-global-policy",
            name: "全局策略验收企业",
            code: "GPOLICY",
            role: role,
            status: "正常",
            memberCount: 371,
            isDefault: true,
            accentHex: 0x5D6BFF,
            isCurrent: true
        )
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110

        let policy = RemoteTenantClientPolicy(
            allowMemberGroupCreation: scenario == .memberOn,
            hideMembershipSystemMessages: scenario == .memberOff,
            clientFriendRequests: scenario == .friendOn,
            showGroupMemberCount: true,
            groupMemberCountPolicyGeneration: 1,
            groupMemberCountContractVersion: 1,
            groupMemberCountPolicyAuthoritative: true,
            groupMemberCountPolicyPresent: true,
            showOnlineStatus: scenario == .presence || scenario == .memberOn || scenario == .friendOn,
            showLastLoginTime: scenario == .presence || scenario == .friendOn
        )

        setCurrentUser(IMUser(
            id: "im-global-policy-me",
            userID: "user-global-policy-me",
            username: "USERNAME_PLACEHOLDER",
            name: scenario == .adminOff ? "策略管理员" : "普通成员",
            title: scenario == .adminOff ? "管理员" : "成员",
            department: "移动端验收",
            departmentPathNames: ["移动端验收"],
            phone: "",
            phoneVerified: false,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "policy@example.test",
            status: "在线",
            lastLoginAt: "今天 09:18",
            enterprise: enterprise.name,
            avatarSeed: 0x5D6BFF,
            badges: [role]
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        let onlineFriend = IMUser(
            id: "im-global-policy-online",
            userID: "user-global-policy-online",
            username: "USERNAME_PLACEHOLDER",
            name: "在线同事",
            title: "产品",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: "在线",
            lastLoginAt: "今天 08:52",
            enterprise: enterprise.name,
            avatarSeed: 0x14B8A6,
            badges: ["online"]
        )
        let hiddenFriend = IMUser(
            id: "im-global-policy-hidden",
            userID: "user-global-policy-hidden",
            username: "USERNAME_PLACEHOLDER",
            name: "隐身同事",
            title: "运营",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: "",
            enterprise: enterprise.name,
            avatarSeed: 0xF97316,
            badges: ["hidden"]
        )
        let unknownFriend = IMUser(
            id: "im-global-policy-unknown",
            userID: "user-global-policy-unknown",
            username: "USERNAME_PLACEHOLDER",
            name: "未知状态同事",
            title: "客服",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: "",
            enterprise: enterprise.name,
            avatarSeed: 0x7C3AED,
            badges: ["unknown"]
        )
        let offlineFriend = IMUser(
            id: "im-global-policy-offline",
            userID: "user-global-policy-offline",
            username: "USERNAME_PLACEHOLDER",
            name: "离线同事",
            title: "支持",
            department: "策略组",
            departmentPathNames: ["策略组"],
            phone: "",
            email: "",
            status: "离线",
            lastLoginAt: "昨天 18:20",
            enterprise: enterprise.name,
            avatarSeed: 0x64748B,
            badges: ["offline"]
        )
        contacts = scenario == .friendOff || scenario == .friendOn
            ? []
            : [onlineFriend, hiddenFriend, unknownFriend, offlineFriend]
        blacklist = []
        friendRequests = []

        let group = GroupInfo(
            id: "group-global-policy-main",
            name: "全局策略验收群",
            notice: "群人数展示由商户策略控制。",
            owner: "策略管理员",
            ownerID: "im-global-policy-admin",
            members: [currentUser, onlineFriend, hiddenFriend, unknownFriend, offlineFriend],
            admins: scenario == .adminOff ? [currentUser] : [],
            muted: false,
            allMuted: false,
            myRole: scenario == .adminOff ? "admin" : "member",
            memberCount: 371
        )
        groups = [group]
        conversationStore.commitConversationSnapshots([
            ConversationMessageSnapshot(
                id: group.id,
                title: group.name,
                subtitle: group.memberCountDisplayText,
                kind: .group,
                lastMessage: "群人数：\(group.memberCountDisplayText)",
                time: "09:20",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: shouldShowGroupMemberCount ? group.effectiveMemberCount : nil,
                accentHex: 0x5D6BFF,
                participants: [currentUser, onlineFriend, hiddenFriend],
                messages: []
            )
        ])
        applyTenantClientPolicy(policy, context: apiContext, groupCountDefaults: groupCountDefaults) // WDT_IOS1_A17_DEBUG_QUOTA_FIXTURE_STORAGE_20261111
        return true
    }

    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
    static func authPolicyScreenshotContext() -> IMAPIContext {
        IMAPIContext(
            platformToken: "debug-platform-token",
            accountID: "debug-account-auth-policy",
            tenantID: "tenant-auth-policy",
            imUID: "im-auth-policy-user",
            imToken: "debug-im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-auth-policy-screenshot"
        )
    }
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END

    func configureAuthPolicyScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        let prefix = "--auth-policy-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let scenario = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !scenario.isEmpty else { return false }

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .chats
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        slideCaptchaPresentationStore.clearScreenshotFixturePrompt() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110

        // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112
        apiContext = Self.authPolicyScreenshotContext()

        let enterprise = Enterprise(
            id: "tenant-auth-policy",
            name: "认证策略测试企业",
            code: "123456",
            role: "成员",
            status: "正常",
            memberCount: 128,
            isDefault: true,
            accentHex: 0x14B8A6,
            isCurrent: true
        )
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        contacts = []

        let realNameComplete = scenario == "phone-alert" || scenario == "phone-flow"
        setCurrentUser(IMUser(
            id: "im-auth-policy-user",
            username: "USERNAME_PLACEHOLDER",
            name: "认证测试用户",
            title: "移动端验收",
            department: "QA",
            phone: realNameComplete ? "" : "13800000000",
            phoneVerified: false,
            realNameVerified: realNameComplete,
            realNameStatus: realNameComplete ? "approved" : "pending",
            email: "auth-policy@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x14B8A6,
            badges: ["iOS", "AppId"]
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110

        appPolicyPresentationStore.snapshot.currentAppPolicy = RemoteAppCurrentPolicy( // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            appID: IMAPIContext.canonicalIOSAppID,
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            requireRealName: true,
            requirePhoneVerification: true,
            supportContactEmail: scenario == "contact-email" ? "haha@qq.com" : "",
            supportContactConfigured: scenario == "contact-email",
            cacheTTLSeconds: 60
        )
        currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "live")
        resetForcedAppPolicyAuthState()

        // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
        switch scenario {
        case "both-alert", "realname-alert":
            forcedAppPolicyAuthStore.setPrompt(AppPolicyForcedAuthRequirement.pendingRequirement(
                policy: currentAppPolicy!,
                user: currentUser
            ))
        case "realname-flow":
            forcedAppPolicyAuthStore.setDestination(.realName)
        case "phone-alert":
            forcedAppPolicyAuthStore.setPrompt(AppPolicyForcedAuthRequirement.pendingRequirement(
                policy: currentAppPolicy!,
                user: currentUser
            ))
        case "phone-flow":
            forcedAppPolicyAuthStore.setDestination(.phone)
        // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END
        case "contact-email":
            activeTab = .me
        default:
            return false
        }
        return true
    }

}
// WDT_APPSTATE_DEBUG_FIXTURES_SPLIT_20260924_END
#endif // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
