import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

extension DomainStoreTests {
    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
    func testBootstrapPresentationSeparatesLaunchAndInitialLoadingFromPagination() {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        let store = state.bootstrapPresentationStore
        var launches: [BootstrapPresentationStore.Launch] = []
        var initialLoading: [Bool] = []
        var pagination: [Bool] = []
        var globalUpdates = 0
        let observations = [
            store.$launch.sink { launches.append($0) },
            store.syncUpdates(\.isInitialLoading).sink { initialLoading.append($0) },
            store.syncUpdates(\.isLoadingMoreConversations).sink { pagination.append($0) },
            state.objectWillChange.sink { globalUpdates += 1 }
        ]
        withExtendedLifetime(observations) {
            store.launch.isRestoringSession = true
            store.sync.isInitialDataLoading = true
            store.sync.isLoadingMoreConversations = true
            store.sync.hasLoadedRemoteSnapshot = true
            store.sync.isLoadingMoreConversations = false
            store.launch.isRestoringSession = false
        }

        XCTAssertEqual(launches.map(\.isRestoringSession), [false, true, false])
        XCTAssertEqual(initialLoading, [false, true, false])
        XCTAssertEqual(pagination, [false, true, false])
        XCTAssertEqual(globalUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END

    func testSplashTenantScopeSeparatesAppAccountTenantAndNormalizedAPIOrigin() {
        let base = SplashTenantScope(
            appID: " app-main ",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "HTTPS://TENANT-A.EXAMPLE.TEST/api/tenant/"
        )
        let normalized = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test:443/api/tenant"
        )

        XCTAssertTrue(base.isValid)
        XCTAssertEqual(base, normalized)
        XCTAssertEqual(base.tenantOrigin, "https://tenant-a.example.test:443/api/tenant")
        XCTAssertEqual(base.storageKey, normalized.storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-secondary",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-2",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-2",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test:8443/api/tenant"
        ).storageKey)
        XCTAssertNotEqual(base.storageKey, SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant-a.example.test/api/other"
        ).storageKey)
    }

    func testColdLaunchSplashCanReplaceLaunchOrRestoreButNeverCoverInteractiveUI() {
        XCTAssertTrue(canPresentColdLaunchSplash(
            hasMainShellBecomeInteractive: false
        ))
        XCTAssertFalse(canPresentColdLaunchSplash(
            hasMainShellBecomeInteractive: true
        ))
    }

    func testSplashSkipPolicyHonorsMinimumShowDuration() {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertFalse(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 1_200,
            now: startedAt.addingTimeInterval(1.199)
        ))
        XCTAssertTrue(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 1_200,
            now: startedAt.addingTimeInterval(1.2)
        ))
        XCTAssertTrue(canSkipSplash(
            startedAt: startedAt.timeIntervalSince1970,
            minShowMS: 0,
            now: startedAt
        ))
    }

    // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
    func testSplashCountdownUpdatesOnlyOverlayAndRejectsOldPresentation() {
        let state = AppState()
        let store = state.splashOverlayStore
        let config = testSplashSnapshot(tenantID: "tenant-splash", assetID: "cover", version: "1")
        let prepared = SplashPreparedImage(
            fileURL: URL(fileURLWithPath: "/tmp/test-splash-cover.png"),
            image: testSplashImage(), mimeType: "image/png",
            sizeBytes: 1, width: 1, height: 1, sha256Hex: ""
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let first = SplashOverlayPresentation(snapshot: config, preparedImage: prepared, startedAt: now)
        var visibility: [Bool] = []
        var countdown: [Int] = []
        var rootChanges = 0
        let shown = store.updates { $0.presentation != nil }.sink { visibility.append($0) }
        let timer = store.updates(\.remainingSeconds).sink { countdown.append($0) }
        let root = state.objectWillChange.sink { rootChanges += 1 }
        defer {
            shown.cancel()
            timer.cancel()
            root.cancel()
        }

        store.present(first, at: now)
        XCTAssertFalse(store.snapshot.canSkip)
        XCTAssertTrue(store.updateCountdown(for: first.id, remainingSeconds: 3, canSkip: false))
        XCTAssertTrue(store.updateCountdown(for: first.id, remainingSeconds: 2, canSkip: true))
        XCTAssertTrue(store.snapshot.canSkip)
        XCTAssertEqual(countdown, [0, 3, 2])
        XCTAssertEqual(visibility, [false, true])

        store.clear()
        let nextDate = now.addingTimeInterval(1)
        let next = SplashOverlayPresentation(snapshot: config, preparedImage: prepared, startedAt: nextDate)
        store.present(next, at: nextDate)
        XCTAssertFalse(store.updateCountdown(for: first.id, remainingSeconds: 1, canSkip: true))
        XCTAssertEqual(store.snapshot.presentation?.id, next.id)
        XCTAssertFalse(store.snapshot.canSkip)
        XCTAssertEqual(countdown, [0, 3, 2, 0, 3])
        XCTAssertEqual(visibility, [false, true, false, true])
        XCTAssertEqual(rootChanges, 0)
    }
    // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END

    func testSplashRefreshCandidateRejectsLateTenantAndVersionResponses() throws {
        let suiteName = "BlueStoneIMTests.splash.candidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "asset-a",
            version: "a-1"
        )
        let snapshotB1 = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-1"
        )
        let candidateA = try XCTUnwrap(SplashRefreshCandidate(
            generation: 1,
            scope: scopeA,
            snapshot: snapshotA
        ))
        XCTAssertNil(SplashRefreshCandidate(
            generation: 0,
            scope: scopeA,
            snapshot: snapshotA
        ))
        let candidateB1 = try XCTUnwrap(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: snapshotB1
        ))
        SplashSnapshotStore.saveSnapshot(snapshotB1, scope: scopeB, defaults: defaults)

        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertTrue(candidateB1.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))

        let disabledB = snapshotB1.disabled(reason: "config_disabled")
        SplashSnapshotStore.saveSnapshot(disabledB, scope: scopeB, defaults: defaults)
        XCTAssertFalse(disabledB.isConfigDisplayable)
        XCTAssertNil(SplashRefreshCandidate(
            generation: 3,
            scope: scopeB,
            snapshot: disabledB
        ))

        let snapshotB2 = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-2"
        )
        SplashSnapshotStore.saveSnapshot(snapshotB2, scope: scopeB, defaults: defaults)
        XCTAssertFalse(candidateB1.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertFalse(SplashSnapshotStore.updatePrefetchStatus(
            candidate: candidateB1,
            status: .downloaded,
            defaults: defaults
        ))
        XCTAssertEqual(
            SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)?.normalizedVersion,
            "b-2"
        )
    }

    func testScopedSplashSnapshotAndImageCacheNeverCrossTenants() throws {
        let suiteName = "BlueStoneIMTests.splash.scoped.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.scoped.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "shared-asset",
            version: "1",
            cacheKeyOverride: "shared-asset:1"
        )
        let snapshotB = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "shared-asset",
            version: "1",
            cacheKeyOverride: "shared-asset:1"
        )
        SplashSnapshotStore.saveSnapshot(snapshotA, scope: scopeA, defaults: defaults)
        SplashSnapshotStore.saveSnapshot(snapshotB, scope: scopeB, defaults: defaults)

        let cacheKeyA = try XCTUnwrap(snapshotA.cacheKey(scope: scopeA))
        let cacheKeyB = try XCTUnwrap(snapshotB.cacheKey(scope: scopeB))
        XCTAssertNotEqual(cacheKeyA, cacheKeyB)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyA))
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(scope: scopeA, cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scopeB, cache: cache, defaults: defaults))

        SplashSnapshotStore.disableSnapshot(scope: scopeB, reason: "config_disabled", defaults: defaults)
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(scope: scopeA, cache: cache, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scopeB, cache: cache, defaults: defaults))
    }

    func testSplashTenantSwitchOnlyPresentsCurrentConfirmedTenant() throws {
        let suiteName = "BlueStoneIMTests.splash.tenant-switch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.tenant-switch.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let scopeA = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-a",
            tenantOrigin: "https://tenant-a.example.test/api/tenant"
        )
        let scopeB = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-b",
            tenantOrigin: "https://tenant-b.example.test/api/tenant"
        )
        let snapshotA = testSplashSnapshot(
            tenantID: "tenant-a",
            assetID: "asset-a",
            version: "a-1"
        )
        let snapshotB = testSplashSnapshot(
            tenantID: "tenant-b",
            assetID: "asset-b",
            version: "b-1"
        )
        SplashSnapshotStore.saveSnapshot(snapshotA, scope: scopeA, defaults: defaults)
        let cacheKeyA = try XCTUnwrap(snapshotA.cacheKey(scope: scopeA))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyA))
        let candidateA = try XCTUnwrap(SplashRefreshCandidate(
            generation: 1,
            scope: scopeA,
            snapshot: snapshotA
        ))
        XCTAssertEqual(
            SplashSnapshotStore.displayableSnapshot(
                scope: scopeA,
                cache: cache,
                defaults: defaults
            )?.tenantID,
            "tenant-a"
        )

        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(
            scope: scopeB,
            cache: cache,
            defaults: defaults
        ))

        let disabledB = snapshotB.disabled(reason: "splash_config_disabled")
        SplashSnapshotStore.saveSnapshot(disabledB, scope: scopeB, defaults: defaults)
        XCTAssertNil(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: disabledB
        ))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(
            scope: scopeB,
            cache: cache,
            defaults: defaults
        ))

        SplashSnapshotStore.saveSnapshot(snapshotB, scope: scopeB, defaults: defaults)
        let cacheKeyB = try XCTUnwrap(snapshotB.cacheKey(scope: scopeB))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKeyB))
        let candidateB = try XCTUnwrap(SplashRefreshCandidate(
            generation: 2,
            scope: scopeB,
            snapshot: snapshotB
        ))
        XCTAssertTrue(candidateB.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertFalse(candidateA.matches(
            currentGeneration: 2,
            currentScope: scopeB,
            snapshot: SplashSnapshotStore.snapshot(scope: scopeB, defaults: defaults)
        ))
        XCTAssertEqual(
            SplashSnapshotStore.displayableSnapshot(
                scope: scopeB,
                cache: cache,
                defaults: defaults
            )?.tenantID,
            "tenant-b"
        )
    }

    func testScopedSplashStoreDoesNotTrustLegacyTenantOnlySnapshot() throws {
        let suiteName = "BlueStoneIMTests.splash.no-legacy-fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.no-legacy-fallback.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshot = testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1")
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        let legacyCacheKey = try XCTUnwrap(snapshot.cacheKey)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: legacyCacheKey))

        let scoped = SplashTenantScope(
            appID: "app-main",
            accountID: "account-1",
            tenantID: "tenant-1",
            tenantOrigin: "https://tenant.example.test/api/tenant"
        )
        XCTAssertNil(SplashSnapshotStore.snapshot(scope: scoped, defaults: defaults))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(scope: scoped, cache: cache, defaults: defaults))
    }

    func testSplashSnapshotStoreUsesExplicitCacheKeyWhenProvided() throws {
        let suiteName = "BlueStoneIMTests.splash.explicit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.explicit.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let explicitRawKey = "tenant-1/asset-stage4/v4"
        let snapshot = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-stage4",
            version: "v4",
            cacheKeyOverride: explicitRawKey
        )
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)

        let assetVersionKey = try XCTUnwrap(SplashImageDiskCache.cacheKey(
            assetID: "asset-stage4",
            version: "v4",
            imageURL: "https://cdn.example.test/splash.png"
        ))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: assetVersionKey))
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let explicitCacheKey = try XCTUnwrap(SplashImageDiskCache.cacheKey(explicitKey: explicitRawKey))
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: explicitCacheKey))
        XCTAssertNotNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
    }

    func testSplashImageDiskCachePrefetchesFileURLAndRejectsInvalidData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory.appendingPathComponent("cache", isDirectory: true))
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("splash.png", isDirectory: false)
        let invalidURL = directory.appendingPathComponent("splash.txt", isDirectory: false)
        try testSplashPNGData().write(to: imageURL)
        try Data("not-image".utf8).write(to: invalidURL)

        let status = await cache.prefetchImage(from: imageURL.absoluteString, cacheKey: "file-success")
        let invalidStatus = await cache.prefetchImage(from: invalidURL.absoluteString, cacheKey: "file-invalid")

        XCTAssertEqual(status, .downloaded)
        XCTAssertTrue(cache.containsImage(for: "file-success"))
        XCTAssertEqual(invalidStatus, .failed)
        XCTAssertFalse(cache.containsImage(for: "file-invalid"))
    }

    func testSplashImageValidatorAcceptsFrozenPNGJPEGAndWebPContract() throws {
        let png = testSplashPNGData(width: 2, height: 3)
        let jpeg = try XCTUnwrap(testSplashImage(width: 2, height: 3).jpegData(compressionQuality: 0.9))
        let webP = try XCTUnwrap(Data(
            base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA=="
        ))
        let fixtures: [(name: String, data: Data, mimeType: String, width: Int, height: Int)] = [
            ("splash.png", png, "image/png", 2, 3),
            ("splash.jpg", jpeg, "image/jpeg", 2, 3),
            ("splash.webp", webP, "image/webp", 1, 1)
        ]

        for fixture in fixtures {
            let result = SplashImageValidator.validate(
                data: fixture.data,
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(fixture.name),
                expectedSHA256: splashSHA256Hex(fixture.data),
                expectedSizeBytes: Int64(fixture.data.count),
                expectedMimeType: fixture.mimeType,
                expectedWidth: fixture.width,
                expectedHeight: fixture.height
            )
            guard case .valid(let preparedImage) = result else {
                XCTFail("Expected valid \(fixture.mimeType) splash image")
                continue
            }
            XCTAssertEqual(preparedImage.mimeType, fixture.mimeType)
            XCTAssertEqual(preparedImage.sizeBytes, Int64(fixture.data.count))
            XCTAssertEqual(preparedImage.width, fixture.width)
            XCTAssertEqual(preparedImage.height, fixture.height)
            XCTAssertEqual(preparedImage.sha256Hex, splashSHA256Hex(fixture.data))
        }
    }

    func testSplashImageValidatorRejectsIntegrityAndSafetyViolations() {
        let data = testSplashPNGData(width: 2, height: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splash.png")

        assertSplashValidationFailure(.checksumMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedSHA256: String(repeating: "0", count: 64)
        ))
        assertSplashValidationFailure(.sizeMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedSizeBytes: Int64(data.count + 1)
        ))
        assertSplashValidationFailure(.mimeTypeMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedMimeType: "image/jpeg"
        ))
        assertSplashValidationFailure(.dimensionsMismatch, result: SplashImageValidator.validate(
            data: data,
            fileURL: url,
            expectedWidth: 3,
            expectedHeight: 3
        ))
        assertSplashValidationFailure(.fileTooLarge, result: SplashImageValidator.validate(
            data: Data(repeating: 0, count: SplashImageValidator.maxSizeBytes + 1),
            fileURL: url
        ))
        let tooWide = testSplashPNGData(width: SplashImageValidator.maxWidth + 1, height: 1)
        assertSplashValidationFailure(.dimensionsOutOfRange, result: SplashImageValidator.validate(
            data: tooWide,
            fileURL: url
        ))
        assertSplashValidationFailure(.unsupportedFormat, result: SplashImageValidator.validate(
            data: Data("not-an-image".utf8),
            fileURL: url
        ))
    }

    func testSplashImagePreparationDeletesCacheThatFailsExpectedIntegrity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.bad-cache.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory.appendingPathComponent("cache", isDirectory: true))
        let sourceURL = directory.appendingPathComponent("source.png", isDirectory: false)
        let cacheKey = "strict-cache"
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let data = testSplashPNGData(width: 2, height: 3)
        try data.write(to: sourceURL)
        try data.write(to: cache.fileURL(for: cacheKey))

        let result = await cache.prepareImage(
            from: sourceURL.absoluteString,
            cacheKey: cacheKey,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedSizeBytes: Int64(data.count),
            expectedMimeType: "image/png",
            expectedWidth: 2,
            expectedHeight: 3
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailure, .checksumMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: cacheKey).path))
    }

    func testSplashSnapshotStoreClearsTenantAndAllSnapshots() throws {
        let suiteName = "BlueStoneIMTests.splash.clear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        SplashSnapshotStore.saveSnapshot(testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1"), defaults: defaults)
        SplashSnapshotStore.saveSnapshot(testSplashSnapshot(tenantID: "tenant-2", assetID: "asset-2", version: "v1"), defaults: defaults)

        SplashSnapshotStore.clearTenant("tenant-1", defaults: defaults)
        XCTAssertNil(SplashSnapshotStore.snapshot(tenantID: "tenant-1", defaults: defaults))
        XCTAssertNotNil(SplashSnapshotStore.snapshot(tenantID: "tenant-2", defaults: defaults))

        SplashSnapshotStore.clearAll(defaults: defaults)
        XCTAssertTrue(SplashSnapshotStore.snapshots(defaults: defaults).isEmpty)
        XCTAssertTrue(SplashSnapshotStore.displayStates(defaults: defaults).isEmpty)
    }

    func testSplashDisplayStateAllowsRepeatedColdStartsButHonorsLaunchOnce() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-1",
            version: "v1",
            minIntervalSec: 14_400,
            dailyCap: 3
        )
        let shown = SplashDisplayState.empty.recordingShown(snapshot: snapshot, at: now)

        XCTAssertFalse(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(60), isColdStartLike: false, alreadyShownInThisLaunch: false))
        XCTAssertTrue(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
        XCTAssertFalse(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(14_400), isColdStartLike: true, alreadyShownInThisLaunch: true))
        XCTAssertTrue(shown.canPresent(snapshot: snapshot, at: now.addingTimeInterval(14_400), isColdStartLike: true, alreadyShownInThisLaunch: false))
    }

    func testSplashDisplayStateIgnoresDailyCapAndMinInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-1",
            version: "v1",
            minIntervalSec: 14_400,
            dailyCap: 1
        )
        let second = testSplashSnapshot(
            tenantID: "tenant-1",
            assetID: "asset-2",
            version: "v2",
            minIntervalSec: 14_400,
            dailyCap: 1
        )
        let shown = SplashDisplayState.empty.recordingShown(snapshot: first, at: now)

        XCTAssertTrue(shown.canPresent(snapshot: first, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
        XCTAssertTrue(shown.canPresent(snapshot: second, at: now.addingTimeInterval(60), isColdStartLike: true, alreadyShownInThisLaunch: false))
    }

    func testSplashSnapshotStoreRecordsBackgroundTimePerTenant() throws {
        let suiteName = "BlueStoneIMTests.splash.background.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let backgroundedAt = Date(timeIntervalSince1970: 2_000_123_456)

        SplashSnapshotStore.recordBackgrounded(tenantID: "tenant-1", at: backgroundedAt, defaults: defaults)

        XCTAssertEqual(
            SplashSnapshotStore.displayState(tenantID: "tenant-1", defaults: defaults).lastBackgroundedAt,
            backgroundedAt.timeIntervalSince1970
        )
        XCTAssertNil(SplashSnapshotStore.displayState(tenantID: "tenant-2", defaults: defaults).lastBackgroundedAt)
    }

    func testSplashInitialEvaluationKeepsOpportunityUntilSnapshotAndCacheReady() throws {
        XCTAssertTrue(SplashOverlayEvaluationResult.notReadyNoSnapshot.keepsInitialEvaluationPending)
        XCTAssertTrue(SplashOverlayEvaluationResult.notReadyNoCache.keepsInitialEvaluationPending)
        XCTAssertFalse(SplashOverlayEvaluationResult.blockedByPolicy("already_shown_in_activation").keepsInitialEvaluationPending)
        XCTAssertFalse(SplashOverlayEvaluationResult.shown.keepsInitialEvaluationPending)

        let suiteName = "BlueStoneIMTests.splash.initial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMTests.splash.initial.\(UUID().uuidString)", isDirectory: true)
        let cache = SplashImageDiskCache(directory: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let snapshot = testSplashSnapshot(tenantID: "tenant-1", assetID: "asset-1", version: "v1")
        SplashSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        XCTAssertNil(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))

        let cacheKey = try XCTUnwrap(snapshot.cacheKey)
        XCTAssertTrue(cache.storeImageData(testSplashPNGData(), cacheKey: cacheKey))
        let displayable = try XCTUnwrap(SplashSnapshotStore.displayableSnapshot(tenantID: "tenant-1", cache: cache, defaults: defaults))
        XCTAssertTrue(SplashDisplayState.empty.canPresent(
            snapshot: displayable,
            isColdStartLike: true,
            alreadyShownInThisLaunch: false
        ))
    }

    private func testSplashImage(width: Int = 1, height: Int = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testSplashPNGData(width: Int = 1, height: Int = 1) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func splashSHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func assertSplashValidationFailure(
        _ expected: SplashImageValidationFailure,
        result: SplashImageValidationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .invalid(let actual) = result else {
            XCTFail("Expected splash validation failure \(expected.rawValue)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testSplashSnapshot(
        tenantID: String,
        assetID: String,
        version: String,
        cacheKeyOverride: String? = nil,
        minIntervalSec: Int? = 3600,
        dailyCap: Int? = 1
    ) -> SplashConfigSnapshot {
        SplashConfigSnapshot(
            tenantID: tenantID,
            licenseEnabled: true,
            splashEnabled: true,
            assetID: assetID,
            imageURL: "https://cdn.example.test/splash.png",
            version: version,
            cacheKeyOverride: cacheKeyOverride,
            width: 1170,
            height: 2532,
            mimeType: "image/png",
            sizeBytes: 128,
            etag: "etag",
            sha256: "sha",
            minIntervalSec: minIntervalSec,
            dailyCap: dailyCap,
            minShowMS: 800,
            maxShowMS: 3000,
            actionURL: "",
            fetchedAt: Date().timeIntervalSince1970,
            disabledReason: "",
            prefetchStatus: .pending,
            lastPrefetchAt: nil,
            lastPrefetchError: ""
        )
    }
}
