// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
import Foundation
import IM4Core // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111
import Combine
import XCTest
import IM4Data
import IM4Stores
@testable import WenDaTong

@MainActor
final class DataDirectoryContactDTOBoundaryTests: XCTestCase {
    func testOrganizationDTOsKeepPrecisionAliasesDefaultsAndValueConformance() throws {
        let node = try decode(IM4Data.RemoteDepartmentNode.self, #"{"department_id":null,"departmentId":"d1","parent_id":"company","name":"研发","status":"future-state","is_virtual":"enabled","depth":"7","member_count":9007199254740993,"departmentPath":["company","d1"],"department_path_names":["公司","研发"],"children":[{"id":"child"}]}"#)
        XCTAssertEqual(node.departmentID, "d1")
        XCTAssertEqual(node.id, "d1")
        XCTAssertEqual(node.parentDepartmentID, "company")
        XCTAssertEqual(node.status, "future-state")
        XCTAssertTrue(node.isVirtual)
        XCTAssertEqual(node.depth, 7)
        XCTAssertEqual(node.memberCount, 9_007_199_254_740_993)
        XCTAssertEqual(node.departmentPath, ["company", "d1"])
        XCTAssertEqual(node.departmentPathNames, ["公司", "研发"])
        XCTAssertEqual(node.children.first?.id, "child")
        XCTAssertEqual(Set([node, node]).count, 1)
        let tree = try decode(IM4Data.RemoteOrganizationTree.self, #"{"departmentEnabled":"yes","can_manage":1,"can_manage_department":"future","items":[]}"#)
        XCTAssertEqual(tree, IM4Data.RemoteOrganizationTree(departmentEnabled: true, canManage: true, canManageDepartment: true, root: nil, items: []))
        let fallback = IM4Data.RemoteOrganizationTree.disabledFallback(root: node)
        XCTAssertFalse(fallback.departmentEnabled)
        XCTAssertEqual(fallback.root, node)
        XCTAssertTrue(fallback.items.isEmpty)
        let members = try decode(IM4Data.RemoteOrganizationMemberList.self, #"{"canManage":"1","items":[{"im_uid":"u1","avatar_url":"a","avatarVersion":"v","avatarUpdatedAt":"t","online":"disabled","is_online":true,"last_seen_at":"  ","lastLoginAt":" yesterday ","isPrimary":1,"sort_order":"-7","positionName":"研发","departmentPathNames":["公司"]}]}"#)
        XCTAssertEqual(members.departmentID, "company")
        XCTAssertTrue(members.canManageDepartment)
        let member = try XCTUnwrap(members.items.first)
        XCTAssertEqual(member.id, "u1")
        XCTAssertEqual(member.userID, "u1")
        XCTAssertEqual(member.avatar, "a")
        XCTAssertEqual(member.avatarVersion, "v")
        XCTAssertEqual(member.avatarUpdatedAt, "t")
        XCTAssertFalse(member.online)
        XCTAssertTrue(member.onlineKnown)
        XCTAssertEqual(member.lastSeenAt, "yesterday")
        XCTAssertTrue(member.isPrimary)
        XCTAssertEqual(member.sortOrder, -7)
        XCTAssertEqual(member.positionName, "研发")
        XCTAssertEqual(Set([member, member]).count, 1)
        let empty = try decode(IM4Data.RemoteDepartmentNode.self, "{}")
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.memberCount, 0)
        XCTAssertFalse(empty.isVirtual)
        XCTAssertTrue(empty.children.isEmpty)
    }

    func testContactsKeepAuthoritativeAliasesStrictAndLossyPolicies() throws {
        let relation = try decode(IM4Data.RemoteFriendRelation.self, #"{"owner_uid":" ","owner_im_uid":" owner ","friend_uid":" ","friend_im_uid":" compat ","friend_user_id":" number ","friend_nickname":"friend","raw_nickname":"raw","displayName":"display","friend_phone":"plain","phone_masked":"masked","friend_online":"no","online":true,"presence_status":"future","last_seen_at":" ","lastLoginAt":" seen ","departmentPath":["d"]}"#)
        XCTAssertEqual(relation.ownerUID, "owner")
        XCTAssertEqual(relation.friendUID, "compat")
        XCTAssertNil(relation.authoritativeFriendUID)
        XCTAssertEqual(relation.authoritativeFriendUserID, "number")
        XCTAssertEqual(relation.friendUserID, "number")
        XCTAssertEqual(relation.friendNickname, "friend")
        XCTAssertEqual(relation.rawNickname, "raw")
        XCTAssertEqual(relation.displayName, "display")
        XCTAssertEqual(relation.visiblePhone, "masked")
        XCTAssertFalse(relation.friendOnline)
        XCTAssertTrue(relation.friendOnlineKnown)
        XCTAssertEqual(relation.friendStatus, "future")
        XCTAssertEqual(relation.friendLastSeenAt, "seen")
        XCTAssertEqual(relation.departmentPath, ["d"])
        XCTAssertNil(relation.remark)
        let profile = try decode(IM4Data.RemoteFriendProfile.self, #"{"im_uid":"u","nickname":"old","rawNickname":"raw","display_name":"","avatarUrl":"avatar","version":"v","updated_at":"t","phone":"plain","phone_masked":"masked"}"#)
        XCTAssertEqual(profile.userID, "u")
        XCTAssertEqual(profile.nickname, "raw")
        XCTAssertEqual(profile.displayName, "")
        XCTAssertEqual(profile.avatar, "avatar")
        XCTAssertEqual(profile.avatarVersion, "v")
        XCTAssertEqual(profile.avatarUpdatedAt, "t")
        XCTAssertEqual(profile.visiblePhone, "masked")
        let search = try decode(IM4Data.RemoteUserSearchItem.self, #"{"im_uid":"u","can_apply_friend":true,"requires_tenant_review":"yes","requires_target_approval":0,"online":"unknown","is_online":1}"#)
        XCTAssertEqual(search.relationStatus, "none")
        XCTAssertEqual(search.friendAction, "request")
        XCTAssertTrue(search.onlineKnown)
        XCTAssertTrue(search.online)
        XCTAssertEqual(search.requiresTenantReview, true)
        XCTAssertEqual(search.requiresTargetApproval, false)
        let application = try decode(IM4Data.RemoteFriendApplication.self, #"{"applicant_nickname":"A","target_nickname":"B","status":"future","directly_established":"yes","actionable_by_current_user":false}"#)
        XCTAssertEqual(application.applicantName, "A")
        XCTAssertEqual(application.targetName, "B")
        XCTAssertEqual(application.status, "future")
        XCTAssertTrue(application.directlyEstablished)
        XCTAssertEqual(application.actionableByCurrentUser, false)
        XCTAssertNil(application.message)
        let apply = try decode(IM4Data.RemoteFriendApplyResult.self, #"{"id":null,"application_id":"app","request_id":"request","outcome":"future","requires_target_approval":"enabled"}"#)
        XCTAssertEqual(apply.id, "app")
        XCTAssertEqual(apply.outcome, "future")
        XCTAssertEqual(apply.requiresTargetApproval, true)
        XCTAssertEqual(try decode(IM4Data.RemoteBlacklistRelation.self, "{}").blockedUID, "")
        for sample in [#"{"can_apply_friend":"true"}"#, #"{"nickname":7}"#] {
            XCTAssertThrowsError(try decode(IM4Data.RemoteUserSearchItem.self, sample)) { error in
                guard case DecodingError.typeMismatch = error else { return XCTFail("changed strict decoding error: \(error)") }
            }
        }
        XCTAssertThrowsError(try decode(IM4Data.RemoteFriendApplication.self, #"{"actionable_by_current_user":"true"}"#))
        XCTAssertThrowsError(try decode(IM4Data.RemoteDepartmentNode.self, #"{"children":{}}"#))
    }

    func testDirectoryAppConsumerReturnsDataTypesWithOriginalRequests() async throws {
        try await withPrivateClient([
            #"{"department_enabled":true,"can_manage":true,"root":{"id":"company"}}"#,
            #"{"department_id":"d /?","items":[{"im_uid":"member","sort_order":7}]}"#,
            #"{"department_id":"new","name":"研发"}"#,
            #"{"department_id":"new","name":"修改"}"#
        ]) { client, context, transport in
            let tree: IM4Data.RemoteOrganizationTree = try await client.organizationTree(context: context)
            let members: IM4Data.RemoteOrganizationMemberList = try await client.organizationMembers(context: context, departmentID: " d /? ")
            let created: IM4Data.RemoteDepartmentNode = try await client.createOrganizationDepartment(context: context, parentDepartmentID: " company ", name: " 研发 ")
            let updated: IM4Data.RemoteDepartmentNode = try await client.updateOrganizationDepartment(context: context, departmentID: "new", parentDepartmentID: nil, name: " 修改 ")
            XCTAssertEqual(tree.root?.departmentID, "company")
            XCTAssertEqual(members.items.first?.sortOrder, 7)
            XCTAssertEqual(created.name, "研发")
            XCTAssertEqual(updated.name, "修改")
            XCTAssertEqual(String(reflecting: RemoteOrganizationTree.self), "IM4Data.RemoteOrganizationTree")
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "POST", "PATCH"])
            XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tenant/org/tree", "/api/tenant/org/members", "/api/tenant/org/departments", "/api/tenant/org/departments/new"])
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "department_id", value: "d /?")])
            XCTAssertEqual(try body(requests[2]), ["name": "研发", "parent_department_id": "company"])
            XCTAssertEqual(try body(requests[3]), ["name": "修改"])
            for request in requests { assertTenantRequest(request) }
        }
    }

    func testContactAppConsumerReturnsDataTypesWithOriginalRoutesBodiesAndMapping() async throws {
        try await withPrivateClient([
            #"{"items":[{"friend_uid":"friend","friend_user_id":"number","remark":"备注"}]}"#,
            #"{"im_uid":"friend","remark":"备注"}"#,
            #"{"im_uid":"friend","remark":"修改"}"#,
            #"{"items":[{"id":"application","status":"future"}]}"#,
            #"{"items":[{"im_uid":"friend","can_apply_friend":true}]}"#,
            #"{"application_id":"application","outcome":"application_suppressed"}"#,
            #"{"items":[{"blocked_uid":"blocked"}]}"#,
            #"{"blocked_uid":"blocked","reason":"reason"}"#
        ]) { client, context, transport in
            let friends: [IM4Data.RemoteFriendRelation] = try await client.listFriends(context: context)
            let profile: IM4Data.RemoteFriendProfile = try await client.friendProfile(context: context, canonicalFriendUID: "friend/segment")
            let modified: IM4Data.RemoteFriendProfile = try await client.updateFriendRemark(context: context, canonicalFriendUID: "friend/segment", remark: " 修改 ")
            let applications: [IM4Data.RemoteFriendApplication] = try await client.listFriendApplications(context: context)
            let search: [IM4Data.RemoteUserSearchItem] = try await client.searchTenantUsers(context: context, userID: " number ")
            let apply: IM4Data.RemoteFriendApplyResult = try await client.applyFriend(context: context, targetUID: "friend", message: "hello", source: "search_user", sourceGroupID: "group")
            let blacklist: [IM4Data.RemoteBlacklistRelation] = try await client.listBlacklist(context: context)
            let blocked: IM4Data.RemoteBlacklistRelation = try await client.addBlacklist(context: context, userID: "blocked", reason: "reason")
            XCTAssertEqual(friends.first?.authoritativeFriendUID, "friend")
            XCTAssertEqual(friends.first?.remark, "备注")
            XCTAssertEqual(profile.imUID, "friend")
            XCTAssertEqual(modified.remark, "修改")
            XCTAssertEqual(applications.first?.status, "future")
            XCTAssertEqual(search.first?.friendAction, "request")
            XCTAssertEqual(AppState.friendApplyResolution(apply), .terminal)
            XCTAssertEqual(blacklist.first?.blockedUID, "blocked")
            XCTAssertEqual(blocked.reason, "reason")
            XCTAssertEqual(String(reflecting: RemoteFriendRelation.self), "IM4Data.RemoteFriendRelation")
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 8)
            XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "PATCH", "GET", "GET", "POST", "GET", "POST"])
            XCTAssertEqual(requests[0].url?.path, "/api/tenant/friends")
            XCTAssertEqual(requests[1].url?.absoluteString, "https://tenant.example.test/api/tenant/friends/friend%2Fsegment")
            XCTAssertEqual(requests[1].cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(requests[2].url, requests[1].url)
            XCTAssertEqual(try body(requests[2]), ["remark": "修改"])
            XCTAssertEqual(requests[3].url?.query, "scope=all")
            XCTAssertEqual(requests[4].url?.path, "/api/tenant/users/search")
            XCTAssertEqual(requests[4].url?.query, "user_id=number")
            XCTAssertEqual(requests[5].url?.path, "/api/tenant/friends/apply")
            XCTAssertEqual(try body(requests[5]), ["target_uid": "friend", "message": "hello", "source": "search_user", "source_group_id": "group"])
            XCTAssertEqual(requests[6].url?.path, "/api/tenant/blacklist")
            XCTAssertEqual(try body(requests[7]), ["blocked_uid": "blocked", "reason": "reason"])
            for request in requests { assertTenantRequest(request) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
    }

    private func assertTenantRequest(_ request: URLRequest) {
        XCTAssertEqual(request.url?.host, "tenant.example.test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer directory-fixture-token")
    }

    private func withPrivateClient(_ payloads: [String], operation: (IMAPIClient, IMAPIContext, FakeHTTPTransport) async throws -> Void) async throws {
        let suite = "im4.private.directory-dto.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = payloads.map { HTTPTransportResult(data: Data(("{\"ok\":true,\"data\":" + $0 + "}").utf8), isHTTPResponse: true, statusCode: 200) }
        let transport = FakeHTTPTransport(results: results)
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!, tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, bootstrapBases: [], httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults))
        let context = IMAPIContext(platformToken: "directory-fixture-platform", accountID: "directory-fixture-account", tenantID: "directory-fixture-tenant", imUID: "directory-fixture-viewer", imToken: "directory-fixture-token", platformAuthSession: nil, tenantAuthSession: nil, appID: "ios-main", deviceID: "directory-fixture-device")
        try await operation(client, context, transport)
    }
}
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111_BEGIN
extension HTTPTransportTests {
    // WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_BEGIN
    func testOrganizationMembersPreservesCustomDepartmentIDInNativeURL() async throws {
        captureA43RuntimeLoadedImages()
        let suiteName = "OrganizationMembersQuery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defer { RuntimeRouteURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = RuntimeRouteTestClock(nowMS: 10_000)
        let client = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test")!,
            tenantBase: URL(string: "https://seed-tenant.example.test")!,
            imBase: URL(string: "https://seed-im.example.test")!,
            httpTransport: URLSessionHTTPTransport(session: session),
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults),
            runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle(monitorsNetwork: false),
            runtimeMonotonicNowMS: { clock.now() },
            runtimeSleep: { clock.advance(by: $0) }
        )
        XCTAssertEqual(client.activateRuntimeRoutesForTesting(runtimeRouteSnapshotForHTTPWiring()), .applied)

