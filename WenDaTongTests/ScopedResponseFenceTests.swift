import XCTest // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
@testable import WenDaTong
@testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

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

// WDT_IOS1_REFACTOR_REALTIME_INGEST_BINDING_20261110_BEGIN
extension DomainStoreTests {
    @MainActor
    func testBufferedRealtimeMessagesCannotReenterRetiredSessionBindings() async throws {
        for change in ["tenant", "logout-login", "A-B-A", "reauthentication", "credential-refresh"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-binding-" + UUID().uuidString)
            // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_BEGIN
            // Retain this UUID fixture backing while its original projection tasks may still own SQLite.
            // WDT_IOS1_CORE26_MAIN42_REPAIR_20261111_END
            let persistence = MessagePersistenceCoordinator(
                applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")
            )
            let transport = FakeHTTPTransport(results: [])
            let api = IMAPIClient(
                platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://tenant.example.test")!,
                imBase: URL(string: "https://im.example.test")!, httpTransport: transport
            )
            var original = makeAuthenticatedAPIContext()
            original.accountID = "realtime-" + UUID().uuidString
            original.deviceID = UUID().uuidString
            let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
                messageStore: RealtimeBindingEmptyMessageStore(), messagePersistence: persistence,
                apiContextOverride: original)
            state.setAuthenticated(true)
            state.storeCancellables.removeAll()
            state.suppressCurrentUserIdentityPersistence = true
            state.setCurrentUser(makeUser(id: original.imUID!))
            let firstTicket = try await persistence.ensureTicket(context: original, sessionGeneration: state.localMessageSessionGeneration)
            state.localMessageTicket = firstTicket
            let initialGeneration = state.localMessageSessionGeneration
            var current = makeConversation(id: "same-realtime-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            current.hasUnreadReaction = false
            current.unreadReactionCount = 0
            current.firstUnreadSeq = 0
            current.firstUnreadMessageID = ""
            current.unreadAnchorSeq = 0
            current.unreadAnchorState = "none"
            current.messages = [makeMessage(id: "current", senderId: "peer", seq: 1)]
            current.messageCoveredThroughSeq = 1
            state.conversationStore.commitConversationSnapshots([current])
            let delayed = try decodeRemoteMessage(remoteMessageJSON(id: "delayed", channelID: current.id, channelType: "group", seq: 2))
            XCTAssertEqual(state.enqueueRealtimeMessage(delayed), .messageQueued, change)
            // Hold the existing delayed merge until the binding has changed.
            state.realtimeIngestFlushTask?.cancel()
            state.realtimeIngestFlushTask = nil
            XCTAssertEqual(state.pendingRealtimeMessageCountForTesting(), 1)
            var next = original
            switch change {
            case "tenant":
                next.tenantID = "tenant-next"
                state.apiContext = next
            case "logout-login":
                next.imToken = nil
                next.sessionEpoch = UUID().uuidString
                state.apiContext = next
                state.setAuthenticated(false)
                next = original
                next.sessionEpoch = UUID().uuidString
                state.apiContext = next
                state.setAuthenticated(true)
            case "A-B-A":
                next.tenantID = "tenant-next"
                state.apiContext = next
                state.apiContext = original
            case "reauthentication":
                next.sessionEpoch = UUID().uuidString
                state.sessionReauthenticationCommit = (old: original.authSessionFence, new: next.authSessionFence)
                state.apiContext = next
                state.sessionReauthenticationCommit = nil
                XCTAssertEqual(state.localMessageSessionGeneration, initialGeneration)
            default:
                next.credentialRevision += 1
                state.apiContext = next
                XCTAssertEqual(state.localMessageSessionGeneration, initialGeneration)
            }
            let ticket = try await persistence.ensureTicket(context: state.apiContext, sessionGeneration: state.localMessageSessionGeneration)
            state.localMessageTicket = ticket
            state.conversationStore.commitConversationSnapshots([current])
            state.localMessageProjectionRevision = 1
            _ = try await persistence.persist(ticket: ticket, snapshots: [LocalMessageConversationSnapshot(
                conversation: current, channelID: current.id, channelType: "group", currentActorID: state.apiContext.imUID!
            )], source: .history, revision: 1)
            let beforeRevision = state.localMessageProjectionRevision
            let beforeAcks = transport.requests().filter { $0.httpMethod == "POST" && $0.url?.path.contains("ack") == true }.count
            state.flushPendingRealtimeMessagesForTesting()
            XCTAssertEqual(state.pendingRealtimeMessageCountForTesting(), 0)
            try await Task.sleep(nanoseconds: 250_000_000)
            let accepted = state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).contains { $0.id == "delayed" }
            if change == "credential-refresh" {
                XCTAssertTrue(accepted, "valid same-session message was discarded")
            } else {
                XCTAssertFalse(accepted, change)
                XCTAssertEqual(state.localMessageProjectionRevision, beforeRevision, change)
                let afterAcks = transport.requests().filter { $0.httpMethod == "POST" && $0.url?.path.contains("ack") == true }.count
                XCTAssertEqual(afterAcks, beforeAcks, change)
                let persisted = try await persistence.activateAndLoad(context: state.apiContext, sessionGeneration: state.localMessageSessionGeneration)
                XCTAssertFalse(persisted.conversations.flatMap(\.messages).contains { $0.id == "delayed" }, change)
            }
        }
    }
    @MainActor
    func testRetiredRealtimeTimerKeepsCurrentBindingBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("realtime-timer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = MessagePersistenceCoordinator(
            applicationSupportBase: root.appendingPathComponent("support"),
            cachesBase: root.appendingPathComponent("caches")
        )
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!, httpTransport: FakeHTTPTransport(results: [])
        )
        let original = makeAuthenticatedAPIContext()
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
            messageStore: RealtimeBindingEmptyMessageStore(), messagePersistence: persistence,
            apiContextOverride: original)
        state.setAuthenticated(true)
        state.storeCancellables.removeAll()
        state.suppressCurrentUserIdentityPersistence = true
        state.setCurrentUser(makeUser(id: original.imUID!))
        var current = makeConversation(id: "same-realtime-channel", kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        current.hasUnreadReaction = false
        current.unreadReactionCount = 0
        current.messages = [makeMessage(id: "current", senderId: "peer", seq: 1)]
        current.messageCoveredThroughSeq = 1
        state.conversationStore.commitConversationSnapshots([current])
        let old = try decodeRemoteMessage(remoteMessageJSON(id: "old", channelID: current.id, channelType: "group", seq: 2))
        XCTAssertEqual(state.enqueueRealtimeMessage(old), .messageQueued)
        let timer = try XCTUnwrap(state.realtimeIngestFlushTask)
        var next = original
        next.tenantID = "tenant-next"
        state.apiContext = next
        state.conversationStore.commitConversationSnapshots([current])
        let fresh = try decodeRemoteMessage(remoteMessageJSON(id: "fresh", channelID: current.id, channelType: "group", seq: 2))
        XCTAssertEqual(state.enqueueRealtimeMessage(fresh), .messageQueued)
        XCTAssertEqual(state.pendingRealtimeMessageCountForTesting(), 2)
        await timer.value
        XCTAssertEqual(state.pendingRealtimeMessageCountForTesting(), 0)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().flatMap(\.messages).map(\.id), ["current", "fresh"])
    }
}

