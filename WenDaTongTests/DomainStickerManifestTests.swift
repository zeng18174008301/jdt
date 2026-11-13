@testable import IM4Features
@testable import IM4Stores // WDT_IOS1_STICKER_STATE_FAMILY_20261110
import XCTest
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong

// WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_BEGIN
extension DomainStoreTests {
    func testPrepareStickerPanelHydratesCachedEndpointOnlyStickersBeforeManifestRefresh() async throws {
        let context = IMAPIContext(
            platformToken: "platform-token",
            accountID: "account-\(UUID().uuidString)",
            tenantID: "tenant-\(UUID().uuidString)",
            imUID: "uid-\(UUID().uuidString)",
            imToken: "im-token",
            platformAuthSession: nil,
            tenantAuthSession: nil,
            appID: IMAPIContext.canonicalIOSAppID,
            deviceID: "unit-test-device"
        )
        let scope = [context.tenantID, context.imUID, context.accountID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        // The actual AppState has its normal default store. Own one synthetic key
        // for this fixture and leave every preexisting defaults record alone.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let fixtureKey = "im2.ios.stickerManifest.\(String(hash, radix: 16))"
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: fixtureKey) == nil else {
            XCTFail("fixture unexpectedly overlaps an existing cache entry")
            return
        }
        defer { defaults.removeObject(forKey: fixtureKey) }
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END
        let cachedStore = StickerStore()
        let cachedBinding = cachedStore.activate(scope: try LocalMessageScope(context: context), legacyKey: scope) // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        cachedStore.replaceMyStickers([
            StickerLibraryItem(
                id: "us-cached",
                stickerID: "st-cached",
                fileID: "file-cached",
                packID: "",
                source: .mine,
                status: "active",
                processingStatus: "active",
                sort: 1,
                mimeType: "image/gif",
                sizeBytes: 4096,
                width: 128,
                height: 128,
                durationMS: 600,
                frameCount: 8,
                cacheKey: "cache-cached",
                version: "v1",
                thumbnailURL: "/api/tenant/files/file-cached/thumbnail",
                variants: [
                    StickerAssetVariant(
                        kind: "original",
                        fileID: "file-cached",
                        mimeType: "image/gif",
                        assetURL: "/api/tenant/files/file-cached/presign-download",
                        sizeBytes: 4096,
                        width: 128,
                        height: 128,
                        durationMS: 600,
                        frameCount: 8,
                        thumbnailURL: "/api/tenant/files/file-cached/thumbnail",
                        cacheKey: "cache-cached"
                    )
                ],
                createdAt: "2026-06-26T01:00:00Z",
                updatedAt: "2026-06-26T01:00:00Z"
            )
        ], binding: cachedBinding)

        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_BEGIN
        actor DownloadAttempts {
            var paths: [String] = []

            func fail(_ request: URLRequest) throws -> (URL, URLResponse) {
                paths.append(request.url?.path ?? "")
                throw URLError(.cannotFindHost)
            }
        }
        let downloads = DownloadAttempts()
        let transport = StickerPanelHydrationHTTPTransport()
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [], httpTransport: transport, startupContext: context
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("core-fixture-\(UUID().uuidString)")
        let state = AppState(api: api, realtimeClient: PostLoginSilentRealtimeTransport(),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context, stickerAssetDownload: { request in try await downloads.fail(request) })
        defer { state.retireStickerManifestRequests() }

        await state.prepareStickerExpressionPanel(force: true)

        let downloadPaths = await downloads.paths
        XCTAssertEqual(downloadPaths, ["/file-cached-thumb.gif", "/file-cached-preview.gif", "/file-cached.gif"])
        let evidence = XCTAttachment(string: (transport.paths() + downloadPaths).joined(separator: "\n"))
        evidence.name = "core-fixture-sticker-requests"
        evidence.lifetime = .keepAlways
        add(evidence)
        // WDT_IOS1_CORE_FULLSUITE_FIXTURE_TRANSPORTS_20261111_END

        let hydrated = try XCTUnwrap(state.myStickers.first(where: { $0.id == "us-cached" }))
        XCTAssertEqual(state.stickerThumbnailURL(for: hydrated), "https://cdn.example.test/file-cached-thumb.gif?sig=unit")
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
        let requests = transport.paths()
        let hydrationIndex = try XCTUnwrap(requests.firstIndex(of: "/api/tenant/files/file-cached"))
        let refreshIndex = try XCTUnwrap(requests.firstIndex { $0.hasPrefix("/api/tenant/user-stickers") })
        XCTAssertLessThan(hydrationIndex, refreshIndex)
        let persisted = try XCTUnwrap(defaults.data(forKey: fixtureKey))
        let reloaded = try JSONDecoder().decode(CachedStickerManifest.self, from: persisted)
        XCTAssertEqual(reloaded.myStickers.map(\.id), ["us-cached"])
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("sig=unit"))
        // WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END
    }

    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
    func testStickerManifestRefreshFencesHydrationAcrossAuthorityAndRequestChanges() async throws {
        enum Transition: String, CaseIterable { case switchScope, device, aba, reauthenticate, supersede, renew } // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        func seed(_ id: String) throws -> StickerLibraryItem {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "sticker_id": id, "status": "active"])
            return StickerLibraryItem(remote: try JSONDecoder().decode(RemoteUserSticker.self, from: data))
        }

        for transition in Transition.allCases {
            let fixtureID = UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-fence-" + fixtureID)
            defer { try? FileManager.default.removeItem(at: root) }
            var a = makeAuthenticatedAPIContext(accountID: "fixture-a-" + fixtureID, imUID: "fixture-a")
            a.deviceID = "fixture-" + fixtureID
            var b = makeAuthenticatedAPIContext(accountID: "fixture-b-" + fixtureID, imUID: "fixture-b")
            b.deviceID = a.deviceID

            let hydrationEntered = expectation(description: "\(transition) old file-detail request suspended")
            let successorEntered = transition == .renew ? nil : expectation(description: "\(transition) current manifest request suspended")
            let transport = StickerManifestRefreshGateTransport(hydrationEntered: hydrationEntered, successorEntered: successorEntered)
            let state = AppState(api: makeCallEndingAPI(transport: transport),
                voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
                messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
                messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                    cachesBase: root.appendingPathComponent("caches")),
                protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
                apiContextOverride: a)
            let scopeA = state.stickerLibraryScopeKey(for: a)
            let scopeB = state.stickerLibraryScopeKey(for: b)
            let keyA = stickerManifestTestKey(scopeA), keyB = stickerManifestTestKey(scopeB)
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keyA) == nil, defaults.object(forKey: keyB) == nil else {
                return XCTFail("Synthetic scopes must own fresh defaults keys")
            }
            defer {
                state.retireStickerManifestRequests()
                defaults.removeObject(forKey: keyA)
                defaults.removeObject(forKey: keyB)
            }
            let seeder = StickerStore()
            // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
            let seedA = seeder.activate(scope: try LocalMessageScope(context: a), legacyKey: scopeA)
            seeder.replaceMyStickers([try seed("seed-a")], binding: seedA)
            let seedB = seeder.activate(scope: try LocalMessageScope(context: b), legacyKey: scopeB)
            seeder.replaceMyStickers([try seed("seed-b")], binding: seedB)
            // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
            let originalA = try XCTUnwrap(defaults.data(forKey: keyA))
            let originalB = try XCTUnwrap(defaults.data(forKey: keyB))

            let old = Task { await state.refreshUserStickerManifest(silent: true) }
            defer {
                old.cancel()
                Task { await transport.releaseAll() }
            }
            await fulfillment(of: [hydrationEntered], timeout: 4)
            XCTAssertEqual(state.stickerStore.currentScope, scopeA)
            XCTAssertTrue(state.stickerStore.isManifestRefreshing)
            XCTAssertEqual(state.myStickers.map(\.id), ["seed-a"])

            switch transition {
            case .switchScope:
                state.overrideAPIContextForTesting(b)
            case .device: // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
                var changed = a
                changed.deviceID += "-replacement"
                state.overrideAPIContextForTesting(changed)
                XCTAssertNil(state.stickerStore.activeBinding)
                XCTAssertTrue(state.myStickers.isEmpty)
            case .aba:
                state.overrideAPIContextForTesting(b)
                state.overrideAPIContextForTesting(a)
            case .reauthenticate:
                var reauthenticated = a
                reauthenticated.sessionEpoch = UUID().uuidString
                reauthenticated.credentialRevision &+= 1
                reauthenticated.imToken = "fixture-reauthenticated"
                state.sessionReauthenticationCommit = (a.authSessionFence, reauthenticated.authSessionFence)
                state.overrideAPIContextForTesting(reauthenticated)
                state.sessionReauthenticationCommit = nil
                XCTAssertEqual(state.myStickers.map(\.id), ["seed-a"], "same-scope reauthentication keeps visible cache")
                XCTAssertFalse(state.stickerStore.isManifestRefreshing, "replacement epoch retires the old owner")
            case .supersede:
                break
            case .renew:
                var renewed = a
                renewed.credentialRevision &+= 1
                renewed.imToken = "fixture-renewed"
                XCTAssertTrue(renewed.credentialsAdvanced(since: a.authSessionFence))
                state.overrideAPIContextForTesting(renewed)
                XCTAssertTrue(state.stickerStore.isManifestRefreshing)
            }

            if let successorEntered {
                let successor = Task { await state.refreshUserStickerManifest(force: transition == .supersede, silent: true) }
                defer { successor.cancel() }
                await fulfillment(of: [successorEntered], timeout: 4)
                let currentScope = transition == .switchScope ? scopeB : scopeA
                let currentSeed = transition == .switchScope ? "seed-b" : "seed-a"
                await transport.releaseHydration()
                await old.value
                XCTAssertEqual(state.stickerStore.currentScope, currentScope, transition.rawValue)
                XCTAssertEqual(state.myStickers.map(\.id), [currentSeed], transition.rawValue)
                XCTAssertTrue(state.stickerStore.isManifestRefreshing, transition.rawValue)
                XCTAssertNil(state.stickerStore.manifestErrorMessage, transition.rawValue)
                XCTAssertNil(state.stickerManifestPollTask, transition.rawValue)
                XCTAssertEqual(defaults.data(forKey: keyA), originalA, transition.rawValue)
                XCTAssertEqual(defaults.data(forKey: keyB), originalB, transition.rawValue)

                await transport.releaseSuccessor()
                await successor.value
                XCTAssertEqual(state.myStickers.map(\.id), ["current"], transition.rawValue)
                XCTAssertFalse(state.stickerStore.isManifestRefreshing, transition.rawValue)
                XCTAssertNotNil(state.stickerManifestPollTask, transition.rawValue)
                let persisted = try XCTUnwrap(defaults.data(forKey: stickerManifestTestKey(currentScope)))
                let record = try JSONDecoder().decode(CachedStickerManifest.self, from: persisted)
                XCTAssertEqual(record.scope, currentScope, transition.rawValue)
                XCTAssertEqual(record.myStickers.map(\.id), ["current"], transition.rawValue)
                let otherKey = transition == .switchScope ? keyA : keyB
                XCTAssertEqual(defaults.data(forKey: otherKey), transition == .switchScope ? originalA : originalB)
            } else {
                await transport.releaseHydration()
                await old.value
                XCTAssertEqual(state.stickerStore.currentScope, scopeA)
                XCTAssertEqual(state.myStickers.map(\.id), ["original"])
                XCTAssertFalse(state.stickerStore.isManifestRefreshing)
                XCTAssertNotNil(state.stickerManifestPollTask)
                let bytes = try XCTUnwrap(defaults.data(forKey: keyA))
                let record = try JSONDecoder().decode(CachedStickerManifest.self, from: bytes)
                XCTAssertEqual(record.myStickers.map(\.id), ["original"])
                XCTAssertEqual(defaults.data(forKey: keyB), originalB)
            }
        }
    }
    // WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    func testRetiredStickerManifestDownloadCannotWriteMediaCacheOrStaging() async throws {
        for indexed in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-bytes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("BlueStoneIMAttachmentDownloadStaging")
            func contents(of directory: URL) -> Set<String> {
                Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            }
            let originalStaging = contents(of: staging)
            let oldEntered = expectation(description: "old sticker bytes suspended")
            let currentEntered = expectation(description: "current sticker bytes suspended")
            let download = StickerManifestByteGate(root: root, oldEntered: oldEntered, currentEntered: currentEntered)
            let transport = StickerManifestRefreshGateTransport(
                mode: .downloads(indexed: indexed), hydrationEntered: nil, successorEntered: nil
            )
            let state = makeStickerManifestRepairState(transport: transport, root: root) { request in
                try await download.load(request)
            }
            let context = state.apiContext
            let scope = try LocalMessageScope(context: context)
            let paths = try MessageDatabasePaths(scope: scope, applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches"))
            let media = IOSMediaCacheScopeContext(scopeHash: scope.scopeHash,
                sessionGeneration: state.localMessageSessionGeneration, rootDirectory: paths.mediaScopeDirectory)
            state.resolvedMediaCacheScope = (scope, media)
            let stickerScope = state.stickerLibraryScopeKey(for: context)
            let defaults = UserDefaults.standard
            let key = stickerManifestTestKey(stickerScope)
            guard defaults.object(forKey: key) == nil else { return XCTFail("fixture defaults key already exists") }
            defer {
                state.retireStickerManifestRequests()
                defaults.removeObject(forKey: key)
            }
            let old = Task { await state.refreshUserStickerManifest(silent: true) }
            let current: Task<Void, Never>
            await fulfillment(of: [oldEntered], timeout: 4)
            current = Task { await state.refreshUserStickerManifest(force: true, silent: true) }
            defer {
                old.cancel()
                current.cancel()
                Task { await download.releaseAll() }
            }
            await fulfillment(of: [currentEntered], timeout: 4)

            await download.release("old")
            await old.value
            XCTAssertTrue(state.stickerStore.isManifestRefreshing)
            XCTAssertTrue(contents(of: media.rootDirectory).isEmpty)
            XCTAssertEqual(contents(of: staging), originalStaging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.download").path))
            XCTAssertNil(defaults.data(forKey: key))

            let ticket = try await state.messagePersistence.ensureTicket(context: context, sessionGeneration: media.sessionGeneration)
            let emptyIndex = try await state.messagePersistence.mediaCacheStatistics(ticket: ticket)
            XCTAssertEqual(emptyIndex.fileCount, 0)

            var renewed = context
            renewed.credentialRevision &+= 1
            renewed.imToken = "fixture-renewed-byte-owner"
            XCTAssertTrue(renewed.credentialsAdvanced(since: context.authSessionFence))
            state.overrideAPIContextForTesting(renewed)
            state.resolvedMediaCacheScope = (scope, media)

            await download.release("current")
            await current.value
            let item = try XCTUnwrap(state.myStickers.first)
            XCTAssertEqual(item.id, "current")
            let local = try XCTUnwrap(URL(string: item.thumbnailURL))
            XCTAssertTrue(local.isFileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current.download").path))
            let persisted = try XCTUnwrap(defaults.data(forKey: key))
            XCTAssertEqual(try JSONDecoder().decode(CachedStickerManifest.self, from: persisted).myStickers.map(\.id), ["current"])
            XCTAssertEqual(try Data(contentsOf: local), Data("fixture-current".utf8))
            let currentIndex = try await state.messagePersistence.mediaCacheStatistics(ticket: ticket)
            XCTAssertEqual(currentIndex.fileCount, indexed ? 1 : 0)
            if indexed {
                XCTAssertTrue(local.path.hasPrefix(media.rootDirectory.path + "/"))
                let identity = MediaResourceMetadata(scope: scope.scopeHash, fileID: "current-file",
                    version: "v1", thumbnailVersion: "v1").identity(for: .thumbnail, variant: .thumbnail640)
                let indexKey = try XCTUnwrap(identity.persistentCacheIdentity)
                let entry = try await state.messagePersistence.mediaCacheLookup(
                    ticket: ticket, cacheIdentity: indexKey, messageID: "sticker:current-file", offline: false)
                XCTAssertNotNil(entry)
                XCTAssertEqual(contents(of: staging), originalStaging)
            } else {
                let directory = local.deletingLastPathComponent()
                if directory.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL,
                   !originalStaging.contains(directory.lastPathComponent) {
                    try FileManager.default.removeItem(at: directory)
                } else {
                    XCTFail("current fixture did not use its own staging directory")
                }
            }
        }
    }

    func testStaleColdStickerPreparationCannotStartAnotherForcedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-prepare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coldEntered = expectation(description: "old cold hydration suspended")
        let currentEntered = expectation(description: "current manifest list suspended")
        let transport = StickerManifestRefreshGateTransport(
            mode: .coldPreparation, hydrationEntered: coldEntered, successorEntered: currentEntered
        )
        let state = makeStickerManifestRepairState(transport: transport, root: root)
        let scope = state.stickerLibraryScopeKey(for: state.apiContext)
        let key = stickerManifestTestKey(scope)
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return XCTFail("fixture defaults key already exists") }
        defer {
            state.retireStickerManifestRequests()
            defaults.removeObject(forKey: key)
        }
        let seed = try JSONDecoder().decode(RemoteUserSticker.self,
            from: Data(#"{"id":"seed","file_id":"held-file","thumbnail_url":"/api/tenant/files/held-file/thumbnail","status":"active"}"#.utf8))
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        let seeder = StickerStore()
        let binding = seeder.activate(scope: try LocalMessageScope(context: state.apiContext), legacyKey: scope)
        seeder.replaceMyStickers([StickerLibraryItem(remote: seed)], binding: binding)
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
        let before = try XCTUnwrap(defaults.data(forKey: key))

        let old = Task { await state.prepareStickerExpressionPanel(force: true) }
        await fulfillment(of: [coldEntered], timeout: 4)
        let current = Task { await state.refreshUserStickerManifest(force: true, silent: true) }
        defer {
            old.cancel()
            current.cancel()
            Task { await transport.releaseAll() }
        }
        await fulfillment(of: [currentEntered], timeout: 4)
        await transport.releaseHydration()
        await old.value
        let count = await transport.listCount()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(state.stickerStore.isManifestRefreshing)
        XCTAssertEqual(state.myStickers.map(\.id), ["seed"])
        XCTAssertEqual(defaults.data(forKey: key), before)

        await transport.releaseSuccessor()
        await current.value
        XCTAssertEqual(state.myStickers.map(\.id), ["current"])
        XCTAssertFalse(state.stickerStore.isManifestRefreshing)
        let persisted = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode(CachedStickerManifest.self, from: persisted).myStickers.map(\.id), ["current"])
    }

    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
    func testStickerLibraryRuntimeScopeRetiresLateUploadAfterDeviceSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uploadHydration = expectation(description: "old upload file detail suspended")
        let transport = StickerManifestRefreshGateTransport(mode: .upload,
            hydrationEntered: uploadHydration, successorEntered: nil)
        let state = makeStickerManifestRepairState(transport: transport, root: root)
        let context = state.apiContext
        let key = stickerManifestTestKey(state.stickerLibraryScopeKey(for: context))
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return XCTFail("fixture defaults key already exists") }
        defer { defaults.removeObject(forKey: key) }

        let initial = try XCTUnwrap(state.activateStickerLibrary())
        let seed = try JSONDecoder().decode(RemoteUserSticker.self, from: Data(#"{"id":"seed","status":"active"}"#.utf8))
        state.stickerStore.replaceMyStickers([StickerLibraryItem(remote: seed)], binding: initial)
        let before = try XCTUnwrap(defaults.data(forKey: key))
        let scope = initial.scope
        let otherApp = try LocalMessageScope(accountID: scope.accountID, tenantID: scope.tenantID,
            appID: "fixture-other-app", actorID: scope.actorID, deviceID: scope.deviceID)
        let legacyKey = state.stickerLibraryScopeKey(for: context)
        let appBinding = state.stickerStore.activate(scope: otherApp, legacyKey: legacyKey)
        XCTAssertNotEqual(initial, appBinding)
        state.stickerStore.replaceMyStickers([], binding: initial)
        XCTAssertEqual(state.myStickers.map(\.id), ["seed"])
        XCTAssertEqual(defaults.data(forKey: key), before)
        let old = try XCTUnwrap(state.activateStickerLibrary())
        XCTAssertNotEqual(initial, old)
        let uploadID = StickerLibraryItem.makeLocalUploadID()
        let data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let conversation = makeConversation(id: "uid-a:uid-b", unread: 0, lastMsgSeq: 0, lastReadSeq: 0)
        func beginUpload(_ binding: StickerStore.Binding) {
            state.stickerStore.beginLocalUpload(id: uploadID, name: "fixture.png", mimeType: "image/png",
                sizeBytes: data.count, data: data, conversationID: conversation.id, binding: binding)
        }
        beginUpload(old)
        let task = Task {
            await state.performStickerImageUpload(uploadID: uploadID, data: data, fileName: "fixture.png",
                mimeType: "image/png", fileExtension: "png", conversation: conversation, context: context, binding: old)
        }
        defer {
            task.cancel()
            Task { await transport.releaseAll() }
        }
        await fulfillment(of: [uploadHydration], timeout: 4)

        var changed = context
        changed.deviceID += "-new"
        state.overrideAPIContextForTesting(changed)
        XCTAssertNil(state.stickerStore.activeBinding)
        XCTAssertTrue(state.myStickers.isEmpty)
        XCTAssertNil(state.stickerStore.localUploadDraft(id: uploadID))
        let replacement = try XCTUnwrap(state.activateStickerLibrary())
        XCTAssertNotEqual(old, replacement)
        XCTAssertEqual(state.myStickers.map(\.id), ["seed"])
        beginUpload(replacement)
        let staleProgressApplied = expectation(description: "old upload must not change replacement progress")
        staleProgressApplied.isInverted = true
        let progressObservation = state.stickerStore.$uploadProgress.sink { progress in
            if let progress, progress > 0.02 { staleProgressApplied.fulfill() }
        }
        let releasedProgress = await transport.releaseUploadProgress()
        XCTAssertTrue(releasedProgress, "the old upload must have registered its real progress delegate")
        await fulfillment(of: [staleProgressApplied], timeout: 0.25)
        progressObservation.cancel()
        XCTAssertEqual(state.myStickers.first(where: { $0.id == uploadID })?.uploadProgress, 0.02)
        await transport.releaseHydration()
        await task.value
        let manifestRequests = await transport.listCount()
        XCTAssertEqual(manifestRequests, 0)
        XCTAssertEqual(Set(state.myStickers.map(\.id)), ["seed", uploadID])
        XCTAssertEqual(state.myStickers.first(where: { $0.id == uploadID })?.uploadProgress, 0.02)
        XCTAssertEqual(defaults.data(forKey: key), before)

        var incomplete = changed
        incomplete.deviceID = " " + changed.deviceID + " "
        XCTAssertEqual(changed.authSessionFence, incomplete.authSessionFence)
        XCTAssertNotNil(state.stickerRuntimeScope(for: changed))
        XCTAssertNil(state.stickerRuntimeScope(for: incomplete))
        XCTAssertNotNil(state.stickerStore.localUploadDraft(id: uploadID))
        state.overrideAPIContextForTesting(incomplete)
        XCTAssertEqual(state.apiContext.deviceID, incomplete.deviceID)
        XCTAssertNil(state.stickerStore.activeBinding)
        XCTAssertTrue(state.myStickers.isEmpty)
        XCTAssertNil(state.stickerStore.localUploadDraft(id: uploadID))
        XCTAssertEqual(defaults.data(forKey: key), before)
        await state.prepareStickerExpressionPanel()
        XCTAssertTrue(state.myStickers.isEmpty)
        state.overrideAPIContextForTesting(changed)
        XCTAssertNotNil(state.activateStickerLibrary())
        var loggedOut = changed
        loggedOut.imToken = nil
        state.overrideAPIContextForTesting(loggedOut)
        XCTAssertNil(state.stickerStore.activeBinding)
        XCTAssertTrue(state.myStickers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), before)
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    private func makeStickerManifestRepairState(
        transport: StickerManifestRefreshGateTransport, root: URL,
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { _ in throw URLError(.unsupportedURL) }
    ) -> AppState {
        let fixture = UUID().uuidString
        var context = makeAuthenticatedAPIContext(accountID: "fixture-\(fixture)", imUID: "fixture-sticker-repair")
        context.deviceID = "fixture-\(fixture)"
        return AppState(api: makeCallEndingAPI(transport: transport),
            voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context, stickerAssetDownload: download)
    }

    private func stickerManifestTestKey(_ scope: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "im2.ios.stickerManifest.\(String(hash, radix: 16))"
    }
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
}

// WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_BEGIN
private actor StickerManifestRefreshGateTransport: HTTPTransport {
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    enum Mode {
        case metadata
        case coldPreparation
        case upload // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112
        case downloads(indexed: Bool)
    }

    private let mode: Mode
    private let hydrationEntered: XCTestExpectation?
    private let successorEntered: XCTestExpectation?
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
    private var lists = 0
    private var hydration: CheckedContinuation<Void, Never>?
    private var successor: CheckedContinuation<Void, Never>?
    private var hydrationReleased = false
    private var successorReleased = false
    private var pendingUploadProgress: (UploadProgressDelegate, URLRequest)? // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112

    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
    init(mode: Mode = .metadata, hydrationEntered: XCTestExpectation?, successorEntered: XCTestExpectation?) {
        self.mode = mode
        self.hydrationEntered = hydrationEntered
        self.successorEntered = successorEntered
    }

    func listCount() -> Int { lists }
    // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let body: [String: Any]
        switch request.url?.path {
        case "/api/tenant/user-stickers":
            lists += 1
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
            switch mode {
            case .downloads:
                guard lists <= 2 else { throw URLError(.unsupportedURL) }
                let id = lists == 1 ? "old" : "current"
                body = ["items": [["id": id, "sticker_id": id, "file_id": id + "-file",
                    "status": "active", "mime_type": "image/gif"]]]
            case .metadata where lists == 1:
                body = ["items": [["id": "original", "sticker_id": "original", "file_id": "held-file",
                    "status": "queued", "processing_status": "processing", "mime_type": "image/gif"]]]
            default:
                let expected = if case .coldPreparation = mode { 1 } else { 2 }
                guard lists == expected, let successorEntered else { throw URLError(.unsupportedURL) }
            // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
                if !successorReleased {
                    await withCheckedContinuation { continuation in
                        successor = continuation
                        successorEntered.fulfill()
                    }
                }
                body = ["items": [["id": "current", "sticker_id": "current", "status": "queued",
                    "processing_status": "processing", "mime_type": "image/gif"]]]
            }
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        case "/api/tenant/files/config":
            guard case .upload = mode else { throw URLError(.unsupportedURL) }
            body = ["max_bytes": 1_024]
        case "/api/tenant/files/presign-upload":
            guard case .upload = mode else { throw URLError(.unsupportedURL) }
            body = ["file": ["file_id": "held-file", "file_name": "fixture.png", "mime_type": "image/png"],
                "upload": ["url": "https://upload.example.test/fixture", "method": "PUT"]]
        case "/api/tenant/files/held-file/uploaded":
            guard case .upload = mode else { throw URLError(.unsupportedURL) }
            body = ["file": ["file_id": "held-file", "file_name": "fixture.png",
                "mime_type": "image/png", "status": "uploaded"]]
        case "/api/tenant/user-stickers/commit":
            guard case .upload = mode else { throw URLError(.unsupportedURL) }
            body = ["sticker": ["id": "late", "file_id": "held-file", "status": "active"],
                "task": ["id": "fixture-task", "sticker_id": "late", "file_id": "held-file", "status": "queued"]]
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END
        case "/api/tenant/files/held-file":
            if !hydrationReleased {
                await withCheckedContinuation { continuation in
                    hydration = continuation
                    hydrationEntered?.fulfill() // WDT_IOS1_STICKER_MANIFEST_R2_20261111
                }
            }
            body = ["file": ["id": "held-file", "file_name": "fixture.gif", "mime_type": "image/gif",
                "size_bytes": 1, "status": "uploaded"],
                "preview_available": false, "download_available": false]
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
        case "/api/tenant/files/old-file", "/api/tenant/files/current-file":
            guard case let .downloads(indexed) = mode, let id = request.url?.lastPathComponent else {
                throw URLError(.unsupportedURL)
            }
            let name = String(id.dropLast("-file".count))
            body = ["file": ["id": id, "file_name": name + ".gif", "mime_type": "image/gif",
                "size_bytes": 1, "status": "uploaded", "version": indexed ? "v1" : "",
                "thumbnail_url": "https://cdn.example.test/\(name).gif"]]
        // WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
        default:
            throw URLError(.unsupportedURL)
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "data": body])
        return HTTPTransportResult(data: bytes, isHTTPResponse: true, statusCode: 200)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_BEGIN
        guard case .upload = mode, let delegate = delegate as? UploadProgressDelegate else {
            throw URLError(.unsupportedURL)
        }
        pendingUploadProgress = (delegate, request)
        return HTTPTransportResult(data: Data(), isHTTPResponse: true, statusCode: 204, responseURL: request.url)
    }

    func releaseUploadProgress() -> Bool {
        guard let (delegate, request) = pendingUploadProgress else { return false }
        pendingUploadProgress = nil
        let session = URLSession.shared
        let task = session.dataTask(with: request)
        delegate.urlSession(session, task: task, didSendBodyData: 3, totalBytesSent: 3, totalBytesExpectedToSend: 4)
        task.cancel()
        return true
    }
    // WDT_IOS1_STORES_STICKER_RUNTIME_SCOPE_20261112_END

    func releaseHydration() {
        hydrationReleased = true
        hydration?.resume()
        hydration = nil
    }

    func releaseSuccessor() {
        successorReleased = true
        successor?.resume()
        successor = nil
    }

    func releaseAll() {
        releaseHydration()
        releaseSuccessor()
    }
}
// WDT_IOS1_STICKER_MANIFEST_REFRESH_FENCE_20261111_END

