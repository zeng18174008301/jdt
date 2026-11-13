import Foundation
import XCTest
@testable import WenDaTong

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

    // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_BEGIN
    func testRegistrationAllowsServerDefinedInviteOnlyWithMatchingAuthority() {
        let code = "Invite_case-sensitive_新码"
        XCTAssertEqual(RegistrationFlowPolicy.submittedEntryCode("  \(code)  "), code)
        XCTAssertEqual(RegistrationFlowPolicy.submittedEntryCode(" 710001 "), "WXT710001")
        XCTAssertEqual(RegistrationFlowPolicy.submittedEntryCode("  "), "")
        XCTAssertEqual(RegistrationFlowPolicy.entryAuthority(
            entryType: "member_invite_code", scheme: "unified_v1", canonical: code,
            submittedEntryCode: code, allowsServerDefinedInvite: true
        )?.canonicalCode, code)
        XCTAssertEqual(RegistrationFlowPolicy.entryAuthority(
            entryType: "member_invite_code", scheme: "unified_v1", canonical: "AB-I00A001",
            submittedEntryCode: code, echoedEntryCode: code, allowsServerDefinedInvite: true
        )?.canonicalCode, "AB-I00A001")
        XCTAssertNil(RegistrationFlowPolicy.entryAuthority(
            entryType: "member_invite_code", scheme: "unified_v1", canonical: "Different_code",
            submittedEntryCode: code, echoedEntryCode: "Other_code", allowsServerDefinedInvite: true
        ))
    }
    // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113_END

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

