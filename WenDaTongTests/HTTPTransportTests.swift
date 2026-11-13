import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Combine
import XCTest
import OSLog
@testable import WenDaTong

@MainActor
final class HTTPTransportTests: XCTestCase {
    // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
    func testBackgroundResponseDecodingIsLimitedToChatReadEndpoints() {
        for path in ["/api/im/sync", "/api/im/message-receipts/sync", "/api/im/message-extras/sync"] {
            XCTAssertTrue(IMAPIClient.shouldDecodeChatResponseOffMain(path: path))
            XCTAssertTrue(IMAPIClient.shouldDecodeChatResponseOffMain(path: path + "?limit=20"))
        }
        for path in ["", "/api/im/read-ack", "/api/im/messages/send", "/api/rtc/calls", "/api/platform/auth/login", "/api/im/sync-other"] {
            XCTAssertFalse(IMAPIClient.shouldDecodeChatResponseOffMain(path: path))
        }
    }

    func testChatHistoryResponseDecodesOffMainWithUnchangedCodecOrderAndInput() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data("codec-response".utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let codec = RecordingHTTPWireCodec()
        let client = makeClient(transport: transport, wireCodec: codec)
        let page = try await client.syncMessages(
            context: makeContext(), channelID: "g1", channelType: "group", afterSeq: 7, beforeSeq: nil, limit: 20
        )
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(codec.decodedTypeNames(), ["APIErrorEnvelope", "APILoginSecurityEnvelope", "APIEnvelope<RemoteMessageSyncResult>"])
        XCTAssertEqual(codec.decodedInputTexts(), Array(repeating: "codec-response", count: 3))
        XCTAssertEqual(codec.decodedOnMainThread(), [false, false, false])
        XCTAssertEqual(transport.requests().count, 1)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.path, "/api/im/sync")
        let body = try XCTUnwrap(codec.encodedObjects().first)
        XCTAssertEqual(body["after_seq"] as? Int64, 7)
        XCTAssertEqual(body["limit"] as? Int, 20)
    }

    func testBackgroundResponseDecodingPreservesSuccessErrorAndMalformedEnvelopes() async {
        let client = makeClient(transport: FakeHTTPTransport(results: []))
        let samples = [
            #"{"ok":true,"data":{"items":[],"has_more":true,"next_after_seq":42,"history_visible_from_seq":7,"history_limited":true}}"#,
            #"{"ok":false,"error":{"code":"not_friends","message":"Permission required","retry_after_seconds":12}}"#,
            #"{"code":"account_locked","message":"Locked","data":{}}"#,
            #"{"ok":true,"data":{"items":"invalid"}}"#,
            "invalid-json"
        ]
        for sample in samples {
            let data = Data(sample.utf8)
            let before: IMAPIClient.DecodedAPIResponse<RemoteMessageSyncResult> = client.decodeAPIResponse(from: data)
            let after: IMAPIClient.DecodedAPIResponse<RemoteMessageSyncResult> = await client.decodeAPIResponseOffMain(from: data)
            XCTAssertEqual(before.envelope?.ok, after.envelope?.ok)
            XCTAssertEqual(before.envelope?.data?.items.count, after.envelope?.data?.items.count)
            XCTAssertEqual(before.envelope?.data?.hasMore, after.envelope?.data?.hasMore)
            XCTAssertEqual(before.envelope?.data?.nextAfterSeq, after.envelope?.data?.nextAfterSeq)
            XCTAssertEqual(before.envelope?.data?.historyVisibleFromSeq, after.envelope?.data?.historyVisibleFromSeq)
            XCTAssertEqual(before.envelope?.data?.historyLimited, after.envelope?.data?.historyLimited)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.code, after.errorEnvelope?.resolvedError?.code)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.message, after.errorEnvelope?.resolvedError?.message)
            XCTAssertEqual(before.errorEnvelope?.resolvedError?.retryAfterSeconds, after.errorEnvelope?.resolvedError?.retryAfterSeconds)
            XCTAssertEqual(before.loginSecurityEnvelope?.resolvedError?.code, after.loginSecurityEnvelope?.resolvedError?.code)
            XCTAssertEqual(before.envelope?.error?.code, after.envelope?.error?.code)
        }
    }
    // WDT_CHAT_RESOURCE_PERF_20261023_END

    func configureOrdinaryActionPolicyForExistingFlowTest(_ state: AppState) {
        state.setCurrentEnterprise(Enterprise(id: "tenant-1", name: "Fixture", code: "T1", role: "member",
            status: "正常", memberCount: 1, isDefault: false, accentHex: 0)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.rules.allowMemberBlacklist = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.rules.allowMemberFriendDelete = true // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    }

    func testContractDisabledOrUnknownRelationshipActionsNeverMutateOrSendRequests() {
        let transport = FakeHTTPTransport(results: [])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        configureOrdinaryActionPolicyForExistingFlowTest(state)
        state.tenantInteractionStore.snapshot.rules.allowMemberBlacklist = false // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        state.tenantInteractionStore.snapshot.rules.allowMemberFriendDelete = nil // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        let peer = makeUser(id: "uid-2", name: "Peer")
        state.contacts = [peer]
        state.blockContact(peer)
        state.deleteContact(peer)
        XCTAssertEqual(state.contacts.map(\.id), [peer.id])
        XCTAssertTrue(state.blacklist.isEmpty)
        XCTAssertTrue(transport.requests().isEmpty)
    }

    func testContractGroupFriendSettingSendsOnlySettingAndExpectedRevision() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"group_id":"g1"}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"group":{"group_id":"g1"},"my_role":"admin","settings":{"web_member_friend_apply_enabled":false,"group_revision":8}}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ])
        let response = try await makeClient(transport: transport).updateGroupMemberFriendApply(
            context: makeContext(), groupID: "g1", enabled: false, expectedGroupRevision: 7)
        XCTAssertFalse(response.memberFriendApplyEnabled)
        let requests = transport.requests()
        XCTAssertEqual(requests.first?.url?.path, "/api/tenant/groups/g1/settings")
        XCTAssertEqual(requests.first?.httpMethod, "PATCH")
        let body = try requestJSONObject(XCTUnwrap(requests.first))
        XCTAssertEqual(body["expected_group_revision"] as? Int, 7)
        XCTAssertEqual(body["web_member_friend_apply_enabled"] as? Bool, false)
        XCTAssertEqual(Set(body.keys), ["expected_group_revision", "web_member_friend_apply_enabled"])
    }

    @MainActor
    func testConversationCredentialRotationDiscardsStalePageAndRestartsWithFreshToken() async throws {
        var current = makeProtectedSessionContext()
        var authority = ConversationPageAuthority(context: current)
        var tokens: [String] = []
        var cursors: [String] = []
        var accepted: [String] = []
        var restarts = 0
        let version = try await ConversationPageLoader.load(request: { cursor in
            cursors.append(cursor)
            tokens.append(authority.context.imToken ?? "")
            if tokens.count == 1 {
                current.imToken = "synthetic-rotated-token"
                current.credentialRevision += 1
                return RemoteConversationPage(conversations: [], hasMore: false, nextCursor: nil, snapshotID: "stale", snapshotVersion: 1)
            }
            return RemoteConversationPage(conversations: [], hasMore: false, nextCursor: nil, snapshotID: "fresh", snapshotVersion: 2)
        }, validate: { try authority.validate(current: current) }, onPage: { accepted.append($0.snapshotID ?? "") }, onRestart: { restarts += 1 })
        XCTAssertEqual(tokens, ["synthetic-im-token", "synthetic-rotated-token"])
        XCTAssertEqual(cursors, ["", ""])
        XCTAssertEqual(accepted, ["fresh"])
        XCTAssertEqual(version, 2)
        XCTAssertEqual(restarts, 1)
    }

    @MainActor
    func testConversationCredentialRestartPreservesConcurrentLocalChanges() async throws {
        var current = makeProtectedSessionContext()
        var authority = ConversationPageAuthority(context: current)
        var rows = ["pin": 0, "old": 0]
        var presentation = ConversationSnapshotPresentation(current: rows)
        var requests: [String] = []
        _ = try await ConversationPageLoader.load(request: { cursor in
            requests.append(cursor)
            if requests.count == 2 {
                rows["pin"] = 9
                presentation.observe(current: rows)
                current.credentialRevision += 1
                return RemoteConversationPage(conversations: [], hasMore: false, nextCursor: nil, snapshotID: "old", snapshotVersion: 1)
            }
            return RemoteConversationPage(conversations: [], hasMore: requests.count == 1, nextCursor: requests.count == 1 ? "old-cursor" : nil,
                snapshotID: requests.count == 1 ? "old" : "new", snapshotVersion: requests.count == 1 ? 1 : 2)
        }, validate: { try authority.validate(current: current) }, onPage: { page in
            for id in ["pin", page.snapshotID == "old" ? "speculative" : "fresh"] {
                if presentation.accept(id, current: rows) {
                    let previous = rows // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110
                    rows[id] = 1
                    presentation.didApply([id], current: rows, previous: previous) // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110
                }
            }
        }, onRestart: { rows = presentation.restarting(current: rows) })
        rows = presentation.completing(current: rows)
        XCTAssertEqual(requests, ["", "old-cursor", ""])
        XCTAssertEqual(rows, ["pin": 9, "fresh": 1])
    }

    func testConversationCredentialRestartRejectsChangedIdentityAndUnadvancedFence() throws {
        let original = makeProtectedSessionContext()
        for mutation in ["account", "tenant", "uid", "device", "app", "epoch", "family", "session", "version", "missing"] {
            var current = original
            current.credentialRevision += 1
            switch mutation {
            case "account": current.accountID = "other"
            case "tenant": current.tenantID = "other"
            case "uid": current.imUID = "other"
            case "device": current.deviceID = "other"
            case "app": current.appID = "other"
            case "epoch": current.sessionEpoch = "other"
            case "family": current.tenantAuthSession = nil
            case "session": current.tenantAuthSession = IMStoredAuthSession(sessionID: "other", refreshToken: "synthetic-other", tokenType: "im")
            case "version":
                current.credentialRevision = original.credentialRevision
                current.tenantAuthSession = IMStoredAuthSession(sessionID: "tenant-session", refreshToken: "synthetic-tenant-refresh", tokenType: "im", authVersion: 9)
            default: current.imToken = nil
            }
            var authority = ConversationPageAuthority(context: original)
            XCTAssertThrowsError(try authority.validate(current: current), mutation) { XCTAssertTrue($0 is CancellationError, mutation) }
            XCTAssertEqual(authority.context.authSessionFence, original.authSessionFence)
        }
        var authority = ConversationPageAuthority(context: original)
        XCTAssertNoThrow(try authority.validate(current: original))
    }

    @MainActor
    func testConversationCredentialRestartSharesOneRestartBudgetWithCursorExpiry() async throws {
        for firstExpiry in [false, true] {
            var current = makeProtectedSessionContext()
            var authority = ConversationPageAuthority(context: current)
            var requests = 0
            var restarts = 0
            do {
                _ = try await ConversationPageLoader.load(request: { _ in
                    requests += 1
                    if firstExpiry && requests == 1 {
                        throw ConversationPageFailure(statusCode: 410, code: "conversation_page_cursor_expired")
                    }
                    current.credentialRevision += 1
                    return RemoteConversationPage(conversations: [], hasMore: false, nextCursor: nil, snapshotID: "s", snapshotVersion: 1)
                }, validate: { try authority.validate(current: current) }, onPage: { _ in XCTFail("A stale page must never publish") }, onRestart: { restarts += 1 })
                XCTFail("A second rotation must not loop or report success")
            } catch let failure as ConversationPageFailure {
                XCTAssertEqual(failure.code, "conversation_page_credentials_advanced")
            }
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(restarts, 1)
        }
    }

    @MainActor
    func testConversationCredentialRestartDoesNotSwallowTaskCancellation() async throws {
        let original = makeProtectedSessionContext()
        var current = original
        current.credentialRevision += 1
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var authority = ConversationPageAuthority(context: original)
            do {
                try authority.validate(current: current)
                XCTFail("Cancellation must remain terminal")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(authority.context.authSessionFence, original.authSessionFence)
        }
        await task.value
    }

    func testPrimarySyncDiagnosticBindsActualPrefixedRequestPath() async throws {
        for endpoint in [SyncFailureDiagnostic.Endpoint.conversationPage, .conversationSync] {
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(#"{"ok":true,"data":{"conversations":"MALFORMED","has_more":false}}"#.utf8), isHTTPResponse: true, statusCode: 200)
            ])
            let client: any IMAPIProtocol = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            var context = makeContext()
            context.imAPIBaseURL = "https://im.example.test/gateway"
            let diagnostic = SyncFailureDiagnostic.HTTPObservation(endpoint)
            do {
                try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
                    defer { diagnostic.finish() }
                    try await diagnostic.perform {
                        if endpoint == .conversationPage {
                            _ = try await client.conversationPage(context: context, cursor: "")
                        } else {
                            _ = try await client.syncConversations(context: context, version: 0)
                        }
                    }
                }
                XCTFail("Malformed HTTP200 data must fail decoding")
            } catch {
                XCTAssertEqual(diagnostic.result(error: error).failure, .decode)
                XCTAssertEqual(diagnostic.result(error: error).responseStatus, 200)
            }
            let suffix = endpoint == .conversationPage ? "page" : "sync"
            XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/gateway/api/im/conversations/\(suffix)"])
        }
    }

    func testPrimarySyncDiagnosticPreservesDecodeFailureAfterHTTP200() {
        let observation = SyncFailureDiagnostic.HTTPObservation(.conversationPage)
        observation.recordPrimaryResponse(path: "/api/im/conversations/page", status: 200, fingerprint: "hash:1234abcd")
        observation.record(path: "/api/im/conversations/page", status: 200, code: "json_decode_failed")
        let result = observation.result(error: IMAPIError.server("PRIVATE_RESPONSE_BODY"))
        XCTAssertEqual(result.failure, .decode)
        XCTAssertEqual(result.responseStatus, 200)
        XCTAssertEqual(result.requestFingerprint, "hash:1234abcd")
        XCTAssertFalse(result.summary.contains("PRIVATE_RESPONSE_BODY"))
        XCTAssertFalse(result.summary.contains("SUCCESS"))
    }

    func testPrimarySyncDiagnosticRejectsUnscopedMetadataAndLateMutation() {
        let observation = SyncFailureDiagnostic.HTTPObservation(.conversationPage)
        observation.recordPrimaryResponse(path: "/api/im/conversations/sync", status: 403, fingerprint: "hash:1234abcd")
        XCTAssertNil(observation.result(error: nil).responseStatus)
        observation.recordPrimaryResponse(path: "/api/im/conversations/page", status: 200, fingerprint: "PRIVATE_TRACE_TOKEN")
        XCTAssertNil(observation.result(error: nil).requestFingerprint)
        observation.finish()
        observation.recordPrimaryResponse(path: "/api/im/conversations/page", status: 500, fingerprint: "hash:1234abcd")
        XCTAssertEqual(observation.result(error: nil).responseStatus, 200)
        XCTAssertNil(observation.result(error: nil).requestFingerprint)
        XCTAssertFalse(observation.result(error: nil).summary.contains("PRIVATE_TRACE_TOKEN"))
    }

    func testPrimarySyncDiagnosticSeparatesPageValidationAndCancellation() {
        for (code, expected) in [
            ("invalid_snapshot", SyncFailureDiagnostic.Failure.invalidSnapshot),
            ("invalid_cursor", .invalidCursor),
            ("conversation_page_cursor_expired", .cursorExpired)
        ] {
            XCTAssertEqual(SyncFailureDiagnostic.Failure(error: ConversationPageFailure(statusCode: 0, code: code)), expected)
        }
        XCTAssertEqual(SyncFailureDiagnostic.Failure(error: CancellationError()), .cancelled)
        XCTAssertEqual(SyncFailureDiagnostic.Failure(error: ConversationPageFailure(statusCode: 503, code: "PRIVATE_CODE")), .server)
        XCTAssertEqual(SyncFailureDiagnostic.PrimaryOutcome.skipped.rawValue, "SKIPPED")
        XCTAssertNotEqual(SyncFailureDiagnostic.PrimaryOutcome.skipped, .incomplete)
    }

    func testConversationPageUsesExistingScoped100ItemEndpointAndPreserves410() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"conversations":[],"has_more":false,"snapshot_id":"s"}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"conversation_page_cursor_expired","message":"expired"}}"#.utf8), isHTTPResponse: true, statusCode: 410)
        ])
        let client: any IMAPIProtocol = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
        let context = makeContext()
        _ = try await client.conversationPage(context: context, cursor: "")
        do {
            _ = try await client.conversationPage(context: context, cursor: "next")
            XCTFail("Expired cursor must reach the bounded restart owner")
        } catch let error as ConversationPageFailure {
            XCTAssertEqual(error.statusCode, 410)
            XCTAssertEqual(error.code, "conversation_page_cursor_expired")
        }
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.url?.path, "/api/im/conversations/page")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["limit"] as? Int, 100)
            XCTAssertEqual(body["tenant_id"] as? String, context.tenantID)
            XCTAssertEqual(body["im_uid"] as? String, context.imUID)
            XCTAssertEqual(body["device_id"] as? String, context.deviceID)
            XCTAssertEqual(body["cursor"] as? String, index == 0 ? nil : "next")
        }
    }

    func testFriendAcceptanceDiagnosticKeepsHTTPCodeAndTraceWithoutPrivateValues() {
        let diagnostic = FriendAcceptanceDiagnostic(context: makeContext(), applicationID: "PRIVATE_APPLICATION", attemptID: "attempt-one")
        let body = Data(#"{"ok":false,"error":{"code":"internal_database_error","message":"PRIVATE_MESSAGE token=SECRET"},"trace_id":"PRIVATE_TRACE","data":{"proof":"SECRET"}}"#.utf8)
        let event = diagnostic.summary(.response, endpoint: URL(string: "https://tenant.example.test/path?token=SECRET"),
                                       status: 503, responseData: body, requestID: "PRIVATE_REQUEST")
        XCTAssertTrue(event.contains("stage=response"))
        XCTAssertTrue(event.contains("status=503 envelope_ok=FALSE code=internal_database_error"))
        XCTAssertTrue(event.contains("request_sha12=\(FriendAcceptanceDiagnostic.fingerprint("PRIVATE_REQUEST"))"))
        XCTAssertTrue(event.contains("trace_sha12=\(FriendAcceptanceDiagnostic.fingerprint("PRIVATE_TRACE"))"))
        for secret in ["PRIVATE_APPLICATION", "PRIVATE_MESSAGE", "PRIVATE_TRACE", "PRIVATE_REQUEST", "SECRET", "tenant.example.test"] {
            XCTAssertFalse(event.contains(secret))
        }
        XCTAssertEqual(FriendAcceptanceDiagnostic.fingerprint("abc"), "ba7816bf8f01")
        XCTAssertEqual(FriendAcceptanceDiagnostic.fingerprint(nil), "NONE")
    }

    func testFriendAcceptanceDiagnosticDoesNotInventCodesForHTMLOrExposeUnknownCodes() {
        let diagnostic = FriendAcceptanceDiagnostic(context: makeContext(), applicationID: "application", attemptID: "attempt-two")
        let html = diagnostic.summary(.response, status: 503, responseData: Data("PRIVATE_HTML".utf8))
        XCTAssertTrue(html.contains("status=503 envelope_ok=UNKNOWN code=NONE"))
        XCTAssertFalse(html.contains("PRIVATE_HTML"))
        let unknown = diagnostic.summary(.response, status: 200,
            responseData: Data(#"{"ok":false,"error":{"code":"PRIVATE_CODE\nSECRET"},"trace_id":"PRIVATE_TRACE"}"#.utf8))
        XCTAssertTrue(unknown.contains("status=200 envelope_ok=FALSE code=OTHER"))
        XCTAssertTrue(unknown.contains("code_sha12=\(FriendAcceptanceDiagnostic.fingerprint("PRIVATE_CODE\nSECRET"))"))
        XCTAssertFalse(unknown.contains("PRIVATE"))
        XCTAssertFalse(unknown.contains("SECRET"))
        let normalized = diagnostic.summary(.apiFailed, error: IMAPIError.server("PRIVATE_SERVER_MESSAGE"))
        XCTAssertTrue(normalized.contains("code=client_server"))
        XCTAssertFalse(normalized.contains("PRIVATE_SERVER_MESSAGE"))
    }

    func testFriendAcceptanceDiagnosticRejectsOtherRequestsAndSeparatesAttempts() {
        let first = FriendAcceptanceDiagnostic(context: makeContext(), applicationID: "application", attemptID: "first")
        let second = FriendAcceptanceDiagnostic(context: makeContext(), applicationID: "application", attemptID: "second")
        XCTAssertTrue(first.matches(method: "POST", path: "/api/tenant/friends/applications/application/accept"))
        XCTAssertFalse(first.matches(method: "GET", path: first.path))
        XCTAssertFalse(first.matches(method: "POST", path: first.path + "?token=PRIVATE"))
        XCTAssertFalse(first.matches(method: "POST", path: "/api/platform/apps/current-policy"))
        XCTAssertNotEqual(first.summary(.apiEntered), second.summary(.apiEntered))
    }

    func testFriendAcceptanceDiagnosticKeepsSinglePOSTAndOriginalResponseOutcome() async throws {
        for (status, body, succeeds) in [
            (200, #"{"ok":true,"data":{"status":"accepted"},"trace_id":"trace-accepted"}"#, true),
            (503, #"{"ok":false,"error":{"code":"service_unavailable","message":"服务暂不可用"},"trace_id":"trace-unavailable"}"#, false),
            (409, #"{"ok":false,"error":{"code":"tenant_review_pending","message":"待审核"}}"#, false),
            (200, #"{"ok":false,"error":{"code":"bad_request","message":"失败"}}"#, false),
            (200, #"{"ok":true,"data":null}"#, true)
        ] {
            let transport = FakeHTTPTransport(results: [HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status)])
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            do {
                try await client.acceptFriendApplication(context: makeContext(), id: "application")
                XCTAssertTrue(succeeds)
            } catch {
                XCTAssertFalse(succeeds)
                if status == 503 { guard case IMAPIError.server = error else { return XCTFail("Keep original UI error contract") } }
                if status == 409 { guard case IMAPIError.conflict(let code, _) = error else { return XCTFail("Keep review-pending conflict") }; XCTAssertEqual(code, "tenant_review_pending") }
            }
            XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/friends/applications/application/accept"])
            XCTAssertEqual(transport.requests().first?.httpMethod, "POST")
            XCTAssertNil(SyncFailureDiagnostic.friendAcceptance)
        }
    }

    func testSessionHTTPFailureKeepsDistinctAuthRejectionsAndRequestSummary() throws {
        for code in ["missing_token", "invalid_token", "expired_token", "stale_access_token"] {
            let event = try XCTUnwrap(SyncFailureDiagnostic.SessionRequestFailure(
                method: "POST", path: "/api/im/conversations/sync", status: 401,
                code: code, requestSummary: "hash:1234abcd"
            ))
            XCTAssertEqual(event.summary, "session_http_failure method=POST path=/api/im/conversations/sync status=401 code=\(code) request=hash:1234abcd")
        }
        let transport = try XCTUnwrap(SyncFailureDiagnostic.SessionRequestFailure(
            method: "GET", path: "/api/rtc/calls/events", status: nil,
            code: "transport", requestSummary: nil
        ))
        XCTAssertTrue(transport.summary.contains("status=NONE code=transport request=NONE"))
    }

    func testCertificationHTTPFailureUsesOnlyFixedPathAndSanitizedFields() throws {
        let event = try XCTUnwrap(SyncFailureDiagnostic.SessionRequestFailure(
            method: "POST", path: "/api/tenant/users/profiles", status: 403,
            code: "SENSITIVE_SENTINEL", requestSummary: "SENSITIVE_SENTINEL"
        ))
        XCTAssertEqual(event.summary, "session_http_failure method=POST path=/api/tenant/users/profiles status=403 code=OTHER request=NONE")
        for path in ["/api/tenant/users/profiles?uids=SENSITIVE_SENTINEL", "/api/tenant/users/profiles/SENSITIVE_SENTINEL"] {
            XCTAssertNil(SyncFailureDiagnostic.SessionRequestFailure(
                method: "POST", path: path, status: 403, code: "forbidden", requestSummary: nil
            ))
        }
    }

    func testSessionHTTPFailureRejectsFreeTextAndDynamicPathLeakage() throws {
        let tenant = "00000000-0000-4000-8000-000000000001"
        for path in ["/api/platform/tenants/\(tenant)/session/refresh", "/api/platform/me/tenants/\(tenant)/enter"] {
            let event = try XCTUnwrap(SyncFailureDiagnostic.SessionRequestFailure(
                method: "POST", path: path, status: 401,
                code: "invalid_token SENSITIVE_SENTINEL", requestSummary: "hash:SENSITIVE_SENTINEL"
            ))
            XCTAssertTrue(event.summary.contains("{tenant}"))
            XCTAssertTrue(event.summary.contains("code=OTHER request=NONE"))
            XCTAssertFalse(event.summary.contains(tenant))
            XCTAssertFalse(event.summary.contains("SENSITIVE_SENTINEL"))
        }
        for path in ["/api/tenant/me/profile/SENSITIVE_SENTINEL", "/api/rtc/calls?token=SENSITIVE_SENTINEL", "/api/platform/tenants/SENSITIVE_SENTINEL/session/refresh"] {
            XCTAssertNil(SyncFailureDiagnostic.SessionRequestFailure(
                method: "POST", path: path, status: 401, code: "invalid_token", requestSummary: nil
            ))
        }
        XCTAssertNil(SyncFailureDiagnostic.SessionRequestFailure(
            method: "SENSITIVE_SENTINEL", path: "/api/rtc/calls", status: 401, code: "invalid_token", requestSummary: nil
        ))
    }

    func testSessionHTTPFailureIncludesExistingRegistrationAndRefreshBoundariesOnly() throws {
        let pairs = [
            ("POST", "/api/platform/auth/register"), ("GET", "/api/platform/auth/register/status"),
            ("POST", "/api/platform/auth/register/session"), ("POST", "/api/tenant/auth/platform-entry"),
            ("POST", "/api/platform/auth/session/refresh"), ("POST", "/api/tenant/auth/refresh"),
            ("POST", "/api/tenant/auth/session/refresh"), ("GET", "/api/rtc/calls")
        ]
        for (method, path) in pairs {
            let event = try XCTUnwrap(SyncFailureDiagnostic.SessionRequestFailure(
                method: method, path: path, status: 503, code: "token_sign_failed", requestSummary: nil
            ))
            XCTAssertTrue(event.summary.contains("method=\(method) path=\(path) status=503 code=token_sign_failed request=NONE"))
        }
        XCTAssertNil(SyncFailureDiagnostic.SessionRequestFailure(
            method: "POST", path: "/api/tenant/admin/users", status: 401, code: "invalid_token", requestSummary: nil
        ))
    }

    func testAttachmentUploadPresignKeepsHTTPEnvelopeDecodeAndEmptyEvidence() async throws {
        let cases: [(Int, String, AttachmentUploadFailure)] = [
            (503, #"{"ok":false,"error":{"code":"service_unavailable","message":"SENSITIVE_SENTINEL"}}"#,
             .init(code: .http, httpStatus: 503, serverCode: "service_unavailable")),
            (503, "", .init(code: .http, httpStatus: 503)),
            (200, #"{"ok":false,"error":{"code":"tenant_storage_not_configured","message":"SENSITIVE_SENTINEL"}}"#,
             .init(code: .envelope, httpStatus: 200, serverCode: "tenant_storage_not_configured")),
            (200, #"{"ok":false,"error":{"code":"SENSITIVE_SENTINEL","message":"https://private.invalid?token=secret"}}"#,
             .init(code: .envelope, httpStatus: 200, serverCode: "unrecognized_server_code")),
            (200, "SENSITIVE_SENTINEL invalid json", .init(code: .decode, httpStatus: 200)),
            (200, #"{"ok":true,"data":null}"#, .init(code: .emptyData, httpStatus: 200))
        ]
        for (status, body, expected) in cases {
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true, statusCode: status)
            ])
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            let observation = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
            do {
                _ = try await observation.captureUploadStep {
                    try await client.presignFileUpload(
                        context: makeContext(), conversation: makeDirectConversation(id: "uid-1:uid-2"),
                        channelID: "uid-1:uid-2", clientMessageID: "upload-diagnostic", purpose: "message_attachment",
                        fileName: "fixture.png", mimeType: "image/png", sizeBytes: 4
                    )
                }
                XCTFail("The presign fixture must fail")
            } catch {
                XCTAssertEqual(observation.resolvedUploadFailure(error: error), expected)
                XCTAssertEqual(observation.uploadFailure, expected)
                XCTAssertFalse(expected.detail.contains("SENSITIVE_SENTINEL"))
                XCTAssertFalse(expected.detail.contains("private.invalid"))
                // Evidence must survive the existing public lossy error contract.
                switch expected.code {
                case .emptyData:
                    guard case IMAPIError.emptyResponse = error else { return XCTFail("Expected the original empty-response error") }
                case .http where body.isEmpty:
                    guard case IMAPIError.httpStatus(503, _) = error else { return XCTFail("Expected the original HTTP error") }
                default:
                    guard case IMAPIError.server = error else { return XCTFail("Expected the original server error") }
                }
            }
            XCTAssertEqual(transport.requests().map { $0.url?.path }, ["/api/tenant/files/presign-upload"])
            XCTAssertTrue(transport.uploads().isEmpty)
            XCTAssertNil(SyncFailureDiagnostic.httpObservation)
        }
    }

    func testAttachmentUploadPUTByteAndFileFailuresKeepStatusWithoutRawDetails() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-diagnostic-\(UUID().uuidString).bin")
        let bytes = Data("file".utf8)
        try bytes.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        for fromFile in [false, true] {
            for isHTTP in [false, true] {
                let transport = FakeHTTPTransport(results: [], uploadResults: [
                    HTTPTransportResult(
                        data: Data(#"{"ok":false,"error":{"code":"forbidden","message":"SENSITIVE_SENTINEL"}}"#.utf8),
                        isHTTPResponse: isHTTP, statusCode: isHTTP ? 403 : nil
                    )
                ])
                let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
                let signed = try makeUpload(url: "https://upload.example.test/object?signature=SENSITIVE_SENTINEL", method: "PUT", headers: [:])
                let observation = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
                do {
                    try await observation.captureUploadStep {
                        if fromFile {
                            try await client.uploadFileBinary(upload: signed, fileURL: fileURL, mimeType: "application/octet-stream", sizeBytes: Int64(bytes.count))
                        } else {
                            try await client.uploadFileBinary(upload: signed, data: bytes, mimeType: "application/octet-stream")
                        }
                    }
                    XCTFail("The PUT fixture must fail")
                } catch {
                    let expected = isHTTP
                        ? AttachmentUploadFailure(code: .http, httpStatus: 403, serverCode: "forbidden")
                        : AttachmentUploadFailure(code: .invalidResponse)
                    XCTAssertEqual(observation.resolvedUploadFailure(error: error), expected)
                    XCTAssertFalse(observation.uploadFailure?.detail.contains("SENSITIVE_SENTINEL") ?? true)
                    guard case IMAPIError.server = error else { return XCTFail("PUT must preserve its existing server error") }
                }
                XCTAssertEqual(transport.fileUploads().count, fromFile ? 1 : 0)
                XCTAssertEqual(transport.uploads().count, fromFile ? 0 : 1)
                XCTAssertTrue(transport.requests().isEmpty)
            }
        }
    }

    func testAttachmentUploadTimeoutSurvivesPresignAndBothPUTTransports() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-timeout-\(UUID().uuidString).bin")
        try Data([1]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        for phase in ["presign", "bytes", "file"] {
            let transport = AttachmentUploadTimeoutTransport()
            let client = makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore())
            let observation = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
            let signed = try makeUpload(url: "https://upload.example.test/object", method: "PUT", headers: [:])
            do {
                try await observation.captureUploadStep {
                    switch phase {
                    case "presign":
                        _ = try await client.presignFileUpload(
                            context: makeContext(), conversation: makeDirectConversation(id: "uid-1:uid-2"),
                            channelID: "uid-1:uid-2", clientMessageID: "upload-timeout", purpose: "message_attachment",
                            fileName: "fixture.bin", mimeType: "application/octet-stream", sizeBytes: 1
                        )
                    case "bytes":
                        try await client.uploadFileBinary(upload: signed, data: Data([1]), mimeType: "application/octet-stream")
                    default:
                        try await client.uploadFileBinary(upload: signed, fileURL: fileURL, mimeType: "application/octet-stream", sizeBytes: 1)
                    }
                }
                XCTFail("The transport must throw")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                XCTAssertEqual(observation.uploadFailure, .init(code: .timeout))
                XCTAssertEqual(observation.resolvedUploadFailure(error: error), .init(code: .timeout))
            }
            XCTAssertEqual(transport.calls, [phase], "Diagnostics must not introduce retries or a different transport")
        }
    }

    func testAttachmentUploadStepSuccessIsIsolatedAndChildStopsAcceptingEvidence() async throws {
        let parent = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
        var child: SyncFailureDiagnostic.HTTPObservation?
        parent.recordUploadFailure(.init(code: .http, httpStatus: 503))
        let value = await parent.captureUploadStep {
            child = SyncFailureDiagnostic.httpObservation
            XCTAssertFalse(child === parent)
            // A failed request followed by a successful retry must not taint the attempt.
            child?.record(path: "/fixture", status: 503, code: "service_unavailable")
            child?.beginUploadStep()
            XCTAssertNil(child?.uploadFailure)
            child?.record(path: "/fixture", status: 403, code: "forbidden")
            return 17
        }
        XCTAssertEqual(value, 17)
        XCTAssertNil(parent.uploadFailure, "Successful operations must never copy child failure evidence")
        XCTAssertNil(SyncFailureDiagnostic.httpObservation)
        let retained = try XCTUnwrap(child?.uploadFailure)
        child?.beginUploadStep()
        child?.recordUploadFailure(.init(code: .timeout))
        XCTAssertEqual(child?.uploadFailure, retained, "An inherited task cannot reset or overwrite a finished child")
        parent.finish()
        do {
            try await parent.captureUploadStep { throw URLError(.timedOut) }
        } catch {
            XCTAssertNil(parent.uploadFailure, "A finished parent must reject late child results")
        }
    }

    func testAttachmentUploadStepThrowsOriginalErrorAndReplacesPriorFailure() async throws {
        let parent = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
        let outer = SyncFailureDiagnostic.HTTPObservation(.history)
        parent.recordUploadFailure(.init(code: .http, httpStatus: 503))
        await SyncFailureDiagnostic.$httpObservation.withValue(outer) {
            do {
                try await parent.captureUploadStep {
                    SyncFailureDiagnostic.httpObservation?.record(path: "/fixture", status: 200, code: "decode_envelope_failed")
                    SyncFailureDiagnostic.httpObservation?.beginUploadStep()
                    throw URLError(.timedOut)
                }
                XCTFail("The operation must throw")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                XCTAssertEqual(parent.uploadFailure, .init(code: .timeout))
                XCTAssertTrue(SyncFailureDiagnostic.httpObservation === outer)
                XCTAssertNil(outer.uploadFailure)
            }
        }
        XCTAssertNil(SyncFailureDiagnostic.httpObservation)
    }

    func testSyncResultDiagnosticKeepsCapturedNonSendableValueOnMainActor() async throws {
        final class RequestValue { var calls = 0 }
        let value = RequestValue()
        let observation = SyncFailureDiagnostic.HTTPObservation(.history)
        let returned = try await SyncFailureDiagnostic.$httpObservation.withValue(observation) {
            try await observation.perform {
                MainActor.preconditionIsolated()
                XCTAssertTrue(SyncFailureDiagnostic.httpObservation === observation)
                value.calls += 1
                return value
            }
        }
        XCTAssertTrue(returned === value)
        XCTAssertEqual(value.calls, 1)
        XCTAssertNil(SyncFailureDiagnostic.httpObservation)
    }

    func testSyncResultDiagnosticPreservesCancellationAndTaskLocalBoundary() async {
        let observation = SyncFailureDiagnostic.HTTPObservation(.history)
        let operation = Task { @MainActor in
            try await SyncFailureDiagnostic.$httpObservation.withValue(observation) {
                defer { observation.finish() }
                return try await observation.perform {
                    XCTAssertTrue(SyncFailureDiagnostic.httpObservation === observation)
                    try Task.checkCancellation()
                    return 1
                }
            }
        }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(SyncFailureDiagnostic.httpObservation)
    }

    func testSyncResultDiagnosticPreservesSuccessAndThrownFailure() async throws {
        let observation = SyncFailureDiagnostic.HTTPObservation(.history)
        var calls = 0
        let value = try await observation.perform { calls += 1; return 17 }
        XCTAssertEqual(value, 17)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(observation.result(error: nil).failure)
        let expected = URLError(.notConnectedToInternet)
        do {
            let _: Int = try await observation.perform { calls += 1; throw expected }
            XCTFail("Original error must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, expected.code)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(observation.result(error: expected).failure, .offline)
    }

    func testSyncResultDiagnosticUsesHTTPClassAndNeverRawText() {
        let observation = SyncFailureDiagnostic.HTTPObservation(.history)
        observation.record(path: "/api/im/sync", status: 401, code: "SENSITIVE_SENTINEL")
        observation.finish()
        observation.record(path: "/api/im/sync", status: 403, code: "SENSITIVE_SENTINEL")
        let result = observation.result(error: IMAPIError.server("SENSITIVE_SENTINEL https://private.invalid token=secret"))
        XCTAssertEqual(result.failure, .unauthorized)
        XCTAssertFalse(result.summary.contains("SENSITIVE_SENTINEL"))
        XCTAssertFalse(result.summary.contains("private.invalid"))
        XCTAssertTrue(result.summary.hasPrefix("sync_request_result endpoint=IM_HISTORY result=HTTP_401 elapsed_ms="))
        XCTAssertNil(observation.result(error: nil).failure, "A later successful operation is not the old failure")
        XCTAssertEqual(observation.result(error: nil, now: 0).elapsedMS, 0)
    }


    func testHistorySuccessPreservesFriendshipSendRestrictionAndRequestContext() async throws {
        for items in ["[]", #"[{"message_id":"invite-welcome","channel_id":"uid-1:uid-2","channel_type":"direct","channel_seq":1,"from_uid":"uid-2","content_type":"text","payload":{"text":"welcome"},"created_at":"2026-09-08T01:39:00Z"}]"#] {
            let transport = SyncDiagnosticHTTPTransport(failures: [:])
            transport.historyHTTPResult = HTTPTransportResult(
                data: Data("{\"ok\":true,\"data\":{\"items\":\(items)}}".utf8), isHTTPResponse: true, statusCode: 200)
            let fixture = try makeSyncDiagnosticFixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let conversation = try XCTUnwrap(fixture.state.conversationStore.conversationMessageSnapshots().first)
            let context = DirectFriendRequestContext(targetUID: "uid-2", canApplyFriend: false,
                friendRequestStatus: "pending", reasonCode: "friendship_required")
            fixture.state.conversationStore.markDirectConversationUnavailable(conversation, context: context)
            fixture.state.syncConversationMessagesIfNeeded(conversation.id, force: true, silent: true)
            try await waitForCondition { transport.count("/api/im/sync") > 0 && !fixture.state.conversationStore.hasHistoryLoadingIDs() }
            XCTAssertEqual(fixture.state.conversationSendDisabledReason(conversation.id), FriendAddPresentation.sentMessage)
            XCTAssertEqual(fixture.state.conversationStore.directFriendRequestContext(conversationID: conversation.id)?.targetUID, "uid-2")
            XCTAssertEqual(fixture.state.conversationStore.directFriendRequestContext(conversationID: conversation.id)?.friendRequestStatus, "pending")
            XCTAssertEqual(transport.count("/api/im/sync"), 1)
            XCTAssertTrue(fixture.state.isAuthenticated)
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