        let context = makeContext()
        let expectedAuthorization = "Bearer \(try XCTUnwrap(context.imToken))"
        let primary = "tenant-primary.example.com"
        let backup = "tenant-backup.example.net"
        let cases: [(input: String, expected: String, hosts: [String])] = [
            ("dep team", "dep team", [primary]),
            ("部门+%2B?=;/é#", "部门+%2B?=;/é#", [primary]),
            (" \n ", "", [primary]),
            ("  dep & team  ", "dep & team", [primary, backup])
        ]
        var observations: [[String: Any]] = []
        for sample in cases {
            let (requests, capture) = AsyncStream<URLRequest>.makeStream()
            defer { capture.finish() }
            let response = try JSONSerialization.data(withJSONObject: [
                "ok": true, "data": ["department_id": sample.expected, "items": []]
            ])
            RuntimeRouteURLProtocol.install { request in
                capture.yield(request)
                if sample.hosts.count == 2, request.url?.host == primary {
                    throw URLError(.timedOut)
                }
                return (200, response)
            }

            let members = try await client.organizationMembers(context: context, departmentID: sample.input)
            XCTAssertTrue(members.items.isEmpty)
            capture.finish()

            var hosts: [String] = []
            var encodedQueries: [String?] = []
            for await request in requests {
                let url = try XCTUnwrap(request.url)
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                hosts.append(try XCTUnwrap(url.host))
                encodedQueries.append(components.percentEncodedQuery)
                let expectedItems = sample.expected.isEmpty ? nil : [URLQueryItem(name: "department_id", value: sample.expected)]
                XCTAssertEqual(components.queryItems, expectedItems)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.path, "/api/tenant/org/members")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization)
                observations.append([
                    "url": url.absoluteString,
                    "percentEncodedQuery": components.percentEncodedQuery as Any? ?? NSNull(),
                    "items": (components.queryItems ?? []).map { ["name": $0.name, "value": $0.value as Any? ?? NSNull()] },
                    "normalized": sample.expected,
                    "preserving": true
                ])
            }
            XCTAssertEqual(hosts, sample.hosts)
            if sample.hosts.count == 2 {
                XCTAssertEqual(encodedQueries, Array(repeating: "department_id=dep%20%26%20team", count: 2))
            }
        }
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observations), uniformTypeIdentifier: "public.json")
        evidence.name = "organization-members-query-wire"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
    // WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_END

    func testOrganizationRefreshCommitsThroughSameScopeCredentialRenewalAndKeepsFailureFallback() async throws {
        let transport = StrictAttachmentHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"department_enabled":true,"can_manage":true,"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"department_enabled":true,"items":[{"im_uid":"directory-member","nickname":"目录成员"}]}}"#.utf8), isHTTPResponse: true, statusCode: 200),
            HTTPTransportResult(data: Data(#"{"ok":false,"error":{"code":"temporary_failure","message":"temporary failure"}}"#.utf8), isHTTPResponse: true, statusCode: 500),
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"department_enabled":false,"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ], uploadResults: [], suspendedPath: "/api/tenant/org/tree")
        let state = try makeOrganizationRefreshState(transport: transport)
        let store: IM4Stores.OrganizationDirectoryStore = state.organizationDirectoryStore
        var memberCounts: [Int] = []
        let observations = store.updates { $0.members(for: "company").count }.sink { memberCounts.append($0) }
        defer {
            transport.releaseSuspendedResponse()
            observations.cancel()
        }

        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let pending = Task { await state.refreshOrganizationDirectoryForCurrentSnapshot() }
        try await waitForCondition { transport.requests().count == 1 }
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/tenant/org/tree"])
        XCTAssertTrue(store.snapshot.isSyncing)
        var renewed = state.apiContext
        renewed.imToken = "renewed-test-bearer"
        renewed.credentialRevision += 1
        state.apiContext = renewed
        XCTAssertEqual(state.remoteDataScopeKey(for: state.apiContext), scope)
        transport.releaseSuspendedResponse()
        await pending.value

        XCTAssertFalse(store.snapshot.isSyncing)
        XCTAssertTrue(state.canManageOrganizationDepartments)
        XCTAssertEqual(store.snapshot.members(for: "company").map(\.id), ["directory-member"])
        XCTAssertEqual(store.snapshot.memberIndex["directory-member"]?.name, "目录成员")

        await state.refreshOrganizationDirectoryForCurrentSnapshot()
        XCTAssertEqual(store.snapshot.errorMessage, "组织架构同步失败，当前显示上次缓存")
        XCTAssertEqual(store.snapshot.members(for: "company").count, 1)

        await state.refreshOrganizationDirectoryForCurrentSnapshot()
        XCTAssertFalse(state.isDepartmentFeatureEnabled)
        XCTAssertFalse(state.canManageOrganizationDepartments)
        XCTAssertFalse(store.snapshot.isSyncing)
        XCTAssertNil(store.snapshot.errorMessage)
        XCTAssertTrue(store.snapshot.memberIndex.isEmpty)
        XCTAssertEqual(memberCounts, [0, 1, 0])
        XCTAssertEqual(transport.requests().map(\.url?.path), [
            "/api/tenant/org/tree", "/api/tenant/org/members", "/api/tenant/org/tree", "/api/tenant/org/tree"
        ])
        XCTAssertTrue(transport.isExhausted)
    }

    func testOrganizationRefreshResponseFromRetiredScopeCannotPublishIntoReplacementStore() async throws {
        let transport = StrictAttachmentHTTPTransport(results: [
            HTTPTransportResult(data: Data(#"{"ok":true,"data":{"department_enabled":true,"can_manage":true,"items":[]}}"#.utf8), isHTTPResponse: true, statusCode: 200)
        ], uploadResults: [])
        let state = try makeOrganizationRefreshState(transport: transport)
        let store: IM4Stores.OrganizationDirectoryStore = state.organizationDirectoryStore
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        let reachedDecode = expectation(description: "Organization tree reached background decode")
        let releaseDecode = DispatchSemaphore(value: 0)
        let trace: SDKHTTPTraceContext = (sourceCorrelation: 1, delivery: { _, _, _ in },
            decode: { _, _, main in
                XCTAssertFalse(main)
                reachedDecode.fulfill()
                _ = releaseDecode.wait(timeout: .now() + 3)
            }, linkToPhysicalSource: { _ in })
        let pending = Task {
            await SDKHTTPTrace.$current.withValue(trace) {
                await state.refreshOrganizationDirectoryForCurrentSnapshot()
            }
        }
        let waited = await XCTWaiter.fulfillment(of: [reachedDecode], timeout: 2)
        XCTAssertEqual(waited, .completed)
        XCTAssertTrue(store.snapshot.isSyncing)
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END

        state.apiContext = makeContext(tenantID: "replacement-directory-tenant")
        state.resetAuthenticatedRemoteData(showLoading: false)
        let replacement = store.beginRefresh()
        releaseDecode.signal() // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
        await pending.value

        XCTAssertTrue(store.ownsRefresh(replacement))
        XCTAssertTrue(store.snapshot.isSyncing)
        XCTAssertNil(store.snapshot.tree)
        XCTAssertTrue(store.snapshot.memberIndex.isEmpty)
        XCTAssertEqual(transport.requests().map(\.url?.path), ["/api/tenant/org/tree"])
        store.finishRefresh(replacement)
        XCTAssertFalse(store.snapshot.isSyncing)
    }

    private func makeOrganizationRefreshState(transport: HTTPTransport) throws -> AppState {
        let state = AppState(
            api: makeClient(transport: transport, runtimeRouteStore: isolatedRuntimeRouteStore()),
            apiContextOverride: makeContext(tenantID: "directory-tenant-\(UUID().uuidString)")
        )
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data
        ).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        state.authenticationPresentationStore.setInitialAuthentication(true)
        state.organizationDirectoryStore.setTenantDepartmentEnabled(true)
        _ = state.remoteSyncEngine.beginRemoteSnapshotRefresh()
        return state
    }
}
// WDT_IOS1_STORES_ORGANIZATION_DIRECTORY_OWNER_20261111_END

// WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
extension HTTPTransportTests {
    func testM9OrganizationMembersLargeBatchDecodesOffMainAndPublishes() async throws {
        captureA43RuntimeLoadedImages()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            RuntimeRouteURLProtocol.reset()
        }
        let transport = URLSessionHTTPTransport(session: session)
        var results: [M9ListPass] = []
        for iteration in 1...3 {
            results.append(try await measureM9Organization(transport, iteration: iteration,
                departments: 24, largest: 600, other: 25, unassigned: 60))
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(results), uniformTypeIdentifier: "public.json")
        attachment.name = "M9-organization-members-typed-decode"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func measureM9Organization(_ transport: URLSessionHTTPTransport, iteration: Int,
        departments: Int, largest: Int, other: Int, unassigned: Int) async throws -> M9ListPass {
        let ids = (0..<departments).map { "dept-\($0)" }
        let counts = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset == 0 ? largest : other) })
        let children: [[String: Any]] = ids.map { id in
            ["department_id": id, "parent_department_id": "company", "name": "Department \(id)",
             "status": "active", "is_virtual": false, "depth": 1, "member_count": counts[id]!,
             "department_path": ["company", id], "department_path_names": ["Company", "Department \(id)"], "children": []]
        }
        let tree = try m9Envelope(["department_enabled": true, "can_manage": true,
            "root": ["department_id": "company", "name": "Company", "is_virtual": true,
                "member_count": unassigned, "children": children], "items": children])
        let memberships = counts.merging(["company": unassigned]) { _, actual in actual }
        var members: [String: Data] = [:]
        for (id, count) in memberships {
            let rows: [[String: Any]] = (0..<count).map { number in
                let uid = "\(id)-member-\(number)"
                return ["im_uid": uid, "user_id": uid, "nickname": "Member \(number)", "role": "member",
                        "status": "active", "avatar": "/api/tenant/users/\(uid)/avatar",
                        "avatar_version": "v1", "avatar_updated_at": "2026-08-17T10:00:00Z",
                        "department_id": id, "department_name": "Department \(id)",
                        "department_path": id == "company" ? ["company"] : ["company", id],
                        "department_path_names": id == "company" ? ["Company"] : ["Company", "Department \(id)"],
                        "position_name": "Member", "is_primary": true, "sort_order": number,
                        "created_at": "2026-08-17T10:00:00Z"]
            }
            members[id] = try m9Envelope(["department_enabled": true, "can_manage": true, "department_id": id, "items": rows])
        }
        let payloads = members
        let state = makeIsolatedAuthenticatedHTTPState(transport: transport, context: makeContext())
        let policy = try XCTUnwrap(JSONDecoder().decode(
            APIEnvelope<RemoteAppCurrentPolicy>.self, from: activeAppPolicyResult().data).data)
        state.appPolicyPresentationStore.installResolvedPolicy(policy)
        state.currentAppPolicyExpiresAt = Date().addingTimeInterval(60)
        let store = state.organizationDirectoryStore
        store.setTenantDepartmentEnabled(true)
        _ = state.remoteSyncEngine.beginRemoteSnapshotRefresh()
        var publications: [M9ListPublication] = []
        let observation = store.$snapshot.sink { value in
            publications.append(.init(main: Thread.isMainThread, syncing: value.isSyncing,
                count: value.membersByDepartment.values.reduce(0) { $0 + $1.count },
                treeChildren: value.tree?.root?.children.count))
        }
        defer { observation.cancel() }
        let recorder = M9ListRecorder()
        RuntimeRouteURLProtocol.install { request in
            guard request.httpMethod == "GET", let url = request.url else { throw URLError(.unsupportedURL) }
            if url.path == "/api/tenant/org/tree" {
                recorder.wire(.init(route: "org-tree", rows: departments, bytes: tree.count, status: 200))
                return (200, tree)
            }
            guard url.path == "/api/tenant/org/members" else { throw URLError(.unsupportedURL) }
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "department_id" }?.value ?? "company"
            guard let data = payloads[id], let count = memberships[id] else { throw URLError(.unsupportedURL) }
            recorder.wire(.init(route: id == "company" ? "org-members-company" : "org-members-department",
                rows: count, bytes: data.count, status: 200))
            return (200, data)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        await SDKHTTPTrace.$current.withValue(recorder.context) {
            await state.refreshOrganizationDirectoryForCurrentSnapshot()
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertEqual(store.snapshot.tree?.root?.children.map(\.departmentID), ids)
        XCTAssertEqual(store.snapshot.membersByDepartment.mapValues(\.count), memberships)
        XCTAssertEqual(store.snapshot.members(for: "dept-0").first?.id, "dept-0-member-0")
        XCTAssertEqual(store.snapshot.members(for: "dept-0").last?.name, "Member \(largest - 1)")
        XCTAssertFalse(store.snapshot.isSyncing)
        XCTAssertNil(store.snapshot.errorMessage)
        XCTAssertTrue(publications.contains { $0.syncing && $0.treeChildren == departments && $0.count == 0 })
        XCTAssertEqual(publications.last?.count, memberships.values.reduce(0, +))
        XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts().count, departments + 2)
        return recorder.finish(lane: "directory-\(departments)-\(largest)", iteration: iteration,
            elapsed: elapsed, publications: publications)
    }

    private func m9Envelope(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "data": value], options: [.sortedKeys])
    }
}