extension HTTPTransportTests {
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
    func testRegistrationResolutionDebugScreenshotScenariosPreserveExactStateAndCopy() async throws {
        let hostDomain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let hostDefaultsBefore = UserDefaults.standard.persistentDomain(forName: hostDomain)
            .map { NSDictionary(dictionary: $0) }
        let fileManager = FileManager.default
        let support = try XCTUnwrap(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let caches = try XCTUnwrap(fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first)
#if targetEnvironment(simulator)
        let sessionDirectory = support.appendingPathComponent(hostDomain.replacingOccurrences(of: "/", with: "-"),
                                                               isDirectory: true)
        let sessionFiles = ["authenticated-session.simulator.json", "registration-recovery.simulator.json"]
            .map { sessionDirectory.appendingPathComponent($0) }
        // The simulator store's normal read takes a lock and creates a lock file if absent.
        // Read the host files directly so the comparison itself never initializes storage.
        let hostStorageFiles = sessionFiles + sessionFiles.map { $0.appendingPathExtension("lock") }
        func readHostStorage() throws -> [Data?] {
            try hostStorageFiles.map { url in
                do {
                    return try Data(contentsOf: url)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return nil
                }
            }
        }
        let hostStorageBefore = try readHostStorage()
#endif
        let suite = "RegistrationResolutionScreenshot." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = fileManager.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: root))
            XCTAssertFalse(fileManager.fileExists(atPath: root.path))
        }
        let context = AppState.authPolicyScreenshotContext()
        let scope = try LocalMessageScope(context: context)
        let hostPaths = try MessageDatabasePaths(scope: scope, applicationSupportBase: support, cachesBase: caches)
        func cleanupMarker(in paths: MessageDatabasePaths) -> URL {
            paths.localMessageRoot.deletingLastPathComponent()
                .appendingPathComponent("LocalMessagePendingCleanup", isDirectory: true)
                .appendingPathComponent("\(scope.scopeHash).pending")
        }
        let hostMarker = cleanupMarker(in: hostPaths)
        let hostBefore = try registrationScopeReadback(paths: hostPaths, marker: hostMarker)
        let hostGenerationBefore = await IOSMediaCacheStoreRegistry.shared.currentGeneration(for: scope.scopeHash)
        let sessionClearedMarkerKey = "im2.ios.sessionClearedAt"
        let transport = FakeHTTPTransport(results: [])
        var sessionStores: [InMemoryProtectedSessionStore] = []
        var recoveryStores: [InMemoryProtectedSessionStore] = []

        typealias Fixture = (
            state: AppState, persistence: MessagePersistenceCoordinator, registry: IOSMediaCacheStoreRegistry,
            paths: MessageDatabasePaths, releasePurge: AsyncStream<Void>.Continuation
        )
        func makeState(_ scenario: String) throws -> Fixture {
            let scenarioRoot = root.appendingPathComponent(scenario, isDirectory: true)
            let privateSupport = scenarioRoot.appendingPathComponent("support", isDirectory: true)
            let privateCaches = scenarioRoot.appendingPathComponent("caches", isDirectory: true)
            let paths = try MessageDatabasePaths(scope: scope, applicationSupportBase: privateSupport, cachesBase: privateCaches)
            let registry = IOSMediaCacheStoreRegistry()
            let (purgeHold, releasePurge) = AsyncStream<Void>.makeStream()
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: privateSupport, cachesBase: privateCaches, scopeRetirementMediaRegistry: registry,
                scopePurgeBarrier: { for await _ in purgeHold {} }
            )
            let context = makePreloginContext(deviceID: UUID().uuidString)
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!,
                bootstrapBases: [],
                httpTransport: transport,
                runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
                startupContext: context,
                runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
            )
            var receiptData: Data?
            let session = InMemoryProtectedSessionStore()
            let recovery = InMemoryProtectedSessionStore()
            sessionStores.append(session)
            recoveryStores.append(recovery)
            let state = AppState(
                api: api,
                pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(
                    readData: { receiptData }, writeData: { receiptData = $0 }
                ),
                realtimeClient: PostLoginSilentRealtimeTransport(),
                voiceMediaClient: NoopVoiceMediaClient(),
                videoMediaClient: NoopVideoMediaClient(),
                messageStore: SnapshotCache(directoryURL: scenarioRoot.appendingPathComponent("snapshots", isDirectory: true)),
                messagePersistence: persistence,
                biometricDefaults: defaults,
                currentUserIdentityDefaults: defaults,
                rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
                rememberedLoginPreferenceStore: RecordingRememberedLoginPreferenceStore(),
                protectedSessionStore: session,
                registrationSessionStore: recovery,
                apiContextOverride: context
            )
            state.suppressCurrentUserIdentityPersistence = true
            return (state, persistence, registry, paths, releasePurge)
        }

        func verifyRetirement(_ scenario: String, checkState: (AppState) -> Void) async throws {
            let fixture = try makeState(scenario)
            // The fixture installs the screenshot scope, then immediately clears it.
            let generation = fixture.state.localMessageSessionGeneration &+ 1
            let loaded = try await fixture.persistence.activateAndLoad(context: context, sessionGeneration: generation)
            let mediaContext = IOSMediaCacheScopeContext(
                scopeHash: scope.scopeHash, sessionGeneration: generation, rootDirectory: fixture.paths.mediaScopeDirectory
            )
            _ = try await fixture.registry.store(for: mediaContext)
            let mediaSample = fixture.paths.mediaScopeDirectory.appendingPathComponent("registration-fixture")
            try fileManager.createDirectory(at: fixture.paths.mediaScopeDirectory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: mediaSample)
            let privateMarker = cleanupMarker(in: fixture.paths)
            XCTAssertFalse(fileManager.fileExists(atPath: privateMarker.path))

            XCTAssertTrue(fixture.state.configureRegistrationResolutionScreenshotScenarioIfRequested(
                ["--registration-resolution-screenshot=\(scenario)"], fixtureDefaults: defaults
            ))
            let hostAtReturn = Result { try registrationScopeReadback(paths: hostPaths, marker: hostMarker) }
            XCTAssertTrue(fileManager.fileExists(atPath: privateMarker.path))
            XCTAssertTrue(fileManager.fileExists(atPath: fixture.paths.databaseURL.path))
            XCTAssertTrue(fileManager.fileExists(atPath: mediaSample.path))
            XCTAssertEqual(fixture.state.localMessageSessionGeneration, generation &+ 1)
            checkState(fixture.state)
            let hostGenerationAtReturn = await IOSMediaCacheStoreRegistry.shared.currentGeneration(for: scope.scopeHash)

            fixture.releasePurge.finish()
            await fixture.persistence.waitForScheduledScopePurge(scopeHash: scope.scopeHash)

            XCTAssertTrue(try hostAtReturn.get() == hostBefore, "Host scope changed at scenario return")
            XCTAssertEqual(hostGenerationAtReturn, hostGenerationBefore)
            XCTAssertTrue(try registrationScopeReadback(paths: hostPaths, marker: hostMarker) == hostBefore,
                          "Host scope changed after retirement")
            let hostGenerationAfter = await IOSMediaCacheStoreRegistry.shared.currentGeneration(for: scope.scopeHash)
            XCTAssertEqual(hostGenerationAfter, hostGenerationBefore)
            XCTAssertTrue(try registrationScopeReadback(paths: fixture.paths, marker: privateMarker).isEmpty)
            let privateGenerationAfter = await fixture.registry.currentGeneration(for: scope.scopeHash)
            XCTAssertEqual(privateGenerationAfter, generation &+ 1)
            do {
                _ = try await fixture.persistence.repository(for: loaded.ticket)
                XCTFail("The retired message ticket remains active")
            } catch {
                XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
            }
        }

        try await verifyRetirement("pending") { pending in
            XCTAssertEqual(pending.registrationResolutionScreenshotScenario, .pending)
            XCTAssertEqual(pending.registrationResolutionState, .pending)
            XCTAssertFalse(pending.registrationConfirmationTimedOut)
            XCTAssertTrue(pending.isRegistrationSubmissionBlocked)
            XCTAssertEqual(pending.registrationSubmitButtonTitle, "正在确认…")
            XCTAssertEqual(pending.toast, RegistrationConfirmationPolicy.pendingMessage)
            XCTAssertEqual(pending.authScreen, .accountRegister)
            XCTAssertFalse(pending.isAuthenticated)
            XCTAssertNotNil(defaults.persistentDomain(forName: suite)?[sessionClearedMarkerKey])
        }
        defaults.removeObject(forKey: sessionClearedMarkerKey)

        let successFixture = try makeState("success")
        let success = successFixture.state
        XCTAssertTrue(success.configureRegistrationResolutionScreenshotScenarioIfRequested(
            ["--registration-resolution-screenshot=success"], fixtureDefaults: defaults
        ))
        XCTAssertEqual(success.registrationResolutionScreenshotScenario, .success)
        XCTAssertEqual(success.registrationResolutionState, .success)
        XCTAssertEqual(success.toast, "注册成功，已自动登录")
        XCTAssertTrue(success.isAuthenticated)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[sessionClearedMarkerKey])
        XCTAssertEqual(try LocalMessageScope(context: success.apiContext), scope)
        XCTAssertFalse(fileManager.fileExists(atPath: cleanupMarker(in: successFixture.paths).path))
        successFixture.releasePurge.finish()
        await successFixture.persistence.waitForScheduledScopePurge(scopeHash: scope.scopeHash)
        let successGeneration = await successFixture.registry.currentGeneration(for: scope.scopeHash)
        XCTAssertNil(successGeneration)

        try await verifyRetirement("timeout") { timeout in
            XCTAssertEqual(timeout.registrationResolutionScreenshotScenario, .timeout)
            XCTAssertEqual(timeout.registrationResolutionState, .pending)
            XCTAssertTrue(timeout.registrationConfirmationTimedOut)
            XCTAssertFalse(timeout.isRegistrationSubmissionBlocked)
            XCTAssertEqual(timeout.registrationSubmitButtonTitle, "注册并继续")
            XCTAssertEqual(timeout.toast, RegistrationConfirmationPolicy.timeoutMessage)
            XCTAssertEqual(timeout.authScreen, .accountRegister)
            XCTAssertFalse(timeout.isAuthenticated)
            XCTAssertNotNil(defaults.persistentDomain(forName: suite)?[sessionClearedMarkerKey])
        }
        XCTAssertTrue(transport.requests().isEmpty)
        XCTAssertEqual(sessionStores.map { $0.deleteAllCount }, [1, 0, 1])
        XCTAssertTrue(sessionStores.allSatisfy { $0.writeAttemptCount == 0 })
        XCTAssertTrue(recoveryStores.allSatisfy { $0.deleteAllCount == 0 && $0.writeAttemptCount == 0 })
        let hostDefaultsAfter = UserDefaults.standard.persistentDomain(forName: hostDomain)
            .map { NSDictionary(dictionary: $0) }
        XCTAssertTrue(hostDefaultsAfter == hostDefaultsBefore, "The host preferences domain changed")
