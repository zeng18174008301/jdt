import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import UIKit

#if DEBUG
@MainActor
extension AppState {
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
            ConversationMessageSnapshot(
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
            ConversationMessageSnapshot(
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
            ConversationMessageSnapshot(
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
        bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        activeTab = scenario == .incomingCall || scenario == .callRecords ? .rtc : .chats
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        slideCaptchaPresentationStore.clearScreenshotFixturePrompt() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
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
        appPolicyPresentationStore.snapshot.currentAppPolicy = RemoteAppCurrentPolicy( // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
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
        appPolicyPresentationStore.snapshot.currentAppPolicyErrorMessage = nil // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        applyAccessDiagnosticsPolicy(currentAppPolicy!, source: "live")

        setCurrentEnterprise(enterprise) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setEnterprises([enterprise]) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setCurrentUser(me) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        contacts = [mia, leo, admin, callPeer, noAvatarPeer]
        groups = [defaultGroup, customGroup]
        friendRequests = []
        blacklist = []
        inboxItems = [] // WDT_IOS1_REFACTOR_UNUSED_GOVERNANCE_OBSERVATION_20261110
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
#endif // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
