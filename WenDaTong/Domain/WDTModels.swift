import Foundation

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

enum SystemCallIntegrationPolicy {
    // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: submitted build uses in-app RTC calls without CallKit.
    #if WDT_ENABLE_CALLKIT
    static let isCallKitEnabled = true
    static let isVoIPPushRegistrationEnabled = true
    #else
    static let isCallKitEnabled = false
    static let isVoIPPushRegistrationEnabled = false
    #endif

    static let allowsInAppRTCCalls = true

    static var usesSystemCallIntegration: Bool {
        isCallKitEnabled && isVoIPPushRegistrationEnabled
    }
    // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
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
                submittedEntryCode: entryCode,
                allowsServerDefinedInvite: true // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
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

// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110: InboxItem is the same Domain projection value via DomainModuleBridge.swift alias.

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

// WDT_IOS1_STORES_CONTACT_ACTUAL_20261110: DeviceSession is the same Domain projection value via DomainModuleBridge.swift alias.

// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_BEGIN
// LoginLog is the original Domain value via WenDaTong/LoginLogStore.swift.
// WDT_IOS1_LOGIN_LOG_STATE_FAMILY_20261111_END

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
