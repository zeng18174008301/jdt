import XCTest
@testable import BlueStoneIM

final class RegistrationFlowPolicyTests: XCTestCase {
    func testRegistrationRecoverySecretIsRandomAndBoundToOriginalReceipt() throws {
        let first = try XCTUnwrap(RegistrationSessionRecovery.generateSecret())
        let second = try XCTUnwrap(RegistrationSessionRecovery.generateSecret())
        XCTAssertTrue(RegistrationSessionRecovery.isValidSecret(first))
        XCTAssertNotEqual(first, second)
        let receipt = PendingRegistrationReceipt(requestID: UUID().uuidString, appID: "app", deviceID: "device", failureScreen: "account", startedAt: 10)
        let recovery = RegistrationSessionRecovery(requestID: receipt.requestID, appID: "app", deviceID: "device", entryCode: "entry", startedAt: 10, secret: first)
        XCTAssertTrue(recovery.matches(receipt, now: 11))
        XCTAssertFalse(recovery.matches(receipt, now: 610))
        XCTAssertTrue(recovery.matchesScope(receipt), "A committed platform association is distinct from expired proof authority")
        XCTAssertFalse(recovery.matchesScope(PendingRegistrationReceipt(requestID: receipt.requestID,
            appID: "app", deviceID: "device", failureScreen: "account", startedAt: 10, sessionRecoveryCancelled: true)))
        XCTAssertFalse(recovery.matches(receipt, now: 9))
        XCTAssertFalse(recovery.matches(PendingRegistrationReceipt(requestID: receipt.requestID, appID: "app", deviceID: "device", failureScreen: "account", startedAt: 10, sessionRecoveryCancelled: true), now: 11))
        XCTAssertFalse(recovery.matches(PendingRegistrationReceipt(requestID: receipt.requestID, appID: "other", deviceID: "device", failureScreen: "account", startedAt: 10), now: 11))
        XCTAssertFalse(recovery.matches(PendingRegistrationReceipt(requestID: UUID().uuidString, appID: "app", deviceID: "device", failureScreen: "account", startedAt: 10), now: 11))
        let publicReceipt = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(publicReceipt.contains(first))
        XCTAssertFalse(publicReceipt.contains("secret"))
    }

    func testRegistrationConfirmationContractUsesExactCopyAndBoundedBackoff() {
        XCTAssertEqual(
            RegistrationConfirmationPolicy.pendingMessage,
            "正在确认本次注册结果，请稍候。请勿重复提交。"
        )
        XCTAssertEqual(
            RegistrationConfirmationPolicy.timeoutMessage,
            "本次注册确认超时，请重试。如果账号已存在，请直接登录。"
        )
        XCTAssertEqual(
            RegistrationConfirmationPolicy.sleepDelaysSeconds(),
            [2, 4, 8, 16, 32, 60, 60, 60, 58]
        )
        XCTAssertEqual(
            RegistrationConfirmationPolicy.sleepDelaysSeconds().reduce(0, +),
            RegistrationConfirmationPolicy.totalConfirmationSeconds
        )
        XCTAssertLessThanOrEqual(
            RegistrationConfirmationPolicy.sleepDelaysSeconds().max() ?? 0,
            RegistrationConfirmationPolicy.maximumPollDelaySeconds
        )
    }

