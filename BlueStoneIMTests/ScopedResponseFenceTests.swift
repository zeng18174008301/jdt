import XCTest
@testable import BlueStoneIM

final class ScopedResponseFenceTests: XCTestCase {
    private let scope = ScopedResponseScope(
        tenantID: "tenant-a",
        viewerID: "viewer-a",
        appID: "app1",
        featureKey: "profile",
        subjectType: "user",
        subjectID: "WXT00000001",
        sessionID: "session-a",
        sessionGeneration: 3,
        capabilityFingerprint: "ordinary:v1"
    )

    func testNewerRevisionOrSameFamilyGenerationApplies() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 1)
        let newerRevision = checkpoint(revision: 10, generations: [.identity: 41], sequence: 2)
        let newerIdentity = checkpoint(revision: 9, generations: [.identity: 42], sequence: 2)

        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: newerRevision
            ),
            .apply(newerRevision)
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: newerIdentity
            ),
            .apply(newerIdentity)
        )
    }

    func testEqualIsIdempotentAndLowerValuesAreIgnored() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 3)
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 3,
                incoming: current
            ),
            .ignoreIdempotent
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 4,
                incoming: checkpoint(
                    revision: 8,
                    generations: [.identity: 41],
                    sequence: 4
                )
            ),
            .ignoreStale
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: checkpoint(
                    revision: 10,
                    generations: [.identity: 42],
                    sequence: 2
                )
            ),
            .ignoreStale
        )
    }

    func testDifferentGenerationFamiliesNeverCompareNumerically() {
        let current = checkpoint(
            revision: 9,
            generations: [.certification: 100],
            sequence: 1
        )
        let incoming = checkpoint(
            revision: 9,
            generations: [.identity: 2],
            sequence: 2
        )
        let merged = checkpoint(
            revision: 9,
            generations: [.certification: 100, .identity: 2],
            sequence: 2
        )

        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: incoming
            ),
            .apply(merged)
        )
    }

    func testGenerationGapAndUnknownContractPurgeAndRefetch() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 1)
        let gap = checkpoint(revision: 9, generations: [.identity: 43], sequence: 2)
        let unknown = checkpoint(
            contractVersion: 2,
            revision: 10,
            generations: [.identity: 42],
            sequence: 2
        )

        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: gap
            ),
            .purgeAndRefetch
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: unknown
            ),
            .purgeAndRefetch
        )
    }

    func testTenantViewerSubjectSessionRoleAndLogoutPreventLatePaint() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 1)
        let changedCapability = ScopedResponseScope(
            tenantID: scope.tenantID,
            viewerID: scope.viewerID,
            appID: scope.appID,
            featureKey: scope.featureKey,
            subjectType: scope.subjectType,
            subjectID: scope.subjectID,
            sessionID: scope.sessionID,
            sessionGeneration: scope.sessionGeneration,
            capabilityFingerprint: "internal:v2"
        )
        let staleIncoming = checkpoint(
            scope: scope,
            revision: 10,
            generations: [.identity: 42],
            sequence: 2
        )

        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: changedCapability,
                activeRequestSequence: 2,
                incoming: staleIncoming
            ),
            .purgeAndRefetch
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: nil,
                activeRequestSequence: 2,
                incoming: staleIncoming
            ),
            .purge
        )
    }

    func testForeignAppRouteSubjectOrViewerResponsesAreIgnoredWithoutPurgingCurrent() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 1)
        let foreignScopes = [
            ScopedResponseScope(
                tenantID: scope.tenantID,
                viewerID: scope.viewerID,
                appID: "app2",
                featureKey: scope.featureKey,
                subjectType: scope.subjectType,
                subjectID: scope.subjectID,
                sessionID: scope.sessionID,
                sessionGeneration: scope.sessionGeneration,
                capabilityFingerprint: scope.capabilityFingerprint
            ),
            ScopedResponseScope(
                tenantID: scope.tenantID,
                viewerID: scope.viewerID,
                appID: scope.appID,
                featureKey: "conversation",
                subjectType: scope.subjectType,
                subjectID: scope.subjectID,
                sessionID: scope.sessionID,
                sessionGeneration: scope.sessionGeneration,
                capabilityFingerprint: scope.capabilityFingerprint
            ),
            ScopedResponseScope(
                tenantID: scope.tenantID,
                viewerID: "viewer-b",
                appID: scope.appID,
                featureKey: scope.featureKey,
                subjectType: "group",
                subjectID: "group-1",
                sessionID: scope.sessionID,
                sessionGeneration: scope.sessionGeneration,
                capabilityFingerprint: scope.capabilityFingerprint
            )
        ]

        for foreignScope in foreignScopes {
            let invalidForeign = checkpoint(
                scope: foreignScope,
                contractVersion: 999,
                revision: -1,
                generations: [.identity: -1],
                sequence: -1
            )
            let (retained, outcome) = ScopedResponseFence.reducing(
                current: current,
                activeScope: scope,
                activeRequestSequence: 2,
                incoming: invalidForeign
            )
            XCTAssertEqual(outcome, .ignoreForeign)
            XCTAssertEqual(retained, current)
        }
    }

    func testInvalidCurrentOrActiveScopePurgesAndRefetches() {
        let invalidActive = ScopedResponseScope(
            tenantID: scope.tenantID,
            viewerID: scope.viewerID,
            appID: "",
            featureKey: scope.featureKey,
            subjectType: scope.subjectType,
            subjectID: scope.subjectID,
            sessionID: scope.sessionID,
            sessionGeneration: scope.sessionGeneration,
            capabilityFingerprint: scope.capabilityFingerprint
        )
        let incoming = checkpoint(revision: 10, generations: [.identity: 42], sequence: 2)

        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: nil,
                activeScope: invalidActive,
                activeRequestSequence: 2,
                incoming: incoming
            ),
            .purgeAndRefetch
        )

        let foreignCurrent = checkpoint(
            scope: scope,
            revision: 9,
            generations: [.identity: 41],
            sequence: 1
        )
        let changedActive = ScopedResponseScope(
            tenantID: scope.tenantID,
            viewerID: scope.viewerID,
            appID: scope.appID,
            featureKey: scope.featureKey,
            subjectType: scope.subjectType,
            subjectID: scope.subjectID,
            sessionID: "session-b",
            sessionGeneration: scope.sessionGeneration + 1,
            capabilityFingerprint: scope.capabilityFingerprint
        )
        let sameActiveIncoming = checkpoint(
            scope: changedActive,
            revision: 10,
            generations: [.identity: 42],
            sequence: 2
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: foreignCurrent,
                activeScope: changedActive,
                activeRequestSequence: 2,
                incoming: sameActiveIncoming
            ),
            .purgeAndRefetch
        )
    }

    func testOnlyExactActiveRequestSequenceCanApply() {
        let current = checkpoint(revision: 9, generations: [.identity: 41], sequence: 1)
        for inactiveSequence in [2, 4] {
            let incoming = checkpoint(
                revision: 10,
                generations: [.identity: 42],
                sequence: Int64(inactiveSequence)
            )
            let (retained, outcome) = ScopedResponseFence.reducing(
                current: current,
                activeScope: scope,
                activeRequestSequence: 3,
                incoming: incoming
            )
            XCTAssertEqual(outcome, .ignoreInactiveRequest)
            XCTAssertEqual(retained, current)
        }

        let activeIncoming = checkpoint(
            revision: 10,
            generations: [.identity: 42],
            sequence: 3
        )
        XCTAssertEqual(
            ScopedResponseFence.evaluate(
                current: current,
                activeScope: scope,
                activeRequestSequence: 3,
                incoming: activeIncoming
            ),
            .apply(activeIncoming)
        )
    }

    func testCurrentProfileAuthorityRejectsPreMutationReadAndDowngrade() {
        let scope = CurrentProfileAuthorityScope(
            tenantID: "tenant-1",
            actorIMUID: "uid-1",
            appID: "jianhuitong-ios"
        )!
        var fence = CurrentProfileAuthorityFence()
        let readBeforeMutation = fence.beginRead(scope: scope)
        let mutation = fence.beginMutation(scope: scope)

        let staleRead = CurrentProfileAuthoritySnapshot(
            tenantID: "tenant-1",
            imUID: "uid-1",
            appID: "jianhuitong-ios",
            userRevision: 1,
            identityGeneration: 1,
            nickname: "旧昵称",
            avatar: "old.png"
        )
        XCTAssertEqual(
            fence.consume(staleRead, request: readBeforeMutation),
            .rejectPreMutationResponse
        )

        let patch = CurrentProfileAuthoritySnapshot(
            tenantID: "tenant-1",
            imUID: "uid-1",
            appID: "jianhuitong-ios",
            userRevision: 2,
            identityGeneration: 2,
            nickname: "新昵称",
            avatar: "new.png"
        )
        XCTAssertEqual(
            fence.consume(patch, request: mutation),
            .acceptVersioned(
                CurrentProfileAuthorityCheckpoint(
                    scope: scope,
                    userRevision: 2,
                    identityGeneration: 2,
                    nickname: "新昵称",
                    avatar: "new.png"
                )
            )
        )

        let newerRead = fence.beginRead(scope: scope)
        let downgrade = CurrentProfileAuthoritySnapshot(
            tenantID: "tenant-1",
            imUID: "uid-1",
            appID: "jianhuitong-ios",
            userRevision: 1,
            identityGeneration: 2,
            nickname: "旧昵称",
            avatar: "new.png"
        )
        XCTAssertEqual(
            fence.consume(downgrade, request: newerRead),
            .rejectDowngrade
        )
    }

    func testCurrentProfileAuthorityRejectsSameRevisionContentConflict() {
        let scope = CurrentProfileAuthorityScope(
            tenantID: "tenant-1",
            actorIMUID: "uid-1",
            appID: "jianhuitong-ios"
        )!
        var fence = CurrentProfileAuthorityFence()
        let firstRead = fence.beginRead(scope: scope)
        let first = CurrentProfileAuthoritySnapshot(
            tenantID: "tenant-1",
            imUID: "uid-1",
            appID: "jianhuitong-ios",
            userRevision: 5,
            identityGeneration: 7,
            nickname: "Alice",
            avatar: "a.png"
        )
        _ = fence.consume(first, request: firstRead)

        let secondRead = fence.beginRead(scope: scope)
        let conflict = CurrentProfileAuthoritySnapshot(
            tenantID: "tenant-1",
            imUID: "uid-1",
            appID: "jianhuitong-ios",
            userRevision: 5,
            identityGeneration: 8,
            nickname: "Bob",
            avatar: "a.png"
        )
        XCTAssertEqual(
            fence.consume(conflict, request: secondRead),
            .rejectRevisionConflict
        )
    }

    func testProfileContactMutationTicketsRejectOlderAAfterBThenA() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let key = "remark:friend-1"
        let firstA = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: [key]))
        let mutationB = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: [key]))
        let secondA = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: [key]))

        XCTAssertFalse(fence.isCurrent(firstA))
        XCTAssertFalse(fence.isCurrent(mutationB))
        XCTAssertTrue(fence.isCurrent(secondA))
        XCTAssertGreaterThan(secondA.revision, mutationB.revision)
    }

    func testRemarkLatestWriteWinsRejectsOldFailureAfterNewSuccess() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let keys: Set<String> = ["remark:friend-1", "contact:friend-1"]
        let oldRequest = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: keys)
        )
        let newRequest = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: keys)
        )

        XCTAssertTrue(fence.isCurrent(newRequest), "new success may commit")
        XCTAssertFalse(
            fence.isCurrent(oldRequest),
            "old failure may not roll back the newer successful remark"
        )
    }

    func testRemarkSetUpdateClearLeavesOnlyClearTicketAuthoritative() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let keys: Set<String> = ["remark:friend-1", "contact:friend-1"]
        let set = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: keys)
        )
        let update = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: keys)
        )
        let clear = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: keys)
        )

        XCTAssertFalse(fence.isCurrent(set))
        XCTAssertFalse(fence.isCurrent(update))
        XCTAssertTrue(fence.isCurrent(clear))
    }

    func testProfileContactReadFencePreservesOnlyKeysMutatedAfterRead() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let read = try XCTUnwrap(fence.beginRead(scopeHash: "scope-a"))
        _ = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: ["remark:friend-1"]))

        XCTAssertTrue(fence.wasMutated("remark:friend-1", after: read))
        XCTAssertFalse(fence.wasMutated("remark:friend-2", after: read))
        XCTAssertFalse(fence.wasMutated("blacklist:friend-1", after: read))
    }

    func testProfileContactScopeRebindInvalidatesLateMutationAndHydrate() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let readA = try XCTUnwrap(fence.beginRead(scopeHash: "scope-a"))
        let mutationA = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: ["contact:friend-1"]))

        fence.rebind(scopeHash: "scope-b")
        XCTAssertFalse(fence.isCurrent(mutationA))
        XCTAssertFalse(fence.acceptPersistedProjection(scopeHash: "scope-a", readStamp: readA, revision: 40))

        fence.rebind(scopeHash: "scope-a")
        let freshReadA = try XCTUnwrap(fence.beginRead(scopeHash: "scope-a"))
        XCTAssertTrue(fence.acceptPersistedProjection(scopeHash: "scope-a", readStamp: freshReadA, revision: 40))
        XCTAssertEqual(fence.revision, 40)
    }

    func testProfileContactHydrateCannotOverwriteMutationStartedAfterLoad() throws {
        var fence = ProfileContactRevisionFence()
        fence.rebind(scopeHash: "scope-a")
        let hydrateRead = try XCTUnwrap(fence.beginRead(scopeHash: "scope-a"))
        _ = try XCTUnwrap(fence.beginMutation(scopeHash: "scope-a", keys: ["blacklist:friend-1"]))

        XCTAssertFalse(
            fence.acceptPersistedProjection(
                scopeHash: "scope-a",
                readStamp: hydrateRead,
                revision: 999
            )
        )
        XCTAssertEqual(fence.revision, 999)
        let nextMutation = try XCTUnwrap(
            fence.beginMutation(scopeHash: "scope-a", keys: ["blacklist:friend-1"])
        )
        XCTAssertEqual(nextMutation.revision, 1_000)
    }

    private func checkpoint(
        scope: ScopedResponseScope? = nil,
        contractVersion: Int = 1,
        revision: Int64,
        generations: [ScopedGenerationFamily: Int64],
        sequence: Int64
    ) -> ScopedResponseCheckpoint {
        ScopedResponseCheckpoint(
            scope: scope ?? self.scope,
            version: ScopedResponseVersion(
                contractVersion: contractVersion,
                revision: revision,
                familyGenerations: generations,
                requestSequence: sequence
            )
        )
    }
}
