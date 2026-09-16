import Foundation

enum MockData {
    static let enterprises: [Enterprise] = [
        Enterprise(id: "ent_default", name: "BlueStone 默认企业", code: "DEFAULT", role: "成员", status: "当前企业", memberCount: 86, isDefault: true, accentHex: 0x5D6BFF),
        Enterprise(id: "ent_atlas", name: "Atlas Capital 新加坡", code: "ATLAS-SG", role: "风控经理", status: "已加入", memberCount: 238, isDefault: false, accentHex: 0x7C6BFF),
        Enterprise(id: "ent_harbor", name: "Harbor 交易协作", code: "HARBOR-OPS", role: "外部协作", status: "待审批", memberCount: 124, isDefault: false, accentHex: 0x18B6D7)
    ]

    static let currentUser = IMUser(
        id: "u_me",
        name: "林昊",
        title: "风控经理",
        department: "风险与合规 / Asia Desk",
        phone: "+65 6123 8801",
        email: "linhao@bluestone.example",
        status: "在线",
        enterprise: "BlueStone 默认企业",
        avatarSeed: 0x5D6BFF,
        badges: ["实名已验证", "设备已绑定"]
    )

    static let contacts: [IMUser] = [
        IMUser(id: "u_mia", name: "Mia Wong", title: "", department: "", phone: "+65 6123 8890", email: "mia.wong@bluestone.example", status: "在线", enterprise: "BlueStone 默认企业", avatarSeed: 0x50D2FF, badges: []),
        IMUser(id: "u_leo", name: "Leo Chen", title: "", department: "", phone: "+65 6123 8891", email: "leo.chen@bluestone.example", status: "忙碌", enterprise: "BlueStone 默认企业", avatarSeed: 0x7C6BFF, badges: []),
        IMUser(id: "u_nina", name: "Nina Zhao", title: "", department: "", phone: "+65 6123 8892", email: "nina.zhao@bluestone.example", status: "离线", enterprise: "BlueStone 默认企业", avatarSeed: 0x23C48E, badges: []),
        IMUser(id: "u_amy", name: "Amy Tan", title: "", department: "", phone: "+65 6123 8893", email: "amy.tan@bluestone.example", status: "在线", enterprise: "BlueStone 默认企业", avatarSeed: 0xFFB246, badges: []),
        IMUser(id: "u_ray", name: "Ray Xu", title: "", department: "", phone: "+65 6123 8894", email: "ray.xu@bluestone.example", status: "在线", enterprise: "BlueStone 默认企业", avatarSeed: 0xFF6E91, badges: []),
        IMUser(id: "u_kai", name: "Kai Tan", title: "", department: "", phone: "+65 6123 8895", email: "kai.tan@bluestone.example", status: "在线", enterprise: "BlueStone 默认企业", avatarSeed: 0x3546D8, badges: [])
    ]

    static let friendRequests: [FriendRequest] = [
        FriendRequest(id: "fr_1", name: "An Chen", source: "KYC 审核通过", message: "我是 Atlas Ops 的协作成员", accepted: false),
        FriendRequest(id: "fr_2", name: "张怡", source: "邀请码加入", message: "申请加入项目沟通", accepted: false),
        FriendRequest(id: "fr_3", name: "Harbor Bot", source: "客服入口", message: "企业客服机器人", accepted: true)
    ]

    static let blacklist: [BlacklistItem] = [
        BlacklistItem(id: "blk_1", name: "外部测试账号", reason: "异常加好友频率"),
        BlacklistItem(id: "blk_2", name: "已离职访客", reason: "合规处理")
    ]

    static let files: [FileItem] = [
        FileItem(id: "f_trade", name: "trade-confirmation-0618.pdf", type: "PDF", size: "2.4 MB", owner: "Mia Wong", source: "交易通知群", time: "10:18", scope: "tenant/files/2026/06", status: "安全扫描通过", accentHex: 0x5D6BFF),
        FileItem(id: "f_risk", name: "risk-audit-snapshot.png", type: "PNG", size: "1.8 MB", owner: "Nina Zhao", source: "风险复核群", time: "09:58", scope: "tenant/audit/images", status: "仅群成员可见", accentHex: 0x23C48E),
        FileItem(id: "f_roadmap", name: "im-1.0-mobile-roadmap.xlsx", type: "XLSX", size: "640 KB", owner: "Ray Xu", source: "IM 1.0 产品群", time: "昨天", scope: "tenant/product/docs", status: "文件服务灰度中", accentHex: 0x7C6BFF),
        FileItem(id: "f_policy", name: "device-security-policy.pdf", type: "PDF", size: "820 KB", owner: "Kai Tan", source: "系统通知", time: "周一", scope: "tenant/security", status: "可下载", accentHex: 0x18B6D7)
    ]

