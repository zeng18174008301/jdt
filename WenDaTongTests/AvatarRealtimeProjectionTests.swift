import XCTest
import Combine
@testable import WenDaTong

final class AvatarRealtimeProjectionTests: XCTestCase {
    func testLostPushBudgetUsesMonotonicThreeSecondTickAndBoundedResponse() {
        XCTAssertTrue(AvatarAuthorityRefreshBudget.closesLostPushWithinDeadline)
        XCTAssertEqual(
            AvatarAuthorityRefreshBudget.periodicTickNanoseconds,
            3_000_000_000
        )
        let startedAt: UInt64 = 40_000_000_000
        XCTAssertTrue(
            AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: startedAt,
                completedAt: startedAt + AvatarAuthorityRefreshBudget.requestNanoseconds
            )
        )
        XCTAssertFalse(
            AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: startedAt,
                completedAt: startedAt + AvatarAuthorityRefreshBudget.requestNanoseconds + 1
            )
        )
        XCTAssertFalse(
            AvatarAuthorityRefreshBudget.acceptsResponse(
                startedAt: startedAt,
                completedAt: startedAt - 1
            )
        )
    }

    func testStrictEventAppliesAndOlderOrDuplicateCannotRollback() {
        var projection = AvatarRealtimeProjection()
        let first = projection.consume(envelope(revision: 4, generation: 7), activeTenantID: "tenant-a")
        guard case .applied(let value) = first else {
            return XCTFail("expected applied, got \(first)")
        }
        XCTAssertEqual(value.uid, "u-1")
        XCTAssertEqual(value.cacheVersion, "4")
        XCTAssertEqual(projection.consume(envelope(revision: 4, generation: 7), activeTenantID: "tenant-a"), .idempotent)
        XCTAssertEqual(projection.consume(envelope(revision: 3, generation: 6), activeTenantID: "tenant-a"), .ignoredStale)
    }

    func testSameRevisionDifferentURLFailsClosedAndRequiresAuthority() {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 4, generation: 7), activeTenantID: "tenant-a")
        let conflict = projection.consume(
            envelope(revision: 4, generation: 7, url: "/api/tenant/avatar/other"),
            activeTenantID: "tenant-a"
        )
        XCTAssertEqual(conflict, .refetch(["u-1"], .revisionConflict))
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["u-1"])
    }

    func testGapAndMalformedPayloadRequireAuthorityWithoutProjection() {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 1, generation: 1), activeTenantID: "tenant-a")
        XCTAssertEqual(
            projection.consume(envelope(revision: 3, generation: 3), activeTenantID: "tenant-a"),
            .refetch([], .generationGap)
        )
        var malformed = envelope(revision: 2, generation: 2)
        malformed = RealtimeEnvelope(
            type: malformed.type,
            requestID: nil,
            payload: malformed.payload.merging(["changed": .array([.string("avatar"), .string("name")])]) { _, next in next }
        )
        XCTAssertEqual(
            projection.consume(malformed, activeTenantID: "tenant-a"),
            .refetch(["u-1"], .malformed)
        )
    }

    func testForeignTenantIgnoredAndScopeSwitchPurgesFence() throws {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 2, generation: 2), activeTenantID: "tenant-a")
        XCTAssertEqual(
            projection.consume(envelope(tenantID: "tenant-b", revision: 3, generation: 3), activeTenantID: "tenant-a"),
            .ignoredForeignTenant
        )
        projection.bind(tenantID: "tenant-b")
        XCTAssertTrue(projection.exactUIDs.isEmpty)
        guard case .applied(let rebound) = projection.applyAuthority(
            summary: try summary(revision: 1, generation: 1, url: "/api/tenant/avatar/new-scope"),
            subjectTenantID: "tenant-b"
        ) else {
            return XCTFail("new tenant authority must not inherit the prior tenant fence")
        }
        XCTAssertEqual(rebound.tenantID, "tenant-b")
    }

    func testServerGoldenFieldsAreExactAndExtraSensitiveKeyFailsClosed() {
        var projection = AvatarRealtimeProjection()
        XCTAssertEqual(
            Set(envelope(revision: 1, generation: 1).payload.keys),
            [
                "event", "event_id", "event_type", "tenant_id", "subject_type",
                "subject_id", "revision", "generation_family", "generation",
                "changed", "occurred_at", "uid", "url", "version", "updated_at"
            ]
        )
        var payload = envelope(revision: 1, generation: 1).payload
        payload["object_key"] = .string("must-not-be-consumed")
        XCTAssertEqual(
            projection.consume(
                RealtimeEnvelope(type: "notification", requestID: nil, payload: payload),
                activeTenantID: "tenant-a"
            ),
            .refetch(["u-1"], .malformed)
        )
    }

    func testUppercaseLiteralAndStringNumberAreMalformed() {
        var projection = AvatarRealtimeProjection()
        var uppercase = envelope(revision: 1, generation: 1).payload
        uppercase["event"] = .string("AVATAR_UPDATED")
        XCTAssertEqual(
            projection.consume(
                RealtimeEnvelope(type: "notification", requestID: nil, payload: uppercase),
                activeTenantID: "tenant-a"
            ),
            .refetch(["u-1"], .malformed)
        )

        var stringNumber = envelope(revision: 1, generation: 1).payload
        stringNumber["revision"] = .string("1")
        XCTAssertEqual(
            projection.consume(
                RealtimeEnvelope(type: "notification", requestID: nil, payload: stringNumber),
                activeTenantID: "tenant-a"
            ),
            .refetch(["u-1"], .malformed)
        )
    }

    func testTenantGlobalFamilyGapAppliesToPreviouslyUnseenUID() {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 1, generation: 4), activeTenantID: "tenant-a")
        XCTAssertEqual(
            projection.consume(
                envelope(uid: "u-2", revision: 1, generation: 6),
                activeTenantID: "tenant-a"
            ),
            .refetch([], .generationGap)
        )
        XCTAssertEqual(projection.familyGeneration, 4)
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["u-2"])
    }

    func testGapWatermarkRejectsIntermediateEventAndAuthorityUntilSatisfied() throws {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 12, generation: 12), activeTenantID: "tenant-a")
        XCTAssertEqual(
            projection.consume(envelope(revision: 15, generation: 15), activeTenantID: "tenant-a"),
            .refetch([], .generationGap)
        )
        XCTAssertEqual(
            projection.consume(envelope(revision: 13, generation: 13), activeTenantID: "tenant-a"),
            .refetch(["u-1"], .authorityBehindFence)
        )
        XCTAssertEqual(projection.familyGeneration, 12)
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["u-1"])

        XCTAssertEqual(
            projection.applyAuthority(
                summary: try summary(revision: 14, generation: 14, url: "/api/tenant/avatar/fourteen"),
                subjectTenantID: "tenant-a"
            ),
            .refetch(["u-1"], .authorityBehindFence)
        )
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["u-1"])

        guard case .applied(let resolved) = projection.applyAuthority(
            summary: try summary(revision: 15, generation: 15, url: "/api/tenant/avatar/fifteen"),
            subjectTenantID: "tenant-a"
        ) else {
            return XCTFail("authority at the recorded watermark must resolve the fence")
        }
        XCTAssertEqual(resolved.revision, 15)
        XCTAssertEqual(projection.familyGeneration, 15)
        XCTAssertTrue(projection.pendingAuthorityUIDs.isEmpty)
    }

    func testHigherFamilyGenerationWithLowerSubjectRevisionDoesNotOverwrite() {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 5, generation: 8), activeTenantID: "tenant-a")
        XCTAssertEqual(
            projection.consume(envelope(revision: 4, generation: 9), activeTenantID: "tenant-a"),
            .refetch(["u-1"], .authorityBehindFence)
        )
        XCTAssertEqual(projection.familyGeneration, 8)
    }

    func testAuthorityCannotRollbackGapWatermark() throws {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 2, generation: 2), activeTenantID: "tenant-a")
        _ = projection.consume(envelope(revision: 5, generation: 5), activeTenantID: "tenant-a")
        let stale = try summary(revision: 4, generation: 4, url: "/api/tenant/avatar/stale")
        XCTAssertEqual(
            projection.applyAuthority(summary: stale, subjectTenantID: "tenant-a"),
            .refetch(["u-1"], .authorityBehindFence)
        )
        let fresh = try summary(revision: 5, generation: 5, url: "/api/tenant/avatar/fresh")
        guard case .applied(let value) = projection.applyAuthority(summary: fresh, subjectTenantID: "tenant-a") else {
            return XCTFail("fresh authority did not apply")
        }
        XCTAssertEqual(value.url, "/api/tenant/avatar/fresh")
        XCTAssertEqual(value.cacheVersion, "file-fresh")
    }

    func testReconnectMarksKnownUIDForAuthority() {
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(envelope(revision: 2, generation: 2), activeTenantID: "tenant-a")
        XCTAssertEqual(projection.requireAuthorityAfterReconnect(), .refetch(["u-1"], .reconnect))
    }

    func testAuthorityBatchRejectsMixedIdentityGenerationsAtomically() throws {
        var projection = AvatarRealtimeProjection()
        projection.bind(tenantID: "tenant-a")
        let outcomes = projection.applyAuthorityBatch(
            summaries: [
                try summary(uid: "u-1", revision: 1, generation: 4, url: "/api/tenant/avatar/one"),
                try summary(uid: "u-2", revision: 1, generation: 5, url: "/api/tenant/avatar/two")
            ],
            subjectTenantID: "tenant-a"
        )
        XCTAssertEqual(outcomes, [.refetch(["u-1", "u-2"], .mixedAuthorityGeneration)])
        XCTAssertEqual(projection.familyGeneration, 0)
    }

    func testAuthorityBatchAcceptsUploadedAndDefaultStableAvatarRoutes() throws {
        var projection = AvatarRealtimeProjection()
        projection.bind(tenantID: "tenant-a")
        let uploaded = try summary(
            uid: "u-1",
            revision: 1,
            generation: 7,
            url: "/api/tenant/avatar/uploaded-one"
        )
        let defaultAvatar = try UserSummaryV2(
            userRevision: 1,
            generations: .init(identity: 7),
            imUID: "u-2",
            userID: "u-2",
            displayName: "User Two",
            displayNameSource: "nickname",
            rawNickname: "User Two",
            avatar: .init(
                url: "/api/tenant/static/avatars/default-users-v2/01-natural-landscape/pb-01-001.webp",
                version: "default-avatar-v2:hash:pb-01-001",
                source: "system_default",
                catalogVersion: "v2"
            ),
            certification: nil
        )
        let outcomes = projection.applyAuthorityBatch(
            summaries: [uploaded, defaultAvatar],
            subjectTenantID: "tenant-a"
        )
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy {
            if case .applied = $0 { return true }
            return false
        })
        XCTAssertEqual(projection.familyGeneration, 7)
    }

    func testAuthorityBatchAtomicallyAcceptsUnchangedRevisionZeroAndChangedUser() throws {
        var projection = AvatarRealtimeProjection()
        projection.bind(tenantID: "tenant-a")
        let outcomes = projection.applyAuthorityBatch(
            summaries: [
                try summary(
                    uid: "u-1",
                    revision: 0,
                    generation: 9,
                    url: "/api/tenant/static/avatars/default-users-v2/01-natural-landscape/pb-01-001.webp"
                ),
                try summary(
                    uid: "u-2",
                    revision: 4,
                    generation: 9,
                    url: "/api/tenant/avatar/changed-four"
                )
            ],
            subjectTenantID: "tenant-a"
        )
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy {
            if case .applied = $0 { return true }
            return false
        })
        XCTAssertEqual(projection.value(forExactUID: "u-1")?.revision, 0)
        XCTAssertEqual(projection.value(forExactUID: "u-2")?.revision, 4)
        XCTAssertEqual(projection.familyGeneration, 9)
    }

    func testAuthorityBatchAcceptsInitialZeroGenerationAndRevision() throws {
        var projection = AvatarRealtimeProjection()
        projection.bind(tenantID: "tenant-a")
        let outcomes = projection.applyAuthorityBatch(
            summaries: [
                try summary(
                    uid: "u-1",
                    revision: 0,
                    generation: 0,
                    url: "/api/tenant/static/avatars/default-users-v2/01-natural-landscape/pb-01-001.webp"
                )
            ],
            subjectTenantID: "tenant-a"
        )
        guard case .applied(let value) = outcomes.first else {
            return XCTFail("initial generation-zero authority must be accepted")
        }
        XCTAssertEqual(value.revision, 0)
        XCTAssertEqual(value.generation, 0)
        XCTAssertEqual(projection.familyGeneration, 0)
        XCTAssertEqual(
            projection.consume(
                envelope(revision: 2, generation: 2),
                activeTenantID: "tenant-a"
            ),
            .refetch([], .generationGap)
        )
    }

    func testValidAndExplicitMissingAuthorityBatchDoesNotAdvanceOrClearPending() throws {
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.hasExactAuthorityCoverage(
                requestedUIDs: ["u-1", "deleted-u"],
                itemUIDs: ["u-1"],
                missingUIDs: ["deleted-u"]
            )
        )
        XCTAssertFalse(
            AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: ["u-1", "deleted-u"],
                itemUIDs: ["u-1"],
                missingUIDs: ["deleted-u"],
                allItemsAuthoritative: true
            )
        )
        var projection = AvatarRealtimeProjection()
        _ = projection.consume(
            envelope(uid: "deleted-u", revision: 1, generation: 1),
            activeTenantID: "tenant-a"
        )
        _ = projection.requireAuthorityAfterReconnect()
        XCTAssertEqual(projection.familyGeneration, 1)
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["deleted-u"])
    }

    func testAllMissingAuthorityBatchDoesNotAdvance() {
        XCTAssertFalse(
            AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: ["deleted-u"],
                itemUIDs: [],
                missingUIDs: ["deleted-u"],
                allItemsAuthoritative: true
            )
        )
    }

    func testCompleteAuthorityBatchRequiresEveryRequestedUIDExactlyOnce() {
        XCTAssertTrue(
            AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: ["u-1", "u-2"],
                itemUIDs: ["u-2", "u-1"],
                missingUIDs: [],
                allItemsAuthoritative: true
            )
        )
        XCTAssertFalse(
            AvatarRealtimeSurfaceProjector.isCompleteAvatarAuthorityBatch(
                requestedUIDs: ["u-1", "u-2"],
                itemUIDs: ["u-1", "u-1"],
                missingUIDs: [],
                allItemsAuthoritative: true
            )
        )
    }

    func testLateHTTPUserCollectionsAreOverlaidByRealtimeFence() {
        var root = AvatarRealtimeProjection()
        guard case .applied(let current) = root.consume(
            envelope(revision: 9, generation: 9, url: "/api/tenant/avatar/current-nine"),
            activeTenantID: "tenant-a"
        ) else {
            return XCTFail("event must establish the realtime fence")
        }
        let stale = IMUser(
            id: "u-1",
            name: "User",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "normal",
            enterprise: "Tenant",
            avatarSeed: 1,
            avatarURL: "https://tenant.example/api/tenant/avatar/stale-eight",
            avatarVersion: "8",
            avatarUpdatedAt: "older",
            badges: []
        )
        let resolvedURL = "https://tenant.example/api/tenant/avatar/current-nine"
        let conversationParticipants = [stale].map {
            AvatarRealtimeSurfaceProjector.user($0, projection: current, resolvedURL: resolvedURL)
        }
        let groupMembers = [stale].map {
            AvatarRealtimeSurfaceProjector.user($0, projection: current, resolvedURL: resolvedURL)
        }
        let organizationMembers = [stale].map {
            AvatarRealtimeSurfaceProjector.user($0, projection: current, resolvedURL: resolvedURL)
        }
        XCTAssertEqual(conversationParticipants.first?.avatarVersion, "9")
        XCTAssertEqual(groupMembers.first?.avatarURL, resolvedURL)
        XCTAssertEqual(organizationMembers.first?.avatarURL, resolvedURL)
    }

    func testLateMeProfileAndTenantContextCannotRollbackCurrentUser() {
        var root = AvatarRealtimeProjection()
        guard case .applied(let current) = root.consume(
            envelope(revision: 11, generation: 11, url: "/api/tenant/avatar/me-eleven"),
            activeTenantID: "tenant-a"
        ) else {
            return XCTFail("event must establish the current-user fence")
        }
        let lateMeProfile = IMUser(
            id: "u-1",
            name: "Me",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "normal",
            enterprise: "Tenant",
            avatarSeed: 1,
            avatarURL: "https://tenant.example/api/tenant/avatar/me-ten",
            avatarVersion: "10",
            avatarUpdatedAt: "older",
            badges: []
        )
        let lateTenantContext = IMUser(
            id: "u-1",
            name: "Me from tenant context",
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "normal",
            enterprise: "Tenant",
            avatarSeed: 2,
            avatarURL: "https://tenant.example/api/tenant/avatar/me-nine",
            avatarVersion: "9",
            avatarUpdatedAt: "oldest",
            badges: []
        )
        let resolvedURL = "https://tenant.example/api/tenant/avatar/me-eleven"
        let projectedMe = AvatarRealtimeSurfaceProjector.user(
            lateMeProfile,
            projection: current,
            resolvedURL: resolvedURL
        )
        let projectedContext = AvatarRealtimeSurfaceProjector.user(
            lateTenantContext,
            projection: current,
            resolvedURL: resolvedURL
        )
        XCTAssertEqual(projectedMe.avatarVersion, "11")
        XCTAssertEqual(projectedContext.avatarVersion, "11")
        XCTAssertEqual(projectedMe.avatarURL, resolvedURL)
        XCTAssertEqual(projectedContext.avatarURL, resolvedURL)
    }

    func testLocalAvatarCommitRetiresOldProjectionAndRejectsLateRollback() {
        var projection = AvatarRealtimeProjection()
        guard case .applied(let oldProjection) = projection.consume(
            envelope(
                revision: 7,
                generation: 12,
                url: "/api/tenant/avatar/old"
            ),
            activeTenantID: "tenant-a"
        ) else {
            return XCTFail("expected initial realtime projection")
        }
        XCTAssertEqual(
            projection.retireExactUIDAfterLocalCommit("u-1"),
            oldProjection
        )
        XCTAssertNil(projection.value(forExactUID: "u-1"))
        XCTAssertEqual(projection.pendingAuthorityUIDs, ["u-1"])

        var fence = AvatarLocalCommitAuthorityFence()
        fence.record(
            tenantID: "tenant-a",
            uid: "u-1",
            resolvedURL: "https://tenant.example/api/tenant/avatar/new",
            cacheVersion: "commit-v8",
            updatedAt: "2026-08-24T00:00:00Z",
            minimumRemoteRevision: oldProjection.revision,
            minimumRemoteGeneration: oldProjection.generation
        )
        XCTAssertFalse(
            fence.allows(
                oldProjection,
                resolvedProjectionURL: "https://tenant.example/api/tenant/avatar/old"
            )
        )
        XCTAssertTrue(fence.protects(exactUID: " u-1 "))

        let mixedCacheKeyProjection = AvatarRealtimeProjectionValue(
            tenantID: "tenant-a",
            uid: "u-1",
            url: "/api/tenant/avatar/new",
            cacheVersion: "old-cache-version",
            updatedAt: "2026-08-23T23:59:00Z",
            revision: 7,
            generation: 12
        )
        XCTAssertFalse(
            fence.allows(
                mixedCacheKeyProjection,
                resolvedProjectionURL: "https://tenant.example/api/tenant/avatar/new"
            ),
            "a matching URL must not revive an old cache version/updatedAt pair"
        )

        let committedURLProjection = AvatarRealtimeProjectionValue(
            tenantID: "tenant-a",
            uid: "u-1",
            url: "/api/tenant/avatar/new",
            cacheVersion: "commit-v8",
            updatedAt: "2026-08-24T00:00:00Z",
            revision: 7,
            generation: 12
        )
        XCTAssertTrue(
            fence.allows(
                committedURLProjection,
                resolvedProjectionURL: "https://tenant.example/api/tenant/avatar/new"
            )
        )
    }

    func testLocalAvatarCommitFenceRequiresStrictlyNewerAuthorityAndPurgesAcrossScope() {
        var fence = AvatarLocalCommitAuthorityFence()
        fence.record(
            tenantID: "tenant-a",
            uid: "u-1",
            resolvedURL: "https://tenant.example/new-a",
            cacheVersion: "a",
            updatedAt: "now",
            minimumRemoteRevision: 20,
            minimumRemoteGeneration: 9
        )
        let sameGenerationNewRevision = AvatarRealtimeProjectionValue(
            tenantID: "tenant-a",
            uid: "u-1",
            url: "/newer",
            cacheVersion: "21",
            updatedAt: "later",
            revision: 21,
            generation: 9
        )
        XCTAssertTrue(
            fence.consumeIfAuthoritative(
                sameGenerationNewRevision,
                resolvedProjectionURL: "https://tenant.example/newer"
            )
        )
        XCTAssertFalse(fence.isActive)

        fence.record(
            tenantID: "tenant-a",
            uid: "u-1",
            resolvedURL: "https://tenant.example/new-a-again",
            cacheVersion: "a2",
            updatedAt: "later",
            minimumRemoteRevision: 21,
            minimumRemoteGeneration: 9
        )
        let epochA = fence.epoch
        fence.bind(tenantID: "tenant-b")
        XCTAssertFalse(fence.isActive)
        XCTAssertEqual(fence.tenantID, "tenant-b")
        XCTAssertEqual(fence.epoch, 0)
        fence.bind(tenantID: "tenant-a")
        XCTAssertFalse(fence.isActive)
        XCTAssertNotEqual(epochA, fence.epoch)
    }

    func envelope(
        tenantID: String = "tenant-a",
        uid: String = "u-1",
        revision: Int64,
        generation: Int64,
        url: String = "/api/tenant/avatar/avatar_opaque-1"
    ) -> RealtimeEnvelope {
        let occurredAt = "2026-08-12T08:01:02.123Z"
        return RealtimeEnvelope(
            type: "notification",
            requestID: nil,
            payload: [
                "event": .string("avatar_updated"),
                "event_id": .string("evt-\(uid)-\(revision)-\(generation)"),
                "event_type": .string("identity.summary.updated"),
                "tenant_id": .string(tenantID),
                "subject_type": .string("user"),
                "subject_id": .string(uid),
                "revision": .int(Int(revision)),
                "generation_family": .string("identity"),
                "generation": .int(Int(generation)),
                "changed": .array([.string("avatar")]),
                "occurred_at": .string(occurredAt),
                "uid": .string(uid),
                "url": .string(url),
                "version": .int(Int(revision)),
                "updated_at": .string(occurredAt)
            ]
        )
    }

    func summary(
        uid: String = "u-1",
        revision: Int64,
        generation: Int64,
        url: String
    ) throws -> UserSummaryV2 {
        try UserSummaryV2(
            userRevision: revision,
            generations: .init(identity: generation),
            imUID: uid,
            userID: uid,
            displayName: "User",
            displayNameSource: "nickname",
            rawNickname: "User",
            avatar: .init(url: url, version: "file-fresh", source: "custom"),
            certification: nil
        )
    }
}
