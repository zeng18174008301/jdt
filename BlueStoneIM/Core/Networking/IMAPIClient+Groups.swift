import Foundation

@MainActor
extension IMAPIClient {
    func reviewGroupInviteApproval(context: IMAPIContext, endpoint: String, reason: String = "") async throws -> RemoteGroupInviteApprovalReviewResponse {
        try requireIM(context)
        var body: [String: Any] = [:]
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedReason.isEmpty {
            body["reason"] = normalizedReason
        }
        do {
            return try await request(base: tenantBase(for: context), path: normalizedEndpoint, method: "POST", bearer: context.imToken, body: body)
        } catch IMAPIError.emptyResponse {
            return RemoteGroupInviteApprovalReviewResponse()
        }
    }

    func listGroups(context: IMAPIContext, scope: String) async throws -> [RemoteUserGroup] {
        try requireIM(context)
        let pageLimit = 500
        var offset = 0
        var groups: [RemoteUserGroup] = []
        var seenGroupIDs = Set<String>()

        while true {
            let data: RemoteList<RemoteUserGroup> = try await request(
                base: tenantBase(for: context),
                path: "/api/tenant/groups?scope=\(scope.urlPathEncoded)&limit=\(pageLimit)&offset=\(offset)",
                bearer: context.imToken
            )
            for group in data.items where seenGroupIDs.insert(group.groupID).inserted {
                groups.append(group)
            }
            guard data.hasMore == true else { return groups }

            let nextOffset = data.nextOffset ?? (offset + data.items.count)
            guard nextOffset > offset else {
                throw IMAPIError.server("group_list_pagination_invalid")
            }
            offset = nextOffset
        }
    }