extension HTTPTransportTests {
    func testM9OrganizationMembersDecodeFencesCancelRetirementAndAuthority() async throws {
        captureA43RuntimeLoadedImages()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuntimeRouteURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            RuntimeRouteURLProtocol.reset()
        }
        let (notifications, notificationTrace) = AsyncStream<IMAuthSessionFence>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: .imCurrentDeviceRevoked, object: nil, queue: nil) { event in
            if let fence = event.object as? IMAuthSessionFence { notificationTrace.yield(fence) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var validRevocation: IMAuthSessionFence?
        for scenario in M9MembersFenceScenario.allCases {
            let context = makeContext()
            let suite = "M9MembersColdRoute.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = IMRuntimeRouteStore(defaults: defaults)
            let lifecycle = IMRuntimeColdLaunchLifecycle(monitorsNetwork: false)
            lifecycle.beginProcessLaunch()
            lifecycle.sceneDidBecomeActive()
            lifecycle.setNetworkReachable(true)
            let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                tenantBase: URL(string: "https://seed-tenant.example.test")!,
                imBase: URL(string: "https://seed-im.example.test")!,
                httpTransport: URLSessionHTTPTransport(session: session), runtimeRouteStore: store,
                runtimeColdLaunchLifecycle: lifecycle)
            let routes = runtimeRouteSnapshotForHTTPWiring()
            XCTAssertEqual(client.activateRuntimeRoutesForTesting(routes), .applied)
            XCTAssertTrue(store.updateRecovery(.init(consecutiveQualifiedColdLaunchFailures: 1),
                service: .tenantAPI, snapshot: routes))
            let owner = M9MembersFixtureOwner()
            let check = OrganizationMembersRequestOwner(ownsRequest: { owner.ownsRequest },
                ownsAuthority: { owner.ownsAuthority })
            let status: Int
            let payload: Data
            switch scenario {
            case .stale401, .current401:
                status = 401
                payload = Data(#"{"ok":false,"error":{"code":"expired_token","message":"Fixture expired"}}"#.utf8)
            case .staleRevocation, .currentRevocation:
                status = 403
                payload = Data(#"{"ok":false,"error":{"code":"device_revoked","message":"Fixture revoked"}}"#.utf8)
            default:
                status = 200
                payload = try m9Envelope(["department_enabled": true, "items": [["im_uid": "member", "nickname": "Fixture"]]])
            }
            RuntimeRouteURLProtocol.install { request in
                guard request.httpMethod == "GET", let url = request.url,
                      url.path == "/api/tenant/org/members",
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ==
                        [URLQueryItem(name: "department_id", value: "dep team")] else { throw URLError(.unsupportedURL) }
                return (status, payload)
            }
            let decoded = expectation(description: "Member decode reached callback \(scenario)")
            let release = DispatchSemaphore(value: 0)
            let task = Task { @MainActor in
                try await OrganizationMembersRequestOwner.$current.withValue(check) {
                    try await SDKHTTPTrace.$current.withValue((
                        sourceCorrelation: 2, delivery: { _, _, _ in }, decode: { _, _, onMain in
                            XCTAssertFalse(onMain)
                            decoded.fulfill()
                            _ = release.wait(timeout: .now() + 3)
                        }, linkToPhysicalSource: { _ in }
                    )) {
                        try await client.organizationMembers(context: context, departmentID: "dep team")
                    }
                }
            }
            let waited = await XCTWaiter.fulfillment(of: [decoded], timeout: 2)
            switch scenario {
            case .cancelled: task.cancel()
            case .retired: owner.ownsRequest = false
            case .stale401, .staleRevocation, .renewedSuccess: owner.ownsAuthority = false
            case .currentRevocation: validRevocation = context.authSessionFence
            case .current401: break
            }
            release.signal()
            XCTAssertEqual(waited, .completed)
            do {
                let response = try await task.value
                XCTAssertEqual(scenario, .renewedSuccess)
                XCTAssertEqual(response.items.map(\.imUID), ["member"])
            } catch is CancellationError {
                XCTAssertTrue([.cancelled, .retired, .stale401, .staleRevocation].contains(scenario))
            } catch IMAPIError.unauthorized {
                XCTAssertTrue([.current401, .currentRevocation].contains(scenario))
            }
            XCTAssertEqual(RuntimeRouteURLProtocol.requestHosts(), ["tenant-primary.example.com"])
            let retired = [.retired, .stale401, .staleRevocation].contains(scenario)
            XCTAssertEqual(client.coldLaunchOutcomeRecordedServices.contains(.tenantAPI), !retired)
            XCTAssertEqual(client.runtimeRouteSelector.recovery(routes, service: .tenantAPI)
                .consecutiveQualifiedColdLaunchFailures, retired ? 1 : 0)
        }
        notificationTrace.finish()
        var revocations: [IMAuthSessionFence] = []
        for await fence in notifications { revocations.append(fence) }
        XCTAssertEqual(revocations, [try XCTUnwrap(validRevocation)])
    }
}

@MainActor
private final class M9MembersFixtureOwner {
    var ownsRequest = true
    var ownsAuthority = true
}

private enum M9MembersFenceScenario: CaseIterable {
    case cancelled, retired, stale401, staleRevocation, renewedSuccess, current401, currentRevocation
}

private struct M9ListPublication: Codable {
    let main: Bool
    let syncing: Bool
    let count: Int
    let treeChildren: Int?
}
private struct M9ListWire: Codable, Sendable {
    let route: String
    let rows: Int
    let bytes: Int
    let status: Int
}
private struct M9ListTiming: Codable, Sendable {
    let uptime: UInt64
    let nanoseconds: UInt64
    let main: Bool
}
private struct M9ListPass: Codable {
    let lane: String
    let iteration: Int
    let totalNanoseconds: UInt64
    let wire: [M9ListWire]
    let deliveries: [M9ListTiming]
    let decodes: [M9ListTiming]
    let publications: [M9ListPublication]
}
private final class M9ListRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [M9ListWire] = []
    private var deliveries: [M9ListTiming] = []
    private var decodes: [M9ListTiming] = []

    func wire(_ value: M9ListWire) {
        lock.withLock { requests.append(value) }
    }

    var context: SDKHTTPTraceContext {
        (sourceCorrelation: 1, delivery: { [self] time, duration, main in
            lock.withLock { deliveries.append(.init(uptime: time, nanoseconds: duration, main: main)) }
        }, decode: { [self] time, duration, main in
            lock.withLock { decodes.append(.init(uptime: time, nanoseconds: duration, main: main)) }
        }, linkToPhysicalSource: { _ in })
    }

    func finish(lane: String, iteration: Int, elapsed: UInt64, publications: [M9ListPublication]) -> M9ListPass {
        lock.withLock {
            XCTAssertFalse(requests.isEmpty)
            XCTAssertEqual(requests.count, deliveries.count)
            XCTAssertEqual(requests.count, decodes.count)
            XCTAssertTrue(deliveries.allSatisfy { !$0.main })
            for (request, decode) in zip(requests, decodes) {
                XCTAssertFalse(decode.main, request.route) // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
            }
            XCTAssertFalse(publications.isEmpty)
            XCTAssertTrue(publications.allSatisfy(\.main))
            for (delivery, decode) in zip(deliveries, decodes) {
                XCTAssertLessThanOrEqual(delivery.uptime, decode.uptime)
                XCTAssertGreaterThan(decode.nanoseconds, 0)
            }
            return .init(lane: lane, iteration: iteration, totalNanoseconds: elapsed, wire: requests,
                         deliveries: deliveries, decodes: decodes, publications: publications)
        }
    }
}
// WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END

// WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_BEGIN
extension DomainStoreTests {
    func testIndexedConversationRemarksPreserveAliasPriorityAndSelfExclusion() {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeIsolatedAPIContext())
        state.setCurrentUser(makeUser(id: "self", userID: "self-account", username: "self-login")) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        let first = makeUser(id: "first", name: "第一个联系人", userID: "shared", username: "first-login")
        let second = makeUser(id: "second", name: "第二个联系人", userID: "shared", username: "second-login")
        state.contacts = [first, second] + (0..<1000).map { makeUser(id: "remark-contact-\($0)") }
        state.contactRemarks = ["first-login": "第一个备注", "second-login": "第二个备注", "self-login": "不可用的自己备注"]
        let lookup = DirectConversationCallPeerResolver.ContactLookup(contacts: state.contacts)
        for identifiers in [["shared"], ["second", "shared"], ["second-login"], [" first "], ["unknown"], ["self-login"], ["self", "shared"]] {
            XCTAssertEqual(state.contactRemarkValue(matching: identifiers, contactLookup: lookup),
                           state.contactRemarkValue(matching: identifiers))
        }
        XCTAssertEqual(state.contactRemarkValue(matching: ["second", "shared"], contactLookup: lookup), "第一个备注")
        XCTAssertNil(state.contactRemarkValue(matching: ["self-login"], contactLookup: lookup))
        for user in [first, second, makeUser(id: "missing", name: "原名")] {
            XCTAssertEqual(state.remarkPreferredDisplayName(for: user, contactLookup: lookup), state.remarkPreferredDisplayName(for: user))
        }
        let users = state.makeConversationUserLookup()
        for channelID in ["self:first", "self:shared", "self:second-login", "unknown-peer"] {
            XCTAssertEqual(state.conversationReadStateKey(channelID: channelID, channelType: "direct", lookup: users),
                           state.conversationReadStateKey(channelID: channelID, channelType: "direct"))
            XCTAssertEqual(state.currentReadWatermarkScope(channelID: channelID, channelType: "direct", lookup: users),
                           state.currentReadWatermarkScope(channelID: channelID, channelType: "direct"))
        }
    }

    func testContactProfileReconciliationPublishesOneCompleteBatchAndNoNoop() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var original = (0..<400).map { makeConversation(id: "peer-\($0)", unread: 3, lastMsgSeq: 9, lastReadSeq: 6) }
        original[0].isPinned = true
        let group = makeConversation(id: "group", kind: .group, unread: 7, lastMsgSeq: 10, lastReadSeq: 3)
        store.commitConversationSnapshots(original + [group])
        var published: [[ConversationMessageSnapshot]] = []
        let observation = store.memoryUpdates.dropFirst().sink { _ in published.append(store.conversationMessageSnapshots()) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }
        func refresh() -> Int {
            store.refreshDirectConversationProfiles(
                channelIDForConversation: { $0.id },
                titleForChannel: { "new-" + $0 },
                participantsForChannel: { [self.makeUser(id: $0, name: "new-" + $0,
                    avatarURL: "https://example.invalid/avatar", avatarVersion: "2", avatarUpdatedAt: "now")] }
            )
        }
        XCTAssertEqual(refresh(), 400)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first, store.conversationMessageSnapshots())
        XCTAssertTrue(store.conversationMessageSnapshots()[0].isPinned)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].unread, 3)
        XCTAssertEqual(store.conversationMessageSnapshots()[0].lastReadSeq, 6)
        XCTAssertEqual(store.conversationMessageSnapshots().last, group)
        XCTAssertTrue(store.conversationMessageSnapshots().prefix(400).allSatisfy {
            $0.title == "new-" + $0.id && $0.avatarVersion == "2" && $0.participants.count == 1
        })
        XCTAssertEqual(refresh(), 0)
        XCTAssertEqual(published.count, 1)
        // Other mutations remain immediately observable, including an ABA toggle.
        store.mutateStoredConversation(at: 0) { $0.isPinned = false }
        store.mutateStoredConversation(at: 0) { $0.isPinned = true }
        XCTAssertEqual(published.count, 3)
    }

    func testConversationUserLookupPreservesAliasPriorityAndRebuildsForNewScope() {
        let me = makeUser(id: "self")
        let first = makeUser(id: "canonical-first", userID: " legacy ", username: " duplicate ")
        let second = makeUser(id: "canonical-second", username: "duplicate")
        let member = makeUser(id: "group-member", userID: "legacy", username: "member-alias")
        let lookup = ConversationUserLookup(currentUser: me, currentIdentifiers: ["self", "account"],
            contacts: [first, second, makeUser(id: "account")], groupMembers: [member])
        XCTAssertEqual(lookup.user(for: " account "), me)
        XCTAssertEqual(lookup.user(for: "legacy"), first)
        XCTAssertEqual(lookup.user(for: " duplicate "), first)
        XCTAssertEqual(lookup.user(for: "member-alias"), member)
        XCTAssertNil(lookup.user(for: " "))
        XCTAssertNil(lookup.user(for: "missing"))
        let next = ConversationUserLookup(currentUser: second, currentIdentifiers: [second.id],
            contacts: [], groupMembers: [])
        XCTAssertNil(next.user(for: "legacy"))
        XCTAssertEqual(next.user(for: second.id), second)
    }
}
// WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_END