private struct RealtimeBindingEmptyMessageStore: MessageStore {
    let schemaVersion = 99
    func scopeKey(for context: IMAPIContext) -> String { (try? LocalMessageScope(context: context).scopeHash) ?? "" }
    func load(scope: String) async -> CachedRemoteSnapshotLoadResult? { nil }
    func write(_ snapshot: CachedRemoteSnapshot, scope: String) -> Bool { true }
    func writeNow(_ snapshot: CachedRemoteSnapshot, scope: String) async -> Bool { true }
    func remove(scope: String) {}
    func removeAll() {}
}
// WDT_IOS1_REFACTOR_REALTIME_INGEST_BINDING_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END


// WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
extension DomainStoreTests {
    func testFriendIdentityProjectionKeepsRemarkPriorityAndRejectsAmbiguousUID() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let relations = try JSONDecoder().decode([RemoteFriendRelation].self, from: Data("""
            [
              {"friend_uid":"one","friend_user_id":"shared","raw_nickname":"Public One","remark":"Private"},
              {"friend_uid":"two","friend_user_id":"shared","raw_nickname":"Public Two"},
              {"friend_uid":"three","friend_user_id":"legacy-three","raw_nickname":"Public Three"},
              {"friend_uid":"three","friend_user_id":"duplicate","raw_nickname":"Dropped"},
              {"peer_uid":"alias-only","user_id":"legacy-alias","raw_nickname":"Alias"}
            ]
            """.utf8))
        state.profileContactRevisionFence.rebind(scopeHash: scope)
        let read = try XCTUnwrap(state.profileContactRevisionFence.beginRead(scopeHash: scope))
        state.applyFriendRelations(relations, readStamp: read)

