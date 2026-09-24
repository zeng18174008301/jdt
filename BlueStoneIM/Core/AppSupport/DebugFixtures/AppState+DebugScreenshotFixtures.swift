import Foundation
import SwiftUI
import UIKit

#if DEBUG
// WDT_APPSTATE_DEBUG_FIXTURES_SPLIT_20260924_BEGIN: DEBUG screenshot fixtures moved out of AppState.swift without behavior changes.
@MainActor
extension AppState {
    func configureRegistrationResolutionScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
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
        hasResolvedCurrentAppPolicyForAuthUI = true
        registrationConfirmationTimedOut = scenario == .timeout
        switch scenario {
        case .pending, .timeout:
            resetForcedAppPolicyAuthState()
            apiContext.clearSession(sessionStore: protectedSessionStore)
            enterprises = []
            isAuthenticated = false
            authScreen = .accountRegister
            activeTab = .chats
            registrationResolutionState = .pending
            toast = scenario == .timeout
                ? RegistrationConfirmationPolicy.timeoutMessage
                : RegistrationConfirmationPolicy.pendingMessage
        case .success:
            registrationResolutionState = .success
            toast = "注册成功，已自动登录"
        }
        return true
    }

    func configureLicenseQuotaScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
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
            apiContext.clearSession(sessionStore: protectedSessionStore)
            enterprises = []
            isAuthenticated = false
            authScreen = .accountRegister
            activeTab = .chats
            toast = IMAPIClient.licenseQuotaUserMessage(for: "registered_user_quota_exceeded")

        case .onlineLimit, .onlineServiceUnavailable:
            guard configureGlobalPolicyScreenshotScenarioIfRequested([
                "--global-policy-screenshot=member-on"
            ]) else {
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

    func configureGlobalPolicyScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
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
        isShowingLaunchSplash = false
        isRestoringSession = false
        isInitialDataLoading = false
        hasLoadedRemoteSnapshot = true
        authScreen = .accountLogin
        isAuthenticated = true
        activeTab = .contacts
        toast = nil
        slideCaptchaPrompt = nil
        activeSplashOverlay = nil
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
        currentEnterprise = enterprise
        enterprises = [enterprise]

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

        currentUser = IMUser(
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
        )

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
        conversationStore.conversations = [
            Conversation(
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
        ]
        applyTenantClientPolicy(policy, context: apiContext)
        return true
    }

    func configureAuthPolicyScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        let prefix = "--auth-policy-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let scenario = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !scenario.isEmpty else { return false }

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        isShowingLaunchSplash = false
        isRestoringSession = false
        isInitialDataLoading = false
        hasLoadedRemoteSnapshot = true
        authScreen = .accountLogin
        isAuthenticated = true
        activeTab = .chats
        toast = nil
        slideCaptchaPrompt = nil

        apiContext = IMAPIContext(
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
        currentEnterprise = enterprise
        enterprises = [enterprise]
        contacts = []

        let realNameComplete = scenario == "phone-alert" || scenario == "phone-flow"
        currentUser = IMUser(
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
        )

        currentAppPolicy = RemoteAppCurrentPolicy(
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
        currentAppPolicyErrorMessage = nil
        applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "live")
        resetForcedAppPolicyAuthState()

        switch scenario {
        case "both-alert", "realname-alert":
            forcedAppPolicyAuthPrompt = AppPolicyForcedAuthRequirement.pendingRequirement(
                policy: currentAppPolicy!,
                user: currentUser
            )
        case "realname-flow":
            forcedAppPolicyAuthDestination = .realName
        case "phone-alert":
            forcedAppPolicyAuthPrompt = AppPolicyForcedAuthRequirement.pendingRequirement(
                policy: currentAppPolicy!,
                user: currentUser
            )
        case "phone-flow":
            forcedAppPolicyAuthDestination = .phone
        case "contact-email":
            activeTab = .me
        default:
            return false
        }
        return true
    }

    func configureAvatarStage4ScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        let prefix = "--avatar-stage4-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = AvatarStage4ScreenshotScenario(rawValue: rawScenario) else {
            return false
        }

        let meAvatar = avatarStage4FixtureImageURL(fileName: "me-v4.png", startHex: 0x2563EB, endHex: 0x14B8A6, text: "LH")
        let miaAvatar = avatarStage4FixtureImageURL(fileName: "mia-v2.png", startHex: 0xF97316, endHex: 0xEC4899, text: "MW")
        let leoAvatar = avatarStage4FixtureImageURL(fileName: "leo-v5.png", startHex: 0x7C3AED, endHex: 0x0EA5E9, text: "LC")
        let adminAvatar = avatarStage4FixtureImageURL(fileName: "admin-v7.png", startHex: 0x0F172A, endHex: 0x64748B, text: "AA")
        let callAvatar = avatarStage4FixtureImageURL(fileName: "call-peer-v9.png", startHex: 0x16A34A, endHex: 0x22C55E, text: "RC")
        let groupAvatar = avatarStage4FixtureImageURL(fileName: "group-v3.png", startHex: 0x0891B2, endHex: 0x4F46E5, text: "GX")

        let enterprise = Enterprise(
            id: "tenant-avatar-stage4",
            name: "头像闭环验收企业",
            code: "AVATAR4",
            role: "iOS Owner",
            status: "正常",
            memberCount: 36,
            isDefault: true,
            accentHex: 0x5D6BFF,
            isCurrent: true
        )

        let me = IMUser(
            id: "im-avatar-me",
            userID: "user-avatar-me",
            username: "USERNAME_PLACEHOLDER",
            name: "林昊",
            title: "iOS 验收",
            department: "头像专项",
            phone: "+86 13800000001",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "linhao.avatar@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x5D6BFF,
            avatarURL: meAvatar,
            avatarVersion: "user-me-v4",
            avatarUpdatedAt: "2026-06-26T09:00:00Z",
            badges: ["当前用户"]
        )
        let mia = IMUser(
            id: "im-avatar-mia",
            userID: "user-avatar-mia",
            username: "USERNAME_PLACEHOLDER",
            name: "Mia Wong",
            title: "交易运营",
            department: "Ops",
            phone: "+65 6123 8802",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "mia.avatar@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0xF97316,
            avatarURL: miaAvatar,
            avatarVersion: "user-mia-v2",
            avatarUpdatedAt: "2026-06-26T09:10:00Z",
            badges: ["用户默认/自定义"]
        )
        let leo = IMUser(
            id: "im-avatar-leo",
            userID: "user-avatar-leo",
            username: "USERNAME_PLACEHOLDER",
            name: "Leo Chen",
            title: "群管理员",
            department: "Risk",
            phone: "+65 6123 8803",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "leo.avatar@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x7C3AED,
            avatarURL: leoAvatar,
            avatarVersion: "user-leo-v5",
            avatarUpdatedAt: "2026-06-26T09:20:00Z",
            badges: ["群成员"]
        )
        let admin = IMUser(
            id: "im-avatar-admin",
            userID: "admin-avatar-ada",
            username: "USERNAME_PLACEHOLDER",
            name: "Ada 陪聊管理员",
            title: "陪聊后台",
            department: "Admin",
            phone: "+65 6123 8804",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "ada.admin@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x0F172A,
            avatarURL: adminAvatar,
            avatarVersion: "admin-ada-v7",
            avatarUpdatedAt: "2026-06-26T09:30:00Z",
            badges: ["管理员"]
        )
        let callPeer = IMUser(
            id: "im-avatar-call",
            userID: "user-avatar-call",
            username: "USERNAME_PLACEHOLDER",
            name: "Rina Call",
            title: "语音验收",
            department: "Voice",
            phone: "+65 6123 8805",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "rina.call@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x16A34A,
            avatarURL: callAvatar,
            avatarVersion: "call-peer-v9",
            avatarUpdatedAt: "2026-06-26T09:40:00Z",
            badges: ["RTC"]
        )
        let noAvatarPeer = IMUser(
            id: "im-avatar-no-url",
            userID: "user-avatar-no-url",
            username: "USERNAME_PLACEHOLDER",
            name: "No Avatar",
            title: "无头像兜底",
            department: "Voice",
            phone: "+65 6123 8806",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "no.avatar@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0xFFB246,
            badges: ["fallback"]
        )

        let readBy = [
            ReadReceipt(id: "avatar-rr-me", user: me, device: "iPhone", time: "10:05"),
            ReadReceipt(id: "avatar-rr-mia", user: mia, device: "Web", time: "10:05")
        ]
        let groupMessages = [
            ChatMessage(
                id: "avatar-m1",
                senderId: mia.id,
                senderName: mia.name,
                senderAvatarURL: mia.avatarURL,
                senderAvatarVersion: mia.avatarVersion,
                senderAvatarUpdatedAt: mia.avatarUpdatedAt,
                senderAvatarSeed: mia.avatarSeed,
                text: "自定义头像已从后端资料同步，列表和消息里都应该直接 cover 填满。",
                time: "10:01",
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: readBy,
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            ),
            ChatMessage(
                id: "avatar-m2",
                senderId: me.id,
                senderName: me.name,
                senderAvatarURL: me.avatarURL,
                senderAvatarVersion: me.avatarVersion,
                senderAvatarUpdatedAt: me.avatarUpdatedAt,
                senderAvatarSeed: me.avatarSeed,
                text: "收到。群未设置头像时走系统群默认头像，设置后所有入口刷新为自定义群头像。",
                time: "10:03",
                isOutgoing: true,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: readBy,
                unreadBy: [],
                quote: "自定义头像已从后端资料同步",
                attachmentName: nil,
                attachmentMeta: nil
            ),
            ChatMessage(
                id: "avatar-m3",
                senderId: admin.id,
                senderName: admin.name,
                senderAvatarURL: admin.avatarURL,
                senderAvatarVersion: admin.avatarVersion,
                senderAvatarUpdatedAt: admin.avatarUpdatedAt,
                senderAvatarSeed: admin.avatarSeed,
                text: "管理员/陪聊身份头像也要保留 version 和 updatedAt，避免缓存今天好明天丢。",
                time: "10:06",
                isOutgoing: false,
                status: .sent,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            )
        ]
        let directMessages = [
            ChatMessage(
                id: "avatar-d1",
                senderId: callPeer.id,
                senderName: callPeer.name,
                senderAvatarURL: callPeer.avatarURL,
                senderAvatarVersion: callPeer.avatarVersion,
                senderAvatarUpdatedAt: callPeer.avatarUpdatedAt,
                senderAvatarSeed: callPeer.avatarSeed,
                text: "下一通语音如果没有头像，不应该沿用我这张图。",
                time: "09:58",
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            )
        ]

        let defaultGroup = GroupInfo(
            id: "group-avatar-default",
            name: "默认群头像验收群",
            notice: "未设置头像时展示统一系统群默认头像。",
            owner: me.name,
            ownerID: me.id,
            members: [me, mia, leo],
            admins: [leo],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            myRole: "owner",
            memberCount: 3
        )
        let customGroup = GroupInfo(
            id: "group-avatar-custom",
            name: "自定义群头像验收群",
            avatarURL: groupAvatar,
            avatarVersion: "group-custom-v3",
            avatarUpdatedAt: "2026-06-26T10:00:00Z",
            notice: "设置头像后所有群入口展示自定义头像。",
            owner: me.name,
            ownerID: me.id,
            members: [me, mia, leo, admin],
            admins: [leo, admin],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            myRole: "owner",
            memberCount: 4
        )

        let conversations = [
            Conversation(
                id: "conv-avatar-default-group",
                title: defaultGroup.name,
                subtitle: "群聊 · 系统默认头像",
                kind: .group,
                lastMessage: "未设置头像，使用统一群默认头像",
                time: "10:08",
                unread: 1,
                isPinned: true,
                isMuted: false,
                memberCount: defaultGroup.memberCount,
                accentHex: 0x5D6BFF,
                participants: defaultGroup.members,
                messages: groupMessages,
                avatarURL: "",
                avatarVersion: "",
                avatarUpdatedAt: ""
            ),
            Conversation(
                id: "conv-avatar-custom-group",
                title: customGroup.name,
                subtitle: "群聊 · 自定义头像 v3",
                kind: .group,
                lastMessage: "Ada：管理员/陪聊身份头像也要保留 version",
                time: "10:06",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: customGroup.memberCount,
                accentHex: 0x0891B2,
                participants: customGroup.members,
                messages: groupMessages,
                avatarURL: customGroup.avatarURL,
                avatarVersion: customGroup.avatarVersion,
                avatarUpdatedAt: customGroup.avatarUpdatedAt
            ),
            Conversation(
                id: "conv-avatar-direct-call",
                title: callPeer.name,
                subtitle: "单聊 · 语音头像来源",
                kind: .direct,
                lastMessage: "下一通语音如果没有头像，不应该沿用我这张图。",
                time: "09:58",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 2,
                accentHex: callPeer.avatarSeed,
                participants: [callPeer],
                messages: directMessages
            )
        ]

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        avatarStage4ScreenshotScenario = scenario
        isShowingLaunchSplash = false
        isRestoringSession = false
        isInitialDataLoading = false
        hasLoadedRemoteSnapshot = true
        isAuthenticated = true
        authScreen = .accountLogin
        activeTab = scenario == .incomingCall || scenario == .callRecords ? .rtc : .chats
        toast = nil
        slideCaptchaPrompt = nil
        resetForcedAppPolicyAuthState()

        apiContext = IMAPIContext(
            platformToken: "debug-platform-token",
            accountID: "debug-account-avatar-stage4",
            tenantID: enterprise.id,
            imUID: me.id,
            imToken: "debug-im-token-avatar-stage4",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-avatar-stage4-screenshot"
        )
        currentAppPolicy = RemoteAppCurrentPolicy(
            appID: IMAPIContext.canonicalIOSAppID,
            platform: "ios",
            status: "active",
            allowWorkspaceSwitch: true,
            allowDefaultTenantJoin: true,
            requireRealName: false,
            requirePhoneVerification: false,
            supportContactEmail: "",
            supportContactConfigured: false,
            cacheTTLSeconds: 60
        )
        currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        currentAppPolicyErrorMessage = nil
        applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "live")

        currentEnterprise = enterprise
        enterprises = [enterprise]
        currentUser = me
        contacts = [mia, leo, admin, callPeer, noAvatarPeer]
        groups = [defaultGroup, customGroup]
        friendRequests = []
        blacklist = []
        inboxItems = []
        governanceItems = []
        files = []
        conversationStore.hydrateCachedConversations(conversations)

        let now = Date()
        calls = [
            CallRecord(
                id: "call-avatar-incoming",
                callID: "rtc-avatar-incoming",
                peerID: callPeer.id,
                peerUserID: callPeer.userID,
                peerAvatarURL: callPeer.avatarURL,
                peerAvatarVersion: callPeer.avatarVersion,
                peerAvatarUpdatedAt: callPeer.avatarUpdatedAt,
                peerAvatarSource: "fixture_profile",
                title: callPeer.name,
                subtitle: "语音来电 · 已接听",
                time: "10:12",
                status: "已结束",
                direction: .incoming,
                startedAt: now.addingTimeInterval(-420),
                endedAt: now.addingTimeInterval(-180),
                durationSeconds: 240
            ),
            CallRecord(
                id: "call-avatar-fallback",
                callID: "rtc-avatar-no-url",
                peerID: noAvatarPeer.id,
                peerUserID: noAvatarPeer.userID,
                title: noAvatarPeer.name,
                subtitle: "语音呼出 · 无头像兜底",
                time: "09:30",
                status: "未接通",
                direction: .outgoing,
                startedAt: now.addingTimeInterval(-3600),
                endedAt: now.addingTimeInterval(-3540),
                durationSeconds: 0
            )
        ]

        incomingVoiceCall = scenario == .incomingCall ? IncomingVoiceCall(
            id: "incoming-avatar-stage4",
            callID: "rtc-avatar-live-incoming",
            caller: callPeer,
            startedAt: "刚刚",
            source: "VoIP Push · caller_profile.avatar"
        ) : nil
        activeVoiceCall = scenario == .activeCall ? VoiceCallSession(
            id: "active-avatar-stage4",
            callID: "rtc-avatar-live-active",
            roomID: "room-avatar-stage4",
            rtcToken: "debug-rtc-token",
            mediaBaseURL: "https://media.example.test",
            peer: callPeer,
            direction: "来电",
            startedAt: "刚刚",
            statusText: "通话中",
            mediaState: .connected,
            isMuted: false,
            speakerOn: true,
            startedAtDate: now.addingTimeInterval(-86),
            connectedAt: now.addingTimeInterval(-62)
        ) : nil
        isStartingVoiceCall = false
        return true
    }

    func configureGroupLifecycleScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        let prefix = "--group-lifecycle-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = GroupLifecycleScreenshotScenario(rawValue: rawScenario) else {
            return false
        }

        let enterprise = Enterprise(
            id: "tenant-group-lifecycle",
            name: "群生命周期验收企业",
            code: "GROUP4",
            role: "成员",
            status: "正常",
            memberCount: 42,
            isDefault: true,
            accentHex: 0x5D6BFF,
            isCurrent: true
        )
        let meRole: String = {
            switch scenario {
            case .owner, .dissolveConfirm:
                return "owner"
            case .admin:
                return "admin"
            case .member:
                return "member"
            }
        }()
        let me = IMUser(
            id: "im-group-me",
            userID: "user-group-me",
            username: "USERNAME_PLACEHOLDER",
            name: meRole == "owner" ? "群主验收号" : (meRole == "admin" ? "管理员验收号" : "成员验收号"),
            title: "iOS Stage 4",
            department: "QA",
            phone: "13800000001",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "group.lifecycle@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x5D6BFF,
            badges: [meRole]
        )
        let owner = meRole == "owner" ? me : IMUser(
            id: "im-group-owner",
            userID: "user-group-owner",
            username: "USERNAME_PLACEHOLDER",
            name: "项目群主",
            title: "Owner",
            department: "QA",
            phone: "13800000002",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "owner.lifecycle@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x14B8A6,
            badges: ["owner"]
        )
        let admin = meRole == "admin" ? me : IMUser(
            id: "im-group-admin",
            userID: "user-group-admin",
            username: "USERNAME_PLACEHOLDER",
            name: "群管理员",
            title: "Admin",
            department: "QA",
            phone: "13800000003",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "admin.lifecycle@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x7C3AED,
            badges: ["admin"]
        )
        let member = meRole == "member" ? me : IMUser(
            id: "im-group-member",
            userID: "user-group-member",
            username: "USERNAME_PLACEHOLDER",
            name: "普通成员",
            title: "Member",
            department: "QA",
            phone: "13800000004",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "member.lifecycle@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0xF97316,
            badges: ["member"]
        )
        let group = GroupInfo(
            id: "group-lifecycle-stage4",
            name: "群聊退出解散验收群",
            notice: "用于 iOS Stage 4 角色入口、退出确认和解散确认验收。",
            owner: owner.name,
            ownerID: owner.id,
            members: [owner, admin, member],
            admins: [admin],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            myRole: meRole,
            memberCount: 3
        )
        let conversation = Conversation(
            id: group.id,
            title: group.name,
            subtitle: "群聊 · 生命周期验收",
            kind: .group,
            lastMessage: "群生命周期操作入口正在验收",
            time: "刚刚",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: group.memberCount,
            accentHex: 0x5D6BFF,
            participants: group.members,
            messages: []
        )

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        groupLifecycleScreenshotScenario = scenario
        avatarStage4ScreenshotScenario = nil
        isShowingLaunchSplash = false
        isRestoringSession = false
        isInitialDataLoading = false
        hasLoadedRemoteSnapshot = true
        isAuthenticated = true
        authScreen = .accountLogin
        activeTab = .chats
        toast = nil
        slideCaptchaPrompt = nil
        resetForcedAppPolicyAuthState()

        apiContext = IMAPIContext(
            platformToken: "debug-platform-token",
            accountID: "debug-account-group-lifecycle",
            tenantID: enterprise.id,
            imUID: me.id,
            imToken: "debug-im-token-group-lifecycle",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-group-lifecycle-screenshot"
        )
        currentEnterprise = enterprise
        enterprises = [enterprise]
        currentUser = me
        contacts = [owner, admin, member].filter { $0.id != me.id }
        groups = [group]
        inboxItems = []
        governanceItems = []
        files = []
        conversationStore.hydrateCachedConversations([conversation])
        return true
    }

    func configureGroupHistoryVisibilityScreenshotScenarioIfRequested(_ launchArguments: [String]) -> Bool {
        let prefix = "--group-history-screenshot="
        guard let argument = launchArguments.first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let rawScenario = String(argument.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let scenario = GroupHistoryVisibilityScreenshotScenario(rawValue: rawScenario) else {
            return false
        }

        let enterprise = Enterprise(
            id: "tenant-group-history",
            name: "历史边界验收企业",
            code: "HISTORY",
            role: "iOS Owner",
            status: "正常",
            memberCount: 18,
            isDefault: true,
            accentHex: 0x5D6BFF,
            isCurrent: true
        )
        let owner = IMUser(
            id: "im-history-owner",
            userID: "user-history-owner",
            username: "USERNAME_PLACEHOLDER",
            name: "边界群主",
            title: "Owner",
            department: "QA",
            phone: "13800001001",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "owner.history@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x5D6BFF,
            badges: ["owner"]
        )
        let admin = IMUser(
            id: "im-history-admin",
            userID: "user-history-admin",
            username: "USERNAME_PLACEHOLDER",
            name: "边界管理员",
            title: "Admin",
            department: "QA",
            phone: "13800001002",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "admin.history@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x14B8A6,
            badges: ["admin"]
        )
        let member = IMUser(
            id: "im-history-member",
            userID: "user-history-member",
            username: "USERNAME_PLACEHOLDER",
            name: "新成员验收号",
            title: "Member",
            department: "QA",
            phone: "13800001003",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "member.history@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0xF97316,
            badges: ["member"]
        )
        let directPeer = IMUser(
            id: "im-history-direct",
            userID: "user-history-direct",
            username: "USERNAME_PLACEHOLDER",
            name: "单聊同事",
            title: "Direct",
            department: "QA",
            phone: "13800001004",
            phoneVerified: true,
            realNameVerified: true,
            realNameStatus: "approved",
            email: "direct.history@example.test",
            status: "在线",
            enterprise: enterprise.name,
            avatarSeed: 0x7C3AED,
            badges: ["direct"]
        )

        let me: IMUser = {
            switch scenario {
            case .ownerSettings, .ownerSettingsLimited:
                return owner
            case .memberReadonly, .restrictedGroup, .restrictedGroupFiles, .episodeWidened, .directUnaffected:
                return member
            }
        }()
        let historyVisible = scenario == .ownerSettings
        let isRestrictedFixture = scenario == .restrictedGroup || scenario == .restrictedGroupFiles
        let isHistoryLimitedFixture = isRestrictedFixture || scenario == .memberReadonly
        let group = GroupInfo(
            id: "group-history-boundary",
            name: "历史边界验收群",
            notice: "",
            owner: owner.name,
            ownerID: owner.id,
            members: [owner, admin, member],
            admins: [admin],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            myRole: me.id == owner.id ? "owner" : "member",
            memberCount: 3,
            inviteConfirmRequired: false,
            pendingJoinRequestCount: 0,
            fileCount: isRestrictedFixture ? 0 : 2,
            blacklistCount: 0,
            historyVisible: historyVisible,
            historyVisibleFromSeq: scenario == .episodeWidened ? 1 : 421,
            historyLimited: isHistoryLimitedFixture
        )

        let visibleGroupMessages = [
            ChatMessage(
                id: "history-m421",
                senderId: owner.id,
                senderName: owner.name,
                senderAvatarSeed: owner.avatarSeed,
                text: "seq 421：入群后第一条。",
                time: "12:41",
                channelSeq: 421,
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            ),
            ChatMessage(
                id: "history-m422",
                senderId: member.id,
                senderName: member.name,
                senderAvatarSeed: member.avatarSeed,
                text: "seq 422：边界后消息。",
                time: "12:42",
                channelSeq: 422,
                isOutgoing: me.id == member.id,
                status: .sent,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            )
        ]
        let widenedGroupMessages = [
            ChatMessage(
                id: "history-m001",
                senderId: owner.id,
                senderName: owner.name,
                senderAvatarSeed: owner.avatarSeed,
                text: "seq 1：新 episode 重拉。",
                time: "09:01",
                channelSeq: 1,
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            ),
            ChatMessage(
                id: "history-m420",
                senderId: admin.id,
                senderName: admin.name,
                senderAvatarSeed: admin.avatarSeed,
                text: "seq 420：扩权后可见。",
                time: "12:40",
                channelSeq: 420,
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            )
        ] + visibleGroupMessages
        let directMessages = [
            ChatMessage(
                id: "history-d001",
                senderId: directPeer.id,
                senderName: directPeer.name,
                senderAvatarSeed: directPeer.avatarSeed,
                text: "direct seq 1：单聊不裁剪。",
                time: "10:01",
                channelSeq: 1,
                isOutgoing: false,
                status: .read,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            ),
            ChatMessage(
                id: "history-d002",
                senderId: member.id,
                senderName: member.name,
                senderAvatarSeed: member.avatarSeed,
                text: "direct seq 2：完整显示。",
                time: "10:02",
                channelSeq: 2,
                isOutgoing: true,
                status: .sent,
                kind: .text,
                reactions: [],
                readBy: [],
                unreadBy: [],
                quote: nil,
                attachmentName: nil,
                attachmentMeta: nil
            )
        ]
        let groupMessages = scenario == .episodeWidened ? widenedGroupMessages : visibleGroupMessages
        let groupConversation = Conversation(
            id: group.id,
            title: group.name,
            subtitle: group.historyLimited ? "群聊 · 仅入群后" : "群聊 · 全部可见",
            kind: .group,
            lastMessage: groupMessages.last?.text ?? "",
            time: groupMessages.last?.time ?? "刚刚",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: group.memberCount,
            accentHex: 0x5D6BFF,
            participants: group.members,
            messages: groupMessages,
            lastMsgSeq: groupMessages.last?.channelSeq ?? 0,
            sortTimestamp: Date().timeIntervalSince1970,
            historyVisibleFromSeq: group.historyVisibleFromSeq,
            historyLimited: group.historyLimited,
            historyBoundaryConfirmed: true
        )
        let directConversation = Conversation(
            id: "direct-history-unaffected",
            title: directPeer.name,
            subtitle: "单聊 · 不受群历史边界影响",
            kind: .direct,
            lastMessage: directMessages.last?.text ?? "",
            time: "10:02",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 2,
            accentHex: directPeer.avatarSeed,
            participants: [directPeer],
            messages: directMessages,
            lastMsgSeq: directMessages.last?.channelSeq ?? 0,
            sortTimestamp: Date().timeIntervalSince1970
        )

        launchSplashDismissTasks.cancel()
        authPolicyScreenshotModeEnabled = true
        forceDisableAccessDiagnosticsOverlay()
        groupHistoryVisibilityScreenshotScenario = scenario
        groupLifecycleScreenshotScenario = nil
        avatarStage4ScreenshotScenario = nil
        isShowingLaunchSplash = false
        isRestoringSession = false
        isInitialDataLoading = false
        hasLoadedRemoteSnapshot = true
        isAuthenticated = true
        authScreen = .accountLogin
        activeTab = scenario == .directUnaffected ? .chats : .contacts
        toast = nil
        slideCaptchaPrompt = nil
        resetForcedAppPolicyAuthState()

        apiContext = IMAPIContext(
            platformToken: "debug-platform-token",
            accountID: "debug-account-group-history",
            tenantID: enterprise.id,
            imUID: me.id,
            imToken: "debug-im-token-group-history",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "ios-group-history-screenshot"
        )
        currentEnterprise = enterprise
        enterprises = [enterprise]
        currentUser = me
        contacts = [owner, admin, member, directPeer].filter { $0.id != me.id }
        groups = [group]
        inboxItems = []
        governanceItems = []
        files = isRestrictedFixture ? [] : [
            FileItem(
                id: "history-file-421",
                name: "visible-421.pdf",
                type: "PDF",
                size: "240 KB",
                owner: owner.name,
                source: group.name,
                time: "12:41",
                scope: "群文件",
                status: "可预览",
                accentHex: 0x5D6BFF,
                channelID: group.id,
                channelType: "group",
                channelSeq: 421,
                mediaCategory: "document",
                mimeType: "application/pdf",
                fileExtension: "pdf"
            )
        ]
        fileStore.replaceGroupFiles(files, groupID: group.id)
        favoriteAssets = []
        conversationStore.hydrateCachedConversations([groupConversation, directConversation])
        if isRestrictedFixture {
            conversationStore.setHistoryMessage(conversationID: group.id, message: groupHistoryLimitedMessageText)
        }
        return true
    }

    private func avatarStage4FixtureImageURL(fileName: String, startHex: UInt, endHex: UInt, text: String) -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("im2-avatar-stage4-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let image = avatarStage4FixtureImage(startHex: startHex, endHex: endHex, text: text)
        if let data = image.pngData() {
            try? data.write(to: url, options: [.atomic])
        }
        return url.absoluteString
    }

    private func avatarStage4FixtureImage(startHex: UInt, endHex: UInt, text: String) -> UIImage {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cgContext = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                avatarStage4FixtureColor(startHex).cgColor,
                avatarStage4FixtureColor(endHex).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            UIColor.white.withAlphaComponent(0.20).setFill()
            UIBezierPath(ovalIn: CGRect(x: 100, y: -18, width: 104, height: 104)).fill()
            UIColor.black.withAlphaComponent(0.10).setFill()
            UIBezierPath(ovalIn: CGRect(x: -34, y: 112, width: 116, height: 116)).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .black),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let textRect = CGRect(x: 0, y: 58, width: size.width, height: 70)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    private func avatarStage4FixtureColor(_ hex: UInt) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
// WDT_APPSTATE_DEBUG_FIXTURES_SPLIT_20260924_END
#endif
