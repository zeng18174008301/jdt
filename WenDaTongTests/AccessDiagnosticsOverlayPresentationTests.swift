import XCTest
@testable import WenDaTong

import SwiftUI

extension AccessDiagnosticsTests {
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
}