// WDT_IOS1_STICKER_MANIFEST_R2_20261111_BEGIN
private actor StickerManifestByteGate {
    let root: URL
    let oldEntered: XCTestExpectation
    let currentEntered: XCTestExpectation
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []

    init(root: URL, oldEntered: XCTestExpectation, currentEntered: XCTestExpectation) {
        self.root = root
        self.oldEntered = oldEntered
        self.currentEntered = currentEntered
    }

    func load(_ request: URLRequest) async throws -> (URL, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let name = url.deletingPathExtension().lastPathComponent
        guard name == "old" || name == "current", waiting[name] == nil else { throw URLError(.unsupportedURL) }
        if !released.contains(name) {
            await withCheckedContinuation { continuation in
                waiting[name] = continuation
                (name == "old" ? oldEntered : currentEntered).fulfill()
            }
        }
        let temporary = root.appendingPathComponent(name + ".download")
        try Data("fixture-\(name)".utf8).write(to: temporary)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (temporary, response)
    }

    func release(_ name: String) {
        released.insert(name)
        waiting.removeValue(forKey: name)?.resume()
    }

    func releaseAll() {
        release("old")
        release("current")
    }
}
// WDT_IOS1_STICKER_MANIFEST_R2_20261111_END
// WDT_IOS1_DOMAIN_TEST_SOURCE_SPLIT_20261111_END
