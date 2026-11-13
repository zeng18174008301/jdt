import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteAppCurrentPolicy: Equatable, Sendable {
    public let appID: String

    public let platform: String

    public let status: String

    public let allowWorkspaceSwitch: Bool

    public let allowDefaultTenantJoin: Bool

    public let requireRealName: Bool

    public let requirePhoneVerification: Bool

    public let phoneAuthEnabled: Bool

    public let registrationEnabled: Bool

    public let enterpriseCodeFirst: Bool

    public let preferredEnterpriseCode: String

    public let supportContactEmail: String

    public let supportContactConfigured: Bool

    public let departmentEnabled: Bool

    public let accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration

    public let accessDiagnosticsCopyEnabled: Bool

    public let cacheTTLSeconds: Int

    public init(
        wireAppID appID: String,
        platform: String,
        status: String,
        allowWorkspaceSwitch: Bool,
        allowDefaultTenantJoin: Bool,
        requireRealName: Bool,
        requirePhoneVerification: Bool,
        phoneAuthEnabled: Bool,
        registrationEnabled: Bool,
        enterpriseCodeFirst: Bool,
        preferredEnterpriseCode: String,
        supportContactEmail: String,
        supportContactConfigured: Bool,
        departmentEnabled: Bool,
        accessDiagnosticsOverlayConfiguration: AccessDiagnosticsOverlayConfiguration,
        accessDiagnosticsCopyEnabled: Bool,
        cacheTTLSeconds: Int
    ) {
        self.appID = appID
        self.platform = platform
        self.status = status
        self.allowWorkspaceSwitch = allowWorkspaceSwitch
        self.allowDefaultTenantJoin = allowDefaultTenantJoin
        self.requireRealName = requireRealName
        self.requirePhoneVerification = requirePhoneVerification
        self.phoneAuthEnabled = phoneAuthEnabled
        self.registrationEnabled = registrationEnabled
        self.enterpriseCodeFirst = enterpriseCodeFirst
        self.preferredEnterpriseCode = preferredEnterpriseCode
        self.supportContactEmail = supportContactEmail
        self.supportContactConfigured = supportContactConfigured
        self.departmentEnabled = departmentEnabled
        self.accessDiagnosticsOverlayConfiguration = accessDiagnosticsOverlayConfiguration
        self.accessDiagnosticsCopyEnabled = accessDiagnosticsCopyEnabled
        self.cacheTTLSeconds = cacheTTLSeconds
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END
