import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong

extension HTTPTransportTests {
    func testSyncDiagnosticsHistoryFailureEntrypointUsesClosedClassesAndOriginalRequestCount() async throws {
        let sentinel = "SENSITIVE_SENTINEL token=never-log https://private.invalid/secret?account=hidden"
        let cases: [(Error, SyncFailureDiagnostic.Failure, SyncFailureDiagnostic.Recovery)] = [
            (IMAPIError.unauthorized(sentinel), .unauthorized, .noRefreshAuthority),
            (IMAPIError.forbidden(sentinel), .forbidden, .notApplicable),
            (IMAPIError.httpStatus(503, message: sentinel), .server, .notApplicable),
            (URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: sentinel]), .timeout, .notApplicable),
            (IMAPIError.businessForbidden(code: "route_contract_mismatch", message: sentinel, error: nil), .route, .notApplicable),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: sentinel)), .decode, .notApplicable),
            (CancellationError(), .cancelled, .notApplicable),
            // The existing recovery predicate recognizes .unauthorized only, not
            // arbitrary .httpStatus(401). Diagnostics must not broaden it.
            (IMAPIError.httpStatus(401, message: sentinel), .unauthorized, .notApplicable),
            (NSError(domain: sentinel, code: 999, userInfo: [NSLocalizedDescriptionKey: sentinel]), .other, .notApplicable)
        ]
        for (error, failure, recovery) in cases {
            let transport = SyncDiagnosticHTTPTransport(failures: ["/api/im/sync": error])
            let fixture = try makeSyncDiagnosticFixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var events: [SyncFailureDiagnostic] = []
            fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
            fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true)
            try await waitForCondition { !events.isEmpty && !fixture.state.conversationStore.hasHistoryLoadingIDs() }
            XCTAssertEqual(events, [.init(endpoint: .history, failure: failure, recovery: recovery)])
            XCTAssertEqual(transport.count("/api/im/sync"), 1)
            XCTAssertEqual(transport.refreshCount, 0)
            XCTAssertEqual(fixture.state.conversationStore.historyMessage(conversationID: "uid-1:uid-2"), "聊天记录同步失败，请稍后重试")
            for event in events {
                XCTAssertFalse(event.summary.contains("SENSITIVE_SENTINEL"))
                XCTAssertFalse(event.summary.contains("https:"))
                XCTAssertFalse(event.summary.contains("hidden"))
            }
        }
    }

    func testSyncDiagnosticsRealHTTPFailureKeepsStatusAndDecodeWithoutChangingErrors() async throws {
        for (status, body, failure, recovery) in [
            (401, #"{"ok":false,"error":{"code":"unauthorized","message":"SENSITIVE_SENTINEL"}}"#, SyncFailureDiagnostic.Failure.unauthorized, SyncFailureDiagnostic.Recovery.noRefreshAuthority),
            (403, #"{"ok":false,"error":{"code":"forbidden","message":"SENSITIVE_SENTINEL"}}"#, .forbidden, .notApplicable),
            (502, #"{"ok":false,"error":{"code":"upstream","message":"SENSITIVE_SENTINEL"}}"#, .server, .notApplicable),
            (200, "SENSITIVE_SENTINEL invalid json", .decode, .notApplicable)
        ] {
            let transport = SyncDiagnosticHTTPTransport(failures: [:])
            transport.historyHTTPResult = HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status)
            let fixture = try makeSyncDiagnosticFixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var events: [SyncFailureDiagnostic] = []
            fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
            fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true)
            try await waitForCondition { !events.isEmpty && !fixture.state.conversationStore.hasHistoryLoadingIDs() }
            XCTAssertEqual(events, [.init(endpoint: .history, failure: failure, recovery: recovery)])
            XCTAssertEqual(transport.count("/api/im/sync"), 1)
            XCTAssertEqual(transport.refreshCount, 0)
            XCTAssertFalse(events.contains { $0.summary.contains("SENSITIVE_SENTINEL") })
            XCTAssertNil(SyncFailureDiagnostic.httpObservation, "request-local evidence must not leak to its caller")
            // Compare the unchanged public API error outside diagnostics scope.
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            do {
                _ = try await client.syncMessages(context: fixture.context, channelID: "uid-1:uid-2", channelType: "direct", afterSeq: 0, beforeSeq: nil, limit: 50)
                XCTFail("the synthetic failure must still throw")
            } catch {
                switch (status, error) {
                case (401, IMAPIError.unauthorized): break
                case (403, IMAPIError.businessForbidden): break
                case (502, IMAPIError.server), (200, IMAPIError.server): break
                default: XCTFail("diagnostics changed the existing API error case")
                }
            }
            XCTAssertEqual(transport.count("/api/im/sync"), 2, "one history entry plus one direct contract comparison, without retries")
            XCTAssertEqual(events.count, 1, "the direct comparison is outside the sync failure scope")
        }
    }

    func testSyncDiagnosticsHistoryAuthRecoveryBranchesRetainOriginalCalls() async throws {
        for (refreshable, allowed, expected, refreshCalls) in [
            (false, true, SyncFailureDiagnostic.Recovery.noRefreshAuthority, 0),
            (true, false, .notAllowed, 0),
            // Existing timeout recovery makes one primary attempt and one
            // tenant-IM fallback. Diagnostics must preserve both, not add one.
            (true, true, .attempted, 2)
        ] {
            let transport = SyncDiagnosticHTTPTransport(failures: ["/api/im/sync": IMAPIError.unauthorized("synthetic refusal")])
            let fixture = try makeSyncDiagnosticFixture(transport: transport, refreshable: refreshable)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var events: [SyncFailureDiagnostic] = []
            fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
            fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true, authRecoveryAllowed: allowed)
            try await waitForCondition {
                !events.isEmpty && !fixture.state.conversationStore.hasHistoryLoadingIDs()
                    && transport.refreshCount == refreshCalls
                    && fixture.engine.currentAuthSessionRefreshTask(for: fixture.context.authSessionFence) == nil
            }
            XCTAssertEqual(events, [.init(endpoint: .history, failure: .unauthorized, recovery: expected)])
            XCTAssertEqual(transport.count("/api/im/sync"), 1, "failed refresh must not add a history replay")
            XCTAssertEqual(transport.refreshCount, refreshCalls)
            if refreshCalls == 2 {
                XCTAssertEqual(transport.count("/api/platform/tenants/tenant-1/session/refresh"), 1)
                XCTAssertEqual(transport.count("/api/tenant/auth/session/refresh"), 1)
            }
            XCTAssertTrue(fixture.state.isAuthenticated)
            XCTAssertEqual(fixture.store.deleteAllCount, 0)
        }
    }

    func testSyncDiagnosticsRevokedHistoryRetainsOriginalNoRecoveryBehavior() async throws {
        let transport = SyncDiagnosticHTTPTransport(failures: ["/api/im/sync": IMAPIError.unauthorized("device_revoked")])
        let fixture = try makeSyncDiagnosticFixture(transport: transport, refreshable: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var events: [SyncFailureDiagnostic] = []
        fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
        fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true)
        try await waitForCondition { !events.isEmpty && !fixture.state.isAuthenticated }
        XCTAssertEqual(events, [.init(endpoint: .history, failure: .unauthorized, recovery: .deviceRevoked)])
        XCTAssertFalse(fixture.state.isAuthenticated)
        XCTAssertEqual(transport.refreshCount, 0)
        XCTAssertEqual(transport.count("/api/im/sync"), 1)
    }

    func testSyncDiagnosticsHistoryDeduplicationAndSuccessDoNotChangeAttempts() async throws {
        let transport = SyncDiagnosticHTTPTransport(failures: ["/api/im/sync": URLError(.timedOut)])
        let fixture = try makeSyncDiagnosticFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var events: [SyncFailureDiagnostic] = []
        fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
        for attempt in 1...4 {
            transport.setFailure(attempt == 3 ? nil : URLError(.timedOut), path: "/api/im/sync")
            fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true)
            try await waitForCondition { transport.count("/api/im/sync") == attempt && !fixture.state.conversationStore.hasHistoryLoadingIDs() }
            XCTAssertEqual(transport.count("/api/im/sync"), attempt)
            XCTAssertEqual(events.count, attempt == 4 ? 2 : 1)
        }
        XCTAssertEqual(transport.refreshCount, 0)
    }

    func testSyncDiagnosticsTenantFailureEntrypointsKeepFourResultsAndDeduplicate() async throws {
        let transport = SyncDiagnosticHTTPTransport(failures: ["/api/tenant/me/profile": CancellationError()])
        for (path, status) in [("/api/tenant/context", 401), ("/api/tenant/workspaces", 403), ("/api/tenant/profile", 502)] {
            transport.httpResults[path] = HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"synthetic_failure","message":"SENSITIVE_SENTINEL"}}"#.utf8),
                isHTTPResponse: true, statusCode: status
            )
        }
        let fixture = try makeSyncDiagnosticFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousEnterprise = fixture.state.currentEnterprise
        let previousUser = fixture.state.currentUser
        var events: [SyncFailureDiagnostic] = []
        fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
        for _ in 0..<2 { await fixture.state.refreshTenantProfileForSyncDiagnosticsTesting() }
        XCTAssertEqual(events, [
            .init(endpoint: .tenantContext, failure: .unauthorized, recovery: .notApplicable),
            .init(endpoint: .workspaces, failure: .forbidden, recovery: .notApplicable),
            .init(endpoint: .tenantProfile, failure: .server, recovery: .notApplicable),
            .init(endpoint: .meProfile, failure: .cancelled, recovery: .notApplicable)
        ])
        XCTAssertEqual(fixture.state.currentEnterprise, previousEnterprise)
        XCTAssertEqual(fixture.state.currentUser, previousUser)
        for path in SyncDiagnosticHTTPTransport.tenantPaths { XCTAssertEqual(transport.count(path), 2) }
        XCTAssertEqual(transport.refreshCount, 0, "tenant soft failures must not gain a recovery call")
        XCTAssertTrue(events.allSatisfy { !$0.summary.contains("SENSITIVE_SENTINEL") })
    }

    func testSyncDiagnosticsTenantMixedSuccessPreservesApplyAndRearmsOnlySuccessfulEndpoint() async throws {
        let transport = SyncDiagnosticHTTPTransport(failures: ["/api/tenant/profile": URLError(.timedOut)])
        let fixture = try makeSyncDiagnosticFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var events: [SyncFailureDiagnostic] = []
        fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
        await fixture.state.refreshTenantProfileForSyncDiagnosticsTesting()
        XCTAssertEqual(events, [.init(endpoint: .tenantProfile, failure: .timeout, recovery: .notApplicable)])
        XCTAssertEqual(fixture.state.currentEnterprise.name, "Diagnostics fixture tenant")
        XCTAssertEqual(fixture.state.currentUser.name, "Diagnostics fixture member")
        transport.setFailure(nil, path: "/api/tenant/profile")
        await fixture.state.refreshTenantProfileForSyncDiagnosticsTesting()
        XCTAssertEqual(events.count, 1, "success must not emit a failure record")
        transport.setFailure(URLError(.timedOut), path: "/api/tenant/profile")
        await fixture.state.refreshTenantProfileForSyncDiagnosticsTesting()
        XCTAssertEqual(events.count, 2, "a success ends the deduplication incident")
        for path in SyncDiagnosticHTTPTransport.tenantPaths { XCTAssertEqual(transport.count(path), 3) }
    }

    func testSyncDiagnosticsHistoryActualEntrypointPersistsUnifiedLog() async throws {
        let began = Date()
        let transport = SyncDiagnosticHTTPTransport(failures: ["/api/im/sync": URLError(.timedOut)])
        let fixture = try makeSyncDiagnosticFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var events: [SyncFailureDiagnostic] = []
        fixture.state.syncFailureDiagnosticObserverForTesting = { events.append($0) }
        fixture.state.syncConversationMessagesIfNeeded("uid-1:uid-2", force: true, silent: true)
        try await waitForCondition { !events.isEmpty && !fixture.state.conversationStore.hasHistoryLoadingIDs() }
        let expected = "sync_failure endpoint=IM_HISTORY error=TIMEOUT recovery=NOT_APPLICABLE"
        XCTAssertEqual(events.map(\.summary), [expected])
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        var persisted: [String] = []
        for _ in 0..<20 {
            let entries = try logStore.getEntries(at: logStore.position(date: began.addingTimeInterval(-1)))
            persisted = entries.compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog, log.category == "sync-failure" else { return nil }
                return log.composedMessage
            }
            if persisted.contains(expected) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(persisted.contains(expected), "the production failure entry must reach unified logging, not only the test observer")
        XCTAssertFalse(persisted.contains { $0.contains("SENSITIVE_SENTINEL") || $0.contains("private.invalid") })
    }

    func testSyncDiagnosticsRequestEvidenceRejectsOtherEndpointsAndLateInheritedWork() {
        let evidence = SyncFailureDiagnostic.HTTPObservation(.history)
        evidence.record(path: "/api/tenant/profile", status: 401, code: "SENSITIVE_SENTINEL")
        XCTAssertNil(evidence.failure)
        evidence.record(path: "/api/im/sync", status: 502, code: "SENSITIVE_SENTINEL")
        XCTAssertEqual(evidence.failure, .server)
        evidence.finish()
        // Existing preferred-route probe tasks may inherit task-local values;
        // after the request returns they must not rewrite its failure evidence.
        evidence.record(path: "/api/im/sync", status: 401, code: "SENSITIVE_SENTINEL")
        XCTAssertEqual(evidence.failure, .server)
        let next = SyncFailureDiagnostic.HTTPObservation(.history)
        XCTAssertNil(next.failure, "a later history window must not reuse earlier evidence")
    }

    func makeSyncDiagnosticFixture(transport: HTTPTransport, refreshable: Bool = false) throws ->
        (state: AppState, engine: DefaultSyncEngine, context: IMAPIContext, store: InMemoryProtectedSessionStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-diagnostic-\(UUID().uuidString)")
        let context = refreshable ? makeRefreshableMessageSendContext() : makeContext()
        let store = InMemoryProtectedSessionStore()
        XCTAssertTrue(context.save(sessionStore: store).isCommitted)
        let engine = DefaultSyncEngine()
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            realtimeClient: PostLoginSilentRealtimeTransport(),
            messageStore: AvatarProjectionEmptyMessageStore(),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"), cachesBase: root.appendingPathComponent("caches")),
            remoteSyncEngine: engine, protectedSessionStore: store, apiContextOverride: context
        )
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        state.conversationStore.hydrateCachedConversations([makeDirectConversation(id: "uid-1:uid-2")])
        _ = engine.beginRemoteSnapshotRefresh()
        return (state, engine, context, store, root)
    }

    func testSessionReauthenticationCommitsSameIdentityWithoutPurgingLocalHistory() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let loaded = try await fixture.persistence.activateAndLoad(context: fixture.original, sessionGeneration: 1)
        _ = try await fixture.persistence.persist(
            ticket: loaded.ticket,
            snapshots: [LocalMessageConversationSnapshot(
                conversation: makeDirectConversation(id: "reauth-preserved-conversation"),
                channelID: "reauth-preserved-conversation", channelType: "person", currentActorID: "uid-1"
            )],
            source: .history, revision: 1
        )

        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.loginRequestCount, 1)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertFalse(fixture.state.isSessionReauthenticationPresented)
        XCTAssertNil(fixture.state.sessionReauthenticationError)
        let saved = IMAPIContext.load(sessionStore: store)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(saved))
        XCTAssertFalse(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(saved.imToken, "reauth-im-token")
        XCTAssertEqual(saved.tenantAuthSession?.sessionID, "reauth-tenant-session")
        XCTAssertEqual(try LocalMessageScope(context: saved), try LocalMessageScope(context: fixture.original))
        XCTAssertEqual(store.deleteAllCount, 0)
        let rebound = try await fixture.persistence.activateAndLoad(context: saved, sessionGeneration: 2)
        XCTAssertEqual(rebound.conversations.map(\.id), ["reauth-preserved-conversation"])
        let paths = try MessageDatabasePaths(
            scope: LocalMessageScope(context: fixture.original),
            applicationSupportBase: fixture.root.appendingPathComponent("support"),
            cachesBase: fixture.root.appendingPathComponent("caches")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databaseURL.path))
        XCTAssertFalse(try paths.hasPendingCleanupResidue())
    }

    func testSessionReauthenticationFirstProjectionAdvancesPersistedHighRevisionAndFencesOldTicket() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let originalTicket = try await fixture.persistence.ensureTicket(context: fixture.original, sessionGeneration: 1)
        var conversation = makeDirectConversation(id: "uid-1:uid-2")
        conversation.title = "Before reauthentication"
        conversation.messages = [ChatMessage(
            id: "high-revision-existing", senderId: "uid-2", senderName: "Peer",
            text: "Persisted before reauthentication", time: "09:00", channelSeq: 1,
            isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: [], unreadBy: []
        )]
        conversation.lastMsgSeq = 1
        conversation.messageCoveredThroughSeq = 1
        let originalProjection = LocalMessageConversationSnapshot(
            conversation: conversation, channelID: conversation.id, channelType: "direct", currentActorID: "uid-1"
        )
        // The new AppState's counter is initially zero; the repository already contains
        // a much newer projection from its previous owner/session.
        _ = try await fixture.persistence.persist(
            ticket: originalTicket, snapshots: [originalProjection], source: .localMutation, revision: 50_000
        )
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertTrue(succeeded)

        conversation.title = "First projection after reauthentication"
        conversation.messages.append(ChatMessage(
            id: "first-reauth-projection", senderId: "uid-2", senderName: "Peer",
            text: "First new-session message", time: "09:01", channelSeq: 2,
            isOutgoing: false, status: .sent, kind: .text, reactions: [], readBy: [], unreadBy: []
        ))
        conversation.lastMsgSeq = 2
        conversation.messageCoveredThroughSeq = 2
        fixture.state.conversationStore.hydrateCachedConversations([conversation])
        // One actual AppState write: no repeated writes to catch up to the old revision.
        await fixture.state.persistConversationSnapshotForReauthenticationTesting(conversationID: conversation.id)

        do {
            _ = try await fixture.persistence.persist(
                ticket: originalTicket, snapshots: [originalProjection], source: .localMutation, revision: 90_000
            )
            XCTFail("a higher revision must not let the retired ticket overwrite the new session")
        } catch {
            XCTAssertEqual(error as? LocalMessageDatabaseError, .staleSession)
        }
        let saved = IMAPIContext.load(sessionStore: store)
        let reopened = MessagePersistenceCoordinator(
            applicationSupportBase: fixture.root.appendingPathComponent("support"),
            cachesBase: fixture.root.appendingPathComponent("caches")
        )
        let reloaded = try await reopened.activateAndLoad(context: saved, sessionGeneration: 1)
        let persisted = try XCTUnwrap(reloaded.conversations.first(where: { $0.id == conversation.id }))
        XCTAssertEqual(persisted.title, conversation.title)
        XCTAssertEqual(persisted.messages.map(\.id), ["high-revision-existing", "first-reauth-projection"])
        XCTAssertEqual(persisted.messages.last?.text, "First new-session message")
        let diagnostics = try await reopened.diagnostics(ticket: reloaded.ticket)
        XCTAssertEqual(diagnostics.conversationCount, 1)
        XCTAssertEqual(diagnostics.messageCount, 2)
    }

    func testSessionReauthenticationDirectLoginCommitsNewTenantIMAndRealtimeRoutes() async throws {
        let oldRoutes = sessionReauthenticationRoutes(revision: 40, suffix: "old")
        let newRoutes = sessionReauthenticationRoutes(revision: 41, suffix: "new")
        let transport = RememberedLoginGateHTTPTransport(
            loginResult: try sessionReauthenticationRouteLoginResult(routes: newRoutes, platformOnly: false)
        )
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        XCTAssertEqual(fixture.client.activateRuntimeRoutesForTesting(oldRoutes), .applied)
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertTrue(succeeded)
        let saved = IMAPIContext.load(sessionStore: store)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(saved))
        XCTAssertEqual(fixture.client.activeRuntimeBase(service: .tenantAPI, appID: saved.appID, tenantID: saved.tenantID)?.absoluteString,
                       "https://tenant-new.example.test")
        XCTAssertEqual(fixture.client.activeRuntimeBase(service: .imAPI, appID: saved.appID, tenantID: saved.tenantID)?.absoluteString,
                       "https://im-new.example.test")
        XCTAssertEqual(fixture.client.webSocketURL(context: saved)?.absoluteString, "wss://ws-new.example.test")
        XCTAssertEqual(fixture.routes.record(appID: saved.appID, tenantID: saved.tenantID).current, newRoutes)
    }

    func testSessionReauthenticationPlatformCandidateFailureOrCancellationKeepsOriginalRoutes() async throws {
        for failure in ["identity", "protected-save", "cancel"] {
            let oldRoutes = sessionReauthenticationRoutes(revision: 40, suffix: "old")
            let newRoutes = sessionReauthenticationRoutes(revision: 41, suffix: "new")
            let entry = try tenantPlatformEntrySuccess()
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: entry.data) as? [String: Any])
            if failure == "identity" {
                var data = try XCTUnwrap(envelope["data"] as? [String: Any])
                data["im_uid"] = "wrong-entry-user"
                envelope["data"] = data
            }
            let transport = SessionReauthenticationRouteGateTransport(responses: [
                "/api/platform/apps/current-policy": activeAppPolicyResult(),
                "/api/platform/captcha/slide/config": HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"enabled":false,"available":false,"required":false,"provider":"self_hosted_slide","surface":"ios","scene":"im_user_login"}}"#.utf8),
                    isHTTPResponse: true, statusCode: 200
                ),
                "/api/platform/auth/im-login": try sessionReauthenticationRouteLoginResult(routes: newRoutes, platformOnly: true),
                "/api/platform/me/tenants/tenant-1/enter": try tenantEnterSuccess(entryTicket: "candidate-entry", routes: newRoutes),
                "/api/tenant/auth/platform-entry": HTTPTransportResult(
                    data: try JSONSerialization.data(withJSONObject: envelope), isHTTPResponse: true, statusCode: 200
                )
            ])
            let store = InMemoryProtectedSessionStore(failingWriteNumbers: failure == "protected-save" ? [2] : [])
            let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
            defer {
                transport.releaseEntry()
                // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
            }
            XCTAssertEqual(fixture.client.activateRuntimeRoutesForTesting(oldRoutes), .applied)
            let attempt = Task { @MainActor in
                await fixture.state.reauthenticateCurrentSession(
                    identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
                )
            }
            try await waitForCondition { transport.entryRequestCount == 1 }
            XCTAssertEqual(transport.entryRequestCount, 1, failure)
            XCTAssertEqual(transport.entryRequestURL?.host, "tenant-new.example.test", failure)
            // Enter has returned a valid new route, but the candidate is not committed.
            XCTAssertEqual(fixture.client.activeRuntimeBase(service: .tenantAPI, appID: fixture.original.appID, tenantID: fixture.original.tenantID)?.absoluteString,
                           "https://tenant-old.example.test", failure)
            XCTAssertEqual(fixture.routes.record(appID: fixture.original.appID, tenantID: fixture.original.tenantID).current, oldRoutes, failure)
            if failure == "cancel" { fixture.state.cancelSessionReauthentication() }
            transport.releaseEntry()
            let succeeded = await attempt.value
            XCTAssertFalse(succeeded, failure)
            XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original), failure)
            XCTAssertEqual(fixture.client.activeRuntimeBase(service: .tenantAPI, appID: fixture.original.appID, tenantID: fixture.original.tenantID)?.absoluteString,
                           "https://tenant-old.example.test", failure)
            XCTAssertEqual(fixture.client.activeRuntimeBase(service: .imAPI, appID: fixture.original.appID, tenantID: fixture.original.tenantID)?.absoluteString,
                           "https://im-old.example.test", failure)
            XCTAssertEqual(fixture.client.webSocketURL(context: fixture.original)?.absoluteString, "wss://ws-old.example.test", failure)
            XCTAssertEqual(fixture.routes.record(appID: fixture.original.appID, tenantID: fixture.original.tenantID).current, oldRoutes, failure)
            XCTAssertEqual(store.deleteAllCount, 0, failure)
        }
    }

    func testSessionReauthenticationRouteCandidateCannotReviveNewerRevocation() async throws {
        let oldRoutes = sessionReauthenticationRoutes(revision: 40, suffix: "old")
        let candidateRoutes = sessionReauthenticationRoutes(revision: 41, suffix: "new")
        let transport = FakeHTTPTransport(results: [try tenantEnterSuccess(entryTicket: "candidate-entry", routes: candidateRoutes)])
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        XCTAssertEqual(fixture.client.activateRuntimeRoutesForTesting(oldRoutes), .applied)
        let candidate = try await fixture.client.enterTenantCandidate(
            tenantID: "tenant-1", platformToken: "reauth-platform-token", appID: fixture.original.appID, deviceID: fixture.original.deviceID
        )
        XCTAssertEqual(fixture.routes.record(appID: fixture.original.appID, tenantID: "tenant-1").current, oldRoutes)
        XCTAssertEqual(fixture.routes.applyRevocation(
            environment: "synthetic-test", appID: fixture.original.appID, tenantID: "tenant-1", revision: 42,
            publicationID: "synthetic-revocation", profileFingerprint: String(repeating: "a", count: 64),
            status: "tombstone", keysetRevision: 1
        ), .revoked)
        XCTAssertThrowsError(try fixture.client.commitTenantRuntimeRoutes(
            candidate.runtimeConfig.runtimeRouteSnapshot, appID: fixture.original.appID, tenantID: "tenant-1"
        ))
        let persisted = fixture.routes.record(appID: fixture.original.appID, tenantID: "tenant-1")
        XCTAssertNil(persisted.current)
        XCTAssertEqual(persisted.publicationWatermark?.revision, 42)
        XCTAssertEqual(persisted.publicationWatermark?.status, "tombstone")
        XCTAssertNil(fixture.client.activeRuntimeBase(service: .tenantAPI, appID: fixture.original.appID, tenantID: "tenant-1"))
        XCTAssertNil(fixture.client.activeRuntimeBase(service: .imAPI, appID: fixture.original.appID, tenantID: "tenant-1"))
        XCTAssertNil(fixture.client.webSocketURL(context: fixture.original))
        let restartedTransport = FakeHTTPTransport(results: [])
        let restartedClient = makeClient(transport: restartedTransport, runtimeRouteStore: fixture.routes)
        do {
            _ = try await restartedClient.tenantContext(context: fixture.original)
            XCTFail("persisted revocation must stop a restarted client's tenant request")
        } catch { }
        do {
            _ = try await restartedClient.refreshTenantIMSession(context: fixture.original)
            XCTFail("persisted revocation must stop a restarted client's refresh request")
        } catch { }
        XCTAssertTrue(restartedTransport.requests().isEmpty)
    }

    func testSessionReauthenticationFailedRoutePersistenceRestoresExactRecordAndActiveRoutes() throws {
        let suite = "SessionReauthenticationRoutes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SessionReauthenticationFailingRouteDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let routeStore = IMRuntimeRouteStore(defaults: defaults)
        let client = makeClient(transport: FakeHTTPTransport(results: []), runtimeRouteStore: routeStore)
        let oldRoutes = sessionReauthenticationRoutes(revision: 40, suffix: "old")
        let candidate = sessionReauthenticationRoutes(revision: 41, suffix: "new")
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(oldRoutes), .applied)
        let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("wxt.runtime.routes.v2.") })
        let originalBytes = try XCTUnwrap(defaults.data(forKey: key))
        defaults.failNextSynchronization()
        XCTAssertThrowsError(try client.commitTenantRuntimeRoutes(candidate, appID: oldRoutes.appID, tenantID: "tenant-1"))
        XCTAssertEqual(defaults.data(forKey: key), originalBytes)
        XCTAssertEqual(routeStore.record(appID: oldRoutes.appID, tenantID: "tenant-1").current, oldRoutes)
        XCTAssertEqual(client.activeRuntimeBase(service: .tenantAPI, appID: oldRoutes.appID, tenantID: "tenant-1")?.absoluteString,
                       "https://tenant-old.example.test")
        XCTAssertEqual(client.activeRuntimeBase(service: .imAPI, appID: oldRoutes.appID, tenantID: "tenant-1")?.absoluteString,
                       "https://im-old.example.test")
        XCTAssertEqual(client.webSocketURL(context: makeRefreshableMessageSendContext())?.absoluteString, "wss://ws-old.example.test")
    }

    func testSessionReauthenticationRetiredPresignAndPUTCannotAdvanceOrClearImageAndVoiceReplacement() async throws {
        for kind in [MessageKind.image, .voice] {
            for phase in ["presign", "put"] {
                for lateFailure in [false, true] {
                    try await assertSessionReauthenticationRetiresUpload(kind: kind, phase: phase, lateFailure: lateFailure)
                }
            }
            try await assertSessionReauthenticationRetiresUpload(kind: kind, phase: "put", lateFailure: false, retireDurableTicketOnly: true)
        }
    }

    func testSessionReauthenticationRetiredSendCannotApplyLateImageOrVoiceSuccessOrFailure() async throws {
        for kind in [MessageKind.image, .voice] {
            for lateFailure in [false, true] {
                try await assertSessionReauthenticationRetiresUpload(kind: kind, phase: "send", lateFailure: lateFailure)
            }
        }
    }

    func testSessionReauthenticationWrongPasswordPreservesOriginalAuthorityAndStore() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: HTTPTransportResult(
            data: Data(#"{"ok":false,"error":{"code":"invalid_credentials","message":"SyntheticSecretMustNotAppear"}}"#.utf8),
            isHTTPResponse: true, statusCode: 401
        ))
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")

        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticBadPassword", enterpriseCode: ""
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(transport.loginRequestCount, 1)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertTrue(fixture.state.isSessionReauthenticationPresented)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2"), originalSnapshot)
        XCTAssertEqual(store.writeAttemptCount, 1)
        XCTAssertEqual(store.deleteAllCount, 0)
        XCTAssertNotNil(fixture.state.sessionReauthenticationError)
        XCTAssertFalse(fixture.state.sessionReauthenticationError?.contains("SyntheticSecretMustNotAppear") ?? true)
    }

    func testSessionReauthenticationTransportFailurePreservesOriginalAuthorityAndStore() async throws {
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(
            transport: FailingHTTPTransport(error: URLError(.notConnectedToInternet)), store: store
        )
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2"), originalSnapshot)
        XCTAssertEqual(store.writeAttemptCount, 1)
        XCTAssertEqual(store.deleteAllCount, 0)
        XCTAssertNotNil(fixture.state.sessionReauthenticationError)
    }

    func testSessionReauthenticationProtectedSaveFailureDoesNotInstallCandidate() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore(failingWriteNumbers: [2])
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertFalse(succeeded)
        XCTAssertEqual(transport.loginRequestCount, 1)
        XCTAssertGreaterThanOrEqual(store.writeAttemptCount, 2)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertTrue(fixture.state.isSessionReauthenticationPresented)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")).utf8)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(originalSnapshot).utf8)) as? NSDictionary
        )
        XCTAssertEqual(store.deleteAllCount, 0)
        XCTAssertNotNil(fixture.state.sessionReauthenticationError)
    }

    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
    func testSessionReauthenticationCancelledAttemptCannotCommitAfterSheetReopens() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        defer {
            transport.releaseLoginResponse()
            // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        }
        let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
        let oldPresentation = try XCTUnwrap(fixture.state.sessionReauthenticationStore.snapshot.presentationID)
        let attempt = Task { @MainActor in
            await fixture.state.reauthenticateCurrentSession(
                identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
            )
        }
        try await waitForCondition { transport.loginRequestCount == 1 }
        XCTAssertEqual(transport.loginRequestCount, 1)
        fixture.state.cancelSessionReauthentication()
        XCTAssertFalse(fixture.state.isSessionReauthenticationPresented)
        fixture.state.beginSessionReauthentication()
        XCTAssertTrue(fixture.state.isSessionReauthenticationPresented)
        let replacement = try XCTUnwrap(fixture.state.sessionReauthenticationStore.snapshot.presentationID)
        XCTAssertNotEqual(oldPresentation, replacement)
        fixture.state.cancelSessionReauthentication(presentationID: oldPresentation)
        XCTAssertEqual(fixture.state.sessionReauthenticationStore.snapshot.presentationID, replacement)
        transport.releaseLoginResponse()
        let succeeded = await attempt.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertTrue(fixture.state.isSessionReauthenticationPresented)
        let obsoleteSubmission = await fixture.state.reauthenticateCurrentSession(
            identifier: "", password: "", enterpriseCode: "", presentationID: oldPresentation
        )
        XCTAssertFalse(obsoleteSubmission)
        XCTAssertNil(fixture.state.sessionReauthenticationError)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2"), originalSnapshot)
        XCTAssertEqual(store.writeAttemptCount, 1)
        XCTAssertEqual(store.deleteAllCount, 0)
        fixture.state.cancelSessionReauthentication()
    }

    func testSessionReauthenticationFormErrorDoesNotInvalidateWorkbenchPresentation() async {
        let state = AppState(api: makeClient(transport: FakeHTTPTransport(results: [])), apiContextOverride: makeContext())
        state.setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        var visibility: [Bool] = []
        var errors: [String?] = []
        var appUpdates = 0
        let store = state.sessionReauthenticationStore
        let subscriptions = [
            store.updates(\.isPresented).sink { visibility.append($0) },
            store.updates(\.errorMessage).sink { errors.append($0) },
            state.objectWillChange.sink { appUpdates += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        state.beginSessionReauthentication()
        let result = await state.reauthenticateCurrentSession(identifier: "", password: "", enterpriseCode: "")
        XCTAssertFalse(result)
        XCTAssertEqual(visibility, [false, true])
        XCTAssertEqual(errors, [nil, "请输入当前账号和密码"])
        state.cancelSessionReauthentication()
        XCTAssertEqual(visibility, [false, true, false])
        XCTAssertEqual(errors, [nil, "请输入当前账号和密码", nil])
        XCTAssertEqual(appUpdates, 0)
    }
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END

    func testSessionReauthenticationProtectedReadbackFailureRestoresOriginalSnapshot() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        transport.releaseLoginResponse()
        let store = InMemoryProtectedSessionStore(unreadableAfterWriteNumbers: [2])
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let originalSnapshot = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.writeAttemptCount, 3)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")).utf8)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(originalSnapshot).utf8)) as? NSDictionary
        )
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertNotNil(fixture.state.sessionReauthenticationError)
        XCTAssertEqual(store.deleteAllCount, 0)
    }

    func testSessionReauthenticationLateResponseCannotCommitAcrossAccountABA() async throws {
        let transport = RememberedLoginGateHTTPTransport(loginResult: try sessionReauthenticationLoginResult())
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        defer {
            transport.releaseLoginResponse()
            // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        }
        let attempt = Task { @MainActor in
            await fixture.state.reauthenticateCurrentSession(
                identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
            )
        }
        try await waitForCondition { transport.loginRequestCount == 1 }
        XCTAssertEqual(transport.loginRequestCount, 1)
        var other = fixture.original
        other.accountID = "other-account"
        other.imUID = "other-user"
        fixture.state.overrideAPIContextForTesting(other)
        fixture.state.overrideAPIContextForTesting(fixture.original)
        XCTAssertFalse(fixture.state.isSessionReauthenticationPresented)
        fixture.state.beginSessionReauthentication()
        let snapshotBeforeLateResponse = store.string(forKey: "im2.ios.protectedSessionSnapshot.v2")
        let writesBeforeLateResponse = store.writeAttemptCount
        transport.releaseLoginResponse()
        let succeeded = await attempt.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(store.string(forKey: "im2.ios.protectedSessionSnapshot.v2"), snapshotBeforeLateResponse)
        XCTAssertEqual(store.writeAttemptCount, writesBeforeLateResponse)
        XCTAssertNil(fixture.state.sessionReauthenticationError)
        fixture.state.cancelSessionReauthentication()
    }

    func testSessionReauthenticationMissingRequiredEnterpriseCodeDoesNotSendLogin() async throws {
        let transport = FakeHTTPTransport(results: [HTTPTransportResult(
            data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","status":"active","enterprise_code_first":true}}"#.utf8),
            isHTTPResponse: true, statusCode: 200
        )])
        let store = InMemoryProtectedSessionStore()
        let fixture = try makeSessionReauthenticationFixture(transport: transport, store: store)
        // WDT_IOS1_REAUTH_FIXTURE_BACKING_LIFETIME_20261111: Keep this factory-owned UUID backing while original tasks/pools may retain SQLite.
        let succeeded = await fixture.state.reauthenticateCurrentSession(
            identifier: "member1", password: "SyntheticPass123!", enterpriseCode: ""
        )
        XCTAssertFalse(succeeded)
        XCTAssertFalse(transport.requests().contains { $0.url?.path == "/api/platform/auth/im-login" })
        XCTAssertTrue(fixture.state.sessionReauthenticationMatchesContextForTesting(fixture.original))
        XCTAssertEqual(store.writeAttemptCount, 1)
        XCTAssertTrue(fixture.state.isAuthenticated)
        XCTAssertNotNil(fixture.state.sessionReauthenticationError)
    }
}