    static let calls: [CallRecord] = [
        CallRecord(id: "c_1", title: "Mia Wong", subtitle: "语音呼出 · 未接通", time: "10:24", status: "未接通", direction: .outgoing),
        CallRecord(id: "c_2", title: "Ray Xu", subtitle: "语音来电 · 已取消", time: "昨天", status: "已取消", direction: .incoming),
        CallRecord(id: "c_3", title: "设备安全核验", subtitle: "系统通话记录", time: "周一", status: "已结束", direction: .system)
    ]

    static let inboxItems: [InboxItem] = [
        InboxItem(id: "inbox_1", title: "设备安全策略更新", subtitle: "管理员开启新设备登录提醒和强制下线审计。", time: "今天 09:12", category: "system", isRead: false, accentHex: 0x18B6D7),
        InboxItem(id: "inbox_2", title: "交易通知群公告已更新", subtitle: "文件外发审批和敏感词复核将在本周灰度。", time: "昨天", category: "announcement", isRead: false, accentHex: 0x5D6BFF),
        InboxItem(id: "inbox_3", title: "加入 Atlas Capital 申请", subtitle: "企业管理员正在审核你的加入申请。", time: "周一", category: "system", isRead: true, accentHex: 0x18B6D7)
    ]

    static let governanceItems: [GovernanceItem] = [
        GovernanceItem(id: "gov_report", title: "消息举报", detail: "1 条举报待处置，已同步商户后台 message_reports。", status: "待复核", accentHex: 0xFF6E91),
        GovernanceItem(id: "gov_sensitive", title: "敏感词审计", detail: "命中 2 条风控词，支持定位到原始消息。", status: "可定位", accentHex: 0xFFB246),
        GovernanceItem(id: "gov_mute", title: "全员禁言", detail: "风险复核群处于审批模式，管理员可临时解除。", status: "灰度中", accentHex: 0x7C6BFF),
        GovernanceItem(id: "gov_appeal", title: "申诉中心", detail: "设备封禁、消息处置可提交申诉。", status: "灰度中", accentHex: 0x18B6D7)
    ]

    static let tenantPolicy = TenantPolicy(
        messageRetention: "180 天",
        fileLimit: "单文件 200 MB",
        groupLimit: "500 人 / 群",
        deviceLimit: "10 台设备",
        rateLimit: "60 条 / 分钟",
        sensitiveAudit: "敏感词命中后先发后审"
    )

    static let deviceSessions: [DeviceSession] = [
        DeviceSession(id: "dev_ios", name: "iPhone 17 Pro", platform: "iOS", lastSeen: "当前在线", status: "可信设备", isBound: true, isBlocked: false),
        DeviceSession(id: "dev_web", name: "Chrome / macOS", platform: "Web", lastSeen: "10 分钟前", status: "在线", isBound: true, isBlocked: false),
        DeviceSession(id: "dev_win", name: "Windows PC", platform: "PC", lastSeen: "昨天 21:18", status: "已离线", isBound: false, isBlocked: false)
    ]

    static let loginLogs: [LoginLog] = [
        LoginLog(id: "log_1", device: "iPhone 17 Pro", location: "Singapore", time: "刚刚", result: "成功"),
        LoginLog(id: "log_2", device: "Chrome / macOS", location: "Singapore", time: "10 分钟前", result: "成功"),
        LoginLog(id: "log_3", device: "Unknown Browser", location: "Hong Kong", time: "昨天 21:18", result: "已拦截")
    ]

    static var defaultEnterprise: Enterprise {
        enterprises.first(where: { $0.isDefault }) ?? Enterprise(
            id: "ent_default_fallback",
            name: "BlueStone 默认企业",
            code: "DEFAULT",
            role: "成员",
            status: "当前企业",
            memberCount: 1,
            isDefault: true,
            accentHex: 0x5D6BFF
        )
    }

    static var defaultGroup: GroupInfo {
        GroupInfo(
            id: "g_default",
            name: "默认群聊",
            notice: "企业协作消息会在这里同步。",
            owner: currentUser.name,
            members: contacts.isEmpty ? [currentUser] : contacts,
            admins: [contacts[safe: 0] ?? currentUser],
            muted: false,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil
        )
    }