#if targetEnvironment(simulator)
        let hostStorageAfter = try readHostStorage()
        XCTAssertTrue(hostStorageAfter == hostStorageBefore, "The host session or recovery storage changed")
#endif
    }

    private struct RegistrationScopeEntry: Equatable {
        let type: FileAttributeType?
        let size: UInt64?
        let inode: UInt64?
        let modified: Date?
    }

    private func registrationScopeReadback(
        paths: MessageDatabasePaths, marker: URL
    ) throws -> [URL: RegistrationScopeEntry] {
        let fileManager = FileManager.default
        var entries: [URL: RegistrationScopeEntry] = [:]
        func record(_ url: URL) throws {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return
            }
            let type = attributes[.type] as? FileAttributeType
            entries[url] = RegistrationScopeEntry(
                type: type, size: (attributes[.size] as? NSNumber)?.uint64Value,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                modified: attributes[.modificationDate] as? Date
            )
            if type == .typeDirectory {
                for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try record(child)
                }
            }
        }

        try record(marker)
        for scopeDirectory in [paths.scopeDirectory, paths.legacyScopeDirectory, paths.mediaScopeDirectory] {
            try record(scopeDirectory)
            let parent = scopeDirectory.deletingLastPathComponent()
            let prefix = ".\(scopeDirectory.lastPathComponent).pending-cleanup-"
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: parent.path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            }
            for name in names where name.hasPrefix(prefix) {
                try record(parent.appendingPathComponent(name))
            }
        }
        return entries
    }
    // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END
}