        let displayed = try XCTUnwrap(state.contacts.first)
        XCTAssertEqual(displayed.name, "Private")
        XCTAssertEqual(state.contactCardLocalDisplayName(for: displayed), "Private")
        XCTAssertEqual(state.contactCardExportDisplayName(for: displayed), "Public One")
        XCTAssertEqual(state.contactCardOriginalName(matching: ["one", "shared"]), "Public One")
        XCTAssertEqual(state.contactCardOriginalName(matching: [" shared ", "one"]), "Public Two")
        XCTAssertEqual(state.contactCardOriginalName(matching: ["three"]), "Public Three")
        XCTAssertNil(state.contactCardOriginalName(matching: ["duplicate"]))
        let ambiguous = makeUser(id: "one", userID: "shared")
        let unambiguous = makeUser(id: "three", userID: "legacy-three")
        let alias = makeUser(id: "alias-only", userID: "legacy-alias")
        XCTAssertNil(state.contactStore.canonicalFriendUIDForRemark(for: ambiguous, in: scope))
        XCTAssertEqual(state.contactStore.canonicalFriendUIDForRemark(for: unambiguous, in: scope), "three")
        XCTAssertNil(state.contactStore.canonicalFriendUIDForRemark(for: alias, in: scope))
        XCTAssertNil(state.contactStore.canonicalFriendUIDForRemark(for: unambiguous, in: "other"))
    }

    func testCachedContactProjectionReplacesNamesOnlyInAcceptedScope() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let store = state.contactStore
        let peer = makeUser(id: "peer", userID: "legacy")
        store.replaceFriendIdentityProjection(originalNames: ["peer": "Before", "stale": "Stale"],
            canonicalUIDs: [.userID("legacy"): ["peer"]], in: scope)
        store.cacheContactCardOriginalName("Other", identifiers: ["peer"], in: "other")
        state.profileContactRevisionFence.rebind(scopeHash: scope)
        let read = try XCTUnwrap(state.profileContactRevisionFence.beginRead(scopeHash: scope))
        let projection = LocalProfileContactProjection(revision: 7, contacts: [], remarks: [:], blacklist: [],
            originalNames: [" peer ": " Restored ", "bad": " "])
        state.applyCachedProfileContactProjection(projection, scope: scope, readStamp: read)

        XCTAssertEqual(state.contactCardOriginalName(matching: ["peer"]), "Restored")
        XCTAssertEqual(store.contactCardOriginalNames(in: scope), ["peer": "Restored"])
        XCTAssertEqual(store.contactCardOriginalNames(in: "other"), ["peer": "Other"])
        XCTAssertEqual(store.canonicalFriendUIDForRemark(for: peer, in: scope), "peer")
        store.reset()
        XCTAssertTrue(store.contactCardOriginalNames(in: scope).isEmpty)
        XCTAssertTrue(store.contactCardOriginalNames(in: "other").isEmpty)
        XCTAssertNil(store.canonicalFriendUIDForRemark(for: peer, in: scope))
    }
}
// WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
