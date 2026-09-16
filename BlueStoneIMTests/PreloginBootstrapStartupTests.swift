import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import BlueStoneIM

@MainActor
final class PreloginBootstrapStartupTests: XCTestCase {
    func testAuthLegalConsentRequiresExplicitOptIn() {
        XCTAssertTrue(AuthLegalConsentPolicy.isAcceptedByDefault)

        var promptCount = 0
        var requestCount = 0
        if AuthLegalConsentPolicy.authorize(isAccepted: false, onRejected: { promptCount += 1 }) {
            requestCount += 1
        }
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(requestCount, 0)

        if AuthLegalConsentPolicy.authorize(isAccepted: true, onRejected: { promptCount += 1 }) {
            requestCount += 1
        }
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(requestCount, 1)
    }

    func testCompactAuthLayoutKeepsRegistrationActionVisibleAndAuxiliaryRowsAligned() {
        let measuredAccountContentHeight: CGFloat = 552
        let accountCardHeight = AuthFlipLayoutPolicy.loginCardHeight(
            phoneAuthEnabled: false,
            availableHeight: 568,
            measuredContentHeight: measuredAccountContentHeight
        )
        XCTAssertEqual(
            accountCardHeight,
            568
        )
        XCTAssertTrue(
            AuthFlipLayoutPolicy.contentFitsWithoutScrolling(
                measuredContentHeight: measuredAccountContentHeight,
                cardHeight: accountCardHeight
            )
        )
        let measuredPhoneContentHeight: CGFloat = 610
        let phoneCardHeight = AuthFlipLayoutPolicy.loginCardHeight(
            phoneAuthEnabled: true,
            availableHeight: 624,
            measuredContentHeight: measuredPhoneContentHeight
        )
        XCTAssertEqual(phoneCardHeight, 624)
        XCTAssertTrue(
            AuthFlipLayoutPolicy.contentFitsWithoutScrolling(
                measuredContentHeight: measuredPhoneContentHeight,
                cardHeight: phoneCardHeight
            )
        )
        XCTAssertEqual(
            AuthFlipLayoutPolicy.loginCardHeight(
                phoneAuthEnabled: false,
                availableHeight: 540,
                measuredContentHeight: 552
            ),
            540,
            "A viewport shorter than the content must remain bounded and scrollable"
        )
        XCTAssertEqual(AuthFlipLayoutPolicy.auxiliaryControlLeadingInset, 0)
        XCTAssertTrue(AuthLegalConsentPolicy.isAcceptedByDefault)
    }

    func testRenderedCompactLoginCardShowsRegistrationActionWithoutScrolling() async throws {
        try await assertRenderedLoginContentFits(phoneAuthEnabled: false, cardHeight: 568)
        try await assertRenderedLoginContentFits(phoneAuthEnabled: true, cardHeight: 624)
    }

    func testFeatureFlagOffPreservesLegacyStartupWithoutResolver() async {
        var factoryCalls = 0
        let gate = PreloginBootstrapStartupGate(
            plan: .disabled,
            resolverFactory: { _ in
                factoryCalls += 1
                return StartupResolverStub(results: [.success(Self.trustedBase)])
            }
        )

        XCTAssertEqual(gate.state, .ready(nil))
        await gate.start()
        XCTAssertEqual(gate.state, .ready(nil))
        XCTAssertEqual(factoryCalls, 0)

        let legacy = IMAPIClient(platformBase: Self.legacyBase)
        XCTAssertEqual(legacy.platformBase, Self.legacyBase)
    }

    private func assertRenderedLoginContentFits(phoneAuthEnabled: Bool, cardHeight: CGFloat) async throws {
        let policy = HTTPTransportResult(
            data: Data("""
            {"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","registration_enabled":true,"phone_auth_enabled":\(phoneAuthEnabled),"enterprise_code_first":false,"allow_default_tenant_join":true,"cache_ttl_seconds":60}}
            """.utf8),
            isHTTPResponse: true,
            statusCode: 200
        )
        let transport = FakeHTTPTransport(results: [policy])
        let baseURL = try XCTUnwrap(URL(string: "https://auth-layout.example.test"))
        let client = IMAPIClient(platformBase: baseURL, httpTransport: transport)
        let context = IMAPIContext(
            platformToken: nil,
            accountID: nil,
            tenantID: nil,
            imUID: nil,
            imToken: nil,
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: "jianhuitong-ios",
            deviceID: "auth-layout-device"
        )
        let state = AppState(api: client, apiContextOverride: context)
        let policyLoaded = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        XCTAssertTrue(policyLoaded)
        XCTAssertTrue(state.isRegistrationEnabledForAuthUI)
        XCTAssertEqual(state.isPhoneAuthEnabledForAuthUI, phoneAuthEnabled)

        let controller = UIHostingController(
            rootView: AuthFlipView(initialRegister: false, initialMode: .account)
                .environmentObject(state)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: cardHeight + 6))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds

        for _ in 0..<5 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        let loginScrollView = try XCTUnwrap(
            allSubviews(of: UIScrollView.self, in: controller.view)
                .filter { $0.bounds.width > 300 && $0.bounds.height > 300 }
                .max(by: { $0.bounds.height < $1.bounds.height })
        )
        XCTAssertLessThanOrEqual(
            loginScrollView.contentSize.height,
            loginScrollView.bounds.height + 1,
            "auth_switch_to_register_button is the final login action and must fit without scrolling"
        )
    }

    private func allSubviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.reduce(into: root is T ? [root as! T] : []) { result, child in
            result.append(contentsOf: allSubviews(of: type, in: child))
        }
    }

    func testEnabledConfigurationRequiresExactlyThreeCompleteHTTPSSourcesAndPublicKeys() {
        let plan = PreloginBootstrapStartupConfiguration.load(
            info: Self.validInfo,
            bundleID: "com.example.wenxintong"
        )

        guard case let .enabled(configuration) = plan else {
            return XCTFail("expected enabled configuration")
        }
        XCTAssertEqual(configuration.seeds.count, 3)
        XCTAssertEqual(configuration.scope.platform, "ios")
        XCTAssertEqual(configuration.scope.bundleID, "com.example.wenxintong")
        XCTAssertEqual(configuration.rootPublicKey.count, 32)
        XCTAssertEqual(configuration.artifactPublicKeys["artifact-v1"]?.count, 32)

        var incomplete = Self.validInfo
        incomplete[PreloginBootstrapInfoKey.sources] = Array(Self.validSources.prefix(2))
        if case .blocked = PreloginBootstrapStartupConfiguration.load(
            info: incomplete,
            bundleID: "com.example.wenxintong"
        ) {
            // Expected fail-closed configuration result.
        } else {
            XCTFail("enabled configuration with two sources must be blocked")
        }

        var wrongApp = Self.validInfo
        wrongApp[PreloginBootstrapInfoKey.appID] = "another-ios-app"
        if case .blocked = PreloginBootstrapStartupConfiguration.load(
            info: wrongApp,
            bundleID: "com.example.wenxintong"
        ) {
            // Expected: a signed config for another AppId cannot become trusted.
        } else {
            XCTFail("cross-app audience must be blocked")
        }
    }

    func testMalformedFeatureFlagCannotSilentlyFallBackToLegacyStartup() {
        var malformed = Self.validInfo
        malformed[PreloginBootstrapInfoKey.enabled] = "enable"

        if case .blocked = PreloginBootstrapStartupConfiguration.load(
            info: malformed,
            bundleID: "com.example.wenxintong"
        ) {
            // Expected: an ambiguous activation value must not disable security.
        } else {
            XCTFail("malformed feature flag must fail closed")
        }
    }

    func testExternalJSONBuildSettingsDecodeThreeSourcesAndArtifactKeys() throws {
        var info = Self.validInfo
        info.removeValue(forKey: PreloginBootstrapInfoKey.sources)
        info.removeValue(forKey: PreloginBootstrapInfoKey.artifactPublicKeys)
        info[PreloginBootstrapInfoKey.sourcesJSON] = try Self.jsonString(Self.validSources)
        info[PreloginBootstrapInfoKey.artifactPublicKeysJSON] = try Self.jsonString([
            "artifact-v1": Data(repeating: 2, count: 32).base64EncodedString()
        ])

        guard case let .enabled(configuration) = PreloginBootstrapStartupConfiguration.load(
            info: info,
            bundleID: "com.example.wenxintong"
        ) else {
            return XCTFail("valid externally injected JSON trust material must load")
        }

        XCTAssertEqual(Set(configuration.seeds.map(\.id)), [
            "primary",
            "cross-account",
            "cross-provider"
        ])
        XCTAssertEqual(configuration.artifactPublicKeys["artifact-v1"]?.count, 32)
    }

    func testMalformedExternalJSONTrustMaterialFailsClosed() {
        var info = Self.validInfo
        info.removeValue(forKey: PreloginBootstrapInfoKey.sources)
        info[PreloginBootstrapInfoKey.sourcesJSON] = #"{"primary":"https://example.test"}"#

        if case .blocked = PreloginBootstrapStartupConfiguration.load(
            info: info,
            bundleID: "com.example.wenxintong"
        ) {
            // Expected: malformed externally injected trust material cannot fall back.
        } else {
            XCTFail("malformed source JSON must fail closed")
        }
    }

    func testEnabledResolutionProducesOnlyTrustedPlatformBase() async {
        let resolver = StartupResolverStub(results: [.success(Self.trustedBase)])
        let gate = PreloginBootstrapStartupGate(
            plan: .enabled(Self.configuration),
            resolverFactory: { _ in resolver }
        )

        await gate.start()

        XCTAssertEqual(gate.state, .ready(Self.trustedBase))
        let callCount = await resolver.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testEnabledResolutionFailureIsFailClosedUntilExplicitRetry() async {
        let resolver = StartupResolverStub(
            results: [
                .failure(PreloginBootstrapError.allSourcesUnavailable),
                .success(Self.trustedBase)
            ]
        )
        let gate = PreloginBootstrapStartupGate(
            plan: .enabled(Self.configuration),
            resolverFactory: { _ in resolver }
        )

        await gate.start()
        XCTAssertEqual(gate.state, .blocked)
        let firstCallCount = await resolver.callCount()
        XCTAssertEqual(firstCallCount, 1)

        gate.retry()
        await waitUntil { gate.state == .ready(Self.trustedBase) }
        let retryCallCount = await resolver.callCount()
        XCTAssertEqual(retryCallCount, 2)
    }

    func testSignedAndOrderedBootstrapAuthorityMatrixNeverFallsBack() async throws {
        let orderedOrigins = [
            try XCTUnwrap(URL(string: "https://ordered-one.example.com")),
            try XCTUnwrap(URL(string: "https://ordered-two.example.net")),
        ]

        var disabledOrderedCalls = 0
        let disabledGate = PreloginBootstrapStartupGate(plan: .disabled)
        await disabledGate.start()
        if case .ready(nil) = disabledGate.state {
            disabledOrderedCalls += 1
        }
        let disabledClient = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            bootstrapBases: orderedOrigins
        )
        XCTAssertEqual(disabledOrderedCalls, 1)
        XCTAssertEqual(disabledClient.configuredAppBootstrapBases, orderedOrigins)

        var enabledOrderedCalls = 0
        let signedSuccess = StartupResolverStub(results: [.success(Self.trustedBase)])
        let enabledGate = PreloginBootstrapStartupGate(
            plan: .enabled(Self.configuration),
            resolverFactory: { _ in signedSuccess }
        )
        await enabledGate.start()
        if case .ready(nil) = enabledGate.state {
            enabledOrderedCalls += 1
        }
        let signedTransport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":false,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let signedClient = IMAPIClient(
            platformBase: Self.trustedBase,
            bootstrapBases: orderedOrigins,
            trustedPreloginPlatformBase: Self.trustedBase,
            httpTransport: signedTransport
        )
        _ = try await signedClient.currentAppPolicy(appID: "jianhuitong-ios")
        XCTAssertEqual(enabledGate.state, .ready(Self.trustedBase))
        XCTAssertEqual(enabledOrderedCalls, 0)
        XCTAssertEqual(signedClient.configuredAppBootstrapBases, [Self.trustedBase])
        let signedRequestHosts = signedTransport.requests().compactMap { $0.url?.host }
        XCTAssertEqual(signedRequestHosts, ["trusted.example.test"])
        XCTAssertTrue(Set(signedRequestHosts).isDisjoint(with: orderedOrigins.compactMap(\.host)))
        let signedSuccessCalls = await signedSuccess.callCount()
        XCTAssertEqual(signedSuccessCalls, 1)

        var failedOrderedCalls = 0
        let signedFailure = StartupResolverStub(
            results: [.failure(PreloginBootstrapError.allSourcesUnavailable)]
        )
        let failedGate = PreloginBootstrapStartupGate(
            plan: .enabled(Self.configuration),
            resolverFactory: { _ in signedFailure }
        )
        await failedGate.start()
        if case .ready(nil) = failedGate.state {
            failedOrderedCalls += 1
        }
        XCTAssertEqual(failedGate.state, .blocked)
        XCTAssertEqual(failedOrderedCalls, 0)
        let signedFailureCalls = await signedFailure.callCount()
        XCTAssertEqual(signedFailureCalls, 1)
    }

    func testConcurrentLifecycleStartsShareOneResolution() async {
        let resolver = StartupResolverStub(
            results: [.success(Self.trustedBase)],
            delayNanoseconds: 100_000_000
        )
        let gate = PreloginBootstrapStartupGate(
            plan: .enabled(Self.configuration),
            resolverFactory: { _ in resolver }
        )

        async let first: Void = gate.start()
        async let second: Void = gate.start()
        async let third: Void = gate.start()
        async let fourth: Void = gate.start()
        async let fifth: Void = gate.start()
        _ = await (first, second, third, fourth, fifth)

        XCTAssertEqual(gate.state, .ready(Self.trustedBase))
        let callCount = await resolver.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testUnsignedBootstrapCannotChangeSignedPlatformOrigin() {
        let sameOriginWithPath = URL(string: "https://trusted.example.test/api")!
        let sameOriginExplicitPort = URL(string: "https://trusted.example.test:443/api")!
        let otherOrigin = URL(string: "https://attacker.example.test")!

        XCTAssertEqual(
            IMAPIClient.trustedPlatformBaseAfterUnsignedBootstrap(
                declaredBase: sameOriginWithPath,
                trustedBase: Self.trustedBase
            ),
            Self.trustedBase
        )
        XCTAssertEqual(
            IMAPIClient.trustedPlatformBaseAfterUnsignedBootstrap(
                declaredBase: sameOriginExplicitPort,
                trustedBase: Self.trustedBase
            ),
            Self.trustedBase
        )
        XCTAssertNil(
            IMAPIClient.trustedPlatformBaseAfterUnsignedBootstrap(
                declaredBase: otherOrigin,
                trustedBase: Self.trustedBase
            )
        )
    }

    func testLegalDocumentPresentationRouterProjectsLoadingSurfaceSynchronously() {
        var router = LegalDocumentPresentationRouter()

        let first = router.present(.terms)
        let duplicate = router.present(.privacy)

        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(router.presentation?.type, .terms)
        XCTAssertEqual(router.presentation?.loadState, .loading)
        XCTAssertEqual(router.presentation?.accessibilityIdentifier, "legal_document_presentation")
    }

    func testLegalDocumentPresentationRouterKeepsFailureVisibleForRetry() {
        var router = LegalDocumentPresentationRouter()
        XCTAssertTrue(router.present(.terms))

        router.finish(content: nil, errorMessage: "协议内容暂不可用")

        XCTAssertEqual(
            router.presentation?.loadState,
            .failed(message: "协议内容暂不可用")
        )
        XCTAssertTrue(router.retry())
        XCTAssertEqual(router.presentation?.loadState, .loading)

        let manifest = try! JSONDecoder().decode(
            RemoteLegalDocManifest.self,
            from: Data(
                #"{"app_id":"jianhuitong-ios","manifest_revision":1,"manifest_hash":"hash-1","updated_at":"2026-09-14T00:00:00Z","docs":[{"doc_type":"terms","version":1,"title":"用户协议","download_url":"/api/app/legal-docs?app_id=jianhuitong-ios&doc_type=terms&version=1&manifest_hash=hash-1"}]}"#.utf8
            )
        )
        let content = LegalDocumentContent(
            type: .terms,
            title: "用户协议",
            html: "<html><body>terms</body></html>",
            sourceURL: URL(string: "https://platform.example.test/api/app/legal-docs?app_id=jianhuitong-ios&doc_type=terms&version=1&manifest_hash=hash-1")!,
            baseURL: URL(string: "https://platform.example.test")!,
            manifest: manifest
        )
        router.finish(content: content, errorMessage: nil)
        XCTAssertEqual(router.presentation?.loadState, .ready(content: content))

        router.dismiss()
        XCTAssertNil(router.presentation)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private static let legacyBase = URL(string: "https://legacy.example.test")!
    private static let trustedBase = URL(string: "https://trusted.example.test")!
    private static let validSources: [[String: Any]] = [
        ["id": "primary", "url": "https://primary-config.example.test/bootstrap/"],
        ["id": "cross-account", "url": "https://backup-config.example.net/bootstrap/"],
        ["id": "cross-provider", "url": "https://provider-config.example.org/bootstrap/"]
    ]
    private static let validInfo: [String: Any] = [
        PreloginBootstrapInfoKey.enabled: true,
        PreloginBootstrapInfoKey.sources: validSources,
        PreloginBootstrapInfoKey.environment: "production",
        PreloginBootstrapInfoKey.productID: "wenxintong",
        PreloginBootstrapInfoKey.appID: "jianhuitong-ios",
        PreloginBootstrapInfoKey.channel: "app-store",
        PreloginBootstrapInfoKey.recoveryRootKeyID: "recovery-root-v1",
        PreloginBootstrapInfoKey.recoveryRootPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
        PreloginBootstrapInfoKey.artifactPublicKeys: [
            "artifact-v1": Data(repeating: 2, count: 32).base64EncodedString()
        ]
    ]
    private static let configuration: PreloginBootstrapConfiguration = {
        guard case let .enabled(configuration) = PreloginBootstrapStartupConfiguration.load(
            info: validInfo,
            bundleID: "com.example.wenxintong"
        ) else {
            fatalError("valid test configuration must parse")
        }
        return configuration
    }()

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }
}

private actor StartupResolverStub: PreloginPlatformBaseResolving {
    private var results: [Result<URL, Error>]
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(results: [Result<URL, Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func resolvePlatformBase() async throws -> URL {
        calls += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !results.isEmpty else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        return try results.removeFirst().get()
    }

    func callCount() -> Int {
        calls
    }
}
