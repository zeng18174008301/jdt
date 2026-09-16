import Foundation
import CryptoKit
import UIKit

enum JHTRuntimeFeatureFlags {
    // 仅用于排查 RTC/CallKit/WebRTC 线程问题。默认关闭，避免影响正常功能。
    // Debug 下可通过启动参数 --jht-disable-rtc-runtime 或环境变量 JHT_DISABLE_RTC_RUNTIME=1 打开。
    static var disableRTCRuntime: Bool {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("--jht-disable-rtc-runtime") {
            return true
        }
        if processInfo.arguments.contains("--jht-enable-rtc-runtime") {
            return false
        }
        if let rawValue = processInfo.environment["JHT_DISABLE_RTC_RUNTIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            return ["1", "true", "yes", "on"].contains(rawValue)
        }
        return false
        #else
        return false
        #endif
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case chats
    case contacts
    case files
    case rtc
    case me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "会话"
        case .contacts: "通讯录"
        case .files: "资料"
        case .rtc: "沟通"
        case .me: "我的"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right.fill"
        case .contacts: "person.2.fill"
        case .files: "folder.fill"
        case .rtc: "phone.fill"
        case .me: "person.crop.circle.fill"
        }
    }
}

enum AuthScreen: Equatable {
    case enterpriseCode
    // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：普通登录遇到同名多商户时，仅进入一次企业码确认页
    case tenantCodeChallenge
    // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
    case welcome
    case phoneLogin
    case accountLogin
    case phoneRegister
    case accountRegister
    case forgotPassword
    case workspaceSelection
}

enum EnterpriseCodeAuthPresentationPolicy {
    static let registrationDisabledMessage = "当前应用未开放注册"
    static let contextRequiredMessage = "请先输入企业码并完成验证"

    static func normalizedScreen(
        _ requested: AuthScreen,
        enterpriseCodeFirst: Bool,
        registrationEnabled: Bool,
        hasUsableContext: Bool
    ) -> AuthScreen {
        if enterpriseCodeFirst, !hasUsableContext {
            return .enterpriseCode
        }
        if !registrationEnabled {
            switch requested {
            case .phoneRegister:
                return .phoneLogin
            case .accountRegister:
                return .accountLogin
            default:
                break
            }
        }
        if enterpriseCodeFirst, requested == .workspaceSelection {
            return .accountLogin
        }
        return requested
    }

    static func registrationEntryCodeIsReady(
        enterpriseCodeFirst: Bool,
        registrationTenantCodeRequired: Bool,
        hasUsableContext: Bool,
        normalizedEntryCode: String
    ) -> Bool {
        if enterpriseCodeFirst {
            return hasUsableContext
        }
        return !registrationTenantCodeRequired || !normalizedEntryCode.isEmpty
    }
}

struct PreAuthEnterpriseContext: Equatable {
    let appID: String
    let deviceID: String
    let tenantID: String
    let tenantCode: String
    let entryCode: String
    let entryType: String
    let entryScheme: RegistrationEntryCodeScheme
    let tenantName: String
    let tenantLogoURL: String
    let tenantLogoCacheKey: String
    let contextToken: String
    let expiresAt: Date
    let routeRevision: UInt64
    let runtimeRoutes: IMRuntimeRouteSnapshot

    init(
        appID: String,
        deviceID: String,
        tenantID: String,
        tenantCode: String,
        entryCode: String,
        entryType: String,
        entryScheme: RegistrationEntryCodeScheme,
        tenantName: String = "",
        tenantLogoURL: String = "",
        tenantLogoCacheKey: String = "",
        contextToken: String,
        expiresAt: Date,
        routeRevision: UInt64,
        runtimeRoutes: IMRuntimeRouteSnapshot
    ) {
        self.appID = appID
        self.deviceID = deviceID
        self.tenantID = tenantID
        self.tenantCode = tenantCode
        self.entryCode = entryCode
        self.entryType = entryType
        self.entryScheme = entryScheme
        self.tenantName = tenantName
        self.tenantLogoURL = tenantLogoURL
        self.tenantLogoCacheKey = tenantLogoCacheKey
        self.contextToken = contextToken
        self.expiresAt = expiresAt
        self.routeRevision = routeRevision
        self.runtimeRoutes = runtimeRoutes
    }

    func matchesIdentity(appID expectedAppID: String, deviceID expectedDeviceID: String, now: Date = Date()) -> Bool {
        appID == expectedAppID
            && deviceID == expectedDeviceID
            && !tenantID.isEmpty
            && !tenantCode.isEmpty
            && !entryCode.isEmpty
            && RegistrationFlowPolicy.entryAuthority(
                entryType: entryType,
                scheme: entryScheme.rawValue,
                canonical: entryCode,
                submittedEntryCode: entryCode
            ) != nil
            && !contextToken.isEmpty
            && expiresAt > now
            && routeRevision > 0
            && runtimeRoutes.revision == routeRevision
            && runtimeRoutes.validated(appID: expectedAppID, tenantID: tenantID) != nil
    }

    func settingRouteRevision(_ revision: UInt64) -> PreAuthEnterpriseContext {
        PreAuthEnterpriseContext(
            appID: appID,
            deviceID: deviceID,
            tenantID: tenantID,
            tenantCode: tenantCode,
            entryCode: entryCode,
            entryType: entryType,
            entryScheme: entryScheme,
            tenantName: tenantName,
            tenantLogoURL: tenantLogoURL,
            tenantLogoCacheKey: tenantLogoCacheKey,
            contextToken: contextToken,
            expiresAt: expiresAt,
            routeRevision: revision,
            runtimeRoutes: runtimeRoutes
        )
    }
}

enum PhoneAuthPresentationPolicy {
    static let disabledMessage = "当前应用未开放手机号登录或注册，请使用账号继续"

    static func isEnabled(
        policyValue: Bool?,
        hasResolvedPolicy: Bool,
        disabledByServer: Bool = false
    ) -> Bool {
        guard !disabledByServer else { return false }
        if let policyValue {
            return policyValue && hasResolvedPolicy
        }
        return false
    }

    static func normalizedScreen(_ screen: AuthScreen, phoneAuthEnabled: Bool) -> AuthScreen {
        guard !phoneAuthEnabled else { return screen }
        switch screen {
        case .phoneLogin:
            return .accountLogin
        case .phoneRegister:
            return .accountRegister
        default:
            return screen
        }
    }

    static func userMessage(for errorCode: String) -> String? {
        errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "phone_auth_disabled"
            ? disabledMessage
            : nil
    }
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话/消息快照模型允许安全跨异步任务传递
enum ConversationKind: String, Hashable, Sendable {
    case direct = "单聊"
    case group = "群聊"
    case system = "系统"
}

enum MessageKind: String, Hashable, Sendable {
    case text
    case rtcCallRecord = "rtc_call_record"
    case image
    case file
    case system
    case location
    case voice
    case video
    case contactCard
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

struct StickerMessageVariantSnapshot: Codable, Hashable, Sendable {
    let kind: String
    let fileID: String
    let mimeType: String
    let assetURL: String
    let sizeBytes: Int64?
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let thumbnailURL: String
    let cacheKey: String

    init(
        kind: String,
        fileID: String,
        mimeType: String,
        assetURL: String = "",
        sizeBytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMS: Int? = nil,
        frameCount: Int? = nil,
        thumbnailURL: String = "",
        cacheKey: String = ""
    ) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assetURL = assetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.durationMS = durationMS
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cacheKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var dictionary: [String: Any] {
        var output: [String: Any] = [
            "kind": kind,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "cache_key": cacheKey
        ]
        if !assetURL.isEmpty { output["url"] = assetURL }
        if let sizeBytes { output["size_bytes"] = sizeBytes }
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        return output
    }

    var messageSendDictionary: [String: Any] {
        var output: [String: Any] = [
            "kind": kind,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "cache_key": cacheKey
        ]
        if let sizeBytes { output["size_bytes"] = sizeBytes }
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        return output
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case fileID
        case legacyFileID = "file_id"
        case mimeType
        case legacyMimeType = "mime_type"
        case assetURL
        case url
        case legacyAssetURL = "asset_url"
        case downloadURL = "download_url"
        case sizeBytes
        case legacySizeBytes = "size_bytes"
        case width
        case height
        case durationMS
        case legacyDurationMS = "duration_ms"
        case frameCount
        case legacyFrameCount = "frame_count"
        case thumbnailURL
        case legacyThumbnailURL = "thumbnail_url"
        case cacheKey
        case legacyCacheKey = "cache_key"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "",
            fileID: try c.decodeIfPresent(String.self, forKey: .fileID)
                ?? c.decodeIfPresent(String.self, forKey: .legacyFileID)
                ?? "",
            mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType)
                ?? c.decodeIfPresent(String.self, forKey: .legacyMimeType)
                ?? "",
            assetURL: try c.decodeIfPresent(String.self, forKey: .assetURL)
                ?? c.decodeIfPresent(String.self, forKey: .url)
                ?? c.decodeIfPresent(String.self, forKey: .legacyAssetURL)
                ?? c.decodeIfPresent(String.self, forKey: .downloadURL)
                ?? "",
            sizeBytes: try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
                ?? c.decodeIfPresent(Int64.self, forKey: .legacySizeBytes),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS)
                ?? c.decodeIfPresent(Int.self, forKey: .legacyDurationMS),
            frameCount: try c.decodeIfPresent(Int.self, forKey: .frameCount)
                ?? c.decodeIfPresent(Int.self, forKey: .legacyFrameCount),
            thumbnailURL: try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
                ?? c.decodeIfPresent(String.self, forKey: .legacyThumbnailURL)
                ?? "",
            cacheKey: try c.decodeIfPresent(String.self, forKey: .cacheKey)
                ?? c.decodeIfPresent(String.self, forKey: .legacyCacheKey)
                ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileID, forKey: .fileID)
        try c.encode(mimeType, forKey: .mimeType)
        if !assetURL.isEmpty { try c.encode(assetURL, forKey: .assetURL) }
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(durationMS, forKey: .durationMS)
        try c.encodeIfPresent(frameCount, forKey: .frameCount)
        try c.encode(thumbnailURL, forKey: .thumbnailURL)
        try c.encode(cacheKey, forKey: .cacheKey)
    }
}

struct StickerMessageSnapshot: Codable, Hashable, Sendable {
    static let fallbackText = "[GIF表情]"

    let stickerID: String
    let packID: String
    let fileID: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let durationMS: Int?
    let frameCount: Int?
    let thumbnailURL: String
    let variants: [StickerMessageVariantSnapshot]
    let fallbackText: String

