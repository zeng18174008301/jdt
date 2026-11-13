import Foundation

@MainActor
extension IMAPIClient {
    func reviewGroupInviteApproval(context: IMAPIContext, endpoint: String, reason: String = "") async throws -> RemoteGroupInviteApprovalReviewResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body: [String: Any] = [:]
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedReason.isEmpty {
            body["reason"] = normalizedReason
        }
        do {
            return try await request(base: tenantBase(for: context), path: normalizedEndpoint, method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
        } catch IMAPIError.emptyResponse {
            return RemoteGroupInviteApprovalReviewResponse()
        }
    }

    func listGroups(context: IMAPIContext, scope: String) async throws -> [RemoteUserGroup] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let pageLimit = 500
        let encodedScope = scope.urlPathEncoded.replacingOccurrences(of: "&", with: "%26") // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
        var offset = 0
        var groups: [RemoteUserGroup] = []
        var seenGroupIDs = Set<String>()

        while true {
            try GroupDirectoryRequestOwner.check() // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
            let data: RemoteList<RemoteUserGroup> = try await request(
                base: tenantBase(for: context),
                path: "/api/tenant/groups?scope=\(encodedScope)&limit=\(pageLimit)&offset=\(offset)", // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
                bearer: context.imToken,
                preservePercentEncodedPath: true, // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
                requestAuthority: requestAuthority
            )
            try GroupDirectoryRequestOwner.check() // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
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
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body: [String: Any] = ["name": name]
        if !memberUIDs.isEmpty {
            body["member_uids"] = memberUIDs
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func presignGroupAvatarUpload(context: IMAPIContext, groupID: String, fileName: String, mimeType: String, sizeBytes: Int, width: Int, height: Int) async throws -> RemoteAvatarUploadData {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            ],
            requestAuthority: requestAuthority
        )
    }

    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?) async throws -> RemoteGroupProfileUpdateResponse {
        try await updateGroupProfile(context: context, groupID: groupID, name: name, avatarFileID: avatarFileID, expectedGroupRevision: 0)
    }

    func updateGroupProfile(context: IMAPIContext, groupID: String, name: String?, avatarFileID: String?, expectedGroupRevision: Int64) async throws -> RemoteGroupProfileUpdateResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func groupDetail(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func groupSummary(context: IMAPIContext, groupID: String) async throws -> RemoteGroupSummary {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/summary",
            bearer: context.imToken,
            preserveHTTPStatusErrors: true,
            requestAuthority: requestAuthority
        )
    }

    func leaveGroup(context: IMAPIContext, groupID: String, reason: String? = nil) async throws -> RemoteGroupLeaveResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func previewDissolveGroup(context: IMAPIContext, groupID: String) async throws -> RemoteGroupDissolvePreview {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/dissolve/preview",
            method: "POST",
            bearer: context.imToken,
            body: [:],
            requestAuthority: requestAuthority
        )
    }

    func dissolveGroup(context: IMAPIContext, groupID: String, confirmed: Bool, reason: String? = nil) async throws -> RemoteGroupDissolveResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func listGroupMembers(context: IMAPIContext, groupID: String) async throws -> RemoteGroupMembersResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteUserGroupMember> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members", bearer: context.imToken, requestAuthority: requestAuthority)
        return RemoteGroupMembersResult(items: data.items, selfMember: data.selfMember, total: data.total)
    }

    func listGroupMembersPaged(context: IMAPIContext, groupID: String, limit: Int, offset: Int?, cursor: String?, keyword: String?, role: String?) async throws -> RemoteGroupMembersResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            bearer: context.imToken,
            requestAuthority: requestAuthority
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
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedKeyword.isEmpty ? "" : "?keyword=\(trimmedKeyword.urlQueryEncoded)"
        let data: RemoteList<RemoteUserGroupMember> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members\(suffix)", bearer: context.imToken, requestAuthority: requestAuthority)
        return RemoteGroupMembersResult(items: data.items, selfMember: data.selfMember, total: data.total)
    }

    func updateMyGroupNickname(context: IMAPIContext, groupID: String, groupNickname: String) async throws -> RemoteGroupMemberProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/me",
            method: "PATCH",
            bearer: context.imToken,
            body: ["group_nickname": groupNickname],
            requestAuthority: requestAuthority
        )
    }

    func listGroupAnnouncements(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncementList {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func currentGroupAnnouncement(context: IMAPIContext, groupID: String) async throws -> RemoteGroupAnnouncement? {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        do {
            let remote: RemoteGroupAnnouncement = try await request(
                base: tenantBase(for: context),
                path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/current",
                bearer: context.imToken,
                requestAuthority: requestAuthority
            )
            return remote.id.isEmpty ? nil : remote
        } catch IMAPIError.emptyResponse {
            return nil
        } catch IMAPIError.server(let message) where Self.isNoCurrentGroupAnnouncementMessage(message) {
            return nil
        }
    }

    func groupAnnouncementDetail(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/\(announcementID.urlPathEncoded)", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func markGroupAnnouncementRead(context: IMAPIContext, groupID: String, announcementID: String) async throws -> RemoteGroupAnnouncement {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements/\(announcementID.urlPathEncoded)/read",
            method: "POST",
            bearer: context.imToken,
            body: [:],
            requestAuthority: requestAuthority
        )
    }

    func createGroupAnnouncement(context: IMAPIContext, groupID: String, title: String, content: String) async throws -> RemoteGroupAnnouncement {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/announcements",
            method: "POST",
            bearer: context.imToken,
            body: ["title": title.isEmpty ? "群公告" : title, "content": content, "status": "published"],
            requestAuthority: requestAuthority
        )
    }

    func updateGroupAnnouncement(context: IMAPIContext, groupID: String, announcementID: String, title: String, content: String, expectedUpdatedAt: String) async throws -> RemoteGroupAnnouncement {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            ],
            requestAuthority: requestAuthority
        )
    }

    func listGroupJoinRequests(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupJoinRequest] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteGroupJoinRequest> = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func createGroupJoinRequest(context: IMAPIContext, groupID: String, reason: String = "") async throws -> RemoteCreateGroupJoinRequestResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body: [String: Any] = [:]
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedReason.isEmpty {
            body["reason"] = normalizedReason
            body["message"] = normalizedReason
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests", method: "POST", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func reviewGroupJoinRequest(context: IMAPIContext, groupID: String, requestID: String, approved: Bool) async throws -> RemoteGroupJoinRequest {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let action = approved ? "approve" : "reject"
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/join-requests/\(requestID.urlPathEncoded)/\(action)",
            method: "POST",
            bearer: context.imToken,
            body: ["reason": approved ? "同意入群" : "拒绝入群"],
            requestAuthority: requestAuthority
        )
    }

    func updateGroupMute(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body: [String: Any] = ["all_muted": allMuted]
        if let startAt {
            body["all_muted_start_at"] = encoderFormatter.string(from: startAt)
        }
        if let endAt {
            body["all_muted_end_at"] = encoderFormatter.string(from: endAt)
        }
        let _: RemoteRawGroup = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute", method: "PATCH", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
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
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupDND(context: IMAPIContext, groupID: String, muted: Bool) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: RemoteGroupDNDResult = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/dnd", method: "PATCH", bearer: context.imToken, body: ["muted": muted, "dnd": muted], requestAuthority: requestAuthority)
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool) async throws -> RemoteGroupDetail {
        try await updateGroupInviteApproval(context: context, groupID: groupID, required: required, expectedGroupRevision: 0)
    }

    func updateGroupMemberFriendApply(context: IMAPIContext, groupID: String, enabled: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: RemoteGroup = try await request(base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings", method: "PATCH", bearer: context.imToken,
            body: ["web_member_friend_apply_enabled": enabled, "expected_group_revision": max(0, expectedGroupRevision)],
                requestAuthority: requestAuthority)
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupInviteApproval(context: IMAPIContext, groupID: String, required: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: RemoteGroup = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["invite_confirm_required": required, "expected_group_revision": max(0, expectedGroupRevision)],
            requestAuthority: requestAuthority
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool) async throws -> RemoteGroupDetail {
        try await updateGroupHistoryVisibility(context: context, groupID: groupID, historyVisible: historyVisible, expectedGroupRevision: 0)
    }

    func updateGroupHistoryVisibility(context: IMAPIContext, groupID: String, historyVisible: Bool, expectedGroupRevision: Int64) async throws -> RemoteGroupDetail {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: RemoteGroup = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["history_visible": historyVisible, "expected_group_revision": max(0, expectedGroupRevision)],
            requestAuthority: requestAuthority
        )
        return try await groupDetail(context: context, groupID: groupID)
    }

    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String) async throws -> RemoteGroupSettingsMutationResult {
        try await updateGroupDescription(context: context, groupID: groupID, description: description, expectedGroupRevision: 0)
    }

    func updateGroupDescription(context: IMAPIContext, groupID: String, description: String, expectedGroupRevision: Int64) async throws -> RemoteGroupSettingsMutationResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings",
            method: "PATCH",
            bearer: context.imToken,
            body: ["description": description, "expected_group_revision": max(0, expectedGroupRevision)],
            requestAuthority: requestAuthority
        )
    }

    func listGroupMuteList(context: IMAPIContext, groupID: String) async throws -> [RemoteGroupMuteListItem] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteGroupMuteListItem> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute-list",
            bearer: context.imToken,
            requestAuthority: requestAuthority
        )
        return data.items
    }

    func addGroupMuteListMember(context: IMAPIContext, groupID: String, targetUID: String, reason: String) async throws -> RemoteGroupMuteListItem {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func removeGroupMuteListMember(context: IMAPIContext, groupID: String, uid: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/groups/\(groupID.urlPathEncoded)/mute-list/\(uid.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken,
            requestAuthority: requestAuthority
        )
    }

    func removeGroupMember(context: IMAPIContext, groupID: String, userID: String) async throws -> RemoteSearchInvalidationResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func inviteGroupMembers(context: IMAPIContext, groupID: String, memberUIDs: [String]) async throws -> RemoteInviteGroupMembersResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members", method: "POST", bearer: context.imToken, body: ["member_uids": memberUIDs], requestAuthority: requestAuthority)
    }

    func updateGroupSettings(context: IMAPIContext, groupID: String, allMuted: Bool, startAt: Date?, endAt: Date?) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        var body: [String: Any] = ["all_muted": allMuted]
        if let startAt {
            body["all_muted_start_at"] = encoderFormatter.string(from: startAt)
        }
        if let endAt {
            body["all_muted_end_at"] = encoderFormatter.string(from: endAt)
        }
        let _: RemoteGroup = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/settings", method: "PATCH", bearer: context.imToken, body: body, requestAuthority: requestAuthority)
    }

    func updateGroupMemberRole(context: IMAPIContext, groupID: String, userID: String, role: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: RemoteGroupMember = try await request(base: tenantBase(for: context), path: "/api/tenant/groups/\(groupID.urlPathEncoded)/members/\(userID.urlPathEncoded)/role", method: "PATCH", bearer: context.imToken, body: ["role": role], requestAuthority: requestAuthority)
    }

    func transferGroupOwner(context: IMAPIContext, groupID: String, newOwnerUID: String, idempotencyKey: String) async throws -> RemoteGroupOwnerTransferResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            runtimeRouteReplayPolicy: .singleSend,
            requestAuthority: requestAuthority
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
