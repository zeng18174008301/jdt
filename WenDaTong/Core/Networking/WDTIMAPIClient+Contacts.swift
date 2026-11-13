import Foundation

// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
enum UserProfilesRequestAuthority {
    @TaskLocal static var isCurrent: (@MainActor @Sendable () -> Bool)?

    nonisolated static func matches(method: String, path: String, response: Any.Type) -> Bool {
        method == "POST" && path == "/api/tenant/users/profiles" && response == RemoteUserProfilesResponse.self
    }

    @MainActor
    static func check() throws {
        try Task.checkCancellation()
        try checkOwnership()
    }

    @MainActor
    static func checkOwnership() throws {
        if isCurrent?() == false { throw CancellationError() }
    }
}
// WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

@MainActor
extension IMAPIClient {
    func listFriends(context: IMAPIContext) async throws -> [RemoteFriendRelation] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteFriendRelation> = try await request(base: tenantBase(for: context), path: "/api/tenant/friends", bearer: context.imToken, requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */)
        return data.items
    }

    func friendRelationsForRemarkResolution(context: IMAPIContext) async throws -> [RemoteFriendRelation] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteFriendRelation> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/friends",
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            runtimeRouteReplayPolicy: .readOnly,
            requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */
        )
        return data.items
    }

    func organizationTree(context: IMAPIContext) async throws -> RemoteOrganizationTree {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/org/tree", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func organizationMembers(context: IMAPIContext, departmentID: String) async throws -> RemoteOrganizationMemberList {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let normalized = departmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalized.isEmpty ? "" : "?department_id=\(normalized.urlQueryEncoded)"
        // WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_BEGIN
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/members\(query)",
            bearer: context.imToken,
            preservePercentEncodedPath: true,
            requestAuthority: requestAuthority
        )
        // WDT_IOS1_ORG_MEMBERS_QUERY_ENCODING_20261111_END
    }

    func createOrganizationDepartment(context: IMAPIContext, parentDepartmentID: String, name: String) async throws -> RemoteDepartmentNode {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func updateOrganizationDepartment(context: IMAPIContext, departmentID: String, parentDepartmentID: String?, name: String?) async throws -> RemoteDepartmentNode {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func deleteOrganizationDepartment(context: IMAPIContext, departmentID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/departments/\(departmentID.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken,
            requestAuthority: requestAuthority
        )
    }

    func addOrganizationMember(context: IMAPIContext, departmentID: String, userID: String, isPrimary: Bool) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            ],
            requestAuthority: requestAuthority
        )
    }

    func removeOrganizationMember(context: IMAPIContext, departmentID: String, userID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/org/members/\(departmentID.urlPathEncoded)/\(userID.urlPathEncoded)",
            method: "DELETE",
            bearer: context.imToken,
            requestAuthority: requestAuthority
        )
    }

    func listFriendApplications(context: IMAPIContext) async throws -> [RemoteFriendApplication] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteFriendApplication> = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/applications?scope=all", bearer: context.imToken, requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */)
        return data.items
    }

    func searchTenantUsers(context: IMAPIContext, userID: String) async throws -> [RemoteUserSearchItem] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let query = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: RemoteList<RemoteUserSearchItem> = try await request(base: tenantBase(for: context), path: "/api/tenant/users/search?user_id=\(query.urlQueryEncoded)", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func userProfiles(
        context: IMAPIContext,
        exactUIDs: [String]
    ) async throws -> RemoteUserProfilesResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            runtimeRouteReplayPolicy: .readOnly,
            requestAuthority: requestAuthority
        )
    }

    func tenantSearch(
        context: IMAPIContext,
        scope: String,
        query: String,
        types: [String],
        limit: Int,
        cursor: String?,
        cursorV2: String?, // WDT_IOS1_SEARCH_CURSOR_V2_20261113
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
        hasLink: Bool, // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        messageContent: String?, // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        date: String?
    ) async throws -> RemoteTenantSearchResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
        if let cursorV2 {
            guard cursor == nil, typeCursors.isEmpty else {
                throw TenantSearchHTTPFailure(status: 400, code: "search_cursor_conflict")
            }
            queryItems.append("cursor_v2=\(cursorV2.urlQueryEncoded)")
        }
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END
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
        if hasLink { queryItems.append("has_link=true") } // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        appendQueryItem("message_content", messageContent) // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        appendQueryItem("date", date)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/search?\(queryItems.joined(separator: "&"))",
            bearer: context.imToken,
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
            preserveHTTPStatusErrors: true,
            propagateTaskCancellation: true,
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
            requestAuthority: requestAuthority
        )
    }

    func postTenantSearchEvent(context: IMAPIContext, event: TenantSearchAnalyticsEvent) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/search/events",
            method: "POST",
            bearer: context.imToken,
            body: event.body,
            requestAuthority: requestAuthority
        )
    }

    func postRiskActivityEvents(context: IMAPIContext, events: [IOSRiskActivityEvent]) async throws -> IOSRiskActivityBatchResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        guard !events.isEmpty, events.count <= 100 else {
            throw IMAPIError.missingContext("risk activity event batch")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/risk/events/batch",
            method: "POST",
            bearer: context.imToken,
            body: ["events": events.map(\.requestBody)],
            requestAuthority: requestAuthority
        )
    }

    func applyFriend(context: IMAPIContext, targetUID: String, message: String, source: String) async throws -> RemoteFriendApplyResult {
        try await applyFriend(context: context, targetUID: targetUID, message: message, source: source, sourceGroupID: nil)
    }

    func applyFriend(context: IMAPIContext, targetUID: String, message: String, source: String, sourceGroupID: String?) async throws -> RemoteFriendApplyResult {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        var body = ["target_uid": targetUID, "message": message, "source": source]
        if let sourceGroupID { body["source_group_id"] = sourceGroupID }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/friends/apply",
            method: "POST",
            bearer: context.imToken,
            body: body,
            requestAuthority: requestAuthority
        )
    }

    func acceptFriendApplication(context: IMAPIContext, id: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let diagnostic = FriendAcceptanceDiagnostic(context: context, applicationID: id)
        try await SyncFailureDiagnostic.$friendAcceptance.withValue(diagnostic) {
            diagnostic.record(.apiEntered)
            do {
                let _: EmptyPayload = try await request(base: tenantBase(for: context), path: diagnostic.path, method: "POST", bearer: context.imToken, body: [:], requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */)
                diagnostic.record(.apiSucceeded)
            } catch {
                diagnostic.record(.apiFailed, error: error)
                throw error
            }
        }
    }

    func rejectFriendApplication(context: IMAPIContext, id: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/applications/\(id.urlPathEncoded)/reject", method: "POST", bearer: context.imToken, body: [:], requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */)
    }

    func cancelFriendApplication(context: IMAPIContext, id: String) async throws -> RemoteFriendApplication {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            body: [:],
            requestAuthority: requestAuthority
        )
    }

    func deleteFriend(context: IMAPIContext, userID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/friends/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func friendProfile(context: IMAPIContext, canonicalFriendUID: String) async throws -> RemoteFriendProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let path = try Self.friendProfilePath(canonicalFriendUID: canonicalFriendUID)
        return try await request(
            base: tenantBase(for: context),
            path: path,
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData,
            preserveHTTPStatusErrors: true,
            runtimeRouteReplayPolicy: .readOnly,
            preservePercentEncodedPath: true,
            requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */
        )
    }

    func updateFriendRemark(context: IMAPIContext, canonicalFriendUID: String, remark: String) async throws -> RemoteFriendProfile {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
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
            preservePercentEncodedPath: true,
            requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */
        )
    }

    func listBlacklist(context: IMAPIContext) async throws -> [RemoteBlacklistRelation] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let data: RemoteList<RemoteBlacklistRelation> = try await request(base: tenantBase(for: context), path: "/api/tenant/blacklist", bearer: context.imToken, requestAuthority: requestAuthority, contactOwner: ContactHTTPRequestOwner.current /* WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112 */)
        return data.items
    }

    func addBlacklist(context: IMAPIContext, userID: String, reason: String) async throws -> RemoteBlacklistRelation {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/blacklist",
            method: "POST",
            bearer: context.imToken,
            body: [
                "blocked_uid": userID,
                "reason": reason
            ],
            requestAuthority: requestAuthority
        )
    }

    func deleteBlacklist(context: IMAPIContext, userID: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/blacklist/\(userID.urlPathEncoded)", method: "DELETE", bearer: context.imToken, requestAuthority: requestAuthority)
    }

    func listInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteInboxEntry> = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox?limit=50", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func listAnnouncementInbox(context: IMAPIContext) async throws -> [RemoteInboxEntry] {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let data: RemoteList<RemoteInboxEntry> = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox?kind=announcement&limit=200", bearer: context.imToken, requestAuthority: requestAuthority)
        return data.items
    }

    func markInboxRead(context: IMAPIContext, id: String) async throws {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        let _: EmptyPayload = try await request(base: tenantBase(for: context), path: "/api/tenant/inbox/\(id.urlPathEncoded)/read", method: "POST", bearer: context.imToken, body: [:], requestAuthority: requestAuthority)
    }

    func markSystemInboxRead(context: IMAPIContext) async throws -> RemoteSystemInboxReadResponse {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — Immutable caller context, captured before suspension.
        let requestAuthority = context.authSessionFence
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/inbox/system/read", method: "POST", bearer: context.imToken, body: [:], requestAuthority: requestAuthority)
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