    func testRegistrationDiagnosticContainsOnlyStateAndElapsedMilliseconds() {
        let key = "jianhuitong.debug.registration.lastSummary"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        recordRegistrationResolutionState(.pending, elapsedSeconds: 1.234)

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            "state=PENDING elapsed_ms=1234"
        )
    }

    func testManualEntryAcceptsUnifiedAndLegacyCodesWithASCIICanonicalization() {
        XCTAssertFalse(RegistrationFlowPolicy.allowsAutomaticEntryCodeAcquisition)
        XCTAssertEqual(
            RegistrationFlowPolicy.normalizedEntryCode(" 710001 "),
            RegistrationEntryCode(normalizedValue: "WXT710001", kind: .enterprise)
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.normalizedEntryCode("wxt710001"),
            RegistrationEntryCode(normalizedValue: "WXT710001", kind: .enterprise)
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.normalizedEntryCode("yqm7k9p2a1b"),
            RegistrationEntryCode(normalizedValue: "YQM7K9P2A1B", kind: .memberInvitation)
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.normalizedEntryCode(" ab001234 "),
            RegistrationEntryCode(normalizedValue: "AB001234", kind: .enterprise)
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.normalizedEntryCode("abcd-i00a001"),
            RegistrationEntryCode(normalizedValue: "ABCD-I00A001", kind: .memberInvitation)
        )
        XCTAssertNil(RegistrationFlowPolicy.normalizedEntryCode(""))
        XCTAssertNil(RegistrationFlowPolicy.normalizedEntryCode("YQMSHORT"))
    }

    func testManualEntryRejectsInternalWhitespaceUnicodeConfusablesAndURLSyntax() {
        for invalid in [
            "AB 001234",
            "AB- I00A001",
            "AB–I00A001",
            "ＡＢ001234",
            "AB001234/path",
            "https://example.test/AB001234",
            "ABCD-I00A001%00",
            "YQM000001",
            "WXT-I00A001",
            "YQM-I00A001"
        ] {
            XCTAssertNil(RegistrationFlowPolicy.normalizedEntryCode(invalid), invalid)
        }
    }

    func testAuthEntryFilterAcceptsASCIIDashWithoutRewritingInvalidAuthorityInput() {
        XCTAssertEqual(AuthInputFilter.entryCode().apply(to: " abcd-i00a001 "), "ABCD-I00A001")
        XCTAssertEqual(AuthInputFilter.entryCode().apply(to: "ab–i00a001"), "AB–I00A001")
        XCTAssertNil(RegistrationFlowPolicy.normalizedEntryCode(AuthInputFilter.entryCode().apply(to: "ab–i00a001")))
    }

    func testTypedEntryAuthorityUsesServerMetadataAndKeepsLegacyCompatibility() {
        XCTAssertEqual(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "member_invite_code",
                scheme: "unified_v1",
                canonical: "AB-I00A001",
                submittedEntryCode: "ab-i00a001"
            ),
            RegistrationEntryAuthority(
                entryType: "member_invite_code",
                scheme: .unifiedV1,
                canonicalCode: "AB-I00A001",
                kind: .memberInvitation
            )
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "enterprise_code",
                scheme: "unified_v1",
                canonical: "AB000002",
                submittedEntryCode: "WXT000042"
            ),
            RegistrationEntryAuthority(
                entryType: "enterprise_code",
                scheme: .unifiedV1,
                canonicalCode: "AB000002",
                kind: .enterprise
            )
        )
        XCTAssertEqual(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "tenant_code",
                scheme: "",
                canonical: "",
                submittedEntryCode: "wxt000001"
            ),
            RegistrationEntryAuthority(
                entryType: "enterprise_code",
                scheme: .legacyWXT,
                canonicalCode: "WXT000001",
                kind: .enterprise
            )
        )
        XCTAssertNil(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "enterprise_code",
                scheme: "unified_v1",
                canonical: "AB-I00A001",
                submittedEntryCode: "AB-I00A001"
            )
        )
        XCTAssertNil(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "member_invite_code",
                scheme: "unified_v1",
                canonical: "YQM-IABC123",
                submittedEntryCode: "YQM-IABC123"
            )
        )
        XCTAssertNil(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "member_invite_code",
                scheme: "legacy_user_id",
                canonical: "YQM7K9P2A1B",
                submittedEntryCode: "YQM7K9P2A1B"
            )
        )
        XCTAssertNil(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "enterprise_code",
                scheme: "unified_v1",
                canonical: "WXT000001",
                submittedEntryCode: "WXT000001"
            )
        )
        XCTAssertNil(
            RegistrationFlowPolicy.entryAuthority(
                entryType: "member_invite_code",
                scheme: "legacy_yqm",
                canonical: "AB-I00A001",
                submittedEntryCode: "AB-I00A001"
            )
        )
    }

    func testEnterpriseFirstRegistrationHidesDuplicateEntryFieldAndRequiresProjection() throws {
        let unresolved = RegistrationFlowPolicy.registrationFormPresentation(
            enterpriseCodeFirst: true,
            resolvedEnterprise: nil,
            otherwiseReadyToSubmit: true
        )
        XCTAssertFalse(unresolved.showsEntryCodeField)
        XCTAssertFalse(unresolved.canSubmit)

        let enterprise = try XCTUnwrap(
            RegistrationFlowPolicy.resolvedEnterprisePresentation(
                tenantID: " tenant-a ",
                submittedEntryCode: "710001",
                name: " Merchant A ",
                logoURL: "/api/tenant/logo/a"
            )
        )
        let resolved = RegistrationFlowPolicy.registrationFormPresentation(
            enterpriseCodeFirst: true,
            resolvedEnterprise: enterprise,
            otherwiseReadyToSubmit: true
        )
        XCTAssertFalse(resolved.showsEntryCodeField)
        XCTAssertTrue(resolved.canSubmit)
        XCTAssertEqual(resolved.resolvedEnterprise?.tenantID, "tenant-a")
        XCTAssertEqual(resolved.resolvedEnterprise?.name, "Merchant A")
        XCTAssertEqual(resolved.resolvedEnterprise?.logoURL, "/api/tenant/logo/a")
    }

    func testResolvedEnterpriseUsesLogoFallbackWithoutInventingTenantIdentity() throws {
        let enterprise = try XCTUnwrap(
            RegistrationFlowPolicy.resolvedEnterprisePresentation(
                tenantID: "tenant-invite",
                submittedEntryCode: "YQM7K9P2A1B",
                name: "Invite Merchant",
                logoURL: "  "
            )
        )
        XCTAssertTrue(enterprise.usesLogoFallback)
        XCTAssertEqual(enterprise.submittedEntryCode.kind, .memberInvitation)
        XCTAssertNil(
            RegistrationFlowPolicy.resolvedEnterprisePresentation(
                tenantID: "tenant-invite",
                submittedEntryCode: "YQM7K9P2A1B",
                name: "",
                logoURL: "/logo"
            )
        )
    }

    func testNonEnterpriseFirstRegistrationKeepsEntryField() {
        let presentation = RegistrationFlowPolicy.registrationFormPresentation(
            enterpriseCodeFirst: false,
            resolvedEnterprise: nil,
            otherwiseReadyToSubmit: true
        )
        XCTAssertTrue(presentation.showsEntryCodeField)
        XCTAssertTrue(presentation.canSubmit)
        XCTAssertNil(presentation.resolvedEnterprise)
    }

    func testCanonicalEntryCodeRateLimitProjectsThirtyMinuteMessageAndRetryBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let presentation = try XCTUnwrap(
            RegistrationFlowPolicy.entryCodeRateLimitPresentation(
                errorCode: "enterprise_context_rate_limited",
                retryAfterSeconds: 1_800,
                retryAvailableAt: now.addingTimeInterval(1_770),
                now: now
            )
        )
        XCTAssertTrue(presentation.isServerAuthoritative)
        XCTAssertTrue(presentation.message.contains("30分钟后再试"))
        XCTAssertTrue(presentation.message.contains("剩余约30分钟"))
        XCTAssertEqual(presentation.retryAfterSeconds, 1_800)
        XCTAssertEqual(presentation.retryAvailableAt, now.addingTimeInterval(1_800))
    }

    func testEntryCodeRateLimitDoesNotCreateLocalAuthorityForUnrelatedErrors() {
        XCTAssertNil(
            RegistrationFlowPolicy.entryCodeRateLimitPresentation(
                errorCode: "enterprise_context_invalid",
                retryAfterSeconds: nil,
                retryAvailableAt: nil
            )
        )
    }

    func testBothRegistrationModesInstallCompleteSessionAndEnter() {
        let evidence = RegistrationSessionEvidence(
            hasPlatformSession: true,
            hasIMSession: true,
            hasTenant: true,
            hasTenantMember: true,
            matchesResolvedEnterprise: true,
            hasPendingWorkspaceApproval: false
        )
        for enterpriseCodeFirst in [false, true] {
            XCTAssertEqual(
                RegistrationFlowPolicy.completionDecision(
                    enterpriseCodeFirst: enterpriseCodeFirst,
                    evidence: evidence
                ),
                .installSessionAndEnter
            )
        }
    }

    func testRegistrationNeverFallsBackToManualLoginWhenSessionIsIncomplete() {
        let decision = RegistrationFlowPolicy.completionDecision(
            enterpriseCodeFirst: true,
            evidence: RegistrationSessionEvidence(
                hasPlatformSession: true,
                hasIMSession: false,
                hasTenant: true,
                hasTenantMember: true,
                matchesResolvedEnterprise: true,
                hasPendingWorkspaceApproval: false
            )
        )
        XCTAssertEqual(
            decision,
            .rejectIncompleteSession(message: RegistrationFlowPolicy.incompleteSessionMessage)
        )
    }

    func testPendingApprovalStaysExplicitWithoutPretendingSessionIsAuthenticated() {
        let decision = RegistrationFlowPolicy.completionDecision(
            enterpriseCodeFirst: false,
            evidence: RegistrationSessionEvidence(
                hasPlatformSession: true,
                hasIMSession: false,
                hasTenant: true,
                hasTenantMember: true,
                matchesResolvedEnterprise: true,
                hasPendingWorkspaceApproval: true
            )
        )
        XCTAssertEqual(
            decision,
            .awaitWorkspaceApproval(message: RegistrationFlowPolicy.pendingWorkspaceApprovalMessage)
        )
    }

    func testSessionInstallAssessmentUsesFixedValueSafeRejectReasons() {
        func assess(
            hasTenantSession: Bool = true,
            tenantIdentityMatches: Bool = true,
            tenantMemberIdentityMatches: Bool = true,
            appIdentityMatches: Bool = true,
            runtimeContractMatches: Bool = true,
            runtimeIdentityMatches: Bool = true,
            runtimeRouteIsSafe: Bool = true,
            platformSessionPersisted: Bool = true,
            tenantSessionPersisted: Bool = true,
            hasCompleteIMSession: Bool = true
        ) -> RegistrationSessionInstallAssessment {
            RegistrationFlowPolicy.sessionInstallAssessment(
                evidence: RegistrationSessionInstallEvidence(
                    hasTenantSession: hasTenantSession,
                    tenantIdentityMatches: tenantIdentityMatches,
                    tenantMemberIdentityMatches: tenantMemberIdentityMatches,
                    appIdentityMatches: appIdentityMatches,
                    runtimeContractMatches: runtimeContractMatches,
                    runtimeIdentityMatches: runtimeIdentityMatches,
                    runtimeRouteIsSafe: runtimeRouteIsSafe,
                    platformSessionPersisted: platformSessionPersisted,
                    tenantSessionPersisted: tenantSessionPersisted,
                    hasCompleteIMSession: hasCompleteIMSession
                )
            )
        }

        XCTAssertEqual(assess(), .accepted)
        XCTAssertEqual(assess(hasTenantSession: false), .rejectMissingTenantSession)
        XCTAssertEqual(assess(tenantIdentityMatches: false), .rejectTenantIdentity)
        XCTAssertEqual(assess(tenantMemberIdentityMatches: false), .rejectTenantMemberIdentity)
        XCTAssertEqual(assess(appIdentityMatches: false), .rejectAppIdentity)
        XCTAssertEqual(assess(runtimeContractMatches: false), .rejectRuntimeContract)
        XCTAssertEqual(assess(runtimeIdentityMatches: false), .rejectRuntimeIdentity)
        XCTAssertEqual(assess(runtimeRouteIsSafe: false), .rejectUnsafeRuntimeRoute)
        XCTAssertEqual(assess(platformSessionPersisted: false), .rejectPlatformSessionPersistence)
        XCTAssertEqual(assess(tenantSessionPersisted: false), .rejectTenantSessionPersistence)
        XCTAssertEqual(assess(hasCompleteIMSession: false), .rejectIncompleteIMSession)
    }
}
