import Foundation
import IM4Data
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias AccessDiagnosticsOverlayConfiguration = IM4Domain.AccessDiagnosticsOverlayConfiguration

extension AccessDiagnosticsOverlayConfiguration {
    init(configuredValue: Bool?, fieldWasPresent: Bool) {
        if let configuredValue {
            self = configuredValue ? .enabled : .disabled
        } else {
            self = fieldWasPresent ? .disabled : .unavailable
        }
    }

    var isEnabled: Bool { self == .enabled }

    var displayText: String {
        switch self {
        case .unavailable: return "配置未获取"
        case .disabled: return "已关闭"
        case .enabled: return "已启用"
        }
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteAppCurrentPolicy = IM4Data.RemoteAppCurrentPolicy

extension RemoteAppCurrentPolicy: @retroactive Decodable, @retroactive Encodable {
    var accessDiagnosticsOverlayEnabled: Bool {
        accessDiagnosticsOverlayConfiguration.isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case platform
        case status
        case allowWorkspaceSwitch = "allow_workspace_switch"
        case allowWorkspaceSwitchCamel = "allowWorkspaceSwitch"
        case allowDefaultTenantJoin = "allow_default_tenant_join"
        case allowDefaultTenantJoinCamel = "allowDefaultTenantJoin"
        case requireRealName = "require_real_name"
        case requireRealNameCamel = "requireRealName"
        case requirePhoneVerification = "require_phone_verification"
        case requirePhoneVerificationCamel = "requirePhoneVerification"
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case registrationOpen = "registration_open"
        case registrationOpenCamel = "registrationOpen"
        case enabled
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
        case preferredEnterpriseCode = "preferred_enterprise_code"
        case preferredEnterpriseCodeCamel = "preferredEnterpriseCode"
        case policy
        case appPolicy = "app_policy"
        case appPolicyCamel = "appPolicy"
        case authPolicy = "auth_policy"
        case authPolicyCamel = "authPolicy"
        case registerPolicy = "register_policy"
        case registerPolicyCamel = "registerPolicy"
        case loginPolicy = "login_policy"
        case loginPolicyCamel = "loginPolicy"
        case tenantPool = "tenant_pool"
        case tenantPoolCamel = "tenantPool"
        case supportContactEmail = "support_contact_email"
        case supportContactEmailCamel = "supportContactEmail"
        case supportContactConfigured = "support_contact_configured"
        case supportContactConfiguredCamel = "supportContactConfigured"
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case accessDiagnosticsCopyEnabled = "access_diagnostics_copy_enabled"
        case accessDiagnosticsCopyEnabledCamel = "accessDiagnosticsCopyEnabled"
        case debugFeatures = "debug_features"
        case debugFeaturesCamel = "debugFeatures"
        case organization
        case cacheTTLSeconds = "cache_ttl_seconds"
        case cacheTTLSecondsCamel = "cacheTtlSeconds"
        case cacheTTLSecondsUpperCamel = "cacheTTLSeconds"
    }

    enum OrganizationCodingKeys: String, CodingKey {
        case departmentEnabled = "department_enabled"
        case departmentEnabledCamel = "departmentEnabled"
    }

    enum DebugFeaturesCodingKeys: String, CodingKey {
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case accessDiagnosticsCopyEnabled = "access_diagnostics_copy_enabled"
        case accessDiagnosticsCopyEnabledCamel = "accessDiagnosticsCopyEnabled"
    }

    init(
        appID: String,
        platform: String = "",
        status: String,
        allowWorkspaceSwitch: Bool,
        allowDefaultTenantJoin: Bool,
        requireRealName: Bool = false,
        requirePhoneVerification: Bool = false,
        phoneAuthEnabled: Bool = true,
        registrationEnabled: Bool = true,
        enterpriseCodeFirst: Bool = false,
        preferredEnterpriseCode: String = "",
        supportContactEmail: String = "",
        supportContactConfigured: Bool = false,
        departmentEnabled: Bool = false,
        accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration? = nil,
        accessDiagnosticsOverlayEnabled: Bool? = nil,
        accessDiagnosticsCopyEnabled: Bool = false,
        cacheTTLSeconds: Int
    ) {
        let __wire_appID: String
        let __wire_platform: String
        let __wire_status: String
        let __wire_allowWorkspaceSwitch: Bool
        let __wire_allowDefaultTenantJoin: Bool
        let __wire_requireRealName: Bool
        let __wire_requirePhoneVerification: Bool
        let __wire_phoneAuthEnabled: Bool
        let __wire_registrationEnabled: Bool
        let __wire_enterpriseCodeFirst: Bool
        let __wire_preferredEnterpriseCode: String
        let __wire_supportContactEmail: String
        let __wire_supportContactConfigured: Bool
        let __wire_departmentEnabled: Bool
        let __wire_accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration
        let __wire_accessDiagnosticsCopyEnabled: Bool
        let __wire_cacheTTLSeconds: Int
        __wire_appID = appID
        __wire_platform = platform
        __wire_status = status
        __wire_allowWorkspaceSwitch = allowWorkspaceSwitch
        __wire_allowDefaultTenantJoin = allowDefaultTenantJoin
        __wire_requireRealName = requireRealName
        __wire_requirePhoneVerification = requirePhoneVerification
        __wire_phoneAuthEnabled = phoneAuthEnabled
        __wire_registrationEnabled = registrationEnabled
        __wire_enterpriseCodeFirst = enterpriseCodeFirst
        __wire_preferredEnterpriseCode = RemoteAppBootstrap.validPreferredEnterpriseCode(
            preferredEnterpriseCode,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
        __wire_supportContactEmail = supportContactEmail
        __wire_supportContactConfigured = supportContactConfigured
        __wire_departmentEnabled = departmentEnabled
        __wire_accessDiagnosticsOverlayConfiguration = accessDiagnosticsOverlayConfiguration
            ?? AccessDiagnosticsOverlayConfiguration(
                configuredValue: accessDiagnosticsOverlayEnabled,
                fieldWasPresent: accessDiagnosticsOverlayEnabled != nil
            )
        __wire_accessDiagnosticsCopyEnabled = accessDiagnosticsCopyEnabled
        __wire_cacheTTLSeconds = cacheTTLSeconds
        self.init(
            wireAppID: __wire_appID,
            platform: __wire_platform,
            status: __wire_status,
            allowWorkspaceSwitch: __wire_allowWorkspaceSwitch,
            allowDefaultTenantJoin: __wire_allowDefaultTenantJoin,
            requireRealName: __wire_requireRealName,
            requirePhoneVerification: __wire_requirePhoneVerification,
            phoneAuthEnabled: __wire_phoneAuthEnabled,
            registrationEnabled: __wire_registrationEnabled,
            enterpriseCodeFirst: __wire_enterpriseCodeFirst,
            preferredEnterpriseCode: __wire_preferredEnterpriseCode,
            supportContactEmail: __wire_supportContactEmail,
            supportContactConfigured: __wire_supportContactConfigured,
            departmentEnabled: __wire_departmentEnabled,
            accessDiagnosticsOverlayConfiguration: __wire_accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: __wire_accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: __wire_cacheTTLSeconds
        )
    }

    public init(from decoder: Decoder) throws {
        let appID: String
        let platform: String
        let status: String
        let allowWorkspaceSwitch: Bool
        let allowDefaultTenantJoin: Bool
        let requireRealName: Bool
        let requirePhoneVerification: Bool
        let phoneAuthEnabled: Bool
        let registrationEnabled: Bool
        let enterpriseCodeFirst: Bool
        let preferredEnterpriseCode: String
        let supportContactEmail: String
        let supportContactConfigured: Bool
        let departmentEnabled: Bool
        let accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration
        let accessDiagnosticsCopyEnabled: Bool
        let cacheTTLSeconds: Int
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let policyRoot = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .policy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicyCamel))
        let primary = policyRoot ?? c
        let authPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .authPolicyCamel))
        let registerPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .registerPolicyCamel))
        let loginPolicy = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicy))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .loginPolicyCamel))
        let tenantPool = (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPool))
            ?? (try? primary.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPoolCamel))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPool))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .tenantPoolCamel))
        let sources = [primary, c] + [authPolicy, registerPolicy, loginPolicy, tenantPool].compactMap { $0 }
        func firstBool(_ keys: [CodingKeys]) -> Bool? {
            for source in sources {
                for key in keys {
                    if let value = source.decodeLossyBoolIfPresent(forKey: key) { return value }
                }
            }
            return nil
        }
        func firstConfiguredBool(
            _ configuredSources: [KeyedDecodingContainer<CodingKeys>],
            keys: [CodingKeys]
        ) -> Bool? {
            for source in configuredSources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        func firstString(_ keys: [CodingKeys]) -> String? {
            for source in sources {
                for key in keys {
                    do {
                        if let value = try source.decodeIfPresent(String.self, forKey: key) { return value }
                    } catch {
                        continue
                    }
                }
            }
            return nil
        }
        let rootAppID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
        appID = firstString([.appID, .appIDCamel]) ?? rootAppID ?? ""
        platform = firstString([.platform]) ?? ""
        status = firstString([.status]) ?? ""
        allowWorkspaceSwitch = firstBool([.allowWorkspaceSwitch, .allowWorkspaceSwitchCamel]) ?? false
        allowDefaultTenantJoin = firstConfiguredBool(
            sources,
            keys: [.allowDefaultTenantJoin, .allowDefaultTenantJoinCamel]
        ) ?? true
        requireRealName = firstBool([.requireRealName, .requireRealNameCamel])
            ?? false
        requirePhoneVerification = firstBool([.requirePhoneVerification, .requirePhoneVerificationCamel])
            ?? false
        phoneAuthEnabled = firstBool([.phoneAuthEnabled, .phoneAuthEnabledCamel]) ?? true
        registrationEnabled = firstConfiguredBool(sources, keys: [
            .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
        ])
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .enabled)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpen)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpenCamel)
            ?? true
        enterpriseCodeFirst = firstConfiguredBool(sources, keys: [
            .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
        ]) ?? false
        let rawPreferred = try c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCode)
            ?? c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCodeCamel)
            ?? ""
        preferredEnterpriseCode = RemoteAppBootstrap.validPreferredEnterpriseCode(
            rawPreferred,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
        supportContactEmail = firstString([.supportContactEmail, .supportContactEmailCamel]) ?? ""
        supportContactConfigured = firstBool([.supportContactConfigured, .supportContactConfiguredCamel]) ?? false
        let organization = try? c.nestedContainer(keyedBy: OrganizationCodingKeys.self, forKey: .organization)
        departmentEnabled = c.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? organization?.decodeLossyBoolIfPresent(forKey: .departmentEnabled)
            ?? organization?.decodeLossyBoolIfPresent(forKey: .departmentEnabledCamel)
            ?? false
        let debugFeatures = (try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeatures))
            ?? (try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeaturesCamel))
        let accessDiagnosticsOverlayFieldWasPresent = c.contains(.accessDiagnosticsOverlayEnabled)
            || c.contains(.accessDiagnosticsOverlayEnabledCamel)
            || debugFeatures?.contains(.accessDiagnosticsOverlayEnabled) == true
            || debugFeatures?.contains(.accessDiagnosticsOverlayEnabledCamel) == true
        let accessDiagnosticsOverlayValue = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
        accessDiagnosticsOverlayConfiguration = AccessDiagnosticsOverlayConfiguration(
            configuredValue: accessDiagnosticsOverlayValue,
            fieldWasPresent: accessDiagnosticsOverlayFieldWasPresent
        )
        accessDiagnosticsCopyEnabled = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsCopyEnabledCamel)
            ?? false
        cacheTTLSeconds = c.decodeLossyIntIfPresent(forKey: .cacheTTLSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .cacheTTLSecondsCamel)
            ?? c.decodeLossyIntIfPresent(forKey: .cacheTTLSecondsUpperCamel)
            ?? 60
        self.init(
            wireAppID: appID,
            platform: platform,
            status: status,
            allowWorkspaceSwitch: allowWorkspaceSwitch,
            allowDefaultTenantJoin: allowDefaultTenantJoin,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            phoneAuthEnabled: phoneAuthEnabled,
            registrationEnabled: registrationEnabled,
            enterpriseCodeFirst: enterpriseCodeFirst,
            preferredEnterpriseCode: preferredEnterpriseCode,
            supportContactEmail: supportContactEmail,
            supportContactConfigured: supportContactConfigured,
            departmentEnabled: departmentEnabled,
            accessDiagnosticsOverlayConfiguration: accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(platform, forKey: .platform)
        try c.encode(status, forKey: .status)
        try c.encode(allowWorkspaceSwitch, forKey: .allowWorkspaceSwitch)
        try c.encode(allowDefaultTenantJoin, forKey: .allowDefaultTenantJoin)
        try c.encode(requireRealName, forKey: .requireRealName)
        try c.encode(requirePhoneVerification, forKey: .requirePhoneVerification)
        try c.encode(phoneAuthEnabled, forKey: .phoneAuthEnabled)
        try c.encode(registrationEnabled, forKey: .registrationEnabled)
        try c.encode(enterpriseCodeFirst, forKey: .enterpriseCodeFirst)
        if !preferredEnterpriseCode.isEmpty {
            try c.encode(preferredEnterpriseCode, forKey: .preferredEnterpriseCode)
        }
        try c.encode(supportContactEmail, forKey: .supportContactEmail)
        try c.encode(supportContactConfigured, forKey: .supportContactConfigured)
        try c.encode(departmentEnabled, forKey: .departmentEnabled)
        if accessDiagnosticsOverlayConfiguration != .unavailable {
            try c.encode(accessDiagnosticsOverlayEnabled, forKey: .accessDiagnosticsOverlayEnabled)
        }
        try c.encode(accessDiagnosticsCopyEnabled, forKey: .accessDiagnosticsCopyEnabled)
        try c.encode(cacheTTLSeconds, forKey: .cacheTTLSeconds)
    }

    var isUsable: Bool {
        let normalizedStatus = status
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
        return ["active", "enabled", "normal", "available", "usable"].contains(normalizedStatus)
    }

    func settingPhoneAuthEnabled(_ enabled: Bool) -> RemoteAppCurrentPolicy {
        RemoteAppCurrentPolicy(
            appID: appID,
            platform: platform,
            status: status,
            allowWorkspaceSwitch: allowWorkspaceSwitch,
            allowDefaultTenantJoin: allowDefaultTenantJoin,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            phoneAuthEnabled: enabled,
            registrationEnabled: registrationEnabled,
            enterpriseCodeFirst: enterpriseCodeFirst,
            preferredEnterpriseCode: preferredEnterpriseCode,
            supportContactEmail: supportContactEmail,
            supportContactConfigured: supportContactConfigured,
            departmentEnabled: departmentEnabled,
            accessDiagnosticsOverlayConfiguration: accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }

    func settingStartupPolicyHints(from bootstrap: RemoteAppBootstrap) -> RemoteAppCurrentPolicy {
        let sameApp = IMAPIContext.normalizedIOSAppID(bootstrap.appID) == IMAPIContext.normalizedIOSAppID(appID)
        return RemoteAppCurrentPolicy(
            appID: appID,
            platform: platform,
            status: status,
            allowWorkspaceSwitch: allowWorkspaceSwitch,
            allowDefaultTenantJoin: allowDefaultTenantJoin,
            requireRealName: requireRealName,
            requirePhoneVerification: requirePhoneVerification,
            phoneAuthEnabled: phoneAuthEnabled,
            registrationEnabled: bootstrap.registrationEnabled,
            enterpriseCodeFirst: bootstrap.enterpriseCodeFirst,
            preferredEnterpriseCode: sameApp && bootstrap.enterpriseCodeFirst ? bootstrap.preferredEnterpriseCode : "",
            supportContactEmail: supportContactEmail,
            supportContactConfigured: supportContactConfigured,
            departmentEnabled: departmentEnabled,
            accessDiagnosticsOverlayConfiguration: accessDiagnosticsOverlayConfiguration,
            accessDiagnosticsCopyEnabled: accessDiagnosticsCopyEnabled,
            cacheTTLSeconds: cacheTTLSeconds
        )
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