    init(
        stickerID: String,
        packID: String = "",
        fileID: String,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMS: Int? = nil,
        frameCount: Int? = nil,
        thumbnailURL: String = "",
        variants: [StickerMessageVariantSnapshot] = [],
        fallbackText: String = StickerMessageSnapshot.fallbackText
    ) {
        self.stickerID = stickerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.packID = packID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.width = width
        self.height = height
        self.durationMS = durationMS
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.variants = variants
        self.fallbackText = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.fallbackText : fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var dictionary: [String: Any] {
        var output: [String: Any] = [
            "type": "sticker",
            "sticker_id": stickerID,
            "pack_id": packID,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "fallback_text": fallbackText
        ]
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        output["variants"] = variants.map(\.dictionary)
        return output
    }

    var messageSendDictionary: [String: Any] {
        var output: [String: Any] = [
            "type": "sticker",
            "sticker_id": stickerID,
            "pack_id": packID,
            "file_id": fileID,
            "mime_type": mimeType,
            "thumbnail_url": thumbnailURL,
            "fallback_text": fallbackText
        ]
        if let width { output["width"] = width }
        if let height { output["height"] = height }
        if let durationMS { output["duration_ms"] = durationMS }
        if let frameCount { output["frame_count"] = frameCount }
        output["variants"] = variants.map(\.messageSendDictionary)
        return output
    }

    var cacheIdentity: String {
        let variant = variants.first { !$0.kind.isEmpty || !$0.cacheKey.isEmpty || !$0.fileID.isEmpty }
        return [
            fileID,
            variant?.cacheKey ?? "",
            variant?.kind ?? "",
            stickerID
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息投影状态允许安全跨异步任务传递
enum MessageDelivery: String, Hashable, Sendable {
    case sending = "发送中"
    case sent = "已送达"
    case read = "已读"
    case failed = "未送达 · 点按重发"
    case recalled = "已撤回"
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

struct Enterprise: Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
    let role: String
    let status: String
    let memberCount: Int
    let isDefault: Bool
    let accentHex: UInt
    var logoURL: String = ""
    var logoStatus: String = ""
    var logoVersion: String = ""
    var logoUpdatedAt: String = ""
    var logoCacheKey: String = ""
    var logoMime: String = ""
    var logoWidth: Int? = nil
    var logoHeight: Int? = nil
    var joinStatus: String = "joined"
    var applicationID: String = ""
    var applicationStatus: String = ""
    var approvalRequired: Bool = false
    var canSwitch: Bool = true
    var enterable: Bool? = nil
    var isCurrent: Bool = false
    var accountStatus: String = ""
    var tenantStatus: String = ""
    var memberStatus: String = ""
    var disabledReason: String = ""
    var searchEntryType: String = ""
    var searchInviterName: String = ""

    var displayCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchInviteDisplayLine: String {
        let normalizedEntryType = Self.normalizedWorkspaceStatus(searchEntryType)
        guard normalizedEntryType == "memberinvitecode" else { return "" }
        let inviter = searchInviterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inviter.isEmpty else { return "" }
        return "邀请人：\(inviter)"
    }

    private var normalizedJoinStatus: String {
        Self.normalizedWorkspaceStatus(joinStatus)
    }

    private var normalizedApplicationStatus: String {
        Self.normalizedWorkspaceStatus(applicationStatus)
    }

    var isWorkspaceJoinPending: Bool {
        Self.pendingWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.pendingWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoinRejected: Bool {
        Self.rejectedWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.rejectedWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoinApproved: Bool {
        Self.approvedWorkspaceStatuses.contains(normalizedJoinStatus)
            || Self.approvedWorkspaceStatuses.contains(normalizedApplicationStatus)
    }

    var isWorkspaceJoined: Bool {
        Self.joinedWorkspaceStatuses.contains(normalizedJoinStatus) || isWorkspaceJoinApproved
    }

    var isWorkspaceEnterable: Bool {
        enterable ?? canSwitch
    }

    var isLogoRenderable: Bool {
        let normalizedStatus = Self.normalizedWorkspaceStatus(logoStatus)
        guard !Self.unrenderableLogoStatuses.contains(normalizedStatus) else { return false }
        return !logoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func logoImageCacheKey(scope: String) -> String {
        [
            "enterprise-logo",
            scope,
            id,
            logoCacheKey,
            logoVersion,
            logoUpdatedAt,
            logoMime,
            logoWidth.map(String.init) ?? "",
            logoHeight.map(String.init) ?? "",
            logoURL
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    var workspaceDisabledDescription: String {
        let rawReason = disabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = Self.normalizedWorkspaceStatus(rawReason)
        let normalizedAccountStatus = Self.normalizedWorkspaceStatus(accountStatus)
        let normalizedTenantStatus = Self.normalizedWorkspaceStatus(tenantStatus)
        let normalizedMemberStatus = Self.normalizedWorkspaceStatus(memberStatus)
        switch reason {
        case "accountlocked", "locked":
            return "账号已锁定"
        case "accountdisabled":
            return "账号已停用"
        case "iploginblocked":
            return "当前网络已被禁止登录"
        case "tenantdisabled", "tenantservicestopped":
            return "企业已停用"
        case "workspacesessionunavailable", "tenantserviceunavailable":
            return "企业服务暂不可用"
        case "defaultworkspaceunavailable":
            return "默认企业暂不可进入"
        case "defaultworkspacenotfound":
            return "默认企业不存在"
        case "appnotfound":
            return "企业应用不可用"
        case "memberdisabled", "tenantmemberdisabled":
            return "成员已停用"
        case "tenantmembernotfound", "membernotfound":
            return "企业成员不存在"
        case "workspacenotfound", "tenantnotfound":
            return "企业不存在"
        case "workspaceidentityunlinked":
            return "企业身份未同步"
        case "memberprojectionsyncing", "memberprojectionmissing", "memberprojectionstale":
            return "成员数据正在同步"
        case "memberprojectionfailed":
            return "成员数据同步失败"
        case "pending":
            return "等待审批"
        case "rejected":
            return "已拒绝"
        case "forbidden":
            return "无权限进入"
        case "joinstatus", "notjoined", "unjoined":
            return isWorkspaceJoinPending ? "等待审批" : isWorkspaceJoinRejected ? "已拒绝" : ""
        default:
            if !reason.isEmpty, reason.hasPrefix("member") {
                return "成员已停用"
            }
            let disabledTenantStatuses = ["disabled", "suspended", "stopped", "tenantdisabled", "tenantservicestopped"]
            if disabledTenantStatuses.contains(normalizedTenantStatus) {
                return "企业已停用"
            }
            if isWorkspaceJoinPending {
                return "等待审批"
            }
            if isWorkspaceJoinRejected {
                return "已拒绝"
            }
            let lockedAccountStatuses = ["accountlocked", "locked"]
            if lockedAccountStatuses.contains(normalizedAccountStatus) {
                return "账号已锁定"
            }
            if normalizedAccountStatus == "ipblocked" {
                return "当前网络已被禁止登录"
            }
            let activeAccountStatuses = ["", "normal", "active", "enabled"]
            if !activeAccountStatuses.contains(normalizedAccountStatus) {
                return "账号已停用"
            }
            let activeTenantStatuses = ["", "normal", "active", "enabled"]
            if !activeTenantStatuses.contains(normalizedTenantStatus) {
                return "企业已停用"
            }
            let activeMemberStatuses = ["", "normal", "active", "enabled", "joined"]
            if !activeMemberStatuses.contains(normalizedMemberStatus), isWorkspaceJoined {
                return "成员已停用"
            }
            if let humanReason = Self.humanReadableWorkspaceReason(rawReason) {
                return humanReason
            }
            if !isWorkspaceEnterable, isWorkspaceJoined {
                return "不可进入"
            }
            return ""
        }
    }

    private static let pendingWorkspaceStatuses: Set<String> = [
        "pending", "pendingapproval", "pendingreview", "waiting", "waitingapproval", "submitted", "reviewing",
        "approvalrequired", "requiresapproval", "requiresreview", "workspacejoinpending"
    ]

    private static let rejectedWorkspaceStatuses: Set<String> = [
        "rejected", "reject", "denied", "declined", "refused", "workspacejoinrejected"
    ]

    private static let approvedWorkspaceStatuses: Set<String> = [
        "approved", "approve", "accepted", "pass", "passed", "through", "autoapproved", "autoaccepted", "autopassed",
        "workspacejoinapproved"
    ]

    private static let joinedWorkspaceStatuses: Set<String> = [
        "joined", "alreadyjoined", "workspacealreadyjoined", "active", "enabled", "normal"
    ]

    private static let unrenderableLogoStatuses: Set<String> = [
        "unsafe", "missing", "deleted", "blocked", "rejected", "unavailable", "disabled", "invalid", "forbidden"
    ]

    private static func normalizedWorkspaceStatus(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private static func humanReadableWorkspaceReason(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value > 127 }) {
            return trimmed
        }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return trimmed
        }
        return nil
    }
}

let cancelledUserDisplayName = "用户已注销"
let cancelledUserAvatarPath = "/avatars/user-cancelled-gray.svg"

func isCancelledUserStatus(_ rawValue: String) -> Bool {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["cancelled", "canceled", "cancel", "account_cancelled", "account_canceled"].contains(normalized)
}

func isCancelledUserAvatarURL(_ rawValue: String) -> Bool {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }
    if let url = URL(string: normalized), url.path.lowercased() == cancelledUserAvatarPath {
        return true
    }
    return normalized == cancelledUserAvatarPath || normalized.hasSuffix(cancelledUserAvatarPath)
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话参与人模型允许安全跨异步任务传递
struct IMUser: Identifiable, Hashable, Sendable {
    let id: String
    let userID: String
    let username: String
    let name: String
    let title: String
    let department: String
    let departmentPathNames: [String]
    let phone: String
    let phoneVerified: Bool
    let realNameVerified: Bool
    let realNameStatus: String
    let email: String
    let status: String
    let lastLoginAt: String
    let enterprise: String
    let avatarSeed: UInt
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let badges: [String]

    init(
        id: String,
        userID: String = "",
        username: String = "",
        name: String,
        title: String,
        department: String,
        departmentPathNames: [String] = [],
        phone: String,
        phoneVerified: Bool = false,
        realNameVerified: Bool = false,
        realNameStatus: String = "",
        email: String,
        status: String,
        lastLoginAt: String = "",
        enterprise: String,
        avatarSeed: UInt,
        avatarURL: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = "",
        badges: [String]
    ) {
        self.id = id
        self.userID = userID.isEmpty ? id : userID
        self.username = username
        self.name = name
        self.title = title
        self.department = department
        self.departmentPathNames = departmentPathNames
        self.phone = phone
        self.phoneVerified = phoneVerified
        self.realNameVerified = realNameVerified
        self.realNameStatus = realNameStatus
        self.email = email
        self.status = status
        self.lastLoginAt = lastLoginAt
        self.enterprise = enterprise
        self.avatarSeed = avatarSeed
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.badges = badges
    }

    var avatarCacheKey: String {
        AvatarImageCache.cacheKey(url: avatarURL, version: avatarVersion, updatedAt: avatarUpdatedAt)
    }

    var isCancelledUser: Bool {
        isCancelledUserStatus(status) || isCancelledUserAvatarURL(avatarURL)
    }

    var displayName: String {
        isCancelledUser ? cancelledUserDisplayName : name
    }

    var displayAvatarURL: String {
        isCancelledUser ? cancelledUserAvatarPath : avatarURL
    }

    func withDepartment(_ department: String, pathNames: [String] = []) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: title,
            department: department,
            departmentPathNames: pathNames,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email,
            status: status,
            lastLoginAt: lastLoginAt,
            enterprise: enterprise,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: badges
        )
    }

    func withName(_ name: String) -> IMUser {
        IMUser(
            id: id,
            userID: userID,
            username: username,
            name: name,
            title: title,
            department: department,
            departmentPathNames: departmentPathNames,
            phone: phone,
            phoneVerified: phoneVerified,
            realNameVerified: realNameVerified,
            realNameStatus: realNameStatus,
            email: email,
            status: status,
            lastLoginAt: lastLoginAt,
            enterprise: enterprise,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            badges: badges
        )
    }
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

enum IMUserSearchMatcher {
    static func matches(user: IMUser, role: String = "", query: String) -> Bool {
        matchScore(user: user, role: role, query: query) != nil
    }

    static func matchScore(user: IMUser, role: String = "", query: String) -> Int? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }

        var bestScore: Int?
        for (index, key) in searchableKeys(for: user, role: role).enumerated() {
            guard key.contains(needle) else { continue }
            let matchRank: Int
            if key == needle {
                matchRank = 0
            } else if key.hasPrefix(needle) {
                matchRank = 10
            } else {
                matchRank = 30
            }
            let score = matchRank + min(index, 12)
            bestScore = min(bestScore ?? score, score)
        }
        return bestScore
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'’")))
            .joined()
            .lowercased()
    }

    static func isLatinLetterQuery(_ value: String) -> Bool {
        let needle = normalized(value)
        guard !needle.isEmpty else { return false }
        var hasLetter = false
        for scalar in needle.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                hasLetter = true
                continue
            }
            if CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            return false
        }
        return hasLetter
    }

    static func searchableKeys(for user: IMUser, role: String = "") -> [String] {
        let fields = [
            user.name,
            user.id,
            user.userID,
            user.username,
            user.title,
            user.phone,
            user.email,
            user.enterprise,
            role
        ] + user.badges

        return fields.flatMap { searchVariants(for: $0) }.deduplicated()
    }

    static func sortedMatches(users: [IMUser], role: String = "", query: String) -> [IMUser] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return users }
        return users
            .compactMap { user -> (IMUser, Int)? in
                guard let score = matchScore(user: user, role: role, query: query) else { return nil }
                return (user, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsName = sortNameKey(for: lhs.0)
                let rhsName = sortNameKey(for: rhs.0)
                if lhsName != rhsName { return lhsName < rhsName }
                return mentionStableKey(for: lhs.0) < mentionStableKey(for: rhs.0)
            }
            .map(\.0)
    }

    private static func sortNameKey(for user: IMUser) -> String {
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinyin = normalized(name.applyingTransform(.toLatin, reverse: false) ?? name)
        return pinyin.isEmpty ? normalized(name) : pinyin
    }

    private static func mentionStableKey(for user: IMUser) -> String {
        let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userID.isEmpty { return userID }
        return user.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchVariants(for value: String) -> [String] {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        let normalizedRaw = normalized(raw)
        let latin = raw.applyingTransform(.toLatin, reverse: false) ?? raw
        let pinyin = normalized(latin)
        let phraseInitials = pinyinInitials(fromLatin: latin)
        let characterInitials = pinyinInitials(for: raw)

        return [normalizedRaw, pinyin, phraseInitials, characterInitials].filter { !$0.isEmpty }
    }

    private static func pinyinInitials(fromLatin value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func pinyinInitials(for value: String) -> String {
        value.reduce(into: "") { result, character in
            let text = String(character)
            let latin = normalized(text.applyingTransform(.toLatin, reverse: false) ?? text)
            if let first = latin.first {
                result.append(first)
            }
        }
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

struct UserSearchResult: Identifiable, Hashable {
    let imUID: String
    let userID: String
    let nickname: String
    let phone: String
    let avatarURL: String
    let status: String
    let presenceStatus: String
    var relationStatus: String
    var canApplyFriend: Bool
    var reason: String
    var friendAction: String
    var friendFlow: String
    var requiresTenantReview: Bool?
    var requiresTargetApproval: Bool?

    var id: String { imUID.isEmpty ? userID : imUID }
    var isCancelledUser: Bool {
        isCancelledUserStatus(status) || isCancelledUserAvatarURL(avatarURL)
    }
    var displayName: String { isCancelledUser ? cancelledUserDisplayName : (nickname.isEmpty ? id : nickname) }
    var displayAvatarURL: String { isCancelledUser ? cancelledUserAvatarPath : avatarURL }

    init(
        imUID: String,
        userID: String,
        nickname: String,
        phone: String,
        avatarURL: String,
        status: String,
        presenceStatus: String = "",
        relationStatus: String,
        canApplyFriend: Bool,
        reason: String,
        friendAction: String = "",
        friendFlow: String = "",
        requiresTenantReview: Bool? = nil,
        requiresTargetApproval: Bool? = nil
    ) {
        self.imUID = imUID
        self.userID = userID
        self.nickname = nickname
        self.phone = phone
        self.avatarURL = avatarURL
        self.status = status
        self.presenceStatus = presenceStatus
        self.relationStatus = relationStatus
        self.canApplyFriend = canApplyFriend
        self.reason = reason
        self.friendAction = friendAction
        self.friendFlow = friendFlow
        self.requiresTenantReview = requiresTenantReview
        self.requiresTargetApproval = requiresTargetApproval
    }
}

enum FriendApplyResolution: Equatable {
    case pending
    case established
    case terminal
}

enum FriendAddPresentation {
    static let actionTitle = "添加好友"
    static let waitingTitle = "等待对方通过"
    static let sentMessage = "申请已发送，等待对方通过"
    static let establishedMessage = "已添加为好友"
    static let suppressedMessage = "申请未投递，当前策略不允许添加好友"
    static let terminalMessage = "申请未生效，请查看最新状态"
    static let relationChangedMessage = "好友关系已更新，请查看最新状态"
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息附属展示模型允许安全跨异步任务传递
struct Reaction: Identifiable, Hashable, Sendable {
    let id: String
    let emoji: String
    var count: Int
    var reactedByMe: Bool
}

struct ReactionDetail: Identifiable, Hashable, Sendable {
    let id: String
    let emoji: String
    let user: IMUser
    let time: String
}

struct ReadReceipt: Identifiable, Hashable, Sendable {
    let id: String
    let user: IMUser
    let device: String
    let time: String
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

struct MentionIdentity: Identifiable, Hashable, Codable, Sendable {
    let imUID: String
    let userID: String
    let username: String
    let displayText: String

    var id: String {
        if !imUID.isEmpty { return imUID }
        if !userID.isEmpty { return userID }
        return username
    }

    var mentionToken: String {
        displayText.hasPrefix("@") ? displayText : "@\(displayText)"
    }

    init(imUID: String, userID: String = "", username: String = "", displayText: String) {
        self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(user: IMUser) {
        self.init(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: user.name.isEmpty ? user.id : user.name
        )
    }

    func matches(_ user: IMUser) -> Bool {
        let candidates = [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return [imUID, userID, username]
            .filter { !$0.isEmpty }
            .contains { key in candidates.contains(key) }
    }
}

struct MessageReplyContext: Identifiable, Hashable, Codable, Sendable {
    var messageID: String
    var senderID: String
    var senderName: String
    var summary: String
    var contentType: String
    var channelSeq: Int64
    var isUnavailable: Bool
    var thumbnailURL: String = ""

    enum CodingKeys: String, CodingKey {
        case messageID
        case senderID
        case senderName
        case summary
        case contentType
        case channelSeq
        case isUnavailable
        case thumbnailURL
    }

    var id: String {
        if !messageID.isEmpty { return messageID }
        if channelSeq > 0 { return "seq-\(channelSeq)" }
        return "\(senderID)|\(summary)"
    }

    var quoteText: String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSummary = cleanSummary.isEmpty ? (isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : cleanSummary
        let cleanSender = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSender.isEmpty else { return fallbackSummary }
        return "\(cleanSender)：\(fallbackSummary)"
    }

    init(
        messageID: String = "",
        senderID: String = "",
        senderName: String = "",
        summary: String,
        contentType: String = "",
        channelSeq: Int64 = 0,
        isUnavailable: Bool = false,
        thumbnailURL: String = ""
    ) {
        self.messageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senderID = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelSeq = channelSeq
        self.isUnavailable = isUnavailable
        self.thumbnailURL = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messageID: try c.decodeIfPresent(String.self, forKey: .messageID) ?? "",
            senderID: try c.decodeIfPresent(String.self, forKey: .senderID) ?? "",
            senderName: try c.decodeIfPresent(String.self, forKey: .senderName) ?? "",
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            contentType: try c.decodeIfPresent(String.self, forKey: .contentType) ?? "",
            channelSeq: try c.decodeIfPresent(Int64.self, forKey: .channelSeq) ?? 0,
            isUnavailable: try c.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false,
            thumbnailURL: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messageID, forKey: .messageID)
        try c.encode(senderID, forKey: .senderID)
        try c.encode(senderName, forKey: .senderName)
        try c.encode(summary, forKey: .summary)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(channelSeq, forKey: .channelSeq)
        try c.encode(isUnavailable, forKey: .isUnavailable)
        try c.encode(thumbnailURL, forKey: .thumbnailURL)
    }
}

/// Local failure metadata only. Never retain error descriptions, request identifiers,
/// paths, URLs or arbitrary server values in a message/cache payload.
struct AttachmentUploadFailure: Codable, Hashable, Sendable {
    enum Code: String, Codable, Sendable {
        case localPersistence = "LOCAL_PERSISTENCE"
        case localFile = "LOCAL_FILE"
        case missingContext = "MISSING_CONTEXT"
        case route = "ROUTE"
        case requestEncoding = "REQUEST_ENCODING"
        case timeout = "NETWORK_TIMEOUT", dns = "NETWORK_DNS", tls = "NETWORK_TLS"
        case offline = "NETWORK_OFFLINE", transport = "NETWORK_TRANSPORT"
        case cancelled = "CANCELLED", invalidResponse = "INVALID_RESPONSE"
        case http = "HTTP", envelope = "ENVELOPE", decode = "DECODE_ENVELOPE"
        case emptyData = "EMPTY_DATA", policy = "POLICY", unknown = "UNKNOWN"
    }

    let code: Code
    let httpStatus: Int?
    let serverCode: String?
    let storageRequestID: String?

    init(code: Code, httpStatus: Int? = nil, serverCode: String? = nil, storageRequestID: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        // Syntax-only filtering is insufficient: a token can look like a code.
        // Unrecognized server codes are deliberately not copied into storage.
        let known: Set<String> = [
            "bad_request", "invalid_request", "invalid_payload", "invalid_argument",
            "unauthorized", "invalid_credentials", "forbidden", "not_friends",
            "conflict", "rate_limited", "security_blocked", "account_locked",
            "tenant_storage_not_configured", "tenant_storage_resource_unavailable",
            "tenant_storage_provider_unsupported", "tenant_storage_secret_unresolved",
            "tenant_storage_local_unavailable",
            "file_too_large", "unsupported_mime_type", "invalid_file_type",
            "file_not_found", "upload_not_found", "upload_not_completed",
            "checksum_mismatch", "size_mismatch", "internal_error",
            "service_unavailable", "unrecognized_server_code",
            "signaturedoesnotmatch", "accessdenied", "requesttimetooskewed",
            "invalidaccesskeyid", "securitytokenexpired", "invalidsecuritytoken",
            "requestexpired", "invaliddigest", "baddigest", "invalidargument"
        ]
        if let serverCode, !serverCode.isEmpty {
            let normalized = serverCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.serverCode = known.contains(normalized) ? normalized : "unrecognized_server_code"
        } else {
            self.serverCode = nil
        }
        // Keep only the standard 24-hex OSS request ID; omit other header text.
        if let storageRequestID,
           storageRequestID.utf8.count == 24,
           storageRequestID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            self.storageRequestID = storageRequestID
        } else {
            self.storageRequestID = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case code, httpStatus, serverCode, storageRequestID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = try? values.decode(String.self, forKey: .code)
        self.init(
            code: rawCode.flatMap(Code.init(rawValue:)) ?? .unknown,
            httpStatus: try? values.decode(Int.self, forKey: .httpStatus),
            serverCode: try? values.decode(String.self, forKey: .serverCode),
            storageRequestID: try? values.decode(String.self, forKey: .storageRequestID)
        )
    }

    var detail: String {
        var parts = [code.rawValue]
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let serverCode { parts.append(serverCode) }
        if let storageRequestID { parts.append("request_id=\(storageRequestID)") }
        return parts.joined(separator: " · ")
    }
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：消息模型允许安全跨后台投影任务传递
struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let senderId: String
    var senderProvenance: BatchForwardSenderProvenance = .unknown
    var senderName: String
    var senderAvatarURL: String = ""
    var senderAvatarVersion: String = ""
    var senderAvatarUpdatedAt: String = ""
    var senderAvatarSeed: UInt = 0
    var text: String
    let time: String
    var createdAt: Date? = nil
    var channelSeq: Int64 = 0
    let isOutgoing: Bool
    var status: MessageDelivery
    let kind: MessageKind
    var contentType: String = ""
    var reactions: [Reaction]
    var reactionDetails: [ReactionDetail] = []
    var readBy: [ReadReceipt]
    var unreadBy: [ReadReceipt]
    var readCount: Int? = nil
    var unreadCount: Int? = nil
    var readStateKnown: Bool = false
    var deliveryStateKnown: Bool = false
    var canViewReadDetails: Bool = true
    var quote: String?
    var replyContext: MessageReplyContext? = nil
    var attachmentName: String?
    var attachmentMeta: String?
    var attachmentFileID: String? = nil
    var attachmentSizeBytes: Int64? = nil
    var attachmentPreviewURL: String = ""
    var attachmentDownloadURL: String = ""
    var attachmentPreviewAvailable: Bool = false
    var attachmentDownloadAvailable: Bool = false
    var attachmentTransferProgress: Double? = nil
    var attachmentMimeType: String = ""
    var attachmentCacheKey: String = ""
    var attachmentVersion: String = ""
    var attachmentChecksum: String = ""
    var attachmentMediaCategory: String = ""
    var attachmentExtension: String = ""
    var attachmentThumbnailURL: String = ""
    var attachmentPosterURL: String = ""
    var attachmentCoverURL: String = ""
    var attachmentPreviewKind: String = ""
    var attachmentContentDisposition: String = ""
    var attachmentWidth: Int? = nil
    var attachmentHeight: Int? = nil
    var attachmentDurationSeconds: Double? = nil
    var attachmentUploadStatus: String = ""
    var attachmentUploadFailure: AttachmentUploadFailure? = nil
    var isPinned: Bool = false
    var isPinnedContextOnly: Bool = false
    var isFavorited: Bool = false
    var isDeletedLocally: Bool = false
    var isEdited: Bool = false
	var editRevision: Int64 = 0
    var auditTags: [String] = []
    var reportState: String? = nil
    var serverTrace: String? = nil
    var mentionExcluded: Bool = false
    var mentionAll: Bool = false
    var mentionedUsers: [MentionIdentity] = []
    var voiceWaveform: [Int] = []
    var stickerSnapshot: StickerMessageSnapshot? = nil
    var rtcCallRecord: RTCCallRecordPayload? = nil

    var isRTCCallRecordMessage: Bool {
        contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
    }

    var isStickerMessage: Bool {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedContentType == "sticker" || stickerSnapshot != nil
    }

    var isForwardSupported: Bool {
        guard !isDeletedLocally,
              status != .sending,
              status != .failed,
              status != .recalled,
              !isRTCCallRecordMessage else { return false }
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isStickerMessage {
            return normalizedContentType.isEmpty || normalizedContentType == "sticker"
        }
        switch kind {
        case .text:
            return normalizedContentType.isEmpty || normalizedContentType == "text"
        case .file:
            guard normalizedContentType.isEmpty || normalizedContentType == "file" || normalizedContentType == "attachment" else {
                return false
            }
            let mediaCategory = attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let previewKind = attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unsupportedMedia = ["image", "video", "audio", "voice"]
            return !unsupportedMedia.contains(mediaCategory) && !unsupportedMedia.contains(previewKind)
        default:
            return false
        }
    }
    var systemEventType: String? = nil
    var systemDisplayStyle: String? = nil
    var systemColorToken: String? = nil
    var systemTextColorHex: String? = nil
    var systemBackgroundColorHex: String? = nil
    var systemAccentColorHex: String? = nil
    var groupInviteApproval: GroupInviteApproval? = nil
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

enum MessageMentionProjection {
    static func includes(_ message: ChatMessage, currentActor: IMUser) -> Bool {
        guard !message.isOutgoing,
              message.status != .recalled,
              !message.isDeletedLocally,
              message.kind != .system,
              !message.mentionExcluded else {
            return false
        }
        if message.mentionAll {
            return true
        }
        return message.mentionedUsers.contains { $0.matches(currentActor) }
    }
}

enum VoiceMicrophoneAuthorizationStatus: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

enum VoiceMessagePermissionGate {
    static func shouldRequestMicrophone(
        userTriggered: Bool,
        businessBlocked: Bool,
        status: VoiceMicrophoneAuthorizationStatus
    ) -> Bool {
        userTriggered && !businessBlocked && status == .notDetermined
    }
}

enum VoiceMessagePayload {
    static let minDurationMS = 1_000
    static let maxDurationMS = 60_000
    static let maxWaveformSamples = 64
    static let fallbackText = "[语音]"

    static func isTooShort(durationMS: Int) -> Bool {
        durationMS < minDurationMS
    }

    static func normalizedDurationMS(_ durationMS: Int) -> Int {
        min(max(durationMS, 0), maxDurationMS)
    }

    static func isValidFinalDurationMS(_ durationMS: Int) -> Bool {
        (1...maxDurationMS).contains(durationMS)
    }

    static func isSendableDurationMS(_ durationMS: Int) -> Bool {
        (minDurationMS...maxDurationMS).contains(durationMS)
    }

    static func decodedDurationMS(_ decodedDurationSeconds: TimeInterval?) -> Int? {
        guard let decodedDurationSeconds,
              decodedDurationSeconds.isFinite,
              decodedDurationSeconds > 0 else {
            return nil
        }
        let durationMilliseconds = decodedDurationSeconds * 1_000.0
        guard durationMilliseconds <= Double(maxDurationMS) + 0.499 else {
            return nil
        }
        let durationMS = Int(durationMilliseconds.rounded())
        guard isValidFinalDurationMS(durationMS) else { return nil }
        return durationMS
    }

    static func authoritativeDurationMS(
        metadataDurationMS _: Int,
        decodedDurationSeconds: TimeInterval?
    ) -> Int? {
        decodedDurationMS(decodedDurationSeconds)
    }

    static func durationSeconds(from durationMS: Int) -> Int {
        let clamped = normalizedDurationMS(durationMS)
        guard clamped > 0 else { return 0 }
        return max(1, Int(ceil(Double(clamped) / 1_000.0)))
    }

    static func durationLabel(durationMS: Int?) -> String {
        guard let durationMS, durationMS > 0 else { return "" }
        return "\(durationSeconds(from: durationMS))秒"
    }

    static func playbackProgress(elapsedMS: Int, durationMS: Int) -> Double {
        let duration = normalizedDurationMS(durationMS)
        guard duration > 0 else { return 0 }
        return min(max(Double(max(0, elapsedMS)) / Double(duration), 0), 1)
    }

    static func remainingDurationMS(elapsedMS: Int, durationMS: Int) -> Int {
        max(0, normalizedDurationMS(durationMS) - max(0, elapsedMS))
    }

    static func countdownLabel(elapsedMS: Int, durationMS: Int) -> String {
        let remaining = remainingDurationMS(elapsedMS: elapsedMS, durationMS: durationMS)
        return durationLabel(durationMS: remaining)
    }

    static func normalizedWaveform(_ samples: [Int]) -> [Int] {
        let clamped = samples.map { min(max($0, 0), 100) }
        guard !clamped.isEmpty else {
            return Array(repeating: 12, count: 12)
        }
        guard clamped.count > maxWaveformSamples else {
            return clamped
        }
        return (0..<maxWaveformSamples).map { index in
            let start = index * clamped.count / maxWaveformSamples
            let end = max(start + 1, (index + 1) * clamped.count / maxWaveformSamples)
            let slice = clamped[start..<min(end, clamped.count)]
            guard !slice.isEmpty else { return clamped[min(start, clamped.count - 1)] }
            return Int(round(Double(slice.reduce(0, +)) / Double(slice.count)))
        }
    }
}

struct VoiceMessagePlaybackState: Equatable {
    let messageID: String
    let elapsedMS: Int
    let durationMS: Int
    let isPlaying: Bool

    init(messageID: String, elapsedMS: Int, durationMS: Int, isPlaying: Bool = false) {
        let boundedDurationMS = max(1, VoiceMessagePayload.normalizedDurationMS(durationMS))
        let boundedElapsedMS = min(boundedDurationMS, max(0, elapsedMS))
        self.messageID = messageID
        self.elapsedMS = boundedElapsedMS
        self.durationMS = boundedDurationMS
        self.isPlaying = isPlaying && boundedElapsedMS < boundedDurationMS
    }

    var progress: Double {
        VoiceMessagePayload.playbackProgress(elapsedMS: elapsedMS, durationMS: durationMS)
    }

    var remainingMS: Int {
        VoiceMessagePayload.remainingDurationMS(elapsedMS: elapsedMS, durationMS: durationMS)
    }

    var remainingLabel: String {
        VoiceMessagePayload.countdownLabel(elapsedMS: elapsedMS, durationMS: durationMS)
    }
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：群邀请审批消息载荷允许安全跨异步任务传递
struct GroupInviteApproval: Identifiable, Hashable, Sendable {
    let requestID: String
    let requestType: String
    let groupID: String
    let groupName: String
    let inviterName: String
    let inviterAccountID: String
    let inviteeName: String
    let inviteeAccountID: String
    var status: String
    var resultText: String
    var processed: Bool
    var approverName: String
    var approverAccountID: String
    var decidedAt: String
    let canApprove: Bool
    let canReject: Bool
    let approveEndpoint: String
    let rejectEndpoint: String
    let actionEndpoint: String
    let kind: String

    var id: String { requestID }

    var normalizedRequestType: String {
        requestType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isPending: Bool {
        if processed { return false }
        return normalizedStatus.isEmpty || ["pending", "pending_approval", "waiting", "waiting_approval", "submitted", "reviewing"].contains(normalizedStatus)
    }

    var isApproved: Bool {
        ["approved", "approve", "accepted", "pass", "passed"].contains(normalizedStatus)
    }

    var isRejected: Bool {
        ["rejected", "reject", "denied", "declined", "refused"].contains(normalizedStatus)
    }

    var isCanceled: Bool {
        ["canceled", "cancelled", "cancel"].contains(normalizedStatus)
    }

    var isExpired: Bool {
        ["expired", "expire", "timed_out", "timeout"].contains(normalizedStatus)
    }

    var isJoinRequest: Bool {
        normalizedRequestType == "join_request"
            || normalizedRequestType == "join"
            || (!inviteeAccountID.isEmpty && inviterAccountID == inviteeAccountID)
    }

    var isActionable: Bool {
        kind == "group_invite_approval"
            && !processed
            && isPending
            && ((canApprove && !approveEndpoint.isEmpty) || (canReject && !rejectEndpoint.isEmpty))
    }

    var statusText: String {
        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isPending && !trimmedResult.isEmpty {
            return trimmedResult
        }
        if isApproved {
            return "已通过"
        }
        if isRejected {
            return "已拒绝"
        }
        if isCanceled {
            return "已取消"
        }
        if isExpired {
            return "已过期"
        }
        if processed {
            return trimmedResult.isEmpty ? "已处理" : trimmedResult
        }
        return kind == "group_invite_receipt" ? "等待审核" : "待处理"
    }

    var actedSummary: String {
        guard !isPending else { return "" }
        let actor = approverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = decidedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !actor.isEmpty && !time.isEmpty { return "\(actor) · \(time)" }
        if !actor.isEmpty { return actor }
        if !time.isEmpty { return time }
        return ""
    }

    func resolved(status: String, approverName: String = "", approverAccountID: String = "", decidedAt: String = "", resultText: String = "") -> GroupInviteApproval {
        GroupInviteApproval(
            requestID: requestID,
            requestType: requestType,
            groupID: groupID,
            groupName: groupName,
            inviterName: inviterName,
            inviterAccountID: inviterAccountID,
            inviteeName: inviteeName,
            inviteeAccountID: inviteeAccountID,
            status: status,
            resultText: resultText.isEmpty ? self.resultText : resultText,
            processed: true,
            approverName: approverName.isEmpty ? self.approverName : approverName,
            approverAccountID: approverAccountID.isEmpty ? self.approverAccountID : approverAccountID,
            decidedAt: decidedAt.isEmpty ? self.decidedAt : decidedAt,
            canApprove: false,
            canReject: false,
            approveEndpoint: approveEndpoint,
            rejectEndpoint: rejectEndpoint,
            actionEndpoint: actionEndpoint,
            kind: kind
        )
    }
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

struct MessageSearchHit: Identifiable, Hashable {
    let id: String
    let messageID: String
    let conversationID: String
    let senderName: String
    let snippet: String
    let time: String
}

// JHT_MOD_BEGIN APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改开始：会话模型允许安全跨后台投影任务传递
struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var subtitle: String
    let kind: ConversationKind
    var lastMessage: String
    var time: String
    var unread: Int
    var isPinned: Bool
    var isMuted: Bool
    var memberCount: Int?
    let accentHex: UInt
    var participants: [IMUser]
    var messages: [ChatMessage]
    var avatarURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    var hasUnreadReaction: Bool = false
    var unreadReactionCount: Int = 0
    var lastMsgSeq: Int64 = 0
    var messageCoveredThroughSeq: Int64 = 0
    var messageCoverageRequiresRecovery: Bool = false
    var lastReadSeq: Int64 = 0
    var firstUnreadSeq: Int64 = 0
    var firstUnreadMessageID: String = ""
    var unreadAnchorSeq: Int64 = 0
    var unreadAnchorState: String = ""
    var hasMention: Bool = false
    var mentionCount: Int = 0
    var mentionSummaryText: String = ""
    var mentionSummaryMessageID: String = ""
    var mentionSummaryChannelSeq: Int64 = 0
    var sortTimestamp: TimeInterval = 0
    var historyVisibleFromSeq: Int64 = 1
    var historyLimited: Bool = false
    var historyBoundaryConfirmed: Bool = false
}
// JHT_MOD_END APPSTATE_MODEL_SENDABLE_PERF_20260912 - 修改结束

func conversationListSupportsMutableActions(_ conversation: Conversation) -> Bool {
    conversation.kind != .system
}

enum DirectConversationCallPeerResolver {
    struct ContactLookup {
        private let contacts: [IMUser]
        private let identities: [Set<String>]
        private let indicesByIdentity: [String: Set<Int>]

        init(contacts: [IMUser]) {
            self.contacts = contacts
            identities = contacts.map { DirectConversationCallPeerResolver.identityIdentifiers(for: $0) }
            var indices: [String: Set<Int>] = [:]
            for (index, identifiers) in identities.enumerated() {
                for identifier in identifiers {
                    indices[identifier, default: []].insert(index)
                }
            }
            indicesByIdentity = indices
        }

        fileprivate func firstContact(matching identifier: String) -> IMUser? {
            guard let index = indicesByIdentity[identifier]?.min() else { return nil }
            return contacts[index]
        }

        fileprivate func uniqueContact(matching identifiers: Set<String>, excluding currentIDs: Set<String>) -> IMUser? {
            var matchingIndices: Set<Int> = []
            for identifier in identifiers {
                matchingIndices.formUnion(indicesByIdentity[identifier] ?? [])
            }
            let eligible = matchingIndices.filter { identities[$0].isDisjoint(with: currentIDs) }
            guard eligible.count == 1, let index = eligible.first else { return nil }
            return contacts[index]
        }
    }

    static let unavailableMessage = "目标信息同步中，请稍后再试"

    static func resolve(
        conversation: Conversation,
        currentIdentityIDs: Set<String>,
        contacts: [IMUser],
        contactLookup: ContactLookup? = nil
    ) -> IMUser? {
        guard conversation.kind == .direct else { return nil }
        let normalizedCurrentIDs = Set(currentIdentityIDs.compactMap(normalizedIdentifier))

        if !conversation.participants.isEmpty {
            let peers = conversation.participants.filter { participant in
                identityIdentifiers(for: participant).isDisjoint(with: normalizedCurrentIDs)
            }
            guard peers.count == 1 else { return nil }
            return refreshedContactSnapshot(for: peers[0], contacts: contacts, currentIdentityIDs: normalizedCurrentIDs, contactLookup: contactLookup)
                ?? peers[0]
        }

        let channelPeerIDs = Set(
            conversation.id
                .split { character in
                    character == ":" || character == "|" || character == ","
                }
                .compactMap { normalizedIdentifier(String($0)) }
                .filter { !normalizedCurrentIDs.contains($0) }
        )
        guard channelPeerIDs.count == 1 else { return nil }

        if let contactLookup {
            return contactLookup.uniqueContact(matching: channelPeerIDs, excluding: normalizedCurrentIDs)
        }
        let matchingContacts = contacts.filter { contact in
            !identityIdentifiers(for: contact).isDisjoint(with: channelPeerIDs)
                && identityIdentifiers(for: contact).isDisjoint(with: normalizedCurrentIDs)
        }
        guard matchingContacts.count == 1 else { return nil }
        return matchingContacts[0]
    }

    private static func refreshedContactSnapshot(
        for participant: IMUser,
        contacts: [IMUser],
        currentIdentityIDs: Set<String>,
        contactLookup: ContactLookup?
    ) -> IMUser? {
        let participantIDs = identityIdentifiers(for: participant)
        guard !participantIDs.isEmpty else { return nil }
        if let contactLookup {
            return contactLookup.uniqueContact(matching: participantIDs, excluding: currentIdentityIDs)
        }
        let matchingContacts = contacts.filter { contact in
            !identityIdentifiers(for: contact).isDisjoint(with: participantIDs)
                && identityIdentifiers(for: contact).isDisjoint(with: currentIdentityIDs)
        }
        return matchingContacts.count == 1 ? matchingContacts[0] : nil
    }

    private static func identityIdentifiers(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username].compactMap(normalizedIdentifier))
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum DirectConversationProfilePeerResolver {
    static let unavailableMessage = "联系人资料同步中，请稍后再试"

    static func resolve(
        conversation: Conversation,
        currentIdentityIDs: Set<String>,
        contacts: [IMUser],
        fallbackEnterprise: String,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil
    ) -> IMUser? {
        guard conversation.kind == .direct else { return nil }
        if let resolved = DirectConversationCallPeerResolver.resolve(
            conversation: conversation,
            currentIdentityIDs: currentIdentityIDs,
            contacts: contacts,
            contactLookup: contactLookup
        ) {
            return resolved
        }

        let normalizedCurrentIDs = Set(currentIdentityIDs.compactMap(normalizedIdentifier))
        let incoming = conversation.messages.reversed().first { message in
            guard !message.isOutgoing,
                  let senderID = normalizedIdentifier(message.senderId) else {
                return false
            }
            return !normalizedCurrentIDs.contains(senderID)
        }
        guard let incoming,
              let senderID = normalizedIdentifier(incoming.senderId) else {
            return nil
        }

        let contact: IMUser?
        if let contactLookup {
            contact = contactLookup.firstContact(matching: senderID)
        } else {
            contact = contacts.first { contact in
                !identityIdentifiers(for: contact).isDisjoint(with: [senderID])
            }
        }
        if let contact { return contact }

        let senderName = incoming.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationTitle = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = !senderName.isEmpty
            ? senderName
            : (!conversationTitle.isEmpty ? conversationTitle : senderID)
        return IMUser(
            id: senderID,
            userID: senderID,
            name: displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "",
            enterprise: fallbackEnterprise,
            avatarSeed: incoming.senderAvatarSeed,
            avatarURL: incoming.senderAvatarURL,
            avatarVersion: incoming.senderAvatarVersion,
            avatarUpdatedAt: incoming.senderAvatarUpdatedAt,
            badges: []
        )
    }

    private static func identityIdentifiers(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username].compactMap(normalizedIdentifier))
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct ConversationUnreadState: Equatable {
    let unreadCount: Int
    let hasUnreadReaction: Bool
    let unreadReactionCount: Int
    let hasUnreadMessages: Bool
}

enum ConversationUnreadBadgeProjection {
    static func total(
        _ conversations: [Conversation],
        excludingConversationID: String? = nil
    ) -> Int {
        conversations.reduce(into: 0) { total, conversation in
            guard !conversation.isMuted,
                  conversation.id != excludingConversationID else { return }
            total += max(0, conversation.unread)
        }
    }
}

struct GroupHistoryBoundaryGenerationTracker: Equatable {
    private(set) var generations: [String: Int] = [:]

    mutating func begin(key: String) -> Int {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return 0 }
        let next = (generations[normalizedKey] ?? 0) + 1
        generations[normalizedKey] = next
        return next
    }

    func accepts(key: String, generation: Int?) -> Bool {
        guard let generation, generation > 0 else { return true }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return true }
        return generations[normalizedKey] == generation
    }
}

func resolvedConversationUnreadState(
    remoteUnreadCount: Int,
    remoteUnreadReactionCount: Int,
    remoteHasReactionUnread: Bool,
    locallyReadThrough: Bool
) -> ConversationUnreadState {
    let remoteUnread = max(0, remoteUnreadCount)
    let explicitReactionCount = max(0, remoteUnreadReactionCount)
    let hasReactionUnread = remoteHasReactionUnread || explicitReactionCount > 0
    let reactionCount = hasReactionUnread ? max(explicitReactionCount, 1) : 0
    let unreadCount = locallyReadThrough
        ? reactionCount
        : max(remoteUnread, reactionCount)
    let hasUnreadMessages = !locallyReadThrough && remoteUnread > reactionCount

    return ConversationUnreadState(
        unreadCount: unreadCount,
        hasUnreadReaction: hasReactionUnread,
        unreadReactionCount: reactionCount,
        hasUnreadMessages: hasUnreadMessages
    )
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let size: String
    var sizeBytes: Int64? = nil
    let owner: String
    let source: String
    let time: String
    let scope: String
    let status: String
    let accentHex: UInt
    var remoteFileID: String = ""
    var previewURL: String = ""
    var downloadURL: String = ""
    var previewAvailable: Bool = false
    var downloadAvailable: Bool = false
    var channelID: String = ""
    var channelType: String = ""
    var channelSeq: Int64 = 0
    var mediaCategory: String = ""
    var contentType: String = ""
    var kind: String = ""
    var mimeType: String = ""
    var cacheKey: String = ""
    var version: String = ""
    var checksum: String = ""
    var fileExtension: String = ""
    var thumbnailURL: String = ""
    var posterURL: String = ""
    var coverURL: String = ""
    var previewKind: String = ""
    var contentDisposition: String = ""
    var width: Int? = nil
    var height: Int? = nil
    var durationSeconds: Double? = nil

    var remoteLookupID: String {
        let explicit = remoteFileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let fallback = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.hasPrefix("local-attachment|") ? "" : fallback
    }

    var hasRemoteFileID: Bool {
        !remoteLookupID.isEmpty
    }

    var isVoiceMessageAsset: Bool {
        VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: contentType,
            mediaCategory: mediaCategory,
            kind: kind,
            previewKind: previewKind,
            type: type,
            name: name,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }
}

enum VoiceFileListPolicy {
    static func isVoiceMessageAsset(
        contentType: String,
        mediaCategory: String,
        kind: String,
        previewKind: String = "",
        type: String = "",
        name: String = "",
        mimeType: String = "",
        fileExtension: String = ""
    ) -> Bool {
        let explicitValues = [contentType, mediaCategory, kind, previewKind, type]
            .map(normalizedMarker)
        if explicitValues.contains(where: isVoiceMarker) {
            return true
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMIME = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedExtension = (fileExtension.isEmpty ? (name as NSString).pathExtension : fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let legacyVoiceName = normalizedName.hasPrefix("voice-")
            || normalizedName.hasPrefix("voice_")
            || normalizedName.hasPrefix("voice.")
        let audioContainer = normalizedMIME.hasPrefix("audio/")
            || ["m4a", "aac", "wav", "ogg", "opus", "webm", "amr"].contains(normalizedExtension)
        return legacyVoiceName && audioContainer
    }

    private static func normalizedMarker(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func isVoiceMarker(_ value: String) -> Bool {
        [
            "voice",
            "voice_message",
            "audio_message",
            "recorded_voice",
            "语音",
            "语音消息"
        ].contains(value)
    }
}

enum FavoriteAssetCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case pdf
    case image
    case video
    case spreadsheet
    case document
    case archive
    case audio

    static let displayOrder: [FavoriteAssetCategory] = [
        .all, .pdf, .image, .video, .spreadsheet, .document, .archive, .audio
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .pdf: "PDF"
        case .image: "图片"
        case .video: "视频"
        case .spreadsheet: "表格"
        case .document: "文档"
        case .archive: "压缩包"
        case .audio: "音频"
        }
    }

    var requestValue: String {
        switch self {
        case .all: "all"
        default: rawValue
        }
    }

    init(serverValue: String) {
        let normalized = serverValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "all":
            self = .all
        case "pdf":
            self = .pdf
        case "image", "img", "photo":
            self = .image
        case "video":
            self = .video
        case "spreadsheet", "sheet", "excel", "xls", "xlsx", "csv":
            self = .spreadsheet
        case "document", "doc", "word", "ppt", "presentation", "txt", "text":
            self = .document
        case "archive", "zip", "compressed":
            self = .archive
        case "audio", "voice":
            self = .audio
        default:
            self = .all
        }
    }

    init(displayTitle: String) {
        let normalized = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self = Self.displayOrder.first { $0.title == normalized } ?? .all
    }

    func matches(file: FileItem) -> Bool {
        guard self != .all else { return true }
        let mediaCategory = file.mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = file.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = file.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extensionValue = (file.fileExtension.isEmpty ? (file.name as NSString).pathExtension : file.fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch self {
        case .all:
            return true
        case .pdf:
            return mediaCategory == "pdf" || mimeType.contains("pdf") || type == "pdf" || extensionValue == "pdf"
        case .image:
            return mediaCategory == "image" || mimeType.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(extensionValue)
        case .video:
            return mediaCategory == "video" || mimeType.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(extensionValue)
        case .spreadsheet:
            return mediaCategory == "spreadsheet"
                || mediaCategory == "sheet"
                || mimeType.contains("spreadsheet")
                || mimeType.contains("excel")
                || mimeType.contains("csv")
                || ["xls", "xlsx", "csv", "numbers"].contains(extensionValue)
        case .document:
            return mediaCategory == "document"
                || mimeType.contains("word")
                || mimeType.contains("document")
                || mimeType.contains("presentation")
                || mimeType.contains("powerpoint")
                || ["doc", "docx", "ppt", "pptx", "txt", "md", "pages", "key"].contains(extensionValue)
        case .archive:
            return mediaCategory == "archive" || ["zip", "rar", "7z", "tar", "gz"].contains(extensionValue)
        case .audio:
            return mediaCategory == "audio" || mediaCategory == "voice" || mimeType.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(extensionValue)
        }
    }
}

struct FavoriteAssetItem: Identifiable, Hashable {
    let messageID: String
    let tenantID: String
    let channelID: String
    let channelType: String
    let channelSeq: Int64
    let fromUID: String
    let contentType: String
    let status: String
    let createdAt: String?
    let favoritedAt: String?
    let favoriteVersion: Int64
    let category: FavoriteAssetCategory
    let displayText: String
    let cursor: String
    let file: FileItem
    let isUnavailable: Bool

    var id: String { messageID }
}

struct FavoriteAssetsPageResult: Equatable {
    let fetchedCount: Int
    let nextCursor: String
    let hasMore: Bool
    let didSucceed: Bool

    static let empty = FavoriteAssetsPageResult(
        fetchedCount: 0,
        nextCursor: "",
        hasMore: false,
        didSucceed: false
    )
}

struct FavoriteAssetsPageRequestIdentity: Equatable {
    let scope: String
    let category: FavoriteAssetCategory
    let cursor: String
    let generation: UInt64
}

struct FavoriteAssetsCollectionState {
    private var cachedItemsByScope: [String: [FavoriteAssetCategory: [FavoriteAssetItem]]] = [:]
    private var activeRequest: FavoriteAssetsPageRequestIdentity?
    private(set) var activeScope = ""
    private(set) var activeCategory: FavoriteAssetCategory = .all
    private(set) var activeItems: [FavoriteAssetItem] = []
    private(set) var generation: UInt64 = 0

    mutating func begin(
        scope rawScope: String,
        category: FavoriteAssetCategory,
        cursor rawCursor: String
    ) -> FavoriteAssetsPageRequestIdentity {
        generation &+= 1
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        activeScope = scope
        activeCategory = category
        activeItems = cachedItems(scope: scope, category: category)
        let request = FavoriteAssetsPageRequestIdentity(
            scope: scope,
            category: category,
            cursor: cursor,
            generation: generation
        )
        activeRequest = request
        return request
    }

    func isCurrent(_ request: FavoriteAssetsPageRequestIdentity) -> Bool {
        activeRequest == request
            && activeScope == request.scope
            && activeCategory == request.category
            && generation == request.generation
    }

    @discardableResult
    mutating func apply(
        items: [FavoriteAssetItem],
        append: Bool,
        request: FavoriteAssetsPageRequestIdentity
    ) -> Bool {
        guard isCurrent(request) else { return false }
        let existing = cachedItemsByScope[request.scope]?[request.category] ?? activeItems
        let nextItems = append
            ? Self.merged(existing, appending: items)
            : Self.deduplicated(items)
        cachedItemsByScope[request.scope, default: [:]][request.category] = nextItems
        if request.category != .all,
           let allItems = cachedItemsByScope[request.scope]?[.all] {
            cachedItemsByScope[request.scope, default: [:]][.all] = Self.merged(allItems, appending: nextItems)
        }
        activeItems = nextItems
        activeRequest = nil
        return true
    }

    @discardableResult
    mutating func fail(request: FavoriteAssetsPageRequestIdentity) -> Bool {
        guard isCurrent(request) else { return false }
        activeRequest = nil
        return true
    }

    mutating func invalidateVisibleItems() {
        generation &+= 1
        activeRequest = nil
        activeScope = ""
        activeCategory = .all
        activeItems = []
    }

    mutating func purge(scope rawScope: String) {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return }
        cachedItemsByScope.removeValue(forKey: scope)
        guard activeScope == scope else { return }
        invalidateVisibleItems()
    }

    mutating func remove(
        scope rawScope: String,
        where shouldRemove: (FavoriteAssetItem) -> Bool
    ) {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, var categories = cachedItemsByScope[scope] else { return }
        for category in categories.keys {
            categories[category]?.removeAll(where: shouldRemove)
        }
        cachedItemsByScope[scope] = categories
        if activeScope == scope {
            activeItems.removeAll(where: shouldRemove)
        }
    }

    private func cachedItems(scope: String, category: FavoriteAssetCategory) -> [FavoriteAssetItem] {
        guard !scope.isEmpty else { return [] }
        if let exact = cachedItemsByScope[scope]?[category] {
            return exact
        }
        if category == .all,
           let categories = cachedItemsByScope[scope] {
            return Self.deduplicated(
                FavoriteAssetCategory.displayOrder
                    .filter { $0 != .all }
                    .flatMap { categories[$0] ?? [] }
            )
        }
        guard category != .all,
              let allItems = cachedItemsByScope[scope]?[.all] else {
            return []
        }
        return allItems.filter { category.matches(file: $0.file) }
    }

    private static func merged(
        _ existing: [FavoriteAssetItem],
        appending incoming: [FavoriteAssetItem]
    ) -> [FavoriteAssetItem] {
        deduplicated(existing + incoming)
    }

    private static func deduplicated(_ items: [FavoriteAssetItem]) -> [FavoriteAssetItem] {
        var result: [FavoriteAssetItem] = []
        var indexByMessageID: [String: Int] = [:]
        for item in items {
            let messageID = item.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty else { continue }
            if let index = indexByMessageID[messageID] {
                result[index] = item
            } else {
                indexByMessageID[messageID] = result.count
                result.append(item)
            }
        }
        return result
    }
}

struct FileUploadConfig: Hashable {
    static let fallbackMaximumBytes: Int64 = 500 * 1024 * 1024

    static let defaultValue = FileUploadConfig(
        maxBytes: fallbackMaximumBytes,
        maxMB: 500,
        source: "default",
        messageRecallMaxMinutes: 120,
        voiceCallEnabled: true,
        videoCallEnabled: false,
        readReceiptsEnabled: true,
        groupAdminDeleteMessageEnabled: false,
        voiceCallLicenseKnown: false,
        videoCallLicenseKnown: false
    )

    let maxBytes: Int64
    let maxMB: Int
    let source: String
    let messageRecallMaxMinutes: Int
    let voiceCallEnabled: Bool
    let videoCallEnabled: Bool
    let readReceiptsEnabled: Bool
    let groupAdminDeleteMessageEnabled: Bool
    // Presence is local decode metadata, not another server permission source.
    let voiceCallLicenseKnown: Bool
    let videoCallLicenseKnown: Bool

    init(
        maxBytes: Int64, maxMB: Int, source: String,
        messageRecallMaxMinutes: Int, voiceCallEnabled: Bool, videoCallEnabled: Bool,
        readReceiptsEnabled: Bool, groupAdminDeleteMessageEnabled: Bool,
        voiceCallLicenseKnown: Bool = true, videoCallLicenseKnown: Bool = true
    ) {
        self.maxBytes = maxBytes
        self.maxMB = maxMB
        self.source = source
        self.messageRecallMaxMinutes = messageRecallMaxMinutes
        self.voiceCallEnabled = voiceCallEnabled
        self.videoCallEnabled = videoCallEnabled
        self.readReceiptsEnabled = readReceiptsEnabled
        self.groupAdminDeleteMessageEnabled = groupAdminDeleteMessageEnabled
        self.voiceCallLicenseKnown = voiceCallLicenseKnown
        self.videoCallLicenseKnown = videoCallLicenseKnown
    }

    var formattedMaxSize: String {
        let bytes = max(maxBytes, 0)
        let mb = 1024 * 1024
        let kb = 1024
        if bytes >= Int64(mb) {
            let whole = bytes / Int64(mb)
            let remainder = bytes % Int64(mb)
            if remainder == 0 {
                return "\(whole)M"
            }
            let tenths = (bytes * 10 + Int64(mb / 2)) / Int64(mb)
            if tenths % 10 == 0 {
                return "\(tenths / 10)M"
            }
            return "\(tenths / 10).\(tenths % 10)M"
        }
        if bytes >= Int64(kb) {
            let roundedKB = (bytes + Int64(kb - 1)) / Int64(kb)
            return "\(roundedKB)K"
        }
        return "\(bytes)B"
    }

    var overLimitMessage: String {
        "文件大小超出当前企业限制（\(formattedMaxSize)）"
    }

    func allowsUpload(sizeBytes: Int64) -> Bool {
        sizeBytes >= 0 && sizeBytes <= maxBytes
    }
}

struct PendingAttachmentFile: Equatable, Sendable {
    let url: URL
    let sizeBytes: Int64
}

enum PendingAttachmentFileStore {
    static let directoryName = "BlueStoneIMPendingAttachments"

    static func stageFile(
        from sourceURL: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> PendingAttachmentFile {
        let sourceSize = try regularFileSize(at: sourceURL, fileManager: fileManager)

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )

        let destination = directory.appendingPathComponent(
            "\(UUID().uuidString)_\(sanitizedFileName(preferredName))",
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            let destinationSize = try regularFileSize(at: destination, fileManager: fileManager)
            guard destinationSize == sourceSize else {
                throw CocoaError(.fileWriteUnknown)
            }
            return PendingAttachmentFile(url: destination, sizeBytes: destinationSize)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    static func fileSize(at url: URL, fileManager: FileManager = .default) -> Int64? {
        guard isManagedFile(url, fileManager: fileManager) else {
            return nil
        }
        return try? regularFileSize(at: url, fileManager: fileManager)
    }

    static func regularFileSize(at url: URL, fileManager: FileManager = .default) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let rawSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return rawSize.int64Value
    }

    static func removeManagedFile(at url: URL?, fileManager: FileManager = .default) {
        guard let url, isManagedFile(url, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Files in this temporary directory are only sources for the durable
    /// outbox staging copy. No valid ownership survives a process restart.
    static func removeOrphanedFiles(fileManager: FileManager = .default) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for entry in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try fileManager.removeItem(at: entry)
        }
    }

    static func isManagedFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent() == directory
    }

    private static func sanitizedFileName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : String(sanitized.prefix(180))
    }
}

enum SplashImagePrefetchStatus: String, Codable, Hashable, Sendable {
    case pending
    case cached
    case downloaded
    case failed
    case skipped
}

struct SplashTenantScope: Hashable, Sendable {
    let appID: String
    let accountID: String
    let tenantID: String
    let tenantOrigin: String

    init(appID: String, accountID: String, tenantID: String, tenantOrigin: String) {
        self.appID = Self.normalize(appID)
        self.accountID = Self.normalize(accountID)
        self.tenantID = Self.normalize(tenantID)
        self.tenantOrigin = Self.normalizedTenantAPIOrigin(tenantOrigin)
    }

    var isValid: Bool {
        !appID.isEmpty && !accountID.isEmpty && !tenantID.isEmpty && !tenantOrigin.isEmpty
    }

    var storageKey: String {
        [appID, accountID, tenantID, tenantOrigin]
            .map(Self.storageComponent)
            .joined(separator: ".")
    }

    static func normalizedTenantAPIOrigin(_ rawValue: String) -> String {
        let trimmed = normalize(rawValue)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            return ""
        }

        let host = rawHost.lowercased()
        let renderedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        var path = components.percentEncodedPath
        if path.isEmpty || path == "/" {
            path = ""
        } else {
            if !path.hasPrefix("/") {
                path = "/" + path
            }
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
        }
        return "\(scheme)://\(renderedHost):\(port)\(path)"
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storageComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct SplashConfigSnapshot: Codable, Hashable, Sendable {
    static let defaultMinIntervalSec = 14_400
    static let defaultDailyCap = 3
    static let defaultMinShowMS = 1_200
    static let defaultMaxShowMS = 3_000

    let tenantID: String
    let licenseEnabled: Bool
    let splashEnabled: Bool
    let assetID: String
    let imageURL: String
    let version: String
    let cacheKeyOverride: String?
    let width: Int?
    let height: Int?
    let mimeType: String
    let sizeBytes: Int64?
    let etag: String
    let sha256: String
    let minIntervalSec: Int?
    let dailyCap: Int?
    let minShowMS: Int?
    let maxShowMS: Int?
    let actionURL: String
    let fetchedAt: TimeInterval
    let disabledReason: String
    let prefetchStatus: SplashImagePrefetchStatus
    let lastPrefetchAt: TimeInterval?
    let lastPrefetchError: String

    var cacheKey: String? {
        if let cacheKeyOverride = cacheKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cacheKeyOverride.isEmpty {
            return SplashImageDiskCache.cacheKey(explicitKey: cacheKeyOverride)
        }
        return SplashImageDiskCache.cacheKey(assetID: assetID, version: version, imageURL: imageURL)
    }

    func cacheKey(scope: SplashTenantScope) -> String? {
        guard scope.isValid, scope.tenantID == tenantID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if let cacheKeyOverride = cacheKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cacheKeyOverride.isEmpty {
            return SplashImageDiskCache.cacheKey(scope: scope, explicitKey: cacheKeyOverride)
        }
        return SplashImageDiskCache.cacheKey(
            scope: scope,
            assetID: assetID,
            version: version,
            imageURL: imageURL
        )
    }

    var normalizedVersion: String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedMinIntervalSec: Int {
        max(0, minIntervalSec ?? Self.defaultMinIntervalSec)
    }

    var resolvedDailyCap: Int {
        max(0, dailyCap ?? Self.defaultDailyCap)
    }

    var resolvedMinShowMS: Int {
        max(0, minShowMS ?? Self.defaultMinShowMS)
    }

    var resolvedMaxShowMS: Int {
        max(500, max(resolvedMinShowMS, maxShowMS ?? Self.defaultMaxShowMS))
    }

    var isConfigDisplayable: Bool {
        licenseEnabled
            && splashEnabled
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && disabledReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isDisplayable(now: Date = Date(), cache: SplashImageDiskCache = .shared) -> Bool {
        guard isConfigDisplayable,
              let cacheKey else {
            return false
        }
        return cache.containsImage(for: cacheKey)
    }

    func isDisplayable(
        scope: SplashTenantScope,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared
    ) -> Bool {
        guard isConfigDisplayable,
              let cacheKey = cacheKey(scope: scope) else {
            return false
        }
        return cache.containsImage(for: cacheKey)
    }

    func withPrefetch(status: SplashImagePrefetchStatus, error: String = "", at date: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: licenseEnabled,
            splashEnabled: splashEnabled,
            assetID: assetID,
            imageURL: imageURL,
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: fetchedAt,
            disabledReason: disabledReason,
            prefetchStatus: status,
            lastPrefetchAt: date.timeIntervalSince1970,
            lastPrefetchError: error
        )
    }

    func disabled(reason: String, at date: Date = Date()) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: false,
            splashEnabled: false,
            assetID: assetID,
            imageURL: imageURL,
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: width,
            height: height,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            etag: etag,
            sha256: sha256,
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: minShowMS,
            maxShowMS: maxShowMS,
            actionURL: actionURL,
            fetchedAt: date.timeIntervalSince1970,
            disabledReason: reason,
            prefetchStatus: .skipped,
            lastPrefetchAt: lastPrefetchAt,
            lastPrefetchError: lastPrefetchError
        )
    }
}

struct SplashRefreshCandidate: Equatable, Sendable {
    let generation: Int
    let scope: SplashTenantScope
    let version: String
    let cacheKey: String

    init?(
        generation: Int,
        scope: SplashTenantScope,
        snapshot: SplashConfigSnapshot
    ) {
        guard generation > 0,
              scope.isValid,
              snapshot.isConfigDisplayable,
              !snapshot.normalizedVersion.isEmpty,
              let cacheKey = snapshot.cacheKey(scope: scope) else {
            return nil
        }
        self.generation = generation
        self.scope = scope
        version = snapshot.normalizedVersion
        self.cacheKey = cacheKey
    }

    func matches(
        currentGeneration: Int,
        currentScope: SplashTenantScope?,
        snapshot: SplashConfigSnapshot?
    ) -> Bool {
        guard generation == currentGeneration,
              scope == currentScope,
              let snapshot,
              snapshot.normalizedVersion == version,
              snapshot.cacheKey(scope: scope) == cacheKey else {
            return false
        }
        return true
    }
}

struct SplashDisplayState: Codable, Hashable, Sendable {
    var lastShownAt: TimeInterval?
    var lastShownVersion: String
    var shownVersions: [String]
    var todayCount: Int
    var todayDate: String
    var lastBackgroundedAt: TimeInterval?

    static let empty = SplashDisplayState(
        lastShownAt: nil,
        lastShownVersion: "",
        shownVersions: [],
        todayCount: 0,
        todayDate: "",
        lastBackgroundedAt: nil
    )

    func normalizedForDay(_ date: Date) -> SplashDisplayState {
        let today = Self.dayKey(for: date)
        guard todayDate != today else { return self }
        var next = self
        next.todayDate = today
        next.todayCount = 0
        return next
    }

    func canPresent(
        snapshot: SplashConfigSnapshot,
        at date: Date = Date(),
        isColdStartLike: Bool,
        alreadyShownInThisLaunch: Bool
    ) -> Bool {
        guard isColdStartLike,
              !alreadyShownInThisLaunch,
              snapshot.isConfigDisplayable else {
            return false
        }
        let version = snapshot.normalizedVersion
        guard !version.isEmpty else { return false }
        return true
    }

    func recordingShown(snapshot: SplashConfigSnapshot, at date: Date = Date()) -> SplashDisplayState {
        var next = normalizedForDay(date)
        let version = snapshot.normalizedVersion
        next.lastShownAt = date.timeIntervalSince1970
        next.lastShownVersion = version
        if !version.isEmpty, !next.shownVersions.contains(version) {
            next.shownVersions.append(version)
            if next.shownVersions.count > 40 {
                next.shownVersions.removeFirst(next.shownVersions.count - 40)
            }
        }
        next.todayCount += 1
        return next
    }

    func recordingBackgrounded(at date: Date = Date()) -> SplashDisplayState {
        var next = normalizedForDay(date)
        next.lastBackgroundedAt = date.timeIntervalSince1970
        return next
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

enum SplashOverlayEvaluationResult: Equatable, Sendable {
    case shown
    case notReadyNoSnapshot
    case notReadyNoCache
    case imageDecodeFailed
    case launchSplashActive
    case notColdStartLike
    case notAuthenticated
    case noSession
    case noTenant
    case overlayAlreadyActive
    case blockedByPolicy(String)

    var reason: String {
        switch self {
        case .shown:
            return "shown"
        case .notReadyNoSnapshot:
            return "not_ready_no_snapshot"
        case .notReadyNoCache:
            return "not_ready_no_cache"
        case .imageDecodeFailed:
            return "image_decode_failed"
        case .launchSplashActive:
            return "launch_splash_active"
        case .notColdStartLike:
            return "not_cold_start_like"
        case .notAuthenticated:
            return "not_authenticated"
        case .noSession:
            return "no_session"
        case .noTenant:
            return "no_tenant"
        case .overlayAlreadyActive:
            return "overlay_already_active"
        case .blockedByPolicy(let reason):
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "blocked_by_policy" : "blocked_by_policy_\(normalized)"
        }
    }

    var keepsInitialEvaluationPending: Bool {
        switch self {
        case .notReadyNoSnapshot, .notReadyNoCache, .imageDecodeFailed, .launchSplashActive, .notAuthenticated, .noSession, .noTenant:
            return true
        case .shown, .notColdStartLike, .overlayAlreadyActive, .blockedByPolicy:
            return false
        }
    }
}

struct SplashOverlayPresentation: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let tenantID: String
    let version: String
    let imageFileURL: URL
    let image: UIImage
    let minShowMS: Int
    let maxShowMS: Int
    let startedAt: TimeInterval

    init(snapshot: SplashConfigSnapshot, preparedImage: SplashPreparedImage, startedAt: Date = Date()) {
        tenantID = snapshot.tenantID
        version = snapshot.normalizedVersion
        imageFileURL = preparedImage.fileURL
        image = preparedImage.image
        minShowMS = snapshot.resolvedMinShowMS
        maxShowMS = snapshot.resolvedMaxShowMS
        self.startedAt = startedAt.timeIntervalSince1970
        id = "\(snapshot.tenantID)|\(snapshot.normalizedVersion)|\(Int(startedAt.timeIntervalSince1970 * 1000))"
    }

    func canSkip(at date: Date = Date()) -> Bool {
        canSkipSplash(startedAt: startedAt, minShowMS: minShowMS, now: date)
    }

    static func == (lhs: SplashOverlayPresentation, rhs: SplashOverlayPresentation) -> Bool {
        lhs.id == rhs.id
            && lhs.tenantID == rhs.tenantID
            && lhs.version == rhs.version
            && lhs.imageFileURL == rhs.imageFileURL
            && lhs.minShowMS == rhs.minShowMS
            && lhs.maxShowMS == rhs.maxShowMS
            && lhs.startedAt == rhs.startedAt
    }
}

func canPresentColdLaunchSplash(
    hasMainShellBecomeInteractive: Bool
) -> Bool {
    !hasMainShellBecomeInteractive
}

func canSkipSplash(
    startedAt: TimeInterval,
    minShowMS: Int,
    now: Date = Date()
) -> Bool {
    let elapsedMS = max(0, Int((now.timeIntervalSince1970 - startedAt) * 1_000))
    return elapsedMS >= max(0, minShowMS)
}

struct SplashImageCoverLayout: Equatable, Sendable {
    let renderedSize: CGSize

    static func layout(imageSize: CGSize, containerSize: CGSize) -> SplashImageCoverLayout {
        let containerWidth = max(containerSize.width, 0)
        let containerHeight = max(containerSize.height, 0)
        guard containerWidth > 0, containerHeight > 0 else {
            return SplashImageCoverLayout(renderedSize: .zero)
        }

        let imageWidth = max(imageSize.width, 1)
        let imageHeight = max(imageSize.height, 1)
        let scale = max(containerWidth / imageWidth, containerHeight / imageHeight)
        return SplashImageCoverLayout(renderedSize: CGSize(
            width: imageWidth * scale,
            height: imageHeight * scale
        ))
    }
}

enum SplashSnapshotStore {
    private static let snapshotsKey = "im2.ios.splash.snapshots.v1"
    private static let displayStatesKey = "im2.ios.splash.displayStates.v1"
    private static let scopedSnapshotsKey = "im2.ios.splash.snapshots.v2"
    private static let scopedDisplayStatesKey = "im2.ios.splash.displayStates.v2"

    static func snapshot(scope: SplashTenantScope, defaults: UserDefaults = .standard) -> SplashConfigSnapshot? {
        guard scope.isValid else { return nil }
        return scopedSnapshots(defaults: defaults)[scope.storageKey]
    }

    static func displayableSnapshot(
        scope: SplashTenantScope,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared,
        defaults: UserDefaults = .standard
    ) -> SplashConfigSnapshot? {
        guard let snapshot = snapshot(scope: scope, defaults: defaults),
              snapshot.isDisplayable(scope: scope, now: now, cache: cache) else {
            return nil
        }
        return snapshot
    }

    static func saveSnapshot(
        _ snapshot: SplashConfigSnapshot,
        scope: SplashTenantScope,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid,
              normalizedTenantID(snapshot.tenantID) == scope.tenantID else {
            return
        }
        var values = scopedSnapshots(defaults: defaults)
        values[scope.storageKey] = snapshot
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
        ensureDisplayState(scope: scope, defaults: defaults)
    }

    @discardableResult
    static func updatePrefetchStatus(
        candidate: SplashRefreshCandidate,
        status: SplashImagePrefetchStatus,
        error: String = "",
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard var snapshot = snapshot(scope: candidate.scope, defaults: defaults),
              snapshot.normalizedVersion == candidate.version,
              snapshot.cacheKey(scope: candidate.scope) == candidate.cacheKey else {
            return false
        }
        snapshot = snapshot.withPrefetch(status: status, error: error)
        saveSnapshot(snapshot, scope: candidate.scope, defaults: defaults)
        return true
    }

    static func disableSnapshot(
        scope: SplashTenantScope,
        reason: String,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        var values = scopedSnapshots(defaults: defaults)
        if let snapshot = values[scope.storageKey] {
            values[scope.storageKey] = snapshot.disabled(reason: reason)
        } else {
            values.removeValue(forKey: scope.storageKey)
        }
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
    }

    static func clearScope(_ scope: SplashTenantScope, defaults: UserDefaults = .standard) {
        guard scope.isValid else { return }
        var values = scopedSnapshots(defaults: defaults)
        values.removeValue(forKey: scope.storageKey)
        persist(values, key: scopedSnapshotsKey, defaults: defaults)
        var states = scopedDisplayStates(defaults: defaults)
        states.removeValue(forKey: scope.storageKey)
        persist(states, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func scopedSnapshots(defaults: UserDefaults = .standard) -> [String: SplashConfigSnapshot] {
        dictionary(forKey: scopedSnapshotsKey, defaults: defaults)
    }

    static func scopedDisplayStates(defaults: UserDefaults = .standard) -> [String: SplashDisplayState] {
        dictionary(forKey: scopedDisplayStatesKey, defaults: defaults)
    }

    static func displayState(scope: SplashTenantScope, defaults: UserDefaults = .standard) -> SplashDisplayState {
        guard scope.isValid else { return .empty }
        return scopedDisplayStates(defaults: defaults)[scope.storageKey] ?? .empty
    }

    static func saveDisplayState(
        _ state: SplashDisplayState,
        scope: SplashTenantScope,
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        var states = scopedDisplayStates(defaults: defaults)
        states[scope.storageKey] = state
        persist(states, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func recordShown(
        snapshot: SplashConfigSnapshot,
        scope: SplashTenantScope,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid,
              normalizedTenantID(snapshot.tenantID) == scope.tenantID else {
            return
        }
        let state = displayState(scope: scope, defaults: defaults)
            .recordingShown(snapshot: snapshot, at: date)
        saveDisplayState(state, scope: scope, defaults: defaults)
    }

    static func recordBackgrounded(
        scope: SplashTenantScope,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard scope.isValid else { return }
        let state = displayState(scope: scope, defaults: defaults)
            .recordingBackgrounded(at: date)
        saveDisplayState(state, scope: scope, defaults: defaults)
    }

    static func snapshot(tenantID: String, defaults: UserDefaults = .standard) -> SplashConfigSnapshot? {
        snapshots(defaults: defaults)[normalizedTenantID(tenantID)]
    }

    static func displayableSnapshot(
        tenantID: String,
        now: Date = Date(),
        cache: SplashImageDiskCache = .shared,
        defaults: UserDefaults = .standard
    ) -> SplashConfigSnapshot? {
        guard let snapshot = snapshot(tenantID: tenantID, defaults: defaults),
              snapshot.isDisplayable(now: now, cache: cache) else {
            return nil
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: SplashConfigSnapshot, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(snapshot.tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        values[tenantID] = snapshot
        persist(values, key: snapshotsKey, defaults: defaults)
        ensureDisplayState(tenantID: tenantID, defaults: defaults)
    }

    static func updatePrefetchStatus(
        tenantID: String,
        status: SplashImagePrefetchStatus,
        error: String = "",
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard var snapshot = snapshots(defaults: defaults)[tenantID] else { return }
        snapshot = snapshot.withPrefetch(status: status, error: error)
        saveSnapshot(snapshot, defaults: defaults)
    }

    static func disableSnapshot(tenantID: String, reason: String, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        if let snapshot = values[tenantID] {
            values[tenantID] = snapshot.disabled(reason: reason)
        } else {
            values.removeValue(forKey: tenantID)
        }
        persist(values, key: snapshotsKey, defaults: defaults)
    }

    static func clearTenant(_ tenantID: String, defaults: UserDefaults = .standard) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var values = snapshots(defaults: defaults)
        values.removeValue(forKey: tenantID)
        persist(values, key: snapshotsKey, defaults: defaults)
        var states = displayStates(defaults: defaults)
        states.removeValue(forKey: tenantID)
        persist(states, key: displayStatesKey, defaults: defaults)

        var scopedValues = scopedSnapshots(defaults: defaults)
        let removedScopeKeys = scopedValues.compactMap { key, snapshot in
            normalizedTenantID(snapshot.tenantID) == tenantID ? key : nil
        }
        for key in removedScopeKeys {
            scopedValues.removeValue(forKey: key)
        }
        persist(scopedValues, key: scopedSnapshotsKey, defaults: defaults)
        var scopedStates = scopedDisplayStates(defaults: defaults)
        for key in removedScopeKeys {
            scopedStates.removeValue(forKey: key)
        }
        persist(scopedStates, key: scopedDisplayStatesKey, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: snapshotsKey)
        defaults.removeObject(forKey: displayStatesKey)
        defaults.removeObject(forKey: scopedSnapshotsKey)
        defaults.removeObject(forKey: scopedDisplayStatesKey)
    }

    static func snapshots(defaults: UserDefaults = .standard) -> [String: SplashConfigSnapshot] {
        dictionary(forKey: snapshotsKey, defaults: defaults)
    }

    static func displayStates(defaults: UserDefaults = .standard) -> [String: SplashDisplayState] {
        dictionary(forKey: displayStatesKey, defaults: defaults)
    }

    static func displayState(tenantID: String, defaults: UserDefaults = .standard) -> SplashDisplayState {
        displayStates(defaults: defaults)[normalizedTenantID(tenantID)] ?? .empty
    }

    static func saveDisplayState(
        _ state: SplashDisplayState,
        tenantID: String,
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        var states = displayStates(defaults: defaults)
        states[tenantID] = state
        persist(states, key: displayStatesKey, defaults: defaults)
    }

    static func recordShown(
        snapshot: SplashConfigSnapshot,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(snapshot.tenantID)
        guard !tenantID.isEmpty else { return }
        let state = displayState(tenantID: tenantID, defaults: defaults)
            .recordingShown(snapshot: snapshot, at: date)
        saveDisplayState(state, tenantID: tenantID, defaults: defaults)
    }

    static func recordBackgrounded(
        tenantID: String,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let tenantID = normalizedTenantID(tenantID)
        guard !tenantID.isEmpty else { return }
        let state = displayState(tenantID: tenantID, defaults: defaults)
            .recordingBackgrounded(at: date)
        saveDisplayState(state, tenantID: tenantID, defaults: defaults)
    }

    private static func ensureDisplayState(tenantID: String, defaults: UserDefaults) {
        var states = displayStates(defaults: defaults)
        if states[tenantID] == nil {
            states[tenantID] = .empty
            persist(states, key: displayStatesKey, defaults: defaults)
        }
    }

    private static func ensureDisplayState(scope: SplashTenantScope, defaults: UserDefaults) {
        var states = scopedDisplayStates(defaults: defaults)
        if states[scope.storageKey] == nil {
            states[scope.storageKey] = .empty
            persist(states, key: scopedDisplayStatesKey, defaults: defaults)
        }
    }

    private static func dictionary<T: Decodable>(forKey key: String, defaults: UserDefaults) -> [String: T] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: T].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist<T: Encodable>(_ value: [String: T], key: String, defaults: UserDefaults) {
        if value.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func normalizedTenantID(_ tenantID: String) -> String {
        tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SplashImageValidationFailure: String, Equatable, Sendable {
    case emptyData = "empty_data"
    case fileTooLarge = "file_too_large"
    case unsupportedFormat = "unsupported_format"
    case mimeTypeMismatch = "mime_type_mismatch"
    case sizeMismatch = "size_mismatch"
    case checksumMismatch = "checksum_mismatch"
    case decodeFailed = "decode_failed"
    case dimensionsOutOfRange = "dimensions_out_of_range"
    case dimensionsMismatch = "dimensions_mismatch"
}

struct SplashPreparedImage: @unchecked Sendable {
    let fileURL: URL
    let image: UIImage
    let mimeType: String
    let sizeBytes: Int64
    let width: Int
    let height: Int
    let sha256Hex: String
}

enum SplashImageValidationResult {
    case valid(SplashPreparedImage)
    case invalid(SplashImageValidationFailure)
}

enum SplashImageValidator {
    static let maxSizeBytes = 5 * 1_024 * 1_024
    static let maxWidth = 4_096
    static let maxHeight = 8_192
    static let maxPixelCount: Int64 = 12_000_000

    static func validate(
        data: Data,
        fileURL: URL,
        expectedSHA256: String = "",
        expectedSizeBytes: Int64? = nil,
        expectedMimeType: String = "",
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) -> SplashImageValidationResult {
        guard !data.isEmpty else {
            return .invalid(.emptyData)
        }
        guard data.count <= maxSizeBytes else {
            return .invalid(.fileTooLarge)
        }
        guard let detectedMimeType = detectedMimeType(data) else {
            return .invalid(.unsupportedFormat)
        }

        let normalizedExpectedMimeType = normalizedMimeType(expectedMimeType)
        if !expectedMimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !normalizedExpectedMimeType.isEmpty,
                  normalizedExpectedMimeType == detectedMimeType else {
                return .invalid(.mimeTypeMismatch)
            }
        }

        if let expectedSizeBytes {
            guard expectedSizeBytes > 0,
                  Int64(data.count) == expectedSizeBytes else {
                return .invalid(.sizeMismatch)
            }
        }

        let digest = SHA256.hash(data: data)
        let digestData = Data(digest)
        let sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        if !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !matchesExpectedSHA256(
               expectedSHA256,
               digestHex: sha256Hex,
               digestData: digestData
           ) {
            return .invalid(.checksumMismatch)
        }

        guard let sourceImage = UIImage(data: data),
              let sourceCGImage = sourceImage.cgImage else {
            return .invalid(.decodeFailed)
        }
        let width = sourceCGImage.width
        let height = sourceCGImage.height
        guard width > 0,
              height > 0,
              width <= maxWidth,
              height <= maxHeight,
              Int64(width) * Int64(height) <= maxPixelCount else {
            return .invalid(.dimensionsOutOfRange)
        }
        if let expectedWidth {
            guard expectedWidth > 0, width == expectedWidth else {
                return .invalid(.dimensionsMismatch)
            }
        }
        if let expectedHeight {
            guard expectedHeight > 0, height == expectedHeight else {
                return .invalid(.dimensionsMismatch)
            }
        }
        guard let decodedImage = decodedImage(from: sourceImage, cgImage: sourceCGImage) else {
            return .invalid(.decodeFailed)
        }

        return .valid(SplashPreparedImage(
            fileURL: fileURL,
            image: decodedImage,
            mimeType: detectedMimeType,
            sizeBytes: Int64(data.count),
            width: width,
            height: height,
            sha256Hex: sha256Hex
        ))
    }

    private static func detectedMimeType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 12,
           bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]),
           bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        return nil
    }

    private static func normalizedMimeType(_ rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image/jpeg", "image/jpg":
            return "image/jpeg"
        case "image/png":
            return "image/png"
        case "image/webp":
            return "image/webp"
        default:
            return ""
        }
    }

    private static func matchesExpectedSHA256(
        _ rawValue: String,
        digestHex: String,
        digestData: Data
    ) -> Bool {
        var expected = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if expected.lowercased().hasPrefix("sha256:") {
            expected.removeFirst("sha256:".count)
            expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if expected.count == 64,
           expected.unicodeScalars.allSatisfy({ scalar in
               CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
           }) {
            return expected.lowercased() == digestHex
        }

        let expectedBase64 = expected
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedBase64 = expectedBase64 + String(
            repeating: "=",
            count: (4 - expectedBase64.count % 4) % 4
        )
        guard let decoded = Data(base64Encoded: paddedBase64) else {
            return false
        }
        return decoded == digestData
    }

    private static func decodedImage(from image: UIImage, cgImage: CGImage) -> UIImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let decodedCGImage = context.makeImage() else {
            return nil
        }
        return UIImage(
            cgImage: decodedCGImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}

struct SplashImagePreparationResult: @unchecked Sendable {
    let status: SplashImagePrefetchStatus
    let preparedImage: SplashPreparedImage?
    let validationFailure: SplashImageValidationFailure?
}

struct SplashImageDiskCache: Sendable {
    static let shared = SplashImageDiskCache()
    let directory: URL

    init(directory: URL = SplashImageDiskCache.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BlueStoneIMSplashImages", isDirectory: true)
    }

    static func cacheKey(assetID: String, version: String, imageURL: String) -> String? {
        let trimmedAssetID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return nil }
        if !trimmedAssetID.isEmpty {
            return "splash-asset-\(stableHashHex("\(trimmedAssetID)|\(trimmedVersion)"))"
        }
        guard !trimmedURL.isEmpty else { return nil }
        return "splash-url-\(stableHashHex("\(trimmedURL)|\(trimmedVersion)"))"
    }

    static func cacheKey(explicitKey: String) -> String? {
        let trimmedKey = explicitKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return "splash-explicit-\(stableHashHex(trimmedKey))"
    }

    static func cacheKey(
        scope: SplashTenantScope,
        assetID: String,
        version: String,
        imageURL: String
    ) -> String? {
        guard scope.isValid,
              let unscopedKey = cacheKey(assetID: assetID, version: version, imageURL: imageURL) else {
            return nil
        }
        return "splash-scoped-\(stableHashHex("\(scope.storageKey)|\(unscopedKey)"))"
    }

    static func cacheKey(scope: SplashTenantScope, explicitKey: String) -> String? {
        guard scope.isValid,
              let unscopedKey = cacheKey(explicitKey: explicitKey) else {
            return nil
        }
        return "splash-scoped-\(stableHashHex("\(scope.storageKey)|\(unscopedKey)"))"
    }

    func fileURL(for cacheKey: String) -> URL {
        directory.appendingPathComponent(cacheKey, isDirectory: false)
    }

    func containsImage(for cacheKey: String) -> Bool {
        let url = fileURL(for: cacheKey)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        if case .valid = SplashImageValidator.validate(data: data, fileURL: url) {
            return true
        }
        return false
    }

    func storeImageData(_ data: Data, cacheKey: String) -> Bool {
        let url = fileURL(for: cacheKey)
        guard case .valid = SplashImageValidator.validate(data: data, fileURL: url) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    func prepareImage(
        from urlString: String,
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashImagePreparationResult {
        if let cachedImage = await validatedCachedImage(
            cacheKey: cacheKey,
            expectedSHA256: expectedSHA256,
            expectedSizeBytes: expectedSizeBytes,
            expectedMimeType: expectedMimeType,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        ) {
            return SplashImagePreparationResult(
                status: .cached,
                preparedImage: cachedImage,
                validationFailure: nil
            )
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              !cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SplashImagePreparationResult(
                status: .failed,
                preparedImage: nil,
                validationFailure: .emptyData
            )
        }
        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url, options: [.mappedIfSafe])
                }.value
            } else {
                let result = try await URLSession.shared.data(from: url)
                if let http = result.1 as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    return SplashImagePreparationResult(
                        status: .failed,
                        preparedImage: nil,
                        validationFailure: nil
                    )
                }
                data = result.0
            }
            return await validateAndStore(
                data,
                cacheKey: cacheKey,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        } catch {
            return SplashImagePreparationResult(
                status: .failed,
                preparedImage: nil,
                validationFailure: nil
            )
        }
    }

    func prefetchImage(from urlString: String, cacheKey: String) async -> SplashImagePrefetchStatus {
        await prepareImage(
            from: urlString,
            cacheKey: cacheKey,
            expectedSHA256: "",
            expectedSizeBytes: nil,
            expectedMimeType: "",
            expectedWidth: nil,
            expectedHeight: nil
        ).status
    }

    private func validatedCachedImage(
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashPreparedImage? {
        let fileURL = fileURL(for: cacheKey)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                return nil
            }
            switch SplashImageValidator.validate(
                data: data,
                fileURL: fileURL,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            ) {
            case .valid(let preparedImage):
                return preparedImage
            case .invalid:
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }.value
    }

    private func validateAndStore(
        _ data: Data,
        cacheKey: String,
        expectedSHA256: String,
        expectedSizeBytes: Int64?,
        expectedMimeType: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async -> SplashImagePreparationResult {
        let directory = directory
        let fileURL = fileURL(for: cacheKey)
        return await Task.detached(priority: .utility) {
            let validation = SplashImageValidator.validate(
                data: data,
                fileURL: fileURL,
                expectedSHA256: expectedSHA256,
                expectedSizeBytes: expectedSizeBytes,
                expectedMimeType: expectedMimeType,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
            switch validation {
            case .valid(let preparedImage):
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    try data.write(to: fileURL, options: [.atomic])
                    return SplashImagePreparationResult(
                        status: .downloaded,
                        preparedImage: preparedImage,
                        validationFailure: nil
                    )
                } catch {
                    return SplashImagePreparationResult(
                        status: .failed,
                        preparedImage: nil,
                        validationFailure: nil
                    )
                }
            case .invalid(let failure):
                try? FileManager.default.removeItem(at: fileURL)
                return SplashImagePreparationResult(
                    status: .failed,
                    preparedImage: nil,
                    validationFailure: failure
                )
            }
        }.value
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

struct GroupInfo: Identifiable, Hashable {
    let id: String
    let name: String
    var groupRevision: Int64 = 0
    var avatarURL: String = ""
    var avatarVersion: String = ""
    var avatarUpdatedAt: String = ""
    let notice: String
    var groupDescription: String = ""
    var owner: String
    var ownerID: String = ""
    var members: [IMUser]
    var admins: [IMUser]
    var membersPartial: Bool = false
    var membersLoadedCount: Int = 0
    var membersNextOffset: Int? = nil
    var membersNextCursor: String? = nil
    var muted: Bool
    var allMuted: Bool
    var allMuteStart: Date?
    var allMuteEnd: Date?
    var allMuteMode: GroupMuteMode? = nil
    var allMuteActive: Bool? = nil
    var allMuteServerTime: Date? = nil
    var allMuteNextBoundary: Date? = nil
    var allMuteRepairRequired: Bool = false
    var allMuteUpdatedAt: String = ""
    var myRole: String = "member"
    var memberCount: Int? = nil
    var inviteConfirmRequired: Bool = false
    var pendingJoinRequestCount: Int = 0
    var fileCount: Int = 0
    var blacklistCount: Int = 0
    var historyVisible: Bool = true
    var historyVisibleFromSeq: Int64 = 1
    var historyLimited: Bool = false
    var groupMuted: Bool = false
    var canManageMuteList: Bool = false
    var muteListCount: Int? = nil

    var effectiveMemberCount: Int {
        (memberCount ?? 0) > 0 ? (memberCount ?? 0) : members.count
    }

    var visibleMemberCount: Int? {
        memberCount.flatMap { $0 > 0 ? $0 : nil }
    }

    var memberCountDisplayText: String {
        visibleMemberCount.map { "\($0) 人" } ?? "人数待同步"
    }

    var avatarCacheKey: String {
        AvatarImageCache.cacheKey(url: avatarURL, version: avatarVersion, updatedAt: avatarUpdatedAt)
    }

    var canCurrentUserManage: Bool {
        myRole == "owner" || myRole == "admin"
    }

    var muteListStatusText: String {
        guard canManageMuteList else { return "仅群主或管理员可查看" }
        guard let muteListCount else { return "查看、添加或移除成员" }
        return muteListCount > 0 ? "\(muteListCount) 人已禁言" : "暂无禁言成员"
    }

    var historyVisibilityStatusText: String {
        historyVisible ? "全部可见" : "仅入群后"
    }

    var isCurrentUserOwner: Bool {
        myRole == "owner"
    }

    func isAllMuteActive(at date: Date = Date()) -> Bool {
        if let allMuteActive {
            return allMuteActive
        }
        guard allMuted else { return false }
        guard let allMuteStart, let allMuteEnd else { return true }
        return date >= allMuteStart && date < allMuteEnd
    }

    func allMuteTimeRangeText() -> String {
        guard let allMuteStart, let allMuteEnd else { return "当前立即生效" }
        let suffix = Calendar.current.isDate(allMuteStart, inSameDayAs: allMuteEnd) ? "" : "次日 "
        return "\(GroupInfo.shortTimeFormatter.string(from: allMuteStart)) - \(suffix)\(GroupInfo.shortTimeFormatter.string(from: allMuteEnd))"
    }

    func allMuteStatusText(at date: Date = Date()) -> String {
        if allMuteRepairRequired {
            return isAllMuteActive(at: date) ? "禁言中（状态待修复）" : "状态待修复"
        }
        guard allMuteMode != .off, allMuted else { return "未开启" }
        if allMuteMode == .always || (allMuteMode == nil && allMuteStart == nil && allMuteEnd == nil) {
            return "一直禁言中"
        }
        guard let allMuteStart, let allMuteEnd else { return isAllMuteActive(at: date) ? "禁言中" : "未开启" }
        let serverNow = allMuteServerTime ?? date
        if serverNow < allMuteStart {
            return "待生效 \(allMuteTimeRangeText())"
        }
        if serverNow >= allMuteEnd {
            return "已结束 \(allMuteTimeRangeText())"
        }
        return "固定时段禁言中 \(allMuteTimeRangeText())"
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct GroupAnnouncement: Identifiable, Hashable {
    let id: String
    let groupID: String
    let title: String
    let content: String
    let summary: String
    let createdBy: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let publishedAt: String
    let unread: Bool
    let readAt: String?
    let displayPosition: String
    let readAction: String
    let readCount: Int?
    let unreadCount: Int?
    let recipientCount: Int?
    let canViewReadCounts: Bool

    var readCountSummary: String? {
        guard canViewReadCounts,
              let readCount,
              let unreadCount,
              let recipientCount else { return nil }
        return "\(readCount) 人已读 · \(unreadCount) 人未读 · 共 \(recipientCount) 人"
    }

    func scrubbingReadCounts() -> GroupAnnouncement {
        GroupAnnouncement(
            id: id,
            groupID: groupID,
            title: title,
            content: content,
            summary: summary,
            createdBy: createdBy,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            publishedAt: publishedAt,
            unread: unread,
            readAt: readAt,
            displayPosition: displayPosition,
            readAction: readAction,
            readCount: nil,
            unreadCount: nil,
            recipientCount: nil,
            canViewReadCounts: false
        )
    }
}

enum GroupAnnouncementPrivacyProjection {
    static func sanitize(
        _ announcement: GroupAnnouncement,
        requestEpoch: UInt64,
        currentEpoch: UInt64
    ) -> GroupAnnouncement {
        requestEpoch == currentEpoch ? announcement : announcement.scrubbingReadCounts()
    }
}

enum GroupAnnouncementRevisionProjection {
    static func preferred(
        existing: GroupAnnouncement,
        incoming: GroupAnnouncement,
        existingRevision: Date?,
        incomingRevision: Date?
    ) -> GroupAnnouncement {
        if let existingRevision, let incomingRevision {
            if incomingRevision < existingRevision { return existing }
            if incomingRevision == existingRevision, !existing.unread, incoming.unread { return existing }
        } else if !existing.updatedAt.isEmpty, incoming.updatedAt.isEmpty {
            return existing
        }
        return incoming
    }
}

enum GroupDescriptionInputError: Error, Equatable {
    case tooLong

    var userMessage: String {
        switch self {
        case .tooLong:
            return "群描述不能超过 500 个字符"
        }
    }
}

enum GroupDescriptionInputPolicy {
    static let maximumUnicodeScalars = 500

    static func normalizedUnicodeScalarCount(_ value: String) -> Int {
        value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    static func normalize(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUnicodeScalarCount(value) <= maximumUnicodeScalars else {
            throw GroupDescriptionInputError.tooLong
        }
        return normalized
    }
}

struct GroupOwnerTransferIdempotencyState {
    private var keysByIntent: [String: String] = [:]

    mutating func key(
        scope: String,
        groupID: String,
        targetUID: String,
        makeKey: () -> String = { UUID().uuidString.lowercased() }
    ) -> String {
        let intent = [scope, groupID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
        if let existing = keysByIntent[intent] {
            return existing
        }
        let created = makeKey()
        keysByIntent[intent] = created
        return created
    }

    mutating func clear(scope: String, groupID: String, targetUID: String) {
        let intent = [scope, groupID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
        keysByIntent[intent] = nil
    }

    mutating func reset() {
        keysByIntent.removeAll()
    }
}

struct GroupJoinRequest: Identifiable, Hashable {
    let id: String
    let groupID: String
    let applicantUID: String
    let applicantName: String
    let applicantAvatarURL: String
    let inviterAvatarURL: String
    let inviterName: String
    var status: String
    let message: String
    let createdAt: String

    init(
        id: String,
        groupID: String,
        applicantUID: String,
        applicantName: String,
        applicantAvatarURL: String = "",
        inviterAvatarURL: String = "",
        inviterName: String,
        status: String,
        message: String,
        createdAt: String
    ) {
        self.id = id
        self.groupID = groupID
        self.applicantUID = applicantUID
        self.applicantName = applicantName
        self.applicantAvatarURL = applicantAvatarURL
        self.inviterAvatarURL = inviterAvatarURL
        self.inviterName = inviterName
        self.status = status
        self.message = message
        self.createdAt = createdAt
    }
}

struct GroupMuteListItem: Identifiable, Hashable {
    let groupID: String
    let targetUID: String
    let targetUserID: String
    let targetUsername: String
    let targetNickname: String
    let targetAvatarURL: String
    let targetRole: String
    let operatorUID: String
    let operatorName: String
    let reason: String
    let createdAt: String
    let updatedAt: String
    let createdAtText: String
    let updatedAtText: String

    var id: String {
        "\(groupID)|\(targetUID)"
    }

    var targetDisplayName: String {
        [targetNickname, targetUsername, targetUserID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }

    var targetDisplayID: String {
        [targetUserID, targetUID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? targetUsername
    }

    var reasonText: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未填写原因" : trimmed
    }

    var operatorText: String {
        let name = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "管理员" : name
    }
}

struct FriendRequest: Identifiable, Hashable {
    let id: String
    let name: String
    let userID: String
    let avatarURL: String
    let source: String
    let message: String
    let status: String
    let direction: String
    let tenantReviewStatus: String
    let peerReviewStatus: String
    let canRespond: Bool
    let outcome: String
    let relationStatus: String
    let friendAction: String
    let friendFlow: String
    let directlyEstablished: Bool
    let requiresTenantReview: Bool?
    let requiresTargetApproval: Bool?
    let resolutionMode: String
    var accepted: Bool

    var isPendingIncoming: Bool {
        direction == "incoming" && status == "pending" && canRespond
    }

    var isPendingOutgoing: Bool {
        direction == "outgoing" && status == "pending"
    }

    var isSuppressed: Bool {
        status.lowercased() == "suppressed"
            || outcome.lowercased() == "application_suppressed"
            || resolutionMode.lowercased() == "suppressed_by_policy"
    }

    var isExpired: Bool {
        status.lowercased() == "expired" || outcome.lowercased() == "application_expired"
    }

    var canCancel: Bool {
        isPendingOutgoing && !isSuppressed
    }

    var isCancelled: Bool {
        ["cancelled", "canceled"].contains(status.lowercased())
            || outcome.lowercased() == "application_cancelled"
            || resolutionMode.lowercased() == "requester_cancel"
    }

    var statusLabel: String {
        if accepted || status == "accepted" { return "已通过" }
        if status == "rejected" { return "已拒绝" }
        if isCancelled { return "已取消" }
        if isSuppressed { return "未投递" }
        if isExpired { return "已过期" }
        // Tenant review is an internal admission stage. The requester-facing
        // contract stays "waiting for the peer" until the relation reaches a
        // terminal state, so an outgoing row must never leak that stage.
        if direction == "outgoing" { return FriendAddPresentation.waitingTitle }
        if peerReviewStatus == "tenant_review_pending" || tenantReviewStatus == "pending" {
            return "等待企业审核"
        }
        if canRespond { return "待处理" }
        return "处理中"
    }

    init(
        id: String,
        name: String,
        userID: String = "",
        avatarURL: String = "",
        source: String,
        message: String,
        status: String = "pending",
        direction: String = "incoming",
        tenantReviewStatus: String = "",
        peerReviewStatus: String = "",
        canRespond: Bool = true,
        outcome: String = "",
        relationStatus: String = "",
        friendAction: String = "",
        friendFlow: String = "",
        directlyEstablished: Bool = false,
        requiresTenantReview: Bool? = nil,
        requiresTargetApproval: Bool? = nil,
        resolutionMode: String = "",
        accepted: Bool
    ) {
        self.id = id
        self.name = name
        self.userID = userID
        self.avatarURL = avatarURL
        self.source = source
        self.message = message
        self.status = status
        self.direction = direction
        self.tenantReviewStatus = tenantReviewStatus
        self.peerReviewStatus = peerReviewStatus
        self.canRespond = canRespond
        self.outcome = outcome
        self.relationStatus = relationStatus
        self.friendAction = friendAction
        self.friendFlow = friendFlow
        self.directlyEstablished = directlyEstablished
        self.requiresTenantReview = requiresTenantReview
        self.requiresTargetApproval = requiresTargetApproval
        self.resolutionMode = resolutionMode
        self.accepted = accepted
    }
}

// JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：黑名单投影模型允许安全跨后台任务传递
struct BlacklistItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let reason: String
}
// JHT_MOD_END PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改结束

enum CallRecordDirection: String, Hashable, Codable {
    case outgoing
    case incoming
    case system
}

struct CallRecord: Identifiable, Hashable, Codable {
    let id: String
    let callID: String?
    let peerID: String
    let peerUserID: String
    let peerAvatarURL: String
    let peerAvatarVersion: String
    let peerAvatarUpdatedAt: String
    let peerAvatarSource: String
    let title: String
    let subtitle: String
    let time: String
    let status: String
    let direction: CallRecordDirection
    let callType: String
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: TimeInterval?
    let endReason: String
    let stateVersion: Int64

    init(
        id: String,
        callID: String? = nil,
        peerID: String = "",
        peerUserID: String = "",
        peerAvatarURL: String = "",
        peerAvatarVersion: String = "",
        peerAvatarUpdatedAt: String = "",
        peerAvatarSource: String = "",
        title: String,
        subtitle: String,
        time: String,
        status: String,
        direction: CallRecordDirection = .outgoing,
        callType: String = "语音通话",
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        endReason: String = "",
        stateVersion: Int64 = 0
    ) {
        self.id = id
        self.callID = callID
        self.peerID = peerID
        self.peerUserID = peerUserID
        self.peerAvatarURL = peerAvatarURL
        self.peerAvatarVersion = peerAvatarVersion
        self.peerAvatarUpdatedAt = peerAvatarUpdatedAt
        self.peerAvatarSource = peerAvatarSource
        self.title = title
        self.subtitle = subtitle
        self.time = time
        self.status = status
        self.direction = direction
        self.callType = callType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.endReason = endReason
        self.stateVersion = stateVersion
    }
}

struct IncomingVoiceCall: Identifiable, Hashable {
    let id: String
    var callID: String? = nil
    var caller: IMUser
    let startedAt: String
    var source: String
    var requestedMediaMode: String = "audio"
    var stateVersion: Int64 = 0

    var isVideo: Bool {
        requestedMediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
    }
}

enum VideoCallCameraPosition: String, Hashable {
    case front
    case back
}

struct VideoCallPreview: Identifiable, Hashable {
    let id: String
    var peer: IMUser
    var channelID: String?
    var cameraEnabled: Bool
    var isPreparing: Bool
    var unavailableReason: String?
    var isStartingCall: Bool = false
    var startError: String? = nil
}

struct VideoCallTerminalPresentation: Hashable {
    let title: String
    let cause: String
    let nextAction: String

    static func resolve(reason: String, fallback: String = "通话已结束") -> Self {
        let value = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func contains(_ candidates: [String]) -> Bool {
            candidates.contains { value.contains($0) }
        }
        if contains(["reject", "已拒绝"]) {
            return Self(title: "对方已拒绝", cause: "对方没有接听本次通话。", nextAction: "返回聊天")
        }
        if contains(["busy", "忙线"]) {
            return Self(title: "对方正在通话中", cause: "对方当前无法接听。", nextAction: "稍后再试")
        }
        if contains(["timeout", "timed_out", "超时", "未接通"]) {
            return Self(title: "无人接听", cause: "呼叫超时，未建立媒体连接。", nextAction: "返回聊天")
        }
        if contains(["permission", "notallowed", "权限"]) {
            return Self(title: "未获得媒体权限", cause: "麦克风或摄像头权限未开启。", nextAction: "检查权限后重试")
        }
        if contains(["media", "capture", "媒体"]) {
            return Self(title: "媒体设备不可用", cause: "未能安全启用麦克风或摄像头。", nextAction: "检查设备后重试")
        }
        if contains(["license", "未开通"]) {
            return Self(title: "视频通话不可用", cause: "当前企业未开通或已停用视频通话。", nextAction: "返回聊天")
        }
        if contains(["session", "scope", "client_scope_changed", "登录"]) {
            return Self(title: "会话已变更", cause: "账号或企业会话已切换，本次通话已安全结束。", nextAction: "返回聊天")
        }
        if contains(["answered_elsewhere", "其他设备"]) {
            return Self(title: "已在其他设备接听", cause: "本设备不会继续连接媒体。", nextAction: "返回聊天")
        }
        if contains(["failed", "failure", "network_error", "ice_", "连接失败", "恢复失败"]) {
            return Self(title: "通话连接失败", cause: "连接未能恢复，媒体已关闭。", nextAction: "检查网络后重试")
        }
        if contains(["remote", "peer", "callee_hangup", "caller_hangup", "server_signal_terminal", "对方已挂断"]) {
            return Self(title: "对方已挂断", cause: "对方结束了本次通话。", nextAction: "返回聊天")
        }
        if contains(["cancel", "已取消"]) {
            return Self(title: "呼叫已取消", cause: "本次呼叫未接通。", nextAction: "返回聊天")
        }
        if contains(["local_hangup", "user_hangup"]) {
            return Self(title: "通话已结束", cause: "你结束了本次通话，媒体已安全关闭。", nextAction: "返回聊天")
        }
        if contains(["missed", "未接"]) {
            return Self(title: "未接来电", cause: "你没有接听本次视频来电。", nextAction: "返回聊天")
        }
        return Self(title: fallback, cause: "本次通话已结束，媒体已安全关闭。", nextAction: "返回聊天")
    }
}

struct VideoCallTerminalResult: Identifiable, Hashable {
    let id: String
    let callID: String
    let peer: IMUser
    let title: String
    let cause: String
    let nextAction: String
    let reason: String
    let durationText: String

    init(callID: String = "", peer: IMUser, reason: String, fallback: String = "通话已结束", durationText: String = "") {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let presentation = VideoCallTerminalPresentation.resolve(reason: reason, fallback: fallback)
        self.callID = normalizedCallID
        self.id = normalizedCallID.isEmpty
            ? "video-terminal-\(UUID().uuidString)"
            : "video-terminal-\(normalizedCallID)"
        self.peer = peer
        self.title = presentation.title
        self.cause = presentation.cause
        self.nextAction = presentation.nextAction
        self.reason = reason
        self.durationText = durationText
    }
}

struct VoiceCallSession: Identifiable, Hashable {
    let id: String
    var callID: String? = nil
    var roomID: String = ""
    var rtcToken: String = ""
    var mediaBaseURL: String = ""
    var peer: IMUser
    let direction: String
    let startedAt: String
    var statusText: String = "连接中"
    var mediaState: RTCVoiceMediaState = .preparing
    var isMuted: Bool
    var speakerOn: Bool
    var startedAtDate: Date = Date()
    var connectedAt: Date? = nil
    var requestedMediaMode: String = "audio"
    var mediaMode: String = "audio"
    var localCameraEnabled: Bool = false
    var remoteCameraEnabled: Bool = true
    var cameraPosition: VideoCallCameraPosition = .front
    var isMinimized: Bool = false
    var isRecoveringNetwork: Bool = false
    var voiceTransportConnected: Bool = false
    var remoteAudioTrackReady: Bool = false
    var remoteAudioRTPReady: Bool = false
    var remoteVideoTrackReady: Bool = false
    var videoConnectionGate: RTCVideoConnectionGate = RTCVideoConnectionGate()
    var endedReason: String = ""
    var stateVersion: Int64 = 0
    var requiresAcceptedDeviceBeforeJoin: Bool = false

    var isVideoCall: Bool {
        requestedMediaMode == "video" || mediaMode == "video"
    }
}

struct InboxItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let time: String
    let category: String
    var isRead: Bool
    let accentHex: UInt
    let avatarURL: String
    let groupInviteApproval: GroupInviteApproval?
    let sortTimestamp: TimeInterval

    init(
        id: String,
        title: String,
        subtitle: String,
        time: String,
        category: String,
        isRead: Bool,
        accentHex: UInt,
        avatarURL: String = "",
        groupInviteApproval: GroupInviteApproval? = nil,
        sortTimestamp: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.time = time
        self.category = category
        self.isRead = isRead
        self.accentHex = accentHex
        self.avatarURL = avatarURL
        self.groupInviteApproval = groupInviteApproval
        self.sortTimestamp = sortTimestamp
    }

    var normalizedCategory: String {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if InboxItem.isAnnouncementCategory(normalized) {
            return "公告"
        }
        return "系统通知"
    }

    var isAnnouncement: Bool {
        normalizedCategory == "公告"
    }

    private static func isAnnouncementCategory(_ normalizedCategory: String) -> Bool {
        let exactAnnouncementKinds: Set<String> = [
            "announcement",
            "announcements",
            "tenant_announcement",
            "enterprise_announcement",
            "company_announcement",
            "org_announcement",
            "public_announcement",
            "bulletin",
            "bulletins",
            "公告",
            "企业公告",
            "全员公告"
        ]
        return exactAnnouncementKinds.contains(normalizedCategory)
    }

    func withGroupInviteApproval(_ approval: GroupInviteApproval) -> InboxItem {
        InboxItem(
            id: id,
            title: title,
            subtitle: subtitle,
            time: time,
            category: category,
            isRead: isRead,
            accentHex: accentHex,
            avatarURL: avatarURL,
            groupInviteApproval: approval
        )
    }
}

struct GovernanceItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let status: String
    let accentHex: UInt
}

struct TenantPolicy: Hashable {
    let messageRetention: String
    let fileLimit: String
    let groupLimit: String
    let deviceLimit: String
    let rateLimit: String
    let sensitiveAudit: String
}

struct DeviceSession: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: String
    let lastSeen: String
    var status: String
    var isBound: Bool
    var isBlocked: Bool
}

struct LoginLog: Identifiable, Hashable {
    let id: String
    let device: String
    let location: String
    let time: String
    let result: String
}

enum RealNameValidator {
    static func sanitizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(20))
    }

    static func sanitizedIDNumber(_ value: String) -> String {
        let allowed = value
            .uppercased()
            .filter { character in
                character.isNumber || character == "X"
            }
        return String(allowed.prefix(18))
    }

    static func isValidName(_ value: String) -> Bool {
        let name = sanitizedName(value)
        guard (2...20).contains(name.count),
              name.first != "·",
              name.last != "·" else {
            return false
        }
        return name.allSatisfy { character in
            character == "·" || character.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
        }
    }

    static func isValidChineseResidentID(_ value: String) -> Bool {
        let id = sanitizedIDNumber(value)
        let chars = Array(id)
        if chars.count == 15 {
            return isValidLegacyChineseResidentID(chars)
        }
        guard chars.count == 18 else { return false }
        guard chars.prefix(17).allSatisfy(\.isNumber),
              chars[17].isNumber || chars[17] == "X" else {
            return false
        }

        let region = String(chars.prefix(6))
        guard region != "000000" else { return false }

        let birthday = String(chars[6...13])
        guard isValidBirthday(birthday) else { return false }

        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks = Array("10X98765432")
        let sum = chars.prefix(17).enumerated().reduce(0) { partial, item in
            let digit = item.element.wholeNumberValue ?? 0
            return partial + digit * weights[item.offset]
        }
        return chars[17] == checks[sum % 11]
    }

    private static func isValidLegacyChineseResidentID(_ chars: [Character]) -> Bool {
        guard chars.allSatisfy(\.isNumber) else { return false }
        let region = String(chars.prefix(6))
        guard region != "000000" else { return false }
        let birthday = "19" + String(chars[6...11])
        return isValidBirthday(birthday)
    }

    private static func isValidBirthday(_ value: String) -> Bool {
        guard value.count == 8,
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)),
              (1900...Calendar.current.component(.year, from: Date())).contains(year) else {
            return false
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        guard let date = components.date else { return false }
        let resolved = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }
}

enum SupportContactMailto {
    static func normalizedEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "?#/"))
        guard email.rangeOfCharacter(from: forbidden) == nil else { return nil }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".") else {
            return nil
        }
        return email
    }

    static func mailtoURL(email rawEmail: String) -> URL? {
        guard let email = normalizedEmail(rawEmail) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