    static var emptyConversation: Conversation {
        Conversation(
            id: "conv_empty",
            title: "暂无会话",
            subtitle: "空状态",
            kind: .system,
            lastMessage: "暂时没有可展示的消息",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 0,
            accentHex: 0x5D6BFF,
            participants: [],
            messages: []
        )
    }

    private static func contact(_ index: Int) -> IMUser {
        contacts[safe: index] ?? currentUser
    }

    private static func todayAt(hour: Int, minute: Int = 0) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func nextDayAt(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: todayAt(hour: hour, minute: minute)) ?? todayAt(hour: hour, minute: minute)
    }

    static var groups: [GroupInfo] {
        [
            GroupInfo(id: "g_trade", name: "交易通知群", notice: "10:00 前同步大额交易确认，文件外发需审批。", owner: "Nina Zhao", members: contacts, admins: Array(contacts.prefix(2)), muted: false, allMuted: false, allMuteStart: nil, allMuteEnd: nil),
            GroupInfo(id: "g_product", name: "IM 1.0 产品群", notice: "本周关注 iOS 客户端、文件预览和回执链路。", owner: "Ray Xu", members: contacts, admins: [contact(4)], muted: true, allMuted: false, allMuteStart: nil, allMuteEnd: nil),
            GroupInfo(id: "g_risk", name: "风险复核群", notice: "敏感词和异常登录请在 2 小时内完成复核。", owner: "Leo Chen", members: Array(contacts.prefix(4)), admins: [contact(2)], muted: false, allMuted: true, allMuteStart: todayAt(hour: 0), allMuteEnd: nextDayAt(hour: 9))
        ]
    }

    static var conversations: [Conversation] {
        let readBy = [
            ReadReceipt(id: "rr_mia", user: contact(0), device: "iPhone 15 Pro", time: "10:24"),
            ReadReceipt(id: "rr_leo", user: contact(1), device: "MacBook Web", time: "10:25"),
            ReadReceipt(id: "rr_nina", user: contact(2), device: "iPad", time: "10:26")
        ]
        let unreadBy = [
            ReadReceipt(id: "ur_amy", user: contact(3), device: "Android", time: "未读"),
            ReadReceipt(id: "ur_ray", user: contact(4), device: "Windows PC", time: "未读")
        ]

        return [
            Conversation(
                id: "conv_trade",
                title: "交易通知群",
                subtitle: "群聊 · 86 人",
                kind: .group,
                lastMessage: "Mia 上传 trade-confirmation-0618.pdf",
                time: "10:26",
                unread: 12,
                isPinned: true,
                isMuted: false,
                memberCount: 86,
                accentHex: 0x5D6BFF,
                participants: contacts,
                messages: [
                    ChatMessage(id: "m_1", senderId: "u_mia", senderName: "Mia Wong", text: "今日确认单已生成，先发 PDF，清算口径请 Leo 再复核。", time: "10:18", isOutgoing: false, status: .read, kind: .text, reactions: [Reaction(id: "r1", emoji: "👍", count: 6, reactedByMe: true)], readBy: readBy, unreadBy: unreadBy, quote: nil, attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "m_2", senderId: "u_me", senderName: "林昊", text: "收到。我先按风险窗口看一遍，若有异常会引用这条回复。", time: "10:20", isOutgoing: true, status: .read, kind: .text, reactions: [Reaction(id: "r2", emoji: "✅", count: 4, reactedByMe: false)], readBy: readBy, unreadBy: unreadBy, quote: "今日确认单已生成，先发 PDF", attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "m_3", senderId: "u_mia", senderName: "Mia Wong", text: "trade-confirmation-0618.pdf", time: "10:21", isOutgoing: false, status: .read, kind: .file, reactions: [Reaction(id: "r3", emoji: "👀", count: 3, reactedByMe: false)], readBy: readBy, unreadBy: unreadBy, quote: nil, attachmentName: "trade-confirmation-0618.pdf", attachmentMeta: "PDF · 2.4 MB · 安全扫描通过"),
                    ChatMessage(id: "m_4", senderId: "u_me", senderName: "林昊", text: "第 4 页有一笔备注不一致，我标出来了。", time: "10:23", isOutgoing: true, status: .failed, kind: .text, reactions: [], readBy: [], unreadBy: contacts.map { ReadReceipt(id: "u_\($0.id)", user: $0, device: "未同步", time: "未读") }, quote: "trade-confirmation-0618.pdf", attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "m_5", senderId: "system", senderName: "系统", text: "Nina 撤回了一条消息", time: "10:24", isOutgoing: false, status: .recalled, kind: .system, reactions: [], readBy: [], unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "m_6", senderId: "u_leo", senderName: "Leo Chen", text: "@林昊 复核完成，等你的风险结论。", time: "10:26", isOutgoing: false, status: .sent, kind: .text, reactions: [Reaction(id: "r4", emoji: "🔥", count: 2, reactedByMe: false)], readBy: readBy, unreadBy: unreadBy, quote: nil, attachmentName: nil, attachmentMeta: nil)
                ]
            ),
            Conversation(
                id: "conv_mia",
                title: "Mia Wong",
                subtitle: "单聊",
                kind: .direct,
                lastMessage: "下午 3 点前我把补充截图发你。",
                time: "09:42",
                unread: 2,
                isPinned: false,
                isMuted: true,
                memberCount: 2,
                accentHex: 0x50D2FF,
                participants: [contact(0)],
                messages: [
                    ChatMessage(id: "dm_1", senderId: "u_mia", senderName: "Mia Wong", text: "你方便帮我看一下 Harbor 那边的截图吗？", time: "09:38", isOutgoing: false, status: .read, kind: .text, reactions: [], readBy: readBy, unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "dm_2", senderId: "u_me", senderName: "林昊", text: "可以，发我原图，别压缩。", time: "09:39", isOutgoing: true, status: .read, kind: .text, reactions: [Reaction(id: "dr1", emoji: "👌", count: 1, reactedByMe: false)], readBy: readBy, unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "dm_3", senderId: "u_mia", senderName: "Mia Wong", text: "下午 3 点前我把补充截图发你。", time: "09:42", isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: readBy, unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil)
                ]
            ),
            Conversation(
                id: "conv_system",
                title: "系统通知",
                subtitle: "设备与安全",
                kind: .system,
                lastMessage: "新设备登录提醒，已完成 Face ID 绑定。",
                time: "昨天",
                unread: 1,
                isPinned: false,
                isMuted: false,
                memberCount: 1,
                accentHex: 0x18B6D7,
                participants: [],
                messages: [
                    ChatMessage(id: "sys_1", senderId: "system", senderName: "系统", text: "新设备登录提醒，已完成 Face ID 绑定。", time: "昨天 21:18", isOutgoing: false, status: .sent, kind: .system, reactions: [], readBy: [], unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil)
                ]
            ),
            Conversation(
                id: "conv_product",
                title: "IM 1.0 产品群",
                subtitle: "群聊 · 18 人",
                kind: .group,
                lastMessage: "Ray：@林昊 iOS 端需要把企业切换做成主路径。",
                time: "周一",
                unread: 0,
                isPinned: false,
                isMuted: true,
                memberCount: 18,
                accentHex: 0x7C6BFF,
                participants: contacts,
                messages: [
                    ChatMessage(id: "p_1", senderId: "u_ray", senderName: "Ray Xu", text: "@林昊 iOS 端需要把企业切换做成主路径。", time: "周一 18:08", isOutgoing: false, status: .read, kind: .text, reactions: [Reaction(id: "pr1", emoji: "💡", count: 8, reactedByMe: true)], readBy: readBy, unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil)
                ]
            ),
            Conversation(
                id: "conv_risk",
                title: "风险复核群",
                subtitle: "群聊 · 4 人",
                kind: .group,
                lastMessage: "Nina：@林昊 异常登录清单我已经同步到群文件。",
                time: "周一",
                unread: 0,
                isPinned: false,
                isMuted: false,
                memberCount: 4,
                accentHex: 0x23C48E,
                participants: Array(contacts.prefix(4)),
                messages: [
                    ChatMessage(id: "risk_1", senderId: "u_nina", senderName: "Nina Zhao", text: "@林昊 异常登录清单我已经同步到群文件，先看高风险账号。", time: "周一 17:40", isOutgoing: false, status: .read, kind: .text, reactions: [Reaction(id: "risk_r1", emoji: "✅", count: 3, reactedByMe: false)], readBy: readBy, unreadBy: [], quote: nil, attachmentName: nil, attachmentMeta: nil),
                    ChatMessage(id: "risk_2", senderId: "u_me", senderName: "林昊", text: "收到，我先复核 2 小时内的新设备登录。", time: "周一 17:43", isOutgoing: true, status: .read, kind: .text, reactions: [], readBy: readBy, unreadBy: [], quote: "异常登录清单我已经同步到群文件", attachmentName: nil, attachmentMeta: nil)
                ]
            )
        ]
    }
}
