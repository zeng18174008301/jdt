import Foundation

@MainActor
extension IMAPIClient {
    func listFriends(context: IMAPIContext) async throws -> [RemoteFriendRelation] {
        let data: RemoteList<RemoteFriendRelation> = try await request(base: tenantBase(for: context), path: "/api/tenant/friends", bearer: context.imToken)
        return data.items
    }

    func friendRelationsForRemarkResolution(context: IMAPIContext) async throws -> [RemoteFriendRelation] {
        try requireIM(context)
        let data: RemoteList<RemoteFriendRelation> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/friends",
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            runtimeRouteReplayPolicy: .readOnly
        )
        return data.items
    }

    func organizationTree(context: IMAPIContext) async throws -> RemoteOrganizationTree {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/org/tree", bearer: context.imToken)
    }

    func organizationMembers(context: IMAPIContext, departmentID: String) async throws -> RemoteOrganizationMemberList {
        try requireIM(context)
        let normalized = departmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalized.isEmpty ? "" : "?department_id=\(normalized.urlQueryEncoded)"
        return try await request(base: tenantBase(for: context), path: "/api/tenant/org/members\(query)", bearer: context.imToken)
    }

    func createOrganizationDepartment(context: IMAPIContext, parentDepartmentID: String, name: String) async throws -> RemoteDepartmentNode {
        try requireIM(context)
        var body: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        let parentID = parentDepartmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parentID.isEmpty {
            body["parent_department_id"] = parentID
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/departments",
            method: "POST",
            bearer: context.imToken,
            body: body
        )
    }

    func updateOrganizationDepartment(context: IMAPIContext, departmentID: String, parentDepartmentID: String?, name: String?) async throws -> RemoteDepartmentNode {
        try requireIM(context)
        var body: [String: Any] = [:]
        if let name {
            body["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parentDepartmentID {
            body["parent_department_id"] = parentDepartmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/departments/\(departmentID.urlPathEncoded)",
            method: "PATCH",
            bearer: context.imToken,
            body: body
        )
    }

    func deleteOrganizationDepartment(context: IMAPIContext, departmentID: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/departments/\(departmentID.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken
        )
    }

    func addOrganizationMember(context: IMAPIContext, departmentID: String, userID: String, isPrimary: Bool) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/members",
            method: "POST",
            bearer: context.imToken,
            body: [
                "department_id": departmentID,
                "im_uid": userID,
                "is_primary": isPrimary
            ]
        )
    }

    func removeOrganizationMember(context: IMAPIContext, departmentID: String, userID: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/members/\(departmentID.urlPathEncoded)/\(userID.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken
        )
    }

    func listFriendApplications(context: IMAPIContext) async throws -> [RemoteFriendApplication] {
        let data: RemoteList<RemoteFriendApplication> = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/applications?scope=all", bearer: context.imToken)
        return data.items
    }

    func searchTenantUsers(context: IMAPIContext, userID: String) async throws -> [RemoteUserSearchItem] {
        try requireIM(context)
        let query = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: RemoteList<RemoteUserSearchItem> = try await request(base: tenantBase(for: context), path: "/api/tenant/users/search?user_id=\(query.urlQueryEncoded)", bearer: context.imToken)
        return data.items
    }

    func userProfiles(
        context: IMAPIContext,
        exactUIDs: [String]
    ) async throws -> RemoteUserProfilesResponse {
        try requireIM(context)
        let normalizedUIDs = CertificationProfileUIDBatch.normalized(exactUIDs)
        guard !normalizedUIDs.isEmpty,
              normalizedUIDs.count == Set(
                exactUIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
              ).count,
              normalizedUIDs.count <= CertificationProfileUIDBatch.maximumCount else {
            throw IMAPIError.server("invalid_user_profiles_batch")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/users/profiles",
            method: "POST",
            bearer: context.imToken,
            body: ["uids": normalizedUIDs],
            timeoutInterval: TimeInterval(AvatarAuthorityRefreshBudget.requestNanoseconds)
                / 1_000_000_000,
            runtimeRouteReplayPolicy: .readOnly
        )
    }

    func tenantSearch(
        context: IMAPIContext,
        scope: String,
        query: String,
        types: [String],
        limit: Int,
        cursor: String?,
        typeCursors: [String: String],
        channelID: String?,
        channelType: String?,
        fromUID: String?,
        senderID: String?,
        startAt: String?,
        after: String?,
        endAt: String?,
        before: String?,
        fileType: String?,
        mimeType: String?,
        date: String?
    ) async throws -> RemoteTenantSearchResponse {
        try requireIM(context)
        var queryItems: [String] = [
            "scope=\(scope.trimmingCharacters(in: .whitespacesAndNewlines).urlQueryEncoded)",
            "q=\(query.trimmingCharacters(in: .whitespacesAndNewlines).urlQueryEncoded)",
            "types=\(types.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ",").urlQueryEncoded)",
            "limit=\(min(max(limit, 1), 50))"
        ]
        func appendQueryItem(_ name: String, _ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
            queryItems.append("\(name)=\(trimmed.urlQueryEncoded)")
        }
        if let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !cursor.isEmpty {
            queryItems.append("cursor=\(cursor.urlQueryEncoded)")
        }
        for (type, cursor) in typeCursors {
            let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedCursor = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedType.isEmpty, !normalizedCursor.isEmpty else { continue }
            let paramName = normalizedType.hasSuffix("_cursor") ? normalizedType : "\(normalizedType)_cursor"
            queryItems.append("\(paramName)=\(normalizedCursor.urlQueryEncoded)")
        }
        appendQueryItem("channel_id", channelID)
        appendQueryItem("channel_type", channelType)
        appendQueryItem("from_uid", fromUID)
        appendQueryItem("sender_id", senderID)
        appendQueryItem("start_at", startAt)
        appendQueryItem("after", after)
        appendQueryItem("end_at", endAt)
        appendQueryItem("before", before)
        appendQueryItem("file_type", fileType)
        appendQueryItem("mime_type", mimeType)
        appendQueryItem("date", date)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/search?\(queryItems.joined(separator: "&"))",
            bearer: context.imToken
        )
    }

    func postTenantSearchEvent(context: IMAPIContext, event: TenantSearchAnalyticsEvent) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/search/events",
            method: "POST",
            bearer: context.imToken,
            body: event.body
        )
    }

    func postRiskActivityEvents(context: IMAPIContext, events: [IOSRiskActivityEvent]) async throws -> IOSRiskActivityBatchResult {
        try requireIM(context)
        guard !events.isEmpty, events.count <= 100 else {
            throw IMAPIError.missingContext("risk activity event batch")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/risk/events/batch",
            method: "POST",
            bearer: context.imToken,
            body: ["events": events.map(\.requestBody)]
        )
    }

    func applyFriend(context: IMAPIContext, targetUID: String, message: String, source: String) async throws -> RemoteFriendApplyResult {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/friends/apply",
            method: "POST",
            bearer: context.imToken,
            body: [
                "target_uid": targetUID,
                "message": message,
                "source": source
            ]
        )
    }

    func acceptFriendApplication(context: IMAPIContext, id: String) async throws {
        let diagnostic = FriendAcceptanceDiagnostic(context: context, applicationID: id)
        try await SyncFailureDiagnostic.$friendAcceptance.withValue(diagnostic) {
            diagnostic.record(.apiEntered)
            do {
                let _: EmptyPayload = try await request(base: tenantBase(for: context), path: diagnostic.path, method: "POST", bearer: context.imToken, body: [:])
                diagnostic.record(.apiSucceeded)
            } catch {
                diagnostic.record(.apiFailed, error: error)
                throw error
            }
        }
    }

    func rejectFriendApplication(context: IMAPIContext, id: String) async throws {
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/applications/\(id.urlPathEncoded)/reject", method: "POST", bearer: context.imToken, body: [:])
    }

    func cancelFriendApplication(context: IMAPIContext, id: String) async throws -> RemoteFriendApplication {
        try requireIM(context)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw IMAPIError.missingContext("friend application id")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/friends/applications/\(normalizedID.urlPathEncoded)/cancel",
            method: "POST",
            bearer: context.imToken,
            body: [:]
        )
    }

    func deleteFriend(context: IMAPIContext, userID: String) async throws {
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken)
    }

    func friendProfile(context: IMAPIContext, canonicalFriendUID: String) async throws -> RemoteFriendProfile {
        try requireIM(context)
        let path = try Self.friendProfilePath(canonicalFriendUID: canonicalFriendUID)
        return try await request(
            base: tenantBase(for: context),
            path: path,
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            preserveHTTPStatusErrors: true,
            runtimeRouteReplayPolicy: .readOnly,
            preservePercentEncodedPath: true
        )
    }

    func updateFriendRemark(context: IMAPIContext, canonicalFriendUID: String, remark: String) async throws -> RemoteFriendProfile {
        try requireIM(context)
        let normalizedRemark = try FriendRemarkInputPolicy.normalize(remark)
        let path = try Self.friendProfilePath(canonicalFriendUID: canonicalFriendUID)
        return try await request(
            base: tenantBase(for: context),
            path: path,
            method: "PATCH",
            bearer: context.imToken,
            body: ["remark": normalizedRemark],
            preserveHTTPStatusErrors: true,
            preservePercentEncodedPath: true
        )
    }

    func listBlacklist(context: IMAPIContext) async throws -> [RemoteBlacklistRelation] {
        try requireIM(context)
        let data: RemoteList<RemoteBlacklistRelation> = try await request(base: tenantBase(for: context), path: "/api/tenant/blacklist", bearer: context.imToken)
        return data.items
    }

    func addBlacklist(context: IMAPIContext, userID: String, reason: String) async throws -> RemoteBlacklistRelation {
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/blacklist",
            method: "POST",
            bearer: context.imToken,
            body: [
                "blocked_uid": userID,
                "reason": reason
            ]
        )
    }

    func deleteBlacklist(context: IMAPIContext, userID: String) async throws {
        try requireIM(context)
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/blacklist/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken)
    }

    func listInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry] {
        let data: RemoteList<RemoteInboxEntry> = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox?limit=50", bearer: context.imToken)
        return data.items
    }

    func listAnnouncementInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry] {
        let data: RemoteList<RemoteInboxEntry> = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox?kind=announcement&limit=200", bearer: context.imToken)
        return data.items
    }

    func markInboxRead(context: IMAPIContext, id: String) async throws {
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox/\(id.urlPathEncoded)/read", method: "POST", bearer: context.imToken, body: [:])
    }

    func markSystemInboxRead(context: IMAPIContext) async throws -> RemoteSystemInboxReadResponse {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/inbox/system/read", method: "POST", bearer: context.imToken, body: [:])
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
