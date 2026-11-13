import Foundation
import Combine
import XCTest
import OSLog
@testable import WenDaTong
@testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

extension HTTPTransportTests {
    func testGroupAnnouncementPublicationSurvivesPrePublicationRefreshResponse() async throws {
        let transport = GroupAnnouncementRefreshRaceHTTPTransport(suspendInitialRefresh: true, suspendPostPublicationRefresh: true)
        defer {
            transport.releaseInitialRefresh()
            transport.releasePostPublicationRefresh()
        }
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        var group = makeGroupInfo(id: "group-announcement")
        group.myRole = "owner"
        state.groups = [group]

        state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        try await waitForCondition { transport.suspendedRequestCount() == 2 }
        XCTAssertEqual(transport.suspendedRequestCount(), 2)
        var published: Bool?
        state.publishGroupAnnouncement(groupID: group.id, title: "新公告", content: "新正文") {
            published = $0
        }
        try await waitForCondition { published != nil }
        XCTAssertEqual(published, true)
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "new-announcement")
        transport.releaseInitialRefresh()
        try await waitForCondition { transport.postPublicationRequestCount() == 2 }
        XCTAssertEqual(transport.postPublicationRequestCount(), 2)
        // The old response has drained, but the authoritative post-publication
        // response cannot hide an intervening rollback because it is still held.
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "new-announcement")
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.content, "新正文")
        XCTAssertNotEqual(state.group(id: group.id)?.notice, "旧正文")
        transport.releasePostPublicationRefresh()
        try await waitForCondition {
            !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertFalse(state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement"))
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "new-announcement")
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.content, "新正文")
        XCTAssertNotEqual(state.group(id: group.id)?.notice, "旧正文")
    }

    func testGroupAnnouncementSuccessfulPublicationSurvivesReadbackFailureWithoutRetryingPost() async throws {
        let transport = ScriptedMessageHTTPTransport(actions: [
            .response(HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"id":"new-announcement","group_id":"group-announcement","title":"新公告","content":"新正文","updated_at":"2026-09-05T10:00:00Z"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 201
            )),
            .failure(.notConnectedToInternet)
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        var group = makeGroupInfo(id: "group-announcement")
        group.myRole = "owner"
        state.groups = [group]
        var completions: [Bool] = []

        state.publishGroupAnnouncement(groupID: group.id, title: "新公告", content: "新正文") {
            completions.append($0)
        }
        try await waitForCondition {
            !completions.isEmpty && transport.requests().contains { $0.httpMethod == "GET" }
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertTrue(transport.requests().contains { $0.httpMethod == "GET" })
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "new-announcement")
        XCTAssertEqual(state.latestAnnouncement(for: group.id)?.content, "新正文")
        XCTAssertEqual(transport.requests().filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testGroupAnnouncementNullCurrentPreservesListUntilAuthoritativeEmptyRefresh() async throws {
        let transport = GroupAnnouncementRefreshRaceHTTPTransport(suspendInitialRefresh: false, currentNull: true)
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.groups = [makeGroupInfo(id: "group-announcement")]

        state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
        try await waitForCondition {
            state.announcements(for: "group-announcement").count == 2
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertEqual(state.latestAnnouncement(for: "group-announcement")?.id, "new-announcement")
        XCTAssertNil(state.currentUnreadAnnouncement(for: "group-announcement"))
        XCTAssertEqual(state.group(id: "group-announcement")?.notice, "新正文")

        transport.setAnnouncementListEmpty(true)
        state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
        try await waitForCondition {
            state.latestAnnouncement(for: "group-announcement") == nil
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertTrue(state.announcements(for: "group-announcement").isEmpty)
        XCTAssertNil(state.latestAnnouncement(for: "group-announcement"))
        XCTAssertNil(state.currentUnreadAnnouncement(for: "group-announcement"))
        XCTAssertEqual(state.group(id: "group-announcement")?.notice, "")
    }

    func testGroupAnnouncementPublicationRejectsLateSummaryNoticeWithAndWithoutCurrent() async throws {
        for includesCurrent in [true, false] {
            let transport = GroupAnnouncementRefreshRaceHTTPTransport(
                suspendInitialRefresh: false,
                suspendFirstSummary: true,
                summaryIncludesCurrent: includesCurrent,
                summaryHasLegacyNotice: true
            )
            defer { transport.releaseFirstSummary() }
            transport.setAnnouncementReadsFail(true)
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
            var group = makeGroupInfo(id: "group-announcement")
            group.myRole = "owner"
            state.groups = [group]
            var detailLoaded: Bool?
            state.loadGroupAnnouncementDetail(groupID: group.id, announcementID: "old-announcement") {
                detailLoaded = $0
            }
            try await waitForCondition { detailLoaded != nil }
            XCTAssertEqual(detailLoaded, true)
            XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "old-announcement")
            XCTAssertEqual(state.group(id: group.id)?.notice, "旧正文")

            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
            try await waitForCondition { transport.summaryRequestCount() == 1 }
            XCTAssertEqual(transport.summaryRequestCount(), 1)
            var completions: [Bool] = []
            state.publishGroupAnnouncement(groupID: group.id, title: "新公告", content: "新正文") {
                completions.append($0)
            }
            try await waitForCondition { !completions.isEmpty }
            XCTAssertEqual(completions, [true])
            XCTAssertEqual(state.latestAnnouncement(for: group.id)?.id, "new-announcement")
            XCTAssertEqual(state.group(id: group.id)?.notice, "新正文")

            transport.releaseFirstSummary()
            try await waitForCondition {
                transport.summaryRequestCount() >= 2 && transport.failedAnnouncementReadCount() > 0
                    && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
            }
            XCTAssertGreaterThanOrEqual(transport.summaryRequestCount(), 2)
            XCTAssertGreaterThan(transport.failedAnnouncementReadCount(), 0)
            XCTAssertFalse(state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement"))
            XCTAssertEqual(state.announcements(for: group.id).map(\.id), ["new-announcement", "old-announcement"], "includesCurrent=\(includesCurrent)")
            XCTAssertEqual(state.group(id: group.id)?.notice, "新正文", "includesCurrent=\(includesCurrent)")
            XCTAssertEqual(transport.publicationRequestCount(), 1)
            XCTAssertEqual(completions, [true])
        }
    }

    func testGroupAnnouncementAuthoritativeEmptyRejectsLaterLegacySummaryNotice() async throws {
        let transport = GroupAnnouncementRefreshRaceHTTPTransport(
            suspendInitialRefresh: false, currentNull: true, summaryHasLegacyNotice: true
        )
        transport.setAnnouncementListEmpty(true)
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.groups = [makeGroupInfo(id: "group-announcement")]
        state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
        try await waitForCondition {
            state.groupAnnouncements["group-announcement"] != nil
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertNotNil(state.groupAnnouncements["group-announcement"])
        XCTAssertTrue(state.announcements(for: "group-announcement").isEmpty)
        XCTAssertEqual(state.group(id: "group-announcement")?.notice, "")

        transport.setAnnouncementReadsFail(true)
        state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
        try await waitForCondition {
            transport.summaryRequestCount() >= 2 && transport.failedAnnouncementReadCount() > 0
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertGreaterThanOrEqual(transport.summaryRequestCount(), 2)
        XCTAssertGreaterThan(transport.failedAnnouncementReadCount(), 0)
        XCTAssertTrue(state.announcements(for: "group-announcement").isEmpty)
        XCTAssertNil(state.latestAnnouncement(for: "group-announcement"))
        XCTAssertEqual(state.group(id: "group-announcement")?.notice, "")
        XCTAssertEqual(transport.publicationRequestCount(), 0)
    }

    func testGroupAnnouncementLegacySummaryNoticeSurvivesWithoutCachedAnnouncements() async throws {
        for failCurrent in [true, false] {
            let transport = GroupAnnouncementRefreshRaceHTTPTransport(
                suspendInitialRefresh: false, currentNull: true, summaryHasLegacyNotice: true
            )
            transport.setAnnouncementReadsFail(true, includingCurrent: failCurrent)
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
            state.groups = [makeGroupInfo(id: "group-announcement")]
            state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
            try await waitForCondition {
                transport.failedAnnouncementReadCount() > 0
                    && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
            }
            XCTAssertGreaterThan(transport.failedAnnouncementReadCount(), 0)
            XCTAssertNil(state.groupAnnouncements["group-announcement"], "failCurrent=\(failCurrent)")
            XCTAssertNil(state.latestAnnouncement(for: "group-announcement"))
            XCTAssertEqual(state.group(id: "group-announcement")?.notice, "旧正文", "failCurrent=\(failCurrent)")
            XCTAssertEqual(transport.publicationRequestCount(), 0)
        }
    }

    func testGroupAnnouncementLatestRemainsSeparateFromOlderUnreadAndDetail() async throws {
        let transport = GroupAnnouncementRefreshRaceHTTPTransport(suspendInitialRefresh: false)
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.groups = [makeGroupInfo(id: "group-announcement")]

        state.loadGroupDetailIfNeeded(groupID: "group-announcement", force: true)
        try await waitForCondition {
            state.announcements(for: "group-announcement").count == 2
                && !state.contactStore.isGroupBundleRefreshInFlight(refreshKey: "tenant-1|uid-1|group-announcement")
        }
        XCTAssertEqual(state.announcements(for: "group-announcement").map(\.id), ["new-announcement", "old-announcement"])
        XCTAssertEqual(state.latestAnnouncement(for: "group-announcement")?.id, "new-announcement")
        XCTAssertEqual(state.currentUnreadAnnouncement(for: "group-announcement")?.id, "old-announcement")
        var loaded: Bool?
        state.loadGroupAnnouncementDetail(groupID: "group-announcement", announcementID: "old-announcement") {
            loaded = $0
        }
        try await waitForCondition { loaded != nil }
        XCTAssertEqual(loaded, true)
        XCTAssertEqual(state.latestAnnouncement(for: "group-announcement")?.id, "new-announcement")
        XCTAssertEqual(state.currentUnreadAnnouncement(for: "group-announcement")?.id, "old-announcement")
        XCTAssertEqual(state.announcements(for: "group-announcement").first { $0.id == "old-announcement" }?.content, "旧正文")
    }

    func testGroupAnnouncementPublicationRejectsMissingIDAndForeignGroupResponse() async throws {
        for data in [
            #"{"group_id":"group-announcement","content":"正文","updated_at":"2026-09-05T10:00:00Z"}"#,
            #"{"id":"foreign-announcement","group_id":"other-group","content":"正文","updated_at":"2026-09-05T10:00:00Z"}"#
        ] {
            let transport = FakeHTTPTransport(results: [HTTPTransportResult(
                data: Data("{\"ok\":true,\"data\":\(data)}".utf8),
                isHTTPResponse: true,
                statusCode: 201
            )])
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
            var group = makeGroupInfo(id: "group-announcement")
            group.myRole = "owner"
            state.groups = [group]
            var published: Bool?
            state.publishGroupAnnouncement(groupID: group.id, title: "公告", content: "正文") {
                published = $0
            }
            try await waitForCondition { published != nil }
            XCTAssertEqual(published, false)
            XCTAssertTrue(state.announcements(for: group.id).isEmpty)
            XCTAssertTrue(state.announcements(for: "other-group").isEmpty)
            XCTAssertNotEqual(state.toast, "群公告已发布")
            XCTAssertEqual(transport.requests().filter { $0.httpMethod == "POST" }.count, 1)
        }
    }

    func testGroupSummaryPreserves404HTTPStatusForLegacyFallback() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":false,"error":{"code":"not_found","message":"missing summary"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 404
            )
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.groupSummary(context: makeContext(), groupID: "missing")
            XCTFail("Expected http status error")
        } catch IMAPIError.httpStatus(let statusCode, let message) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(message, "missing summary")
        }
    }

    func testGroupSummary404And405TriggerLegacyDetailFallback() async throws {
        for statusCode in [404, 405] {
            let groupID = "g-fallback-\(statusCode)"
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"missing_summary","message":"summary unavailable"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: statusCode
                ),
                HTTPTransportResult(
                    data: Data("""
                    {
                      "ok": true,
                      "data": {
                        "group": {
                          "group_id": "\(groupID)",
                          "name": "旧详情群",
                          "member_count": 3,
                          "my_role": "admin"
                        },
                        "my_role": "admin",
                        "owner": {
                          "im_uid": "owner-1",
                          "nickname": "群主",
                          "role": "owner",
                          "is_owner": true
                        },
                        "admins": [
                          {
                            "im_uid": "admin-1",
                            "nickname": "管理员",
                            "role": "admin",
                            "is_admin": true
                          }
                        ],
                        "member_count": 3,
                        "settings": {
                          "invite_confirm_required": true,
                          "file_count": 2
                        }
                      }
                    }
                    """.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ])
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

            state.loadGroupDetailIfNeeded(groupID: groupID, force: true, includeSecondaryData: false)

            try await waitForCondition {
                transport.requests().count >= 2 && state.group(id: groupID)?.name == "旧详情群"
            }
            let requests = transport.requests()
            XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
                "https://tenant.example.test/api/tenant/groups/\(groupID)/summary",
                "https://tenant.example.test/api/tenant/groups/\(groupID)"
            ])
            let fallbackGroup = try XCTUnwrap(state.group(id: groupID))
            XCTAssertNil(fallbackGroup.memberCount)
            XCTAssertNil(state.visibleGroupMemberCount(fallbackGroup.memberCount))
            XCTAssertEqual(state.group(id: groupID)?.members.map(\.id), ["owner-1", "admin-1"])
            XCTAssertTrue(state.group(id: groupID)?.membersPartial == true)
        }
    }

    func testGroupSummary401And403DoNotTriggerLegacyDetailFallback() async throws {
        for statusCode in [401, 403] {
            let groupID = "g-auth-\(statusCode)"
            let transport = FakeHTTPTransport(results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":false,"error":{"code":"auth_failed","message":"auth failed"}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: statusCode
                )
            ])
            let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())

            state.loadGroupDetailIfNeeded(groupID: groupID, force: true, includeSecondaryData: false)

            try await waitForCondition {
                !transport.requests().isEmpty
            }
            try await Task.sleep(nanoseconds: 120_000_000)
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/\(groupID)/summary")
            XCTAssertNil(state.group(id: groupID))
        }
    }

    func testListGroupMembersPagedCapsLimitAndUsesVisibleCompatibilityOffset() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"im_uid":"u1","nickname":"Alice","role":"member"}],"self_member":{"im_uid":"uid-1","nickname":"全局昵称","group_nickname":"我的群昵称","role":"member","revision":4,"group_membership_generation":8},"total":503,"limit":100,"offset":20,"has_more":true,"next_offset":120}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.listGroupMembersPaged(
            context: makeContext(),
            groupID: "g1",
            limit: 120,
            offset: 20,
            cursor: nil,
            keyword: "Alice",
            role: "member"
        )

        XCTAssertEqual(result.items.map(\.imUID), ["u1"])
        XCTAssertEqual(result.selfMember?.imUID, "uid-1")
        XCTAssertEqual(result.selfMember?.groupNickname, "我的群昵称")
        XCTAssertEqual(result.selfMember?.groupMembershipGeneration, 8)
        XCTAssertEqual(result.total, 503)
        XCTAssertEqual(result.limit, 100)
        XCTAssertEqual(result.offset, 20)
        XCTAssertEqual(result.hasMore, true)
        XCTAssertEqual(result.nextOffset, 120)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/g1/members?limit=100&offset=20&keyword=Alice&role=member")
    }

    func testListGroupMembersPagedPrefersOpaqueCursorAndKeepsMissingTotalAbsent() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"im_uid":"u2","nickname":"Bob","role":"member"}],"limit":100,"has_more":true,"next_cursor":"signed:+/= cursor"}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.listGroupMembersPaged(
            context: makeContext(),
            groupID: "g1",
            limit: 120,
            offset: 100,
            cursor: "signed:+/= cursor one",
            keyword: nil,
            role: nil
        )

        XCTAssertNil(result.total)
        XCTAssertEqual(result.nextCursor, "signed:+/= cursor")
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://tenant.example.test/api/tenant/groups/g1/members?limit=100&cursor=signed:+/=%20cursor%20one"
        )
    }

    func testListGroupMembersKeepsLegacyUnpagedEndpointAndResultShape() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"items":[{"im_uid":"u1","nickname":"Alice","role":"member"}],"total":3,"limit":1,"offset":2,"has_more":true,"next_offset":3}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = makeClient(transport: transport)

        let result = try await client.listGroupMembers(context: makeContext(), groupID: "g1")

        XCTAssertEqual(result.items.map(\.imUID), ["u1"])
        XCTAssertEqual(result.total, 3)
        XCTAssertNil(result.limit)
        XCTAssertNil(result.offset)
        XCTAssertNil(result.hasMore)
        XCTAssertNil(result.nextOffset)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/g1/members")
    }

    func testGroupMemberPreviewDoesNotDowngradeCompleteMemberCache() async throws {
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data(#"{"ok":true,"data":{"group":{"group_id":"g-cache","name":"更新后的群名","member_count":3,"my_role":"member"},"my_role":"member","member_count":3,"member_preview":[{"im_uid":"u1","nickname":"Alice","role":"member"}]}}"#.utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: makeContext())
        state.groups = [
            GroupInfo(
                id: "g-cache",
                name: "原群名",
                notice: "",
                owner: "Alice",
                members: [
                    makeUser(id: "u1", name: "Alice"),
                    makeUser(id: "u2", name: "Bob"),
                    makeUser(id: "u3", name: "Cora")
                ],
                admins: [],
                membersPartial: false,
                membersLoadedCount: 3,
                membersNextOffset: nil,
                muted: false,
                allMuted: false,
                memberCount: 3
            )
        ]

        state.loadGroupDetailIfNeeded(groupID: "g-cache", force: true, includeSecondaryData: false)

        try await waitForCondition {
            state.group(id: "g-cache")?.name == "更新后的群名"
        }
        let group = try XCTUnwrap(state.group(id: "g-cache"))
        XCTAssertEqual(group.members.map(\.id), ["u1", "u2", "u3"])
        XCTAssertFalse(group.membersPartial)
        XCTAssertEqual(group.membersLoadedCount, 3)
        XCTAssertNil(group.membersNextOffset)
    }

    func testSearchGroupMentionMembersDropsStaleResponseWhenScopeChanges() async throws {
        var originalContext = makeContext()
        originalContext.tenantID = "tenant-original"
        var switchedContext = makeContext()
        switchedContext.tenantID = "tenant-switched"
        let transport = FakeHTTPTransport(
            results: [
                HTTPTransportResult(
                    data: Data(#"{"ok":true,"data":{"items":[{"im_uid":"u-remote","nickname":"Remote User","role":"member"}],"total":1,"limit":120,"offset":0,"has_more":false}}"#.utf8),
                    isHTTPResponse: true,
                    statusCode: 200
                )
            ],
            delayNanoseconds: 120_000_000
        )
        let state = AppState(api: makeClient(transport: transport), apiContextOverride: originalContext)
        state.groups = [
            GroupInfo(
                id: "g-mention",
                name: "提及群",
                notice: "",
                owner: "",
                members: [],
                admins: [],
                membersPartial: true,
                membersLoadedCount: 0,
                membersNextOffset: 0,
                muted: false,
                allMuted: false,
                memberCount: 1
            )
        ]

        let searchTask = Task { @MainActor in
            await state.searchGroupMentionMembers(groupID: "g-mention", keyword: "")
        }
        try await waitForCondition {
            !transport.requests().isEmpty
        }
        state.overrideAPIContextForTesting(switchedContext)
        let result = await searchTask.value

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(state.group(id: "g-mention")?.members.isEmpty == true)
        XCTAssertTrue(state.group(id: "g-mention")?.membersPartial == true)
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://tenant.example.test/api/tenant/groups/g-mention/members?limit=100")
    }

    func testCurrentAppPolicyUsesLastGoodBootstrapWithoutBlockingOnSeed() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        IMAppBootstrapLastGoodStore.save(
            appBootstrapForHTTPWiring(platformBase: "https://platform-last-good.example.test"),
            appID: "jianhuitong-ios"
        )
        let storedBootstrap = try XCTUnwrap(
            IMAppBootstrapLastGoodStore.load(appID: "jianhuitong-ios")
        )
        XCTAssertTrue(storedBootstrap.hasValidV2ConfigHash)
        XCTAssertNotNil(
            storedBootstrap.runtimeRouteSnapshot.validated(
                appID: IMAPIContext.canonicalIOSAppID,
                tenantID: nil
            )
        )
        let clock = RuntimeRouteTestClock(nowMS: 40_000)
        let transport = RuntimeRouteBudgetTransport(clock: clock, actions: [
            .failure(.dnsLookupFailed, advanceMS: 5),
            .response(
                status: 200,
                data: Data(#"{"ok":true,"data":{"app_id":"jianhuitong-ios","platform":"ios","status":"active","allow_workspace_switch":true,"allow_default_tenant_join":false,"cache_ttl_seconds":60}}"#.utf8),
                advanceMS: 0
            )
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore(),
            runtimeMonotonicNowMS: { clock.now() },
            runtimeSleep: { clock.advance(by: $0) }
        )
        XCTAssertEqual(client.platformBase.absoluteString, "https://platform-last-good.example.test")

        let policy = try await client.currentAppPolicy(appID: "jianhuitong-ios")

        XCTAssertEqual(policy.appID, "jianhuitong-ios")
        XCTAssertEqual(
            transport.requestHosts(),
            ["app-test.example.test", "platform-last-good.example.test"]
        )
        XCTAssertEqual(
            transport.requestURLs().last,
            "https://platform-last-good.example.test/api/platform/apps/current-policy?app_id=jianhuitong-ios"
        )
    }

    func testCurrentAppPolicyMalformedWellKnownResponseFailsClosedWithoutLegacyPath() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("service placeholder".utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport
        )

        do {
            _ = try await client.currentAppPolicy(appID: "jianhuitong-ios")
            XCTFail("a malformed HTTP response must fail closed")
        } catch {}

        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://app-test.example.test/.well-known/wenxintong-app.json?app_id=jianhuitong-ios")
        XCTAssertNil(IMAppBootstrapLastGoodStore.load(appID: "jianhuitong-ios"))
    }

    func testLegalDocumentContentUsesFixedPrivacyURL() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let bootstrap = appBootstrapForHTTPWiring(platformBase: "https://shared-platform.example.test")
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("<html><body>privacy</body></html>".utf8),
                isHTTPResponse: true,
                statusCode: 200
            ),
            try apiSuccessResult(bootstrap)
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let content = try await client.legalDocumentContent(
            type: .privacy,
            appID: "com.jianhuitongqiyetest.app",
            context: nil
        )
        let manifest = content.manifest

        XCTAssertEqual(manifest.appID, "jianhuitong-ios")
        XCTAssertEqual(manifest.manifestRevision, 0)
        XCTAssertEqual(manifest.document(type: .terms)?.downloadURL, "https://wdatong.cn/ios_yonghu.html")
        XCTAssertEqual(
            manifest.document(type: .privacy)?.downloadURL,
            "https://wdatong.cn/ios_yinsi.html"
        )
        XCTAssertEqual(content.html, "<html><body>privacy</body></html>")
        XCTAssertEqual(content.sourceURL.absoluteString, "https://wdatong.cn/ios_yinsi.html")
        XCTAssertEqual(content.baseURL.absoluteString, "https://wdatong.cn")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://wdatong.cn/ios_yinsi.html")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))

        do {
            _ = try await client.resolveLegalDocAssetURL(
                "javascript:alert(1)",
                appID: "jianhuitong-ios"
            )
            XCTFail("non-http legal document URL must be rejected")
        } catch IMAPIError.badURL(let code) {
            XCTAssertEqual(code, "legal_doc_cross_origin_not_allowed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLegalDocumentContentUsesFixedPrivacyURLWhenKnownTenantExists() async throws {
        clearStoredAPIContext()
        IMAppBootstrapLastGoodStore.clearAll()
        defer {
            clearStoredAPIContext()
            IMAppBootstrapLastGoodStore.clearAll()
        }
        let transport = FakeHTTPTransport(results: [
            HTTPTransportResult(
                data: Data("<html><body>fixed privacy</body></html>".utf8),
                isHTTPResponse: true,
                statusCode: 200
            )
        ])
        let client = IMAPIClient(
            platformBase: IMAPIClient.releasePlaceholderPlatformBase,
            tenantBase: URL(string: "https://tenant.example.test")!,
            imBase: URL(string: "https://im.example.test")!,
            bootstrapBases: [URL(string: "https://app-test.example.test")!],
            httpTransport: transport,
            runtimeRouteStore: isolatedRuntimeRouteStore()
        )

        let content = try await client.legalDocumentContent(
            type: .privacy,
            appID: "com.jianhuitongqiyetest.app",
            context: nil
        )

        XCTAssertEqual(content.html, "<html><body>fixed privacy</body></html>")
        XCTAssertEqual(content.sourceURL.absoluteString, "https://wdatong.cn/ios_yinsi.html")
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://wdatong.cn/ios_yinsi.html")
    }
}