    func createGroup(context: IMAPIContext, name: String, memberUIDs: [String]) async throws -> RemoteCreateGroupResponse {
        try requireIM(context)
        var body: [String: Any] = ["name": name]
        if !memberUIDs.isEmpty {
            body["member_uids"] = memberUIDs
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups", method: "POST", bearer: context.imToken, body: body)
    }

    func presignGroupAvatarUpload(context: IMAPIContext, groupID: String, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/avatar/presign-upload",
            method: "POST",
            bearer: context.imToken,
            body: [
                "file_name": fileName,
                "mime_type": mimeType,
                "size_bytes": sizeBytes,
                "width": width,
                "height": height,
                "app_id": context.appID
            ]
        )
    }

    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?) async throws -> RemoteGroupProfileUpdateResponse {
        try await updateGroupProfile(context: context, groupID: groupID, name: name, avatarFileID: avatarFileID, expectedGroupRevision: 0)
    }

    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?, expectedGroupRevision: Int64) async throws -> RemoteGroupProfileUpdateResponse {
        try requireIM(context)
        var body: [String: Any] = [:]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["name"] = name
        }
        if let avatarFileID, !avatarFileID.isEmpty {
            body["avatar_file_id"] = avatarFileID
        }
        body["expected_group_revision"] = max(0, expectedGroupRevision)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/profile",
            method: "PATCH",
            bearer: context.imToken,
            body: body
        )
    }

    func groupDetail(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDetail {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)", bearer: context.imToken)
    }

    func groupSummary(context: IMAPIContext, groupID: String) async throws -> RemoteGroupSummary {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/summary",
            bearer: context.imToken,
            preserveHTTPStatusErrors: true
        )
    }

    func leaveGroup(context: IMAPIContext, groupID: String, reason: String? = nil) async throws -> RemoteGroupLeaveResult {
        try requireIM(context)
        var body: [String: Any] = [:]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            body["reason"] = reason
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/leave",
            method: "POST",
            bearer: context.imToken,
            body: body
        )
    }

    func previewDissolveGroup(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDissolvePreview {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/dissolve/preview",
            method: "POST",
            bearer: context.imToken,
            body: [:]
        )
    }

    func dissolveGroup(context: IMAPIContext, groupID: String, confirmed: Bool, reason: String? = nil) async throws -> RemoteGroupDissolveResult {
        try requireIM(context)
        var body: [String: Any] = ["confirmed": confirmed]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            body["reason"] = reason
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/dissolve",
            method: "POST",
            bearer: context.imToken,
            body: body
        )
    }

    func listGroupMembers(context: IMAPIContext, groupID: String) async throws -> RemoteGroupMembersResult {
        try requireIM(context)
        let data: RemoteList<RemoteUserGroupMember> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members", bearer: context.imToken)
        return RemoteGroupMembersResult(items: data.items, selfMember: data.selfMember, total: data.total)
    }

    func listGroupMembersPaged(context: IMAPIContext, groupID: String, limit: Int, offset: Int?, cursor: String?, keyword: String?, role: String?) async throws -> RemoteGroupMembersResult {
        try requireIM(context)
        var queryItems: [String] = ["limit=\(min(100, max(1, limit)))"]
        if let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !cursor.isEmpty {
            queryItems.append("cursor=\(cursor.urlQueryEncoded)")
        } else if let offset {
            queryItems.append("offset=\(max(0, offset))")
        }
        if let keyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty {
            queryItems.append("keyword=\(keyword.urlQueryEncoded)")
        }
        if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            queryItems.append("role=\(role.urlQueryEncoded)")
        }
        let data: RemoteList<RemoteUserGroupMember> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members?\(queryItems.joined(separator: "&"))",
            bearer: context.imToken
        )
        return RemoteGroupMembersResult(
            items: data.items,
            selfMember: data.selfMember,
            total: data.total,
            limit: data.limit,
            offset: data.offset,
            hasMore: data.hasMore,
            nextOffset: data.nextOffset,
            nextCursor: data.nextCursor
        )
    }

    func searchGroupMembers(context: IMAPIContext, groupID: String, keyword: String) async throws -> RemoteGroupMembersResult {
        try requireIM(context)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedKeyword.isEmpty ? "" : "?keyword=\(trimmedKeyword.urlQueryEncoded)"
        let data: RemoteList<RemoteUserGroupMember> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members\(suffix)", bearer: context.imToken)
        return RemoteGroupMembersResult(items: data.items, selfMember: data.selfMember, total: data.total)
    }

    func updateMyGroupNickname(context: IMAPIContext, groupID: String, groupNickname: String) async throws -> RemoteGroupMemberProfile {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/me",
            method: "PATCH",
            bearer: context.imToken,
            body: ["group_nickname": groupNickname]
        )
    }

    func listGroupAnnouncements(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncementList {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements", bearer: context.imToken)
    }

    func currentGroupAnnouncement(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncement? {
        try requireIM(context)
        do {
            let remote: RemoteGroupAnnouncement = try await request(
                base: tenantBase(for: context),
                path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/current",
                bearer: context.imToken
            )
            return remote.id.isEmpty ? nil : remote
        } catch IMAPIError.emptyResponse {
            return nil
        } catch IMAPIError.server(let message) where Self.isNoCurrentGroupAnnouncementMessage(message) {
            return nil
        }
    }

    func groupAnnouncementDetail(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/\(announcementID.urlPathEncoded)", bearer: context.imToken)
    }

    func markGroupAnnouncementRead(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/\(announcementID.urlPathEncoded)/read",
            method: "POST",
            bearer: context.imToken,
            body: [:]
        )
    }

    func createGroupAnnouncement(context: IMAPIContext, groupID: String, title: String, content: String) async throws -> RemoteGroupAnnouncement {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements",
            method: "POST",
            bearer: context.imToken,
            body: ["title": title.isEmpty ? "群公告" : title, "content": content, "status": "published"]
        )
    }

    func updateGroupAnnouncement(context: IMAPIContext, groupID: String, announcementID: String, title: String, content: String, expectedUpdatedAt: String) async throws -> RemoteGroupAnnouncement {
        try requireIM(context)
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAnnouncementID = announcementID.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = expectedUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedAnnouncementID.isEmpty, !revision.isEmpty else {
            throw IMAPIError.missingContext("group announcement revision")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(normalizedGroupID.urlPathEncoded)/announcements/\(normalizedAnnouncementID.urlPathEncoded)",
            method: "PATCH",
            bearer: context.imToken,
            body: [
                "title": title,
                "content": content,
                "expected_updated_at": revision
            ]
        )
    }

    func listGroupJoinRequests(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupJoinRequest] {
        try requireIM(context)
        let data: RemoteList<RemoteGroupJoinRequest> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests", bearer: context.imToken)
        return data.items
    }

    func createGroupJoinRequest(context: IMAPIContext, groupID: String, reason: String = "") async throws -> RemoteCreateGroupJoinRequestResponse {
        try requireIM(context)
        var body: [String: Any] = [:]
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedReason.isEmpty {
            body["reason"] = normalizedReason
            body["message"] = normalizedReason
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests", method: "POST", bearer: context.imToken, body: body)
    }

    func reviewGroupJoinRequest(context: IMAPIContext, groupID: String, requestID: String, approved: Bool) async throws -> RemoteGroupJoinRequest {
        try requireIM(context)
        let action = approved ? "approve" : "reject"
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests/\(requestID.urlPathEncoded)/\(action)",
            method: "POST",
            bearer: context.imToken,
            body: ["reason": approved ? "同意入群" : "拒绝入群"]
        )
    }

    func updateGroupMute(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws -> RemoteGroupDetail {
        var body: [String: Any] = ["all_muted": allMuted]
        if let startAt {
            body["all_muted_start_at"] = encoderFormatter.string(from: startAt)
        }
        if let endAt {
            body["all_muted_end_at"] = encoderFormatter.string(from: endAt)
        }
        let _: RemoteRawGroup = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute", method: "PATCH", bearer: context.imToken, body: body)
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupMute(
        context: IMAPIContext,
        groupID: String,
        mode: GroupMuteMode,
        startAt: Date?,
        endAt: Date?
    ) async throws -> RemoteGroupDetail {
        try await updateGroupMute(
            context: context,
            groupID: groupID,
            mode: mode,
            startAt: startAt,
            endAt: endAt,
            expectedGroupRevision: 0
        )
    }

    func updateGroupMute(
        context: IMAPIContext,
        groupID: String,
        mode: GroupMuteMode,
        startAt: Date?,
        endAt: Date?,
        expectedGroupRevision: Int64
    ) async throws -> RemoteGroupDetail {
        let state = try GroupMuteModeState.normalize(
            GroupMuteModeIntent(
                allMuted: mode != .off,
                mode: mode,
                startAt: startAt,
                endAt: endAt
            )
        )
        var body: [String: Any] = [
            "all_muted": state.allMuted,
            "all_muted_mode": state.mode.rawValue,
            "expected_group_revision": max(0, expectedGroupRevision)
        ]
        if let startAt = state.startAt {
            body["all_muted_start_at"] = encoderFormatter.string(from: startAt)
        }
        if let endAt = state.endAt {
            body["all_muted_end_at"] = encoderFormatter.string(from: endAt)
        }
        let _: RemoteRawGroup = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute",
            method: "PATCH",
            bearer: context.imToken,
            body: body
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupDND(context: IMAPIContext, groupID: String, muted: Bool) async throws -> RemoteGroupDetail {
        let _: RemoteGroupDNDResult = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/dnd", method: "PATCH", bearer: context.imToken, body: ["muted": muted, "dnd": muted])
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool) async throws -> RemoteGroupDetail {
        try await updateGroupInviteApproval(context: context, groupID: groupID, required: required, expectedGroupRevision: 0)
    }

    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail {
        let _: RemoteGroup = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["invite_confirm_required": required, "expected_group_revision": max(0, expectedGroupRevision)]
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool) async throws -> RemoteGroupDetail {
        try await updateGroupHistoryVisibility(context: context, groupID: groupID, historyVisible: historyVisible, expectedGroupRevision: 0)
    }

    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail {
        let _: RemoteGroup = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["history_visible": historyVisible, "expected_group_revision": max(0, expectedGroupRevision)]
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String) async throws -> RemoteGroupSettingsMutationResult {
        try await updateGroupDescription(context: context, groupID: groupID, description: description, expectedGroupRevision: 0)
    }

    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String, expectedGroupRevision: Int64) async throws -> RemoteGroupSettingsMutationResult {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["description": description, "expected_group_revision": max(0, expectedGroupRevision)]
        )
    }

    func listGroupMuteList(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupMuteListItem] {
        try requireIM(context)
        let data: RemoteList<RemoteGroupMuteListItem> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute-list",
            bearer: context.imToken
        )
        return data.items
    }

    func addGroupMuteListMember(context: IMAPIContext, groupID: String, targetUID: String, reason: String) async throws -> RemoteGroupMuteListItem {
        try requireIM(context)
        var body: [String: Any] = ["target_uid": targetUID.trimmingCharacters(in: .whitespacesAndNewlines)]
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty {
            body["reason"] = trimmedReason
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute-list",
            method: "POST",
            bearer: context.imToken,
            body: body
        )
    }

    func removeGroupMuteListMember(context: IMAPIContext, groupID: String, uid: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute-list/\(uid.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken
        )
    }

    func removeGroupMember(context: IMAPIContext, groupID: String, userID: String) async throws -> RemoteSearchInvalidationResponse {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken)
    }

    func inviteGroupMembers(context: IMAPIContext, groupID: String, memberUIDs: [String]) async throws -> RemoteInviteGroupMembersResponse {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members", method: "POST", bearer: context.imToken, body: ["member_uids": memberUIDs])
    }

    func updateGroupSettings(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws {
        var body: [String: Any] = ["all_muted": allMuted]
        if let startAt {
            body["all_muted_start_at"] = encoderFormatter.string(from: startAt)
        }
        if let endAt {
            body["all_muted_end_at"] = encoderFormatter.string(from: endAt)
        }
        let _: RemoteGroup = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings", method: "PATCH", bearer: context.imToken, body: body)
    }

    func updateGroupMemberRole(context: IMAPIContext, groupID: String, userID: String, role: String) async throws {
        let _: RemoteGroupMember = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/\(userID.urlPathEncoded)/role", method: "PATCH", bearer: context.imToken, body: ["role": role])
    }

    func transferGroupOwner(context: IMAPIContext, groupID: String, newOwnerUID: String, idempotencyKey: String) async throws -> RemoteGroupOwnerTransferResult {
        try requireIM(context)
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOwnerUID = newOwnerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty,
              !normalizedOwnerUID.isEmpty,
              !normalizedKey.isEmpty,
              normalizedKey.count <= 128 else {
            throw IMAPIError.missingContext("group owner transfer")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(normalizedGroupID.urlPathEncoded)/owner/transfer",
            method: "POST",
            bearer: context.imToken,
            body: ["new_owner_uid": normalizedOwnerUID],
            additionalHeaders: ["Idempotency-Key": normalizedKey],
            runtimeRouteReplayPolicy: .singleSend
        )
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
