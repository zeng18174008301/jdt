// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_BEGIN
import Foundation
import XCTest
import IM4Data
@testable import WenDaTong

@MainActor
final class DataGroupProfileMembershipDTOBoundaryTests: XCTestCase {
    func testGroupProfileAndSettingsKeepInt64StrictBooleanAndNullContract() throws {
        let group = try decode(IM4Data.RemoteUserGroup.self, #"{"group_id":"g","group_revision":9007199254740993,"avatar":null,"avatarUrl":"a","my_role":"future-role","member_count":3.5,"memberCount":"7","all_muted_mode":"future-mode","all_muted_active":"true","all_muted_repair_required":"yes","invite_confirm_required":"unknown","inviteConfirmRequired":"yes","history_visible_from_seq":"9007199254740993","history_limited":"yes","settings":{"web_member_friend_apply_enabled":"true"}}"#)
        XCTAssertEqual(group.groupRevision, 9_007_199_254_740_993)
        XCTAssertTrue(group.avatarProvided)
        XCTAssertEqual(group.avatar, "a")
        XCTAssertEqual(group.explicitMyRole, "future-role")
        XCTAssertEqual(group.myRole, "future-role")
        XCTAssertEqual(group.memberCount, 7)
        XCTAssertEqual(group.allMutedMode, "future-mode")
        XCTAssertNil(group.allMutedActive)
        XCTAssertFalse(group.allMutedRepairRequired)
        XCTAssertTrue(group.inviteConfirmRequired)
        XCTAssertEqual(group.historyVisibleFromSeq, 9_007_199_254_740_993)
        XCTAssertTrue(group.historyLimited)
        XCTAssertEqual(group.memberFriendApplyEnabled, false)
        XCTAssertNil(try decode(IM4Data.RemoteUserGroup.self, "{}").memberFriendApplyEnabled)
        XCTAssertEqual(try decode(IM4Data.RemoteUserGroup.self, #"{"settings":{}}"#).memberFriendApplyEnabled, true)
        XCTAssertTrue(try decode(IM4Data.RemoteGroupSettings.self, "{}").memberFriendApplyEnabled)
        XCTAssertFalse(try decode(IM4Data.RemoteGroupSettings.self, #"{"web_member_friend_apply_enabled":null}"#).memberFriendApplyEnabled)
        let settings = try decode(IM4Data.RemoteGroupSettings.self, #"{"group_revision":-7,"description":"","history_visible":"no","invite_confirm_required":1,"all_muted_active":false,"all_muted_mode":"future","pending_join_request_count":2,"file_count":3,"blacklist_count":4,"mute_list_count":1.9}"#)
        XCTAssertEqual(settings.groupRevision, 0)
        XCTAssertEqual(settings.groupDescription, "")
        XCTAssertFalse(settings.historyVisible)
        XCTAssertTrue(settings.inviteConfirmRequired)
        XCTAssertEqual(settings.allMutedActive, false)
        XCTAssertEqual(settings.allMutedMode, "future")
        XCTAssertEqual(settings.pendingJoinRequestCount, 2)
        XCTAssertEqual(settings.fileCount, 3)
        XCTAssertEqual(settings.blacklistCount, 4)
        XCTAssertEqual(settings.muteListCount, 1)
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupSettings.self, #"{"pending_join_request_count":"2"}"#))
        XCTAssertThrowsError(try decode(IM4Data.RemoteUserGroup.self, #"{"muted":"true"}"#))
        requireCheckedSendable(IM4Data.RemoteUserGroup.empty)
        requireCheckedSendable(IM4Data.RemoteGroupSettings.empty)
    }

    func testMembershipAndAnnouncementsKeepAliasesPrecisionAndGenerationFallback() throws {
        let profile = try decode(IM4Data.RemoteGroupMemberProfile.self, #"{"contract_version":"1","group_id":" g ","im_uid":" u ","group_nickname":" 群昵称 ","raw_nickname":" 全局 ","display_name":" 展示 ","display_name_source":" group_nickname ","revision":"9007199254740993","group_membership_generation":null,"updated_at":" raw-time "}"#)
        XCTAssertEqual(profile.groupID, "g")
        XCTAssertEqual(profile.imUID, "u")
        XCTAssertEqual(profile.groupNickname, "群昵称")
        XCTAssertEqual(profile.rawNickname, "全局")
        XCTAssertEqual(profile.displayName, "展示")
        XCTAssertEqual(profile.displayNameSource, "group_nickname")
        XCTAssertEqual(profile.revision, 9_007_199_254_740_993)
        XCTAssertEqual(profile.groupMembershipGeneration, profile.revision)
        XCTAssertEqual(profile.updatedAt, "raw-time")
        let member = try decode(IM4Data.RemoteUserGroupMember.self, #"{"member_id":" m ","im_uid":" ","user_id":" u ","member_uid":"ignored","rawNickname":" raw ","nickname":"ignored","displayName":" display ","group_nickname":" group ","revision":9223372036854775807,"phone":"plain","phone_masked":"masked","role":"owner","is_owner":false,"online":"bad","isOnline":"yes","last_seen_at":" ","lastLoginAt":" seen ","departmentPath":["d"]}"#)
        XCTAssertEqual(member.memberID, "m")
        XCTAssertEqual(member.imUID, "u")
        XCTAssertEqual(member.userID, "u")
        XCTAssertEqual(member.nickname, "raw")
        XCTAssertEqual(member.displayName, "display")
        XCTAssertEqual(member.groupNickname, "group")
        XCTAssertEqual(member.revision, Int64.max)
        XCTAssertEqual(member.groupMembershipGeneration, Int64.max)
        XCTAssertEqual(member.visiblePhone, "masked")
        XCTAssertFalse(member.isOwner)
        XCTAssertTrue(member.isAdmin)
        XCTAssertTrue(member.online)
        XCTAssertTrue(member.onlineKnown)
        XCTAssertEqual(member.lastSeenAt, "seen")
        XCTAssertEqual(member.departmentPath, ["d"])
        let announcement = try decode(IM4Data.RemoteGroupAnnouncement.self, #"{"announcement_id":"canonical","id":"ignored","group_id":"g","status":"future","updated_at":"2026-08-13T10:01:02.123456Z","read_count":2.8,"can_view_read_counts":"yes","read_action":"future"}"#)
        XCTAssertEqual(announcement.id, "canonical")
        XCTAssertEqual(announcement.status, "future")
        XCTAssertEqual(announcement.updatedAt, "2026-08-13T10:01:02.123456Z")
        XCTAssertEqual(announcement.readCount, 2)
        XCTAssertTrue(announcement.canViewReadCounts)
        XCTAssertEqual(announcement.readAction, "future")
        XCTAssertNil(announcement.unreadCount)
        XCTAssertThrowsError(try decode(IM4Data.RemoteUserGroupMember.self, #"{"is_admin":"true"}"#))
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupAnnouncement.self, #"{"unread":"true"}"#))
        let transfer = try decode(IM4Data.RemoteGroupOwnerTransferResult.self, #"{"old_owner_role":"future","idempotent":"yes"}"#)
        XCTAssertEqual(transfer.group.groupID, "")
        XCTAssertEqual(transfer.oldOwnerRole, "future")
        XCTAssertTrue(transfer.idempotent)
        XCTAssertNil(transfer.previousOwner)
    }

    func testGroupSummaryConstructorsKeepOmissionFallbackAndCompletenessSemantics() throws {
        let summary = try decode(IM4Data.RemoteGroupSummary.self, #"{"group":{"group_id":"g","member_count":3,"history_visible_from_seq":9007199254740993},"summary":{"group_id":"preferred","member_count":2},"member_count":0,"counts":{"member_count":0,"admin_count":"1","pending_join_request_count":2.9},"member_preview":[{"im_uid":"u"}],"settings":{"web_member_friend_apply_enabled":false}}"#)
        XCTAssertEqual(summary.summary.groupID, "preferred")
        XCTAssertEqual(summary.memberCount, 2)
        XCTAssertEqual(summary.counts.adminCount, 1)
        XCTAssertEqual(summary.counts.pendingJoinRequestCount, 2)
        XCTAssertFalse(summary.memberFriendApplyEnabled)
        XCTAssertFalse(summary.isMemberPreviewComplete)
        XCTAssertNil(summary.settings.groupDescription)
        let member = try decode(IM4Data.RemoteUserGroupMember.self, #"{"im_uid":"u"}"#)
        let counts = IM4Data.RemoteGroupSummaryCounts(memberCount: 1, adminCount: nil, pendingJoinRequestCount: 0, fileCount: 0)
        let made = IM4Data.RemoteGroupSummary(summary: .empty, myRole: "member", memberCount: 1, owner: nil, memberPreview: [member], counts: counts, currentAnnouncement: nil, settings: .empty, historyVisibleFromSeq: 0)
        XCTAssertTrue(made.isMemberPreviewComplete)
        XCTAssertEqual(made.historyVisibleFromSeq, 1)
        XCTAssertTrue(made.memberFriendApplyEnabled)
        XCTAssertNil(made.explicitMyRole)
        let detail = try decode(IM4Data.RemoteGroupDetail.self, #"{"group":{"group_id":"g","history_visible_from_seq":9007199254740993,"history_limited":true,"my_role":"admin"},"settings":{"can_manage_mute_list":"yes","mute_list_count":"7"}}"#)
        XCTAssertEqual(detail.historyVisibleFromSeq, 9_007_199_254_740_993)
        XCTAssertTrue(detail.historyLimited)
        XCTAssertEqual(detail.explicitMyRole, "admin")
        XCTAssertEqual(detail.canManageMuteList, true)
        XCTAssertEqual(detail.muteListCount, 7)
        XCTAssertTrue(try decode(IM4Data.RemoteGroupAnnouncementList.self, "{}").items.isEmpty)
        XCTAssertTrue(try decode(IM4Data.RemoteGroupSettingsMutationResult.self, "{}").settings.historyVisible)
    }

    func testActualGroupProfileAndSettingsClientsReturnDataWithOriginalRequests() async throws {
        try await withPrivateClient([
            #"{"items":[{"group_id":"g","name":"name"}],"has_more":false}"#,
            #"{"group":{"group_id":"g","name":"detail"},"settings":{}}"#,
            #"{"group":{"group_id":"g","name":"summary"},"counts":{"file_count":2}}"#,
            #"{"group":{"group_id":"g","name":"changed","group_revision":9007199254740993}}"#,
            #"{"group_id":"g","settings":{"description":"","group_revision":9007199254740993}}"#
        ]) { client, context, transport in
            let groups: [IM4Data.RemoteUserGroup] = try await client.listGroups(context: context, scope: "joined")
            let detail: IM4Data.RemoteGroupDetail = try await client.groupDetail(context: context, groupID: "g")
            let summary: IM4Data.RemoteGroupSummary = try await client.groupSummary(context: context, groupID: "g")
            let mutation = try await client.updateGroupProfile(context: context, groupID: "g", name: "changed", avatarFileID: nil, expectedGroupRevision: 9_007_199_254_740_993)
            let effective: IM4Data.RemoteUserGroup = mutation.effectiveGroup
            let settings: IM4Data.RemoteGroupSettingsMutationResult = try await client.updateGroupDescription(context: context, groupID: "g", description: "", expectedGroupRevision: 9_007_199_254_740_993)
            XCTAssertEqual(groups.first?.name, "name")
            XCTAssertEqual(detail.summary.name, "detail")
            XCTAssertEqual(summary.counts.fileCount, 2)
            XCTAssertEqual(effective.name, "changed")
            XCTAssertEqual(effective.groupRevision, 9_007_199_254_740_993)
            XCTAssertEqual(settings.settings.groupDescription, "")
            XCTAssertEqual(String(reflecting: RemoteGroupDetail.self), "IM4Data.RemoteGroupDetail")
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 5)
            XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "GET", "PATCH", "PATCH"])
            XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tenant/groups", "/api/tenant/groups/g", "/api/tenant/groups/g/summary", "/api/tenant/groups/g/profile", "/api/tenant/groups/g/settings"])
            XCTAssertEqual(requests[0].url?.query, "scope=joined&limit=500&offset=0")
            let profileBody = try body(requests[3])
            XCTAssertEqual(profileBody["name"] as? String, "changed")
            XCTAssertEqual((profileBody["expected_group_revision"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
            let settingsBody = try body(requests[4])
            XCTAssertEqual(settingsBody["description"] as? String, "")
            XCTAssertEqual((settingsBody["expected_group_revision"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
            for request in requests { assertTenantRequest(request) }
        }
    }

    func testActualMemberAnnouncementAndOwnerClientsKeepRequestsAndAppProjection() async throws {
        try await withPrivateClient([
            #"{"group_id":"g","im_uid":"viewer","group_nickname":"群昵称","revision":9007199254740993}"#,
            #"{"items":[{"im_uid":"member"}],"self_member":{"im_uid":"viewer","group_nickname":"群昵称"},"has_more":true,"next_cursor":"next"}"#,
            #"{"items":[{"announcement_id":"a","group_id":"g"}],"current":{"id":"a"},"top_banner":{"id":"a"}}"#,
            #"{"group":{"group_id":"g","owner_uid":"next"},"previous_owner_uid":"viewer","new_owner_uid":"next","new_owner":{"im_uid":"next","role":"owner"},"idempotent":false}"#
        ]) { client, context, transport in
            let profile: IM4Data.RemoteGroupMemberProfile = try await client.updateMyGroupNickname(context: context, groupID: "g", groupNickname: "群昵称")
            let members = try await client.listGroupMembersPaged(context: context, groupID: "g", limit: 120, offset: 90, cursor: " cursor ", keyword: " Alice ", role: " member ")
            let typedMembers: [IM4Data.RemoteUserGroupMember] = members.items
            let announcements: IM4Data.RemoteGroupAnnouncementList = try await client.listGroupAnnouncements(context: context, groupID: "g")
            let transfer: IM4Data.RemoteGroupOwnerTransferResult = try await client.transferGroupOwner(context: context, groupID: " g ", newOwnerUID: " next ", idempotencyKey: " key ")
            XCTAssertEqual(profile.groupMembershipGeneration, 9_007_199_254_740_993)
            XCTAssertEqual(typedMembers.first?.imUID, "member")
            XCTAssertEqual(members.selfMember?.groupNickname, "群昵称")
            XCTAssertNil(members.total)
            XCTAssertEqual(members.nextCursor, "next")
            XCTAssertEqual(announcements.items.first?.id, "a")
            XCTAssertEqual(announcements.topBanner?.id, "a")
            XCTAssertEqual(transfer.group.ownerUID, "next")
            XCTAssertTrue(transfer.newOwner?.isOwner == true)
            XCTAssertEqual(GroupMemberDisplayNameResolver.resolve(authoritativeDisplayName: profile.displayName, viewerRemarks: ["备注"], groupNickname: profile.groupNickname, globalNickname: profile.rawNickname, stableIdentifier: profile.imUID, isCurrentUser: true), "群昵称")
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(requests.map { $0.httpMethod }, ["PATCH", "GET", "GET", "POST"])
            XCTAssertEqual(requests[0].url?.path, "/api/tenant/groups/g/members/me")
            XCTAssertEqual(try body(requests[0])["group_nickname"] as? String, "群昵称")
            XCTAssertEqual(requests[1].url?.query, "limit=100&cursor=cursor&keyword=Alice&role=member")
            XCTAssertEqual(requests[2].url?.path, "/api/tenant/groups/g/announcements")
            XCTAssertEqual(requests[3].url?.path, "/api/tenant/groups/g/owner/transfer")
            XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Idempotency-Key"), "key")
            XCTAssertEqual(try body(requests[3])["new_owner_uid"] as? String, "next")
            for request in requests { assertTenantRequest(request) }
            do {
                _ = try await client.transferGroupOwner(context: context, groupID: "", newOwnerUID: "next", idempotencyKey: "key")
                XCTFail("missing group context accepted")
            } catch IMAPIError.missingContext(let label) {
                XCTAssertEqual(label, "group owner transfer")
            }
            XCTAssertEqual(transport.requests().count, 4)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func requireCheckedSendable<T: Sendable>(_ value: T) {}

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func assertTenantRequest(_ request: URLRequest) {
        XCTAssertEqual(request.url?.host, "tenant.example.test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer group-fixture-token")
    }

    private func withPrivateClient(_ payloads: [String], operation: (IMAPIClient, IMAPIContext, FakeHTTPTransport) async throws -> Void) async throws {
        let suite = "im4.private.group-dto.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeHTTPTransport(results: payloads.map { HTTPTransportResult(data: Data(("{\"ok\":true,\"data\":" + $0 + "}").utf8), isHTTPResponse: true, statusCode: 200) })
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!, tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, bootstrapBases: [], httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults))
        let context = IMAPIContext(platformToken: "group-fixture-platform", accountID: "group-fixture-account", tenantID: "group-fixture-tenant", imUID: "viewer", imToken: "group-fixture-token", platformAuthSession: nil, tenantAuthSession: nil, appID: "ios-main", deviceID: "group-fixture-device")
        try await operation(client, context, transport)
    }
}
// WDT_IOS1_DATA_GROUP_PROFILE_MEMBERSHIP_DTO_20261110_END
