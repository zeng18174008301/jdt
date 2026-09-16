import Foundation
import Security

enum RegistrationEntryCodeKind: Equatable {
    case enterprise
    case memberInvitation
}

enum RegistrationEntryCodeScheme: String, Equatable {
    case unifiedV1 = "unified_v1"
    case legacyWXT = "legacy_wxt"
    case legacyYQM = "legacy_yqm"
    case legacyUserID = "legacy_user_id"
}

struct RegistrationEntryCode: Equatable {
    let normalizedValue: String
    let kind: RegistrationEntryCodeKind
}

struct RegistrationEntryAuthority: Equatable {
    let entryType: String
    let scheme: RegistrationEntryCodeScheme
    let canonicalCode: String
    let kind: RegistrationEntryCodeKind
}

struct RegistrationResolvedEnterprisePresentation: Equatable {
    let tenantID: String
    let submittedEntryCode: RegistrationEntryCode
    let name: String
    let logoURL: String?

    var usesLogoFallback: Bool {
        logoURL == nil
    }
}

struct RegistrationFormPresentation: Equatable {
    let showsEntryCodeField: Bool
    let resolvedEnterprise: RegistrationResolvedEnterprisePresentation?
    let canSubmit: Bool
}

struct RegistrationEntryCodeRateLimitPresentation: Equatable {
    let message: String
    let retryAfterSeconds: Int?
    let retryAvailableAt: Date?

    var isServerAuthoritative: Bool { true }
}

struct RegistrationSessionEvidence: Equatable {
    let hasPlatformSession: Bool
    let hasIMSession: Bool
    let hasTenant: Bool
    let hasTenantMember: Bool
    let matchesResolvedEnterprise: Bool
    let hasPendingWorkspaceApproval: Bool
}

enum RegistrationCompletionDecision: Equatable {
    case installSessionAndEnter
    case awaitWorkspaceApproval(message: String)
    case rejectIncompleteSession(message: String)
}

enum RegistrationResolutionState: String, Codable, Equatable {
    case success = "SUCCESS"
    case pending = "PENDING"
    case failed = "FAILED"
}

// Kept only in the existing protected credential backend, never the public receipt.
struct RegistrationSessionRecovery: Codable, Equatable {
    static let storageKey = "registration-session-recovery.v1"
    let requestID: String
    let appID: String
    let deviceID: String
    let entryCode: String
    let startedAt: TimeInterval
    let secret: String
    var tenantID: String?
    var platformSessionID: String?

    static func generateSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func matchesScope(_ receipt: PendingRegistrationReceipt) -> Bool {
        receipt.hasBoundScope && !receipt.sessionRecoveryCancelled
            && requestID == receipt.requestID && appID == receipt.appID && deviceID == receipt.deviceID
            && startedAt == receipt.startedAt
    }

    func matches(_ receipt: PendingRegistrationReceipt, now: TimeInterval) -> Bool {
        matchesScope(receipt) && now >= startedAt
            && now - startedAt < RegistrationConfirmationPolicy.publicConfirmationSeconds
            && Self.isValidSecret(secret)
    }

