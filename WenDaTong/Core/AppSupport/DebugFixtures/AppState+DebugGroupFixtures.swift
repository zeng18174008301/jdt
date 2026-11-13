import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit

#if DEBUG
@MainActor
extension AppState {
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
        let conversation = ConversationMessageSnapshot(
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
        bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        activeTab = .chats
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        slideCaptchaPresentationStore.clearScreenshotFixturePrompt() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
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
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setCurrentUser(me) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        contacts = [owner, admin, member].filter { $0.id != me.id }
        groups = [group]
        inboxItems = [] // WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110
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
        let groupConversation = ConversationMessageSnapshot(
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
        let directConversation = ConversationMessageSnapshot(
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
        bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        activeTab = scenario == .directUnaffected ? .chats : .contacts
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        slideCaptchaPresentationStore.clearScreenshotFixturePrompt() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
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
        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setCurrentUser(me) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        contacts = [owner, admin, member, directPeer].filter { $0.id != me.id }
        groups = [group]
        inboxItems = [] // WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110
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
        // WDT_IOS1_REFACTOR_FAVORITE_ASSETS_OBSERVATION_20261110
        fileStore.favoriteAssetsSnapshot.items = []
        conversationStore.hydrateCachedConversations([groupConversation, directConversation])
        if isRestrictedFixture {
            conversationStore.setHistoryMessage(conversationID: group.id, message: groupHistoryLimitedMessageText)
        }
        return true
    }

}
#endif // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
