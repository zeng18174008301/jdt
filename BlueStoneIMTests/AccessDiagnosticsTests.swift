import XCTest
@testable import BlueStoneIM

import SwiftUI

@MainActor
final class AccessDiagnosticsTests: XCTestCase {
    func testTurnAddressDeviceAndEpochChangesInvalidateUnchangedSessionGeneration() {
        for changesDevice in [true, false] {
            let diagnostics = makeDiagnostics()
            let original = AccessDiagnosticsActivationScope(appID: "jianhuitong-ios", accountID: "account-a",
                tenantID: "tenant-a", authPhase: .authenticated, sessionGeneration: 1,
                deviceID: "device-a", sessionEpoch: "epoch-a")
            diagnostics.updateScope(original)
            diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
            diagnostics.recordTurnServers(urls: ["turn:192.0.2.1:3478"], callID: "call-a")
            XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: original), .opened)
            let generation = diagnostics.snapshot.turnAddresses.generation
            let changed = AccessDiagnosticsActivationScope(appID: "jianhuitong-ios", accountID: "account-a",
                tenantID: "tenant-a", authPhase: .authenticated, sessionGeneration: 1,
                deviceID: changesDevice ? "device-b" : "device-a", sessionEpoch: changesDevice ? "epoch-a" : "epoch-b")
            XCTAssertNotEqual(original, changed)
            diagnostics.updateScope(changed)
            XCTAssertFalse(diagnostics.isVisible)
            XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
            XCTAssertNotEqual(generation, diagnostics.snapshot.turnAddresses.generation)
            XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: original), .unchanged)
            XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: changed), .opened)
            XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
            diagnostics.recordTurnServers(urls: ["turn:192.0.2.2:3478"], callID: "call-b")
            XCTAssertEqual(diagnostics.snapshot.turnAddresses.hosts, ["192.0.2.2"])
            diagnostics.forceDisable()
        }
    }

    func testTurnAddressHostsExcludeCredentialsAndDeduplicateTransports() {
        XCTAssertEqual(AccessDiagnosticsTurnAddresses.hosts(from: [
            "turn:TURN.example.test:3478?transport=udp", "turns:turn.example.test:5349?transport=tcp",
            "turn:192.0.2.8:3478", "turn:[2001:db8::8]:3478",
            "stun:stun.example.test:3478", "https://not-turn.example.test",
            "turn:user:secret@private.example.test:3478", "turn:bad.example.test/path",
            "turn:bad.example.test\n", "turn:bad.example.test#secret", "turn:-bad.example.test"
        ]), ["192.0.2.8", "2001:db8::8", "turn.example.test"])
        XCTAssertEqual(AccessDiagnosticsTurnAddresses.hosts(from:
            (0..<20).map { "turn:n\($0).example.test:3478" }).count, 8)
    }

    func testTurnAddressAnswersRequireMatchingGenerationAndLiteralIPs() {
        var state = AccessDiagnosticsTurnAddresses()
        state.begin(hosts: ["turn.example.test"])
        let old = state.generation
        XCTAssertEqual(state.rows.last?.1, "解析中")
        state.apply(["192.0.2.8", "2001:db8::8", "192.0.2.8", "secret", "999.0.0.1"],
                    host: "turn.example.test", generation: old)
        XCTAssertEqual(state.rows.last?.1, "192.0.2.8、2001:db8::8")
        state.begin(hosts: ["turn.example.test"])
        state.apply(["192.0.2.9"], host: "turn.example.test", generation: old)
        XCTAssertEqual(state.rows.last?.1, "解析中", "Old account or call lookup cannot replace a new request")
        state.apply(["192.0.2.9"], host: "other.example.test", generation: state.generation)
        XCTAssertTrue(state.answers.isEmpty)
    }

    func testTurnAddressTimeoutDoesNotReplaceSuccessOrAcceptLateAnswer() {
        var state = AccessDiagnosticsTurnAddresses()
        state.begin(hosts: ["a.example.test", "b.example.test"])
        let generation = state.generation
        state.apply(["192.0.2.1"], host: "a.example.test", generation: generation)
        state.apply([], host: "a.example.test", generation: generation)
        state.apply([], host: "b.example.test", generation: generation)
        state.apply(["192.0.2.2"], host: "b.example.test", generation: generation)
        XCTAssertEqual(state.answers["a.example.test"], ["192.0.2.1"])
        XCTAssertEqual(state.rows.last?.1, "解析失败或超时")
        state.begin(hosts: [])
        state.apply(["192.0.2.1"], host: "a.example.test", generation: generation)
        XCTAssertEqual(state.rows.first?.1, "未获取 TURN 配置")
        XCTAssertTrue(state.answers.isEmpty)
    }

    func testTurnAddressStateClearsOnScopeAndPolicyRevocation() {
        let diagnostics = makeDiagnostics()
        let scope = loggedInScope(tenantID: "tenant-a", sessionGeneration: 1)
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        diagnostics.recordTurnServers(urls: ["turn:192.0.2.1:3478"])
        XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope), .opened)
        XCTAssertEqual(diagnostics.snapshot.turnAddresses.hosts, ["192.0.2.1"])
        diagnostics.applyPolicy(.disabled)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope), .opened)
        XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
        diagnostics.recordTurnServers(urls: ["turn:192.0.2.2:3478"])
        let next = loggedInScope(tenantID: "tenant-b", sessionGeneration: 2)
        diagnostics.updateScope(next)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: next), .opened)
        XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
        diagnostics.recordTurnServers(urls: ["turn:192.0.2.3:3478"], callID: "call-a")
        let oldGeneration = diagnostics.snapshot.turnAddresses.generation
        diagnostics.recordTurnServers(urls: ["turn:192.0.2.3:3478"], callID: "call-b")
        XCTAssertNotEqual(diagnostics.snapshot.turnAddresses.generation, oldGeneration)
        diagnostics.clearTurnServers(callID: "call-a")
        XCTAssertEqual(diagnostics.snapshot.turnAddresses.hosts, ["192.0.2.3"])
        diagnostics.clearTurnServers(callID: "call-b")
        XCTAssertTrue(diagnostics.snapshot.turnAddresses.hosts.isEmpty)
        diagnostics.forceDisable()
    }

    func testFirstErrorOneRecordKeepsFirstFailureRejectsOldGenerationAndClearsScope() {
        let diagnostics = makeDiagnostics()
        let scope = loggedInScope(accountID: "a", tenantID: "t", sessionGeneration: 1)
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        _ = registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope)
        let epoch = diagnostics.connectionScopeEpoch
        let failure = RealtimeConnectionDiagnostic(generation: 9, stage: .server,
            result: .serverRejected, transport: .webSocket, elapsedMS: 22,
            serverCode: .onlineQuotaExceeded, operation: .subscribeChannel, correlation: .matched,
            scopeMatch: .current, handling: .quotaDisconnected)
        diagnostics.recordConnection(failure, scopeEpoch: epoch)
        let ordinary = RealtimeConnectionDiagnostic(generation: 9, stage: .admission,
            result: .alreadyActive, transport: .webSocket, elapsedMS: 0)
        diagnostics.recordConnection(ordinary, scopeEpoch: epoch)
        diagnostics.recordConnection(RealtimeConnectionDiagnostic(generation: 9, stage: .socket,
            result: .failure(.timeout), transport: .webSocket, elapsedMS: 100), scopeEpoch: epoch)
        XCTAssertEqual(diagnostics.snapshot.connectionResult, failure)
        let next = RealtimeConnectionDiagnostic(generation: 10, stage: .start,
            result: .started, transport: .webSocket, elapsedMS: 0)
        diagnostics.recordConnection(next, scopeEpoch: epoch)
        diagnostics.recordConnection(failure, scopeEpoch: epoch)
        XCTAssertEqual(diagnostics.snapshot.connectionResult, next)
        var stale = failure
        stale.currentAtReceipt = false
        diagnostics.recordConnection(stale, scopeEpoch: epoch)
        XCTAssertEqual(diagnostics.snapshot.connectionResult, next)
        diagnostics.updateScope(loggedOutScope())
        diagnostics.recordConnection(failure, scopeEpoch: epoch)
        XCTAssertNil(diagnostics.snapshot.connectionResult)
    }

    func testConnectionDiagnosticSurvivesHiddenOpenCloseAndNewResultWithoutClaimingRouteHit() {
        let diagnostics = makeDiagnostics()
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        let failed = RealtimeConnectionDiagnostic(generation: 7, stage: .socket,
            result: .failure(.tls), transport: .webSocket, elapsedMS: 43)
        diagnostics.recordConnection(failed, scopeEpoch: diagnostics.connectionScopeEpoch)
        XCTAssertNil(diagnostics.snapshot.connectionResult, "Hidden UI stays cleared")
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        XCTAssertEqual(diagnostics.snapshot.connectionResult, failed)
        XCTAssertEqual(diagnostics.snapshot.connectionRows.first?.1, "SOCKET")
        XCTAssertTrue(diagnostics.snapshot.routes.isEmpty, "A result must not manufacture a route hit")
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .closed)
        XCTAssertNil(diagnostics.snapshot.connectionResult)
        let ack = RealtimeConnectionDiagnostic(generation: 8, stage: .auth,
            result: .acknowledged, transport: .webSocket, elapsedMS: 18)
        diagnostics.recordConnection(ack, scopeEpoch: diagnostics.connectionScopeEpoch)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        XCTAssertEqual(diagnostics.snapshot.connectionResult, ack)
        diagnostics.forceDisable()
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        XCTAssertNil(diagnostics.snapshot.connectionResult)
        diagnostics.recordConnection(failed, scopeEpoch: diagnostics.connectionScopeEpoch)
        diagnostics.reset()
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .closed)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        XCTAssertNil(diagnostics.snapshot.connectionResult)
    }

    func testConnectionDiagnosticScopeChangeDoesNotReplayPreviousSessionResult() {
        let diagnostics = makeDiagnostics()
        diagnostics.updateScope(loggedOutScope())
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        diagnostics.recordConnection(RealtimeConnectionDiagnostic(generation: 2, stage: .auth,
            result: .forbidden, transport: .webSocket, elapsedMS: 10), scopeEpoch: diagnostics.connectionScopeEpoch)
        let scope = loggedInScope(tenantID: "tenant-a", sessionGeneration: 1)
        diagnostics.updateScope(scope)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope), .opened)
        XCTAssertNil(diagnostics.snapshot.connectionResult)
        XCTAssertEqual(diagnostics.snapshot.connectionRows.first?.1, "尚无记录")
    }

    func testOverlayCapabilityIsPresentInFormalAndInternalBuilds() {
        XCTAssertTrue(AccessDiagnostics.isOverlayCompiled)
        XCTAssertTrue(AccessDiagnosticsOverlayCapability.isEntryCompiledForCurrentBuild)
        let diagnostics = makeDiagnostics()
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: false, copyEnabled: false))
        XCTAssertFalse(diagnostics.isVisible)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        XCTAssertTrue(diagnostics.isVisible)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    func testBuildBooleansCannotRemoveFormalDiagnosticsCapability() {
        let buildConfigurations = [
            (name: "formal-release", debugBuild: false, internalCapability: false),
            (name: "internal-debug", debugBuild: true, internalCapability: true)
        ]

        for configuration in buildConfigurations {
            XCTAssertEqual(
                AccessDiagnosticsOverlayCapability.isEntryCompiled(
                    debugBuild: configuration.debugBuild,
                    internalCapabilityEnabled: configuration.internalCapability
                ),
                true,
                configuration.name
            )
        }
    }

    func testDisabledPolicyHidesAndClearsSnapshot() {
        guard AccessDiagnostics.isOverlayCompiled else { return }
        let diagnostics = makeDiagnostics()
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: true))
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        diagnostics.record(
            .bootstrapSucceeded(
                appID: "jianhuitong-ios",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: "https://bootstrap-b.example.test",
                source: "live"
            )
        )

        XCTAssertTrue(diagnostics.isVisible)
        XCTAssertFalse(diagnostics.isCopyEnabled)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "bootstrap.example.test")

        diagnostics.applyPolicy(.disabled)

        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertFalse(diagnostics.isCopyEnabled)
        XCTAssertEqual(diagnostics.snapshot, .initial)
    }

    func testMissingCurrentPolicyOverlayFieldRemainsUnavailableInsteadOfFalse() {
        let diagnostics = makeDiagnostics()

        diagnostics.applyPolicy(
            AccessDiagnosticsPolicy(
                appID: "jianhuitong-ios",
                overlayConfiguration: .unavailable,
                copyEnabled: false
            )
        )

        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.currentPolicyOverlayStatus, "配置未获取")

        diagnostics.applyPolicy(
            AccessDiagnosticsPolicy(
                appID: "jianhuitong-ios",
                overlayEnabled: false,
                copyEnabled: false
            )
        )
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.currentPolicyOverlayStatus, "已关闭")
    }

    func testFiveTapsFailClosedForDisabledUnavailableAndAppIDMismatch() {
        let policies = [
            AccessDiagnosticsPolicy(
                appID: "jianhuitong-ios",
                overlayConfiguration: .disabled,
                copyEnabled: false
            ),
            AccessDiagnosticsPolicy(
                appID: "jianhuitong-ios",
                overlayConfiguration: .unavailable,
                copyEnabled: false
            ),
            AccessDiagnosticsPolicy(
                appID: "different-app",
                overlayConfiguration: .enabled,
                copyEnabled: false
            )
        ]

        for policy in policies {
            let diagnostics = makeDiagnostics()
            let scope = loggedOutScope()
            diagnostics.updateScope(scope)
            diagnostics.applyPolicy(policy)

            XCTAssertEqual(
                registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope),
                .unchanged
            )
            XCTAssertFalse(diagnostics.isVisible)
        }
    }

    func testTransientFailureWhileHiddenPreservesAuthorizationAndResetsPartialLogoTaps() {
        let diagnostics = makeDiagnostics()
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(appID: scope.appID, overlayEnabled: true, copyEnabled: false))
        for index in 0..<4 {
            XCTAssertEqual(diagnostics.registerLogoTap(
                entry: .loggedOutLoginLogo,
                scope: scope,
                nowNanoseconds: 1_000_000_000 + UInt64(index) * 100_000_000
            ), .unchanged)
        }

        diagnostics.disablePreservingAllowedPolicy()

        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertFalse(diagnostics.isCopyEnabled)
        XCTAssertEqual(diagnostics.snapshot.currentPolicyOverlayStatus, "已启用")
        for index in 0..<5 {
            XCTAssertEqual(diagnostics.registerLogoTap(
                entry: .loggedOutLoginLogo,
                scope: scope,
                nowNanoseconds: 1_500_000_000 + UInt64(index) * 100_000_000
            ), index == 4 ? .opened : .unchanged)
            XCTAssertEqual(diagnostics.isVisible, index == 4)
        }
        XCTAssertEqual(registerFiveLogoTaps(
            diagnostics,
            entry: .loggedOutLoginLogo,
            scope: scope,
            baseNanoseconds: 2_100_000_000
        ), .closed)
        XCTAssertFalse(diagnostics.isVisible)
    }

    func testTransientFailureDoesNotAuthorizeDisabledUnavailableMismatchedOrForceDisabledPolicy() {
        let scope = loggedOutScope()
        let policies = [
            AccessDiagnosticsPolicy(appID: scope.appID, overlayConfiguration: .disabled, copyEnabled: false),
            AccessDiagnosticsPolicy(appID: scope.appID, overlayConfiguration: .unavailable, copyEnabled: false),
            AccessDiagnosticsPolicy(appID: "different-app", overlayConfiguration: .enabled, copyEnabled: false)
        ]
        for policy in policies {
            let diagnostics = makeDiagnostics()
            diagnostics.updateScope(scope)
            diagnostics.applyPolicy(policy)
            diagnostics.disablePreservingAllowedPolicy()
            XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .unchanged)
            XCTAssertFalse(diagnostics.isVisible)
            XCTAssertEqual(diagnostics.snapshot, .initial)
        }

        let diagnostics = makeDiagnostics()
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(appID: scope.appID, overlayEnabled: true, copyEnabled: false))
        diagnostics.forceDisable()
        diagnostics.disablePreservingAllowedPolicy()
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .unchanged)
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot, .initial)
    }

    func testScopeChangeAfterTransientRecoveryClearsSnapshotAndRequiresFreshManualActivation() {
        let diagnostics = makeDiagnostics()
        let original = loggedOutScope()
        diagnostics.updateScope(original)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(appID: original.appID, overlayEnabled: true, copyEnabled: false))
        diagnostics.disablePreservingAllowedPolicy()
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: original), .opened)
        diagnostics.record(.bootstrapSucceeded(
            appID: original.appID,
            bootstrapHost: "https://old-scope.example.test",
            fallbackHost: nil,
            source: "test"
        ))
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "old-scope.example.test")

        let next = loggedInScope(tenantID: "tenant-b", sessionGeneration: 2)
        diagnostics.updateScope(next)
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "未获取")
        diagnostics.disablePreservingAllowedPolicy()
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: original), .unchanged)
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: next), .opened)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "未获取")

        let differentApp = loggedOutScope(appID: "different-app")
        diagnostics.updateScope(differentApp)
        diagnostics.disablePreservingAllowedPolicy()
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: differentApp), .unchanged)
        XCTAssertFalse(diagnostics.isVisible)
    }

    func testRecordIsIgnoredUntilPolicyEnablesOverlay() {
        guard AccessDiagnostics.isOverlayCompiled else { return }
        let diagnostics = makeDiagnostics()
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        diagnostics.record(
            .bootstrapSucceeded(
                appID: "jianhuitong-ios",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: nil,
                source: "live"
            )
        )

        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot, .initial)

        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        diagnostics.record(
            .bootstrapSucceeded(
                appID: "jianhuitong-ios",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: nil,
                source: "live"
            )
        )
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "未获取")
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: scope), .opened)
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        diagnostics.record(
            .bootstrapSucceeded(
                appID: "jianhuitong-ios",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: nil,
                source: "live"
            )
        )

        XCTAssertTrue(diagnostics.isVisible)
        XCTAssertFalse(diagnostics.isCopyEnabled)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "bootstrap.example.test")
        XCTAssertEqual(diagnostics.snapshot.appIDSummary, IMAPIContext.canonicalIOSAppID)
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func testManualActivationIsClearedWhenScopeChanges() {
        guard AccessDiagnostics.isOverlayCompiled else { return }
        let diagnostics = makeDiagnostics()
        let loggedOut = loggedOutScope()
        diagnostics.updateScope(loggedOut)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedOutLoginLogo, scope: loggedOut), .opened)
        diagnostics.record(
            .bootstrapSucceeded(
                appID: "jianhuitong-ios",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: nil,
                source: "live"
            )
        )
        XCTAssertTrue(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "bootstrap.example.test")

        diagnostics.updateScope(loggedInScope(tenantID: "tenant-a", sessionGeneration: 1))

        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertFalse(diagnostics.isCopyEnabled)
        XCTAssertEqual(diagnostics.snapshot.bootstrapHost, "未获取")
        XCTAssertEqual(diagnostics.snapshot.currentPolicyOverlayStatus, "已启用")
    }

    func testPartialTapSequenceResetsAcrossAccountTenantSessionAndPageChanges() {
        let original = loggedInScope(
            accountID: "account-a",
            tenantID: "tenant-a",
            sessionGeneration: 7
        )
        let changedScopes = [
            loggedInScope(accountID: "account-b", tenantID: "tenant-a", sessionGeneration: 7),
            loggedInScope(accountID: "account-a", tenantID: "tenant-b", sessionGeneration: 7),
            loggedInScope(accountID: "account-a", tenantID: "tenant-a", sessionGeneration: 8)
        ]

        for changedScope in changedScopes {
            let diagnostics = makeDiagnostics()
            diagnostics.updateScope(original)
            diagnostics.applyPolicy(
                AccessDiagnosticsPolicy(
                    appID: "jianhuitong-ios",
                    overlayConfiguration: .enabled,
                    copyEnabled: false
                )
            )
            for index in 0..<4 {
                XCTAssertEqual(
                    diagnostics.registerLogoTap(
                        entry: .loggedInAboutLogo,
                        scope: original,
                        nowNanoseconds: 1_000_000_000 + UInt64(index) * 120_000_000
                    ),
                    .unchanged
                )
            }
            diagnostics.updateScope(changedScope)
            XCTAssertEqual(
                diagnostics.registerLogoTap(
                    entry: .loggedInAboutLogo,
                    scope: changedScope,
                    nowNanoseconds: 1_500_000_000
                ),
                .unchanged
            )
            XCTAssertFalse(diagnostics.isVisible)
        }

        let pageDiagnostics = makeDiagnostics()
        pageDiagnostics.updateScope(original)
        pageDiagnostics.applyPolicy(
            AccessDiagnosticsPolicy(
                appID: "jianhuitong-ios",
                overlayConfiguration: .enabled,
                copyEnabled: false
            )
        )
        for index in 0..<4 {
            _ = pageDiagnostics.registerLogoTap(
                entry: .loggedInAboutLogo,
                scope: original,
                nowNanoseconds: 2_000_000_000 + UInt64(index) * 120_000_000
            )
        }
        pageDiagnostics.resetLogoTapSequence(entry: .loggedInAboutLogo)
        XCTAssertEqual(
            pageDiagnostics.registerLogoTap(
                entry: .loggedInAboutLogo,
                scope: original,
                nowNanoseconds: 2_500_000_000
            ),
            .unchanged
        )
        XCTAssertFalse(pageDiagnostics.isVisible)
    }

    func testEntryMismatchAndExpiredTapWindowDoNotToggleOverlay() {
        let diagnostics = makeDiagnostics()
        let scope = loggedOutScope()
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))

        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope), .unchanged)
        XCTAssertFalse(diagnostics.isVisible)

        for index in 0..<4 {
            XCTAssertEqual(
                diagnostics.registerLogoTap(
                    entry: .loggedOutLoginLogo,
                    scope: scope,
                    nowNanoseconds: UInt64(index) * 200_000_000
                ),
                .unchanged
            )
        }
        XCTAssertEqual(
            diagnostics.registerLogoTap(
                entry: .loggedOutLoginLogo,
                scope: scope,
                nowNanoseconds: 3_500_000_000
            ),
            .unchanged
        )
        XCTAssertFalse(diagnostics.isVisible)
    }

    func testFiveTapOnVisibleOverlayClosesAndClearsSnapshot() {
        guard AccessDiagnostics.isOverlayCompiled else { return }
        let diagnostics = makeDiagnostics()
        let scope = loggedInScope(tenantID: "tenant-a", sessionGeneration: 8)
        diagnostics.updateScope(scope)
        diagnostics.applyPolicy(AccessDiagnosticsPolicy(overlayEnabled: true, copyEnabled: false))
        XCTAssertEqual(registerFiveLogoTaps(diagnostics, entry: .loggedInAboutLogo, scope: scope), .opened)
        diagnostics.record(
            .merchantEntered(name: "企业 A", tenantAPIHost: "https://tenant.example.test/private?token=secret")
        )
        XCTAssertEqual(diagnostics.snapshot.merchantName, "企业 A")

        XCTAssertEqual(
            registerFiveLogoTaps(
                diagnostics,
                entry: .loggedInAboutLogo,
                scope: scope,
                baseNanoseconds: 10_000_000_000
            ),
            .closed
        )
        XCTAssertFalse(diagnostics.isVisible)
        XCTAssertEqual(diagnostics.snapshot.merchantName, "未进入")
        XCTAssertEqual(diagnostics.snapshot.currentPolicyOverlayStatus, "已启用")
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    func testOverlayPanelDirectionAdaptsToCapsulePositionAndStaysInBounds() {
        let containerSize = CGSize(width: 390, height: 844)
        let safeAreaInsets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let capsuleSize = CGSize(width: 128, height: 32)
        let panelSize = CGSize(width: 252, height: 320)

        let topLayout = AccessDebugOverlayPanelLayout(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            capsulePosition: CGPoint(x: 315, y: 72),
            capsuleSize: capsuleSize,
            panelSize: panelSize
        )
        XCTAssertEqual(topLayout.expansionDirection, .down)
        XCTAssertGreaterThanOrEqual(topLayout.panelFrame.minY + 0.001, topLayout.topLimit)
        XCTAssertLessThanOrEqual(topLayout.panelFrame.maxY, topLayout.bottomLimit + 0.001)

        let bottomLayout = AccessDebugOverlayPanelLayout(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            capsulePosition: CGPoint(x: 315, y: 700),
            capsuleSize: capsuleSize,
            panelSize: panelSize
        )
        XCTAssertEqual(bottomLayout.expansionDirection, .up)
        XCTAssertGreaterThanOrEqual(bottomLayout.panelFrame.minY + 0.001, bottomLayout.topLimit)
        XCTAssertLessThanOrEqual(bottomLayout.panelFrame.maxY, bottomLayout.bottomLimit + 0.001)
    }

    func testOverlayDragBoundsReserveBottomNavigationArea() {
        let bounds = AccessDebugOverlayDragBounds(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0),
            overlaySize: CGSize(width: 128, height: 32)
        )
        let clamped = bounds.clamp(CGPoint(x: 1000, y: 1000))
        let expectedMaxY = 844 - max(34 + AccessDebugOverlayDragBounds.bottomNavigationReserve, 72) - AccessDebugOverlayDragBounds.bottomMargin - 16

        XCTAssertEqual(clamped.y, expectedMaxY, accuracy: 0.001)
    }

    func testDomainRoutesUseSameFiveSectionsAndSafeHostOnlyLabels() throws {
        var snapshot = AccessDiagnosticsSnapshot.initial
        snapshot = AccessDiagnosticsReducer.reduce(
            snapshot,
            event: .bootstrapRoute(
                primaryHost: "https://bootstrap.wdatongcf.com/api/app/bootstrap?token=secret",
                fallbackHost: nil,
                currentHost: "https://bootstrap.wdatongcf.com/private?object_key=secret",
                // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
                tier: .preferred,
                source: "live"
                // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            )
        )
        let services = Dictionary(uniqueKeysWithValues: IMRuntimeRouteService.allCases.map { service in
            (service.rawValue, IMRuntimeRouteEndpointSet(
                preferred: ["https://\(service.rawValue)-primary.example.test/private?token=secret"],
                backups: ["https://\(service.rawValue)-backup.example.test/private?token=secret"]
            ))
        })
        let runtime = IMRuntimeRouteSnapshot(
            contractVersion: 2,
            appID: IMAPIContext.canonicalIOSAppID,
            tenantID: "tenant-a",
            revision: 1,
            source: "live",
            status: "ready",
            configHash: String(repeating: "a", count: 64),
            services: services,
            policy: IMRuntimeRoutePolicy()
        )
        snapshot = AccessDiagnosticsReducer.reduce(snapshot, event: .runtimeRoutes(runtime))
        XCTAssertEqual(snapshot.domainRoute(for: .platformAPI).current, "等待首次请求")
        XCTAssertEqual(snapshot.domainRoute(for: .platformAPI).tier, "未命中")
        snapshot = AccessDiagnosticsReducer.reduce(
            snapshot,
            event: .routeHit(
                service: .tenantAPI,
                endpoint: "https://tenant_api-backup.example.test/path?token=secret",
                tier: .backup
            )
        )

        XCTAssertEqual(snapshot.bootstrapDomainRoute.current, "bootstrap.wdatongcf.com")
        XCTAssertEqual(snapshot.bootstrapDomainRoute.backupLabel, "未配置")
        XCTAssertEqual(snapshot.domainRoute(for: .tenantAPI).current, "tenant-api-backup.example.test")
        XCTAssertEqual(snapshot.domainRoute(for: .tenantAPI).tier, "备用域")
        XCTAssertEqual(snapshot.domainRoute(for: .tenantAPI).primary, "tenant-api-primary.example.test")
        XCTAssertEqual(
            snapshot.domainSections.map(\.title),
            ["Bootstrap", "platform_api", "tenant_api", "im_api", "im_realtime"]
        )
        // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
        XCTAssertEqual(
            snapshot.domainSections[0].rows.map { $0.0 },
            ["当前命中", "当前层级", "候选 1", "其余候选"]
        )
        snapshot.domainSections.dropFirst().forEach { section in
            XCTAssertEqual(section.rows.map { $0.0 }, ["当前命中", "当前层级", "主域名", "备用域名"])
        }
        // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
        XCTAssertFalse(snapshot.redactedSummary.contains("token"))
        XCTAssertFalse(snapshot.redactedSummary.contains("/private"))
        XCTAssertEqual(
            ["platform_api", "tenant_api", "im_api", "im_realtime"],
            IMRuntimeRouteService.allCases.map(\.rawValue)
        )
    }

    func testExpandedOverlayShowsExactAppIDAndRuntimeBundleIdentifierWithoutSensitiveIdentityFields() {
        let snapshot = AccessDiagnosticsReducer.reduce(
            .initial,
            event: .bootstrapSucceeded(
                appID: "provider-or-server-decoy",
                bootstrapHost: "https://bootstrap.example.test",
                fallbackHost: nil,
                source: "live"
            )
        )

        let identity = AppBuildIdentity(info: [
            AppBuildIdentity.sourceCommitInfoKey: "4c2f643982d43a2341746184af99244b452f62e8",
            AppBuildIdentity.buildIdentityInfoKey: "internal-validation-20260826-4c2f643982d4"
        ])
        let rows = snapshot.clientIdentityRows(buildIdentity: identity)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].0, "AppId")
        XCTAssertEqual(rows[0].1, IMAPIContext.canonicalIOSAppID)
        XCTAssertEqual(rows[1].0, "pkgname")
        XCTAssertEqual(rows[1].1, Bundle.main.bundleIdentifier ?? "未配置")
        XCTAssertEqual(rows[2].0, "source commit")
        XCTAssertEqual(rows[2].1, "4c2f643982d43a2341746184af99244b452f62e8")
        XCTAssertEqual(rows[3].0, "build identity")
        XCTAssertEqual(rows[3].1, "internal-validation-20260826-4c2f643982d4")
        XCTAssertEqual(rows[4].0, "current-policy overlay")
        XCTAssertEqual(rows[4].1, "配置未获取")

        let forbiddenLabels = ["tenant", "account", "identity", "token", "host", "route", "password", "secret"]
        let normalizedLabels = rows.map { $0.0.lowercased() }
        XCTAssertFalse(normalizedLabels.contains { label in
            forbiddenLabels.filter { $0 != "identity" }.contains { label.contains($0) }
        })
    }

    func testBuildIdentityRejectsMissingOrUnsafeBundleValues() {
        let missing = AppBuildIdentity(info: [:])
        XCTAssertEqual(missing.sourceCommit, "配置未获取")
        XCTAssertEqual(missing.buildIdentity, "配置未获取")

        let unsafe = AppBuildIdentity(info: [
            AppBuildIdentity.sourceCommitInfoKey: "not-a-commit",
            AppBuildIdentity.buildIdentityInfoKey: "internal validation\nsecret"
        ])
        XCTAssertEqual(unsafe.sourceCommit, "配置未获取")
        XCTAssertEqual(unsafe.buildIdentity, "配置未获取")
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func testFormalAndInternalArchivesRequireTheSameDiagnosticsCapability() throws {
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let testFile = URL(fileURLWithPath: #filePath)
        let iosRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: iosRoot.appendingPathComponent("scripts/archive-internal-validation.sh"),
            encoding: .utf8
        )
        let plist = try String(
            contentsOf: iosRoot.appendingPathComponent("BlueStoneIM/Info.plist"),
            encoding: .utf8
        )
        let diagnosticsSource = try String(
            contentsOf: iosRoot.appendingPathComponent("BlueStoneIM/AccessDiagnostics.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: iosRoot.appendingPathComponent("BlueStoneIM/BlueStoneIMApp.swift"),
            encoding: .utf8
        )

        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertTrue(script.contains("-DACCESS_DIAGNOSTICS_OVERLAY_ENABLED"))
        XCTAssertTrue(script.contains("-c 'Set :WXTAccessDiagnosticsOverlayCompiled YES'"))
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        XCTAssertTrue(script.contains("SCHEME=\"BlueStoneIM-InternalValidation\""))
        XCTAssertTrue(script.contains("CONFIGURATION=\"Release\""))
        XCTAssertTrue(script.contains("WXT_FORMAL_BUILD=NO"))
        XCTAssertTrue(script.contains("WXT_SOURCE_COMMIT=\"$SOURCE_COMMIT\""))
        XCTAssertTrue(script.contains("WXT_BUILD_IDENTITY=\"$BUILD_IDENTITY\""))
        XCTAssertTrue(script.contains("SOURCE_COMMIT must resolve to the current tracked HEAD"))
        XCTAssertTrue(script.contains("diff --cached --quiet"))
        XCTAssertTrue(script.contains("Print :WXTSourceCommit"))
        XCTAssertTrue(plist.contains("<key>WXTSourceCommit</key>"))
        XCTAssertTrue(plist.contains("<key>WXTBuildIdentity</key>"))
        XCTAssertTrue(plist.contains("<key>WXTAccessDiagnosticsOverlayCompiled</key>"))
        XCTAssertFalse(diagnosticsSource.contains("#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED"))
        XCTAssertFalse(appSource.contains("#if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED"))

        let project = try String(
            contentsOf: iosRoot.appendingPathComponent("BlueStoneIM.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let app2Archive = try String(
            contentsOf: iosRoot.appendingPathComponent("scripts/archive-app2-release.sh"),
            encoding: .utf8
        )
        let app2Verifier = try String(
            contentsOf: iosRoot.appendingPathComponent("scripts/verify-app2-archive.sh"),
            encoding: .utf8
        )
        let app1Verifier = try String(
            contentsOf: iosRoot.appendingPathComponent("scripts/verify_app1_archive.py"),
            encoding: .utf8
        )
        let internalScheme = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BlueStoneIM.xcodeproj/xcshareddata/xcschemes/BlueStoneIM-InternalValidation.xcscheme"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("WXT_ACCESS_DIAGNOSTICS_OVERLAY_COMPILED = YES;"))
        XCTAssertFalse(app2Archive.contains("-DACCESS_DIAGNOSTICS_OVERLAY_ENABLED"))
        XCTAssertFalse(app2Archive.contains("WXT_ACCESS_DIAGNOSTICS_OVERLAY_COMPILED=YES"))
        XCTAssertTrue(internalScheme.contains("--mode internal-validation"))
        XCTAssertFalse(internalScheme.contains("--mode formal"))
        XCTAssertTrue(app1Verifier.contains("archive is missing diagnostics capability metadata"))
        XCTAssertTrue(app1Verifier.contains("archive is missing the diagnostics capability marker"))
        XCTAssertTrue(app2Verifier.contains("formal archive is missing diagnostics capability metadata"))
        XCTAssertTrue(app2Verifier.contains("formal archive is missing the diagnostics capability marker"))
    }

    func testEndpointLabelKeepsOnlyHostAndNonDefaultPort() {
        XCTAssertEqual(
            AccessDiagnosticsReducer.endpointLabel("https://api.example.test/private?token=secret#fragment"),
            "api.example.test"
        )
        XCTAssertEqual(
            AccessDiagnosticsReducer.endpointLabel("wss://im.example.test:9443/im/ws?credential=secret"),
            "im.example.test:9443"
        )
        XCTAssertEqual(
            AccessDiagnosticsReducer.endpointLabel("https://user:password@api.example.test/private"),
            "未配置"
        )
    }

    func testOverlayDragBoundsKeepCapsuleBelowTopNavigationControls() {
        let bounds = AccessDebugOverlayDragBounds(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            overlaySize: CGSize(width: 128, height: 32)
        )

        let clamped = bounds.clamp(CGPoint(x: 315, y: -100))
        let capsuleFrame = CGRect(
            x: clamped.x - 64,
            y: clamped.y - 16,
            width: 128,
            height: 32
        )

        XCTAssertGreaterThanOrEqual(
            capsuleFrame.minY,
            59 + AccessDebugOverlayDragBounds.topNavigationControlReserve
        )
    }

    func testOverlayAutoParkReturnsToTopSafeTrailingPosition() {
        let bounds = AccessDebugOverlayDragBounds(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            overlaySize: CGSize(width: 128, height: 32)
        )

        let parked = AccessDebugOverlayAutoPark.parkedPosition(bounds: bounds)

        XCTAssertEqual(parked.x, 390 - AccessDebugOverlayDragBounds.horizontalMargin - 64, accuracy: 0.001)
        XCTAssertEqual(
            parked.y,
            59 + AccessDebugOverlayDragBounds.topNavigationControlReserve + 16,
            accuracy: 0.001
        )
        XCTAssertEqual(parked, bounds.defaultPosition)
    }

    func testExpandedOverlayPanelCannotEnterTopNavigationControlRegion() {
        let safeAreaInsets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let layout = AccessDebugOverlayPanelLayout(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: safeAreaInsets,
            capsulePosition: CGPoint(x: 315, y: 600),
            capsuleSize: CGSize(width: 128, height: 32),
            panelSize: CGSize(width: 252, height: 520)
        )

        XCTAssertGreaterThanOrEqual(
            layout.panelFrame.minY,
            safeAreaInsets.top + AccessDebugOverlayDragBounds.topNavigationControlReserve
        )
    }

    func testOverlayDragReleaseAddsBoundedInertia() {
        let bounds = AccessDebugOverlayDragBounds(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0),
            overlaySize: CGSize(width: 128, height: 32)
        )
        let resting = CGPoint(x: 200, y: 160)
        let settled = AccessDebugOverlayDragRelease.settledPosition(
            restingPosition: resting,
            translation: CGSize(width: 60, height: 40),
            predictedEndTranslation: CGSize(width: 260, height: 220),
            bounds: bounds
        )

        XCTAssertGreaterThan(settled.x, resting.x + 60)
        XCTAssertGreaterThan(settled.y, resting.y + 40)
        XCTAssertLessThanOrEqual(settled.x, resting.x + 60 + AccessDebugOverlayDragRelease.maxInertiaDistance + 0.001)
        XCTAssertLessThanOrEqual(settled.y, resting.y + 40 + AccessDebugOverlayDragRelease.maxInertiaDistance + 0.001)

        let edgeSettled = AccessDebugOverlayDragRelease.settledPosition(
            restingPosition: resting,
            translation: CGSize(width: 1000, height: 1000),
            predictedEndTranslation: CGSize(width: 1400, height: 1400),
            bounds: bounds
        )
        let clampedEdge = bounds.clamp(edgeSettled)
        XCTAssertEqual(edgeSettled.x, clampedEdge.x, accuracy: 0.001)
        XCTAssertEqual(edgeSettled.y, clampedEdge.y, accuracy: 0.001)
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private func loggedOutScope(appID: String = "jianhuitong-ios") -> AccessDiagnosticsActivationScope {
        AccessDiagnosticsActivationScope(appID: appID, authPhase: .loggedOut)
    }

    private func loggedInScope(
        appID: String = "jianhuitong-ios",
        accountID: String = "account-a",
        tenantID: String,
        sessionGeneration: Int64
    ) -> AccessDiagnosticsActivationScope {
        AccessDiagnosticsActivationScope(
            appID: appID,
            accountID: accountID,
            tenantID: tenantID,
            authPhase: .authenticated,
            sessionGeneration: sessionGeneration
        )
    }

    private func registerFiveLogoTaps(
        _ diagnostics: AccessDiagnostics,
        entry: AccessDiagnosticsActivationEntry,
        scope: AccessDiagnosticsActivationScope,
        baseNanoseconds: UInt64 = 1_000_000_000
    ) -> AccessDiagnosticsVisibilityTransition {
        var transition = AccessDiagnosticsVisibilityTransition.unchanged
        for index in 0..<5 {
            transition = diagnostics.registerLogoTap(
                entry: entry,
                scope: scope,
                nowNanoseconds: baseNanoseconds + UInt64(index) * 120_000_000
            )
        }
        return transition
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    private func makeDiagnostics() -> AccessDiagnostics { AccessDiagnostics() }
}