    static func isValidSecret(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct PendingRegistrationReceipt: Codable, Equatable {
    let schemaVersion: Int
    let requestID: String
    let appID: String?
    let deviceID: String?
    let failureScreen: String
    let startedAt: TimeInterval
    let resolutionState: RegistrationResolutionState?
    let sessionRecoveryCancelled: Bool

    init(
        requestID: String,
        appID: String,
        deviceID: String,
        failureScreen: String,
        startedAt: TimeInterval,
        resolutionState: RegistrationResolutionState? = .pending,
        sessionRecoveryCancelled: Bool = false
    ) {
        schemaVersion = 2
        self.requestID = requestID
        self.appID = appID
        self.deviceID = deviceID
        self.failureScreen = failureScreen
        self.startedAt = startedAt
        self.resolutionState = resolutionState
        self.sessionRecoveryCancelled = sessionRecoveryCancelled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestID
        case appID
        case deviceID
        case failureScreen
        case startedAt
        case resolutionState
        case sessionRecoveryCancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        requestID = try container.decode(String.self, forKey: .requestID)
        appID = try container.decodeIfPresent(String.self, forKey: .appID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        failureScreen = try container.decode(String.self, forKey: .failureScreen)
        startedAt = try container.decode(TimeInterval.self, forKey: .startedAt)
        resolutionState = try container.decodeIfPresent(RegistrationResolutionState.self, forKey: .resolutionState)
        sessionRecoveryCancelled = try container.decodeIfPresent(Bool.self, forKey: .sessionRecoveryCancelled) ?? false
    }

    var hasBoundScope: Bool {
        schemaVersion == 2
            && appID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && deviceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var authScreen: AuthScreen {
        failureScreen == "phone" ? .phoneRegister : .accountRegister
    }
}

struct PendingRegistrationReceiptStore {
    static let storageKey = "jianhuitong.registration.pendingReceipt.v1"

    private let readData: () -> Data?
    private let writeData: (Data?) -> Void

    init(defaults: UserDefaults) {
        readData = { defaults.data(forKey: Self.storageKey) }
        writeData = { data in
            if let data {
                defaults.set(data, forKey: Self.storageKey)
            } else {
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
    }

    init(
        readData: @escaping () -> Data?,
        writeData: @escaping (Data?) -> Void
    ) {
        self.readData = readData
        self.writeData = writeData
    }

    func load() -> PendingRegistrationReceipt? {
        guard let data = readData(),
              let receipt = try? JSONDecoder().decode(PendingRegistrationReceipt.self, from: data),
              !receipt.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              receipt.failureScreen == "phone" || receipt.failureScreen == "account" else {
            return nil
        }
        return receipt
    }

    func save(_ receipt: PendingRegistrationReceipt) -> Bool {
        guard receipt.hasBoundScope else { return false }
        guard let data = try? JSONEncoder().encode(receipt) else { return false }
        writeData(data)
        return load() == receipt
    }

    @discardableResult
    func clear() -> Bool {
        writeData(nil)
        return readData() == nil
    }
}

struct RegistrationConfirmationPolicy {
    // The public registration-status contract is side-effect free and accepts
    // the original request identity; an ordinary login request is not confirmation.
    static let pendingMessage = "正在确认本次注册结果，请稍候。请勿重复提交。"
    static let timeoutMessage = "本次注册确认超时，请重试。如果账号已存在，请直接登录。"
    static let firstPollDelaySeconds: TimeInterval = 2
    static let maximumPollDelaySeconds: TimeInterval = 60
    static let totalConfirmationSeconds: TimeInterval = 5 * 60
    // Public registration-status contract; never extend it by replacing startedAt.
    static let publicConfirmationSeconds: TimeInterval = 10 * 60

    static func sleepDelaysSeconds() -> [TimeInterval] {
        var elapsed: TimeInterval = 0
        var delay = firstPollDelaySeconds
        var result: [TimeInterval] = []
        while elapsed < totalConfirmationSeconds {
            let bounded = min(delay, maximumPollDelaySeconds, totalConfirmationSeconds - elapsed)
            result.append(bounded)
            elapsed += bounded
            delay = min(delay * 2, maximumPollDelaySeconds)
        }
        return result
    }
}

struct RegistrationOutcomeUncertainError: Error, Equatable {}

#if DEBUG
// Observation only: never use these diagnostics as registration resolution states.
// No associated strings or request metadata can enter the public log message.
enum RegistrationDiagnosticState: String, CaseIterable {
    case submitResponseAccepted = "SUBMIT_RESPONSE_ACCEPTED"
    case submitHTTPRejected = "SUBMIT_HTTP_REJECTED"
    case submitServiceUnavailable = "SUBMIT_SERVICE_UNAVAILABLE"
    case submitTransportFailed = "SUBMIT_TRANSPORT_FAILED"
    case submitContractFailed = "SUBMIT_CONTRACT_FAILED"
    case submitCancelled = "SUBMIT_CANCELLED"
    case statusPending = "STATUS_PENDING"
    case statusSuccess = "STATUS_SUCCESS"
    case statusFailed = "STATUS_FAILED"
    case statusNotFound = "STATUS_NOT_FOUND"
    case statusHTTPRejected = "STATUS_HTTP_REJECTED"
    case statusServiceUnavailable = "STATUS_SERVICE_UNAVAILABLE"
    case statusTransportFailed = "STATUS_TRANSPORT_FAILED"
    case statusContractFailed = "STATUS_CONTRACT_FAILED"
    case statusCancelled = "STATUS_CANCELLED"
    case confirmationCancelled = "CONFIRMATION_CANCELLED"
    case confirmationExpired = "CONFIRMATION_EXPIRED"

    func safeSummary(elapsedSeconds: TimeInterval) -> String {
        // Diagnostic timing must not trap or affect business logic, even if a
        // clock returns an invalid value. This is not a new confirmation budget.
        let bounded = elapsedSeconds.isFinite ? min(max(0, elapsedSeconds), 86_400) : 0
        return "diagnostic=\(rawValue) elapsed_ms=\(Int((bounded * 1_000).rounded()))"
    }

    static func transportFailure(isSubmission: Bool, error: Error) -> Self {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        if cancelled { return isSubmission ? .submitCancelled : .statusCancelled }
        return isSubmission ? .submitTransportFailed : .statusTransportFailed
    }

    static func httpResponse(
        isSubmission: Bool,
        statusCode: Int,
        acceptedPayload: Bool = false,
        confirmationStatus: RemoteRegistrationStatus? = nil
    ) -> Self {
        if (500..<600).contains(statusCode) {
            return isSubmission ? .submitServiceUnavailable : .statusServiceUnavailable
        }
        if !isSubmission, statusCode == 404 { return .statusNotFound }
        if (400..<500).contains(statusCode) {
            return isSubmission ? .submitHTTPRejected : .statusHTTPRejected
        }
        if acceptedPayload, isSubmission, (200..<300).contains(statusCode) {
            // An accepted POST payload is not proof of completed registration.
            return .submitResponseAccepted
        }
        if acceptedPayload, !isSubmission, statusCode == 200 {
            switch confirmationStatus {
            case .pending: return .statusPending
            case .success: return .statusSuccess
            case .failed: return .statusFailed
            case nil: break
            }
        }
        return isSubmission ? .submitContractFailed : .statusContractFailed
    }
}
#endif

struct RegistrationSessionInstallEvidence: Equatable {
    let hasTenantSession: Bool
    let tenantIdentityMatches: Bool
    let tenantMemberIdentityMatches: Bool
    let appIdentityMatches: Bool
    let runtimeContractMatches: Bool
    let runtimeIdentityMatches: Bool
    let runtimeRouteIsSafe: Bool
    let platformSessionPersisted: Bool
    let tenantSessionPersisted: Bool
    let hasCompleteIMSession: Bool
}

enum RegistrationSessionInstallAssessment: Equatable {
    case accepted
    case rejectMissingTenantSession
    case rejectTenantIdentity
    case rejectTenantMemberIdentity
    case rejectAppIdentity
    case rejectRuntimeContract
    case rejectRuntimeIdentity
    case rejectUnsafeRuntimeRoute
    case rejectPlatformSessionPersistence
    case rejectTenantSessionPersistence
    case rejectIncompleteIMSession
}

enum RegistrationFlowPolicy {
    static let entryCodePrompt = "请输入企业编码或邀请码"
    static let entryCodeRateLimitMessage = "企业编码或邀请码验证次数过多，请30分钟后再试"
    static let incompleteSessionMessage = "注册成功响应未包含完整登录会话，请重试"
    static let pendingWorkspaceApprovalMessage = "注册成功，入企申请已提交。审核通过后即可进入。"

    // Enterprise-code-first must never silently acquire or resolve a preferred code.
    static let allowsAutomaticEntryCodeAcquisition = false

    static func normalizedEntryCode(_ rawValue: String) -> RegistrationEntryCode? {
        guard let compact = normalizedASCIIEntryCodeInput(rawValue) else { return nil }

        if compact.count == 6, compact.allSatisfy(\.isNumber) {
            return RegistrationEntryCode(normalizedValue: "WXT\(compact)", kind: .enterprise)
        }
        if compact.range(of: "^WXT[0-9]{6}$", options: .regularExpression) != nil {
            return RegistrationEntryCode(normalizedValue: compact, kind: .enterprise)
        }
        if compact.range(of: "^[A-Z]{2,4}[0-9]{6}$", options: .regularExpression) != nil {
            let prefix = String(compact.prefix { $0.isLetter })
            guard prefix != "WXT" && prefix != "YQM" else { return nil }
            return RegistrationEntryCode(normalizedValue: compact, kind: .enterprise)
        }
        if compact.count == 11,
           compact.hasPrefix("YQM"),
           compact.dropFirst(3).count == 8,
           compact.dropFirst(3).allSatisfy(\.isASCIIAlphaNumeric) {
            return RegistrationEntryCode(normalizedValue: compact, kind: .memberInvitation)
        }
        if compact.range(of: "^[A-Z]{2,4}-I[A-Z0-9]{6}$", options: .regularExpression) != nil {
            let prefix = String(compact.prefix { $0.isLetter })
            guard prefix != "WXT" && prefix != "YQM" else { return nil }
            return RegistrationEntryCode(normalizedValue: compact, kind: .memberInvitation)
        }
        return nil
    }

    static func entryAuthority(
        entryType rawEntryType: String,
        scheme rawScheme: String,
        canonical rawCanonical: String,
        submittedEntryCode: String
    ) -> RegistrationEntryAuthority? {
        guard let submitted = normalizedEntryCode(submittedEntryCode) else { return nil }

        let rawType = rawEntryType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isUntypedLegacyResponse = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rawCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let kind: RegistrationEntryCodeKind
        let entryType: String
        switch rawType {
        case "enterprise_code":
            kind = .enterprise
            entryType = "enterprise_code"
        case "tenant_code" where isUntypedLegacyResponse:
            // Compatibility for pre-typed enterprise-context responses.
            kind = .enterprise
            entryType = "enterprise_code"
        case "member_invite_code":
            kind = .memberInvitation
            entryType = "member_invite_code"
        default:
            return nil
        }

        let scheme: RegistrationEntryCodeScheme
        let normalizedScheme = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedScheme.isEmpty, isUntypedLegacyResponse {
            scheme = kind == .enterprise ? .legacyWXT : .legacyYQM
        } else if let decodedScheme = RegistrationEntryCodeScheme(rawValue: normalizedScheme),
                  decodedScheme != .legacyUserID {
            scheme = decodedScheme
        } else {
            return nil
        }

        let canonical: RegistrationEntryCode
        if rawCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isUntypedLegacyResponse {
            canonical = submitted
        } else if let decodedCanonical = normalizedEntryCode(rawCanonical) {
            canonical = decodedCanonical
        } else {
            return nil
        }
        guard canonical.kind == kind,
              submitted.kind == kind,
              schemeMatchesCanonicalCode(scheme, canonical: canonical) else {
            return nil
        }
        return RegistrationEntryAuthority(
            entryType: entryType,
            scheme: scheme,
            canonicalCode: canonical.normalizedValue,
            kind: kind
        )
    }

    private static func normalizedASCIIEntryCodeInput(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var output = String.UnicodeScalarView()
        output.reserveCapacity(trimmed.unicodeScalars.count)
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 45:
                output.append(scalar)
            case 97...122:
                guard let uppercased = UnicodeScalar(scalar.value - 32) else { return nil }
                output.append(uppercased)
            default:
                // Internal whitespace, Unicode confusables, alternate dashes and URL syntax
                // must not be silently rewritten into a valid authority-bearing code.
                return nil
            }
        }
        return String(output)
    }

    private static func schemeMatchesCanonicalCode(
        _ scheme: RegistrationEntryCodeScheme,
        canonical: RegistrationEntryCode
    ) -> Bool {
        switch scheme {
        case .unifiedV1:
            switch canonical.kind {
            case .enterprise:
                guard canonical.normalizedValue.range(
                    of: "^[A-Z]{2,4}[0-9]{6}$",
                    options: .regularExpression
                ) != nil else { return false }
                let prefix = String(canonical.normalizedValue.prefix { $0.isLetter })
                return prefix != "WXT" && prefix != "YQM"
            case .memberInvitation:
                guard canonical.normalizedValue.range(
                    of: "^[A-Z]{2,4}-I[A-Z0-9]{6}$",
                    options: .regularExpression
                ) != nil else { return false }
                let prefix = String(canonical.normalizedValue.prefix { $0.isLetter })
                return prefix != "WXT" && prefix != "YQM"
            }
        case .legacyWXT:
            return canonical.kind == .enterprise
                && canonical.normalizedValue.range(
                    of: "^WXT[0-9]{6}$",
                    options: .regularExpression
                ) != nil
        case .legacyYQM:
            return canonical.kind == .memberInvitation
                && canonical.normalizedValue.range(
                    of: "^YQM[A-Z0-9]{8}$",
                    options: .regularExpression
                ) != nil
        case .legacyUserID:
            return false
        }
    }

    static func resolvedEnterprisePresentation(
        tenantID: String,
        submittedEntryCode: String,
        name: String,
        logoURL: String
    ) -> RegistrationResolvedEnterprisePresentation? {
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTenantID.isEmpty,
              !normalizedName.isEmpty,
              let normalizedEntryCode = normalizedEntryCode(submittedEntryCode) else {
            return nil
        }
        let normalizedLogoURL = logoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return RegistrationResolvedEnterprisePresentation(
            tenantID: normalizedTenantID,
            submittedEntryCode: normalizedEntryCode,
            name: normalizedName,
            logoURL: normalizedLogoURL.isEmpty ? nil : normalizedLogoURL
        )
    }

    static func registrationFormPresentation(
        enterpriseCodeFirst: Bool,
        resolvedEnterprise: RegistrationResolvedEnterprisePresentation?,
        otherwiseReadyToSubmit: Bool
    ) -> RegistrationFormPresentation {
        RegistrationFormPresentation(
            showsEntryCodeField: !enterpriseCodeFirst,
            resolvedEnterprise: enterpriseCodeFirst ? resolvedEnterprise : nil,
            canSubmit: otherwiseReadyToSubmit && (!enterpriseCodeFirst || resolvedEnterprise != nil)
        )
    }

    static func entryCodeRateLimitPresentation(
        errorCode: String,
        retryAfterSeconds: Int?,
        retryAvailableAt: Date?,
        now: Date = Date()
    ) -> RegistrationEntryCodeRateLimitPresentation? {
        let normalizedCode = errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [
            "enterprise_context_rate_limited",
            "registration_tenant_code_probe_rate_limited",
            "rate_limited"
        ].contains(normalizedCode) else {
            return nil
        }

        let headerRemaining = retryAfterSeconds.map { max(0, $0) }
        let boundaryRemaining = retryAvailableAt.map { max(0, Int(ceil($0.timeIntervalSince(now)))) }
        let remainingSeconds = [headerRemaining, boundaryRemaining].compactMap { $0 }.max()
        let effectiveBoundary = remainingSeconds.map { now.addingTimeInterval(TimeInterval($0)) }

        let detail: String
        if let remainingSeconds, remainingSeconds > 0 {
            let remainingMinutes = Int(ceil(Double(remainingSeconds) / 60.0))
            detail = "（剩余约\(remainingMinutes)分钟）"
        } else {
            detail = ""
        }
        return RegistrationEntryCodeRateLimitPresentation(
            message: entryCodeRateLimitMessage + detail,
            retryAfterSeconds: remainingSeconds,
            retryAvailableAt: effectiveBoundary
        )
    }

    static func completionDecision(
        enterpriseCodeFirst _: Bool,
        evidence: RegistrationSessionEvidence
    ) -> RegistrationCompletionDecision {
        if evidence.hasPendingWorkspaceApproval {
            return .awaitWorkspaceApproval(message: pendingWorkspaceApprovalMessage)
        }
        guard evidence.hasPlatformSession,
              evidence.hasIMSession,
              evidence.hasTenant,
              evidence.hasTenantMember,
              evidence.matchesResolvedEnterprise else {
            return .rejectIncompleteSession(message: incompleteSessionMessage)
        }
        return .installSessionAndEnter
    }

    static func sessionInstallAssessment(
        evidence: RegistrationSessionInstallEvidence
    ) -> RegistrationSessionInstallAssessment {
        guard evidence.hasTenantSession else { return .rejectMissingTenantSession }
        guard evidence.tenantIdentityMatches else { return .rejectTenantIdentity }
        guard evidence.tenantMemberIdentityMatches else { return .rejectTenantMemberIdentity }
        guard evidence.appIdentityMatches else { return .rejectAppIdentity }
        guard evidence.runtimeContractMatches else { return .rejectRuntimeContract }
        guard evidence.runtimeIdentityMatches else { return .rejectRuntimeIdentity }
        guard evidence.runtimeRouteIsSafe else { return .rejectUnsafeRuntimeRoute }
        guard evidence.platformSessionPersisted else { return .rejectPlatformSessionPersistence }
        guard evidence.tenantSessionPersisted else { return .rejectTenantSessionPersistence }
        guard evidence.hasCompleteIMSession else { return .rejectIncompleteIMSession }
        return .accepted
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        }
    }
}
