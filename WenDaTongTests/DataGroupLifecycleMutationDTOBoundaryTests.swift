// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
import Foundation
import XCTest
import IM4Data
@testable import WenDaTong

@MainActor
final class DataGroupLifecycleMutationDTOBoundaryTests: XCTestCase {
    func testLifecycleValuesKeepStrictFlexibleAliasesAndInvalidationPrecision() throws {
        let left = try decode(IM4Data.RemoteGroupLeaveResult.self, #"{"left":true,"group_id":null,"groupId":"g","leftAt":"raw-time","conversationRemoved":true,"notificationCount":2,"searchInvalidations":[{"tenant_id":" t ","invalidation_key":" k ","event_type":"removed_conversation","channel_seq":"9007199254740993","version":9223372036854775807}]}"#)
        XCTAssertTrue(left.left)
        XCTAssertEqual(left.groupID, "g")
        XCTAssertEqual(left.leftAt, "raw-time")
        XCTAssertTrue(left.conversationRemoved)
        XCTAssertEqual(left.notificationCount, 2)
        let event: IM4Data.SearchInvalidationEvent = try XCTUnwrap(left.searchInvalidations.first)
        XCTAssertEqual(event.channelSeq, 9_007_199_254_740_993)
        XCTAssertEqual(event.version, Int64.max)
        XCTAssertEqual(event.normalizedTenantID, "t")
        XCTAssertEqual(event.dedupeKey, " t |k")
        XCTAssertTrue(event.isConversationRemoval)
        XCTAssertEqual(event, try decode(IM4Data.SearchInvalidationEvent.self, #"{"tenant_id":" t ","invalidation_key":" k ","event_type":"removed_conversation","channel_seq":"9007199254740993","version":9223372036854775807}"#))
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupLeaveResult.self, #"{"notification_count":"2"}"#))
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupLeaveResult.self, #"{"left":"true"}"#))
        let preview = try decode(IM4Data.RemoteGroupDissolvePreview.self, #"{"member_count":2.5,"memberCount":"7","confirmation_mode":"future","effects":["future-effect"]}"#)
        XCTAssertEqual(preview.memberCount, 7)
        XCTAssertEqual(preview.affectedMembers, 7)
        XCTAssertTrue(preview.confirmationRequired)
        XCTAssertEqual(preview.confirmationMode, "future")
        XCTAssertEqual(preview.effects, ["future-effect"])
        let dissolved = try decode(IM4Data.RemoteGroupDissolveResult.self, #"{"dissolved":true,"status":"future","removed_members":2.5,"removedMembers":"3","notification_count":"9"}"#)
        XCTAssertEqual(dissolved.removedMembers, 3)
        XCTAssertEqual(dissolved.notificationCount, 9)
        XCTAssertEqual(dissolved.status, "future")
        XCTAssertTrue(dissolved.searchInvalidations.isEmpty)
        XCTAssertTrue(IM4Data.RemoteGroupDissolvePreview().confirmationRequired)
        XCTAssertEqual(IM4Data.RemoteGroupLeaveResult().notificationCount, 0)
        XCTAssertEqual(IM4Data.RemoteGroupDissolveResult().removedMembers, 0)
        let reset: IM4Data.SearchInvalidationEvent = SearchInvalidationEvent.tenantScopeReset(tenantID: "t", reason: "logout")
        XCTAssertEqual(reset.clientAction, "clear_search_state")
        XCTAssertTrue(reset.isTenantScopeReset)
    }

    func testMutationValuesKeepRequiredKeysConstructorsAndPureProfileFallback() throws {
        let request = try decode(IM4Data.RemoteGroupJoinRequest.self, #"{"target_uid":"u","target_name":"name","reason":"reason","status":"future"}"#)
        XCTAssertEqual(request.applicantUID, "u")
        XCTAssertEqual(request.applicantName, "name")
        XCTAssertEqual(request.message, "reason")
        XCTAssertEqual(request.status, "future")
        XCTAssertEqual(try decode(IM4Data.RemoteGroupJoinRequest.self, "{}").status, "pending")
        let raw = try decode(IM4Data.RemoteRawGroup.self, #"{"group_id":"g","group_revision":"9007199254740993","avatar":null,"avatarUrl":"a","version":"v","updated_at":"t"}"#)
        XCTAssertEqual(raw.groupRevision, 9_007_199_254_740_993)
        XCTAssertEqual(raw.avatar, "a")
        XCTAssertEqual(raw.avatarVersion, "v")
        XCTAssertEqual(raw.avatarUpdatedAt, "t")
        XCTAssertEqual(IM4Data.RemoteRawGroup(groupID: "g", groupRevision: -7).groupRevision, -7)
        let profile = try decode(IM4Data.RemoteGroupProfileUpdateResponse.self, #"{"group":{"group_id":"g","avatar":"group"},"summary":{"group_id":"preferred","avatar":"summary","avatar_version":"v"},"avatar_url":""}"#)
        XCTAssertEqual(profile.effectiveGroup.groupID, "preferred")
        XCTAssertEqual(profile.avatarURL, "")
        XCTAssertEqual(profile.avatarVersion, "v")
        XCTAssertEqual(try decode(IM4Data.RemoteGroupProfileUpdateResponse.self, "{}").effectiveGroup.groupID, "")
        let member = try decode(IM4Data.RemoteGroupMember.self, #"{"im_uid":" ","user_id":" u ","role":"future"}"#)
        XCTAssertEqual(member.imUID, "u")
        XCTAssertEqual(member.role, "future")
        XCTAssertTrue(try decode(IM4Data.RemoteGroupDNDResult.self, #"{"muted":true}"#).muted)
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupDNDResult.self, "{}"))
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroupDNDResult.self, #"{"muted":"true"}"#))
        XCTAssertEqual(try decode(IM4Data.RemoteGroup.self, #"{"group_id":"g"}"#).groupID, "g")
        XCTAssertThrowsError(try decode(IM4Data.RemoteGroup.self, "{}"))
        let mute = try decode(IM4Data.RemoteGroupMuteListItem.self, #"{"groupId":" g ","target_uid":" ","im_uid":" u ","targetUserID":" number ","targetNickname":" ","displayName":" name ","avatar_url":" avatar ","role":"future","reason":" r ","createdAt":"raw-time"}"#)
        XCTAssertEqual(mute.groupID, "g")
        XCTAssertEqual(mute.targetUID, "u")
        XCTAssertEqual(mute.targetUserID, "number")
        XCTAssertEqual(mute.targetNickname, "name")
        XCTAssertEqual(mute.targetAvatar, "avatar")
        XCTAssertEqual(mute.targetRole, "future")
        XCTAssertEqual(mute.reason, "r")
        XCTAssertEqual(mute.createdAt, "raw-time")
    }

    func testLifecycleAndMemberRemovalClientsReturnDataAndKeepAppInvalidationPolicy() async throws {
        try await withClient([
            #"{"left":true,"group_id":"g","search_invalidations":[{"event_type":"removed_conversation","channel_id":"g","channel_type":"group","version":4}]}"#,
            #"{"group_id":"g","member_count":3,"confirmation_mode":"button"}"#,
            #"{"dissolved":true,"group_id":"g","removed_members":3}"#,
            #"{"search_invalidations":[{"event_type":"permission_lost","channel_id":"g","version":5}]}"#
        ]) { client, context, transport in
            let left: IM4Data.RemoteGroupLeaveResult = try await client.leaveGroup(context: context, groupID: "g", reason: " user ")
            let preview: IM4Data.RemoteGroupDissolvePreview = try await client.previewDissolveGroup(context: context, groupID: "g")
            let dissolved: IM4Data.RemoteGroupDissolveResult = try await client.dissolveGroup(context: context, groupID: "g", confirmed: true, reason: " owner ")
            let removed: IM4Data.RemoteSearchInvalidationResponse = try await client.removeGroupMember(context: context, groupID: "g", userID: "peer")
            XCTAssertTrue(left.left)
            XCTAssertTrue(left.searchInvalidations.first?.isConversationRemoval == true)
            XCTAssertEqual(preview.memberCount, 3)
            XCTAssertEqual(dissolved.removedMembers, 3)
            XCTAssertTrue(removed.searchInvalidations.first?.isConversationRemoval == true)
            XCTAssertEqual(String(reflecting: SearchInvalidationEvent.self), "IM4Data.SearchInvalidationEvent")
            let requests = transport.requests()
            XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "POST", "POST", "DELETE"])
            XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tenant/groups/g/leave", "/api/tenant/groups/g/dissolve/preview", "/api/tenant/groups/g/dissolve", "/api/tenant/groups/g/members/peer"])
            XCTAssertEqual(try body(requests[0])["reason"] as? String, "user")
            XCTAssertTrue(try body(requests[1]).isEmpty)
            XCTAssertEqual(try body(requests[2])["confirmed"] as? Bool, true)
            XCTAssertEqual(try body(requests[2])["reason"] as? String, "owner")
            XCTAssertNil(try body(requests[2])["confirmation"])
            for request in requests { assertTenant(request) }
        }
    }

    func testMuteDNDAndHistoryClientsPreserveMutationThenReadbackContracts() async throws {
        try await withClient([
            #"{"items":[{"target_uid":"u"}]}"#, #"{"target_uid":"u"}"#, "{}",
            #"{"muted":true}"#, #"{"group":{"group_id":"g"}}"#,
            #"{"group_id":"g"}"#, #"{"group":{"group_id":"g"},"settings":{"history_visible":false}}"#
        ]) { client, context, transport in
            let list: [IM4Data.RemoteGroupMuteListItem] = try await client.listGroupMuteList(context: context, groupID: "g")
            let added: IM4Data.RemoteGroupMuteListItem = try await client.addGroupMuteListMember(context: context, groupID: "g", targetUID: " u ", reason: " ")
            try await client.removeGroupMuteListMember(context: context, groupID: "g", uid: "u")
            _ = try await client.updateGroupDND(context: context, groupID: "g", muted: true)
            let history = try await client.updateGroupHistoryVisibility(context: context, groupID: "g", historyVisible: false, expectedGroupRevision: 9_007_199_254_740_993)
            XCTAssertEqual(list.first?.targetUID, "u")
            XCTAssertEqual(added.targetUID, "u")
            XCTAssertFalse(history.settings.historyVisible)
            let requests = transport.requests()
            XCTAssertEqual(requests.count, 7)
            XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "POST", "DELETE", "PATCH", "GET", "PATCH", "GET"])
            XCTAssertEqual(requests[2].url?.path, "/api/tenant/groups/g/mute-list/u")
            XCTAssertEqual(requests[3].url?.path, "/api/tenant/groups/g/dnd")
            XCTAssertEqual(requests[4].url?.path, "/api/tenant/groups/g")
            XCTAssertEqual(requests[5].url?.path, "/api/tenant/groups/g/settings")
            XCTAssertEqual(try body(requests[1])["target_uid"] as? String, "u")
            XCTAssertNil(try body(requests[1])["reason"])
            XCTAssertEqual(try body(requests[3])["muted"] as? Bool, true)
            XCTAssertEqual(try body(requests[3])["dnd"] as? Bool, true)
            XCTAssertEqual(try body(requests[5])["history_visible"] as? Bool, false)
            XCTAssertEqual((try body(requests[5])["expected_group_revision"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
            for request in requests { assertTenant(request) }
        }
    }

    func testMixedAppWrappersKeepMessageInboxAndApprovalProjectionWhileUsingDataValues() async throws {
        try await withClient([
            #"{"group":{"group_id":"g"},"members":[{"im_uid":"u"}],"system_messages":[]}"#,
            #"{"items":[{"id":"r","status":"pending"}]}"#,
            #"{"status":"pending","request":{"id":"r"},"notifications":7,"system_messages":[],"items":[]}"#,
            #"{"id":"r","status":"approved"}"#,
            #"{"items":[],"join_requests":[{"id":"r"}],"already_members":[1],"notifications":[],"system_messages":[],"status":"pending_approval"}"#,
            #"{"im_uid":"u","role":"admin"}"#,
            #"{"summary":{"group_id":"g","name":"updated"},"avatar_url":"a"}"#
        ]) { client, context, transport in
            let created = try await client.createGroup(context: context, name: "name", memberUIDs: ["u"])
            let raw: IM4Data.RemoteRawGroup = created.group
            let members: [IM4Data.RemoteGroupMember] = created.members
            let requests: [IM4Data.RemoteGroupJoinRequest] = try await client.listGroupJoinRequests(context: context, groupID: "g")
            let submitted = try await client.createGroupJoinRequest(context: context, groupID: "g", reason: " join ")
            let reviewed: IM4Data.RemoteGroupJoinRequest = try await client.reviewGroupJoinRequest(context: context, groupID: "g", requestID: "r", approved: true)
            let invitation = try await client.inviteGroupMembers(context: context, groupID: "g", memberUIDs: ["u"])
            try await client.updateGroupMemberRole(context: context, groupID: "g", userID: "u", role: "admin")
            let profile: IM4Data.RemoteGroupProfileUpdateResponse = try await client.updateGroupProfile(context: context, groupID: "g", name: "updated", avatarFileID: nil, expectedGroupRevision: 8)
            XCTAssertEqual(raw.groupID, "g")
            XCTAssertEqual(members.first?.imUID, "u")
            XCTAssertEqual(requests.first?.id, "r")
            XCTAssertTrue(submitted.requiresApproval)
            XCTAssertTrue(submitted.notifications.isEmpty)
            XCTAssertEqual(reviewed.status, "approved")
            XCTAssertTrue(invitation.requiresApproval)
            XCTAssertEqual(invitation.invitationResultMessage, "1 人等待审核，1 人已在群中")
            XCTAssertEqual(profile.effectiveGroup.name, "updated")
            let captured = transport.requests()
            XCTAssertEqual(captured.count, 7)
            XCTAssertEqual(captured.map { $0.httpMethod }, ["POST", "GET", "POST", "POST", "POST", "PATCH", "PATCH"])
            XCTAssertEqual(captured[3].url?.path, "/api/tenant/groups/g/join-requests/r/approve")
            XCTAssertEqual(captured[4].url?.path, "/api/tenant/groups/g/members")
            XCTAssertEqual(captured[5].url?.path, "/api/tenant/groups/g/members/u/role")
            XCTAssertEqual(captured[6].url?.path, "/api/tenant/groups/g/profile")
            XCTAssertEqual(try body(captured[0])["member_uids"] as? [String], ["u"])
            XCTAssertEqual(try body(captured[2])["reason"] as? String, "join")
            XCTAssertEqual(try body(captured[2])["message"] as? String, "join")
            XCTAssertEqual(try body(captured[5])["role"] as? String, "admin")
            for request in captured { assertTenant(request) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func assertTenant(_ request: URLRequest) {
        XCTAssertEqual(request.url?.host, "tenant.example.test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lifecycle-fixture-token")
    }

    private func withClient(_ payloads: [String], operation: (IMAPIClient, IMAPIContext, FakeHTTPTransport) async throws -> Void) async throws {
        let suite = "im4.private.lifecycle-dto.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeHTTPTransport(results: payloads.map { HTTPTransportResult(data: Data(("{\"ok\":true,\"data\":" + $0 + "}").utf8), isHTTPResponse: true, statusCode: 200) })
        let client = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!, tenantBase: URL(string: "https://tenant.example.test")!, imBase: URL(string: "https://im.example.test")!, bootstrapBases: [], httpTransport: transport, runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults))
        let context = IMAPIContext(platformToken: "lifecycle-fixture-platform", accountID: "lifecycle-fixture-account", tenantID: "lifecycle-fixture-tenant", imUID: "viewer", imToken: "lifecycle-fixture-token", platformAuthSession: nil, tenantAuthSession: nil, appID: "ios-main", deviceID: "lifecycle-fixture-device")
        try await operation(client, context, transport)
    }
}
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END
