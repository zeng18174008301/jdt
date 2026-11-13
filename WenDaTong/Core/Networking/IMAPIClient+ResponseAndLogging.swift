// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_BEGIN
import IM4Data
// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_BEGIN
import Foundation
import IM4Core
import CryptoKit
import Dispatch

// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
typealias ConversationPageDecodedResponse = IM4Data.ConversationPageDecodedResponse
// WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END

// WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN
/// A public/pre-auth operation reports its precise rejection to its own flow, without revoking an unrelated live session.
struct IMAnonymousDeviceRejectionError: Error, LocalizedError {
    let statusCode: Int
    let code: String
    let userMessage: String
    var errorDescription: String? { userMessage }
}
// WDT_IOS1_ROOT_REQUEST_DEVICE_AUTHORITY_20261111_END

// WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
struct ContactHTTPRequestOwner: Sendable {
    let ownsOperation: @MainActor @Sendable () -> Bool
    let ownsAuthority: @MainActor @Sendable () -> Bool

    @TaskLocal static var current: Self?

    @MainActor
    func check(requiresExactAuthority: Bool = false) throws {
        try Task.checkCancellation()
        guard ownsOperation(), !requiresExactAuthority || ownsAuthority() else { throw CancellationError() }
    }
}
// WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END

// WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
struct OrganizationMembersRequestOwner: Sendable {
    let ownsRequest: @MainActor @Sendable () -> Bool
    let ownsAuthority: @MainActor @Sendable () -> Bool

    @TaskLocal static var current: Self?

    @MainActor
    static func checkOwnership(requiresCurrentAuthority: Bool = false) throws {
        guard let owner = current else { return }
        guard owner.ownsRequest(), !requiresCurrentAuthority || owner.ownsAuthority() else {
            throw CancellationError()
        }
    }

    @MainActor
    static func checkDecodedResponse(status: Int, error: APIEnvelopeError?) throws {
        try Task.checkCancellation()
        try checkOwnership(requiresCurrentAuthority: status == 401 || DeviceRevocationDetector.matches(error: error))
    }
}

// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
struct GroupDirectoryRequestOwner: Sendable {
    let ownsRefresh: @MainActor @Sendable () -> Bool
    let ownsAuthority: @MainActor @Sendable () -> Bool

    @TaskLocal static var current: Self?

    @MainActor
    func isCurrent() -> Bool {
        ownsRefresh() && ownsAuthority()
    }

    @MainActor
    static func check() throws {
        try Task.checkCancellation()
        if current?.isCurrent() == false { throw CancellationError() }
    }
}
// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END

// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
struct ScopedListRequestOwner: Sendable {
    let ownsRequest: @MainActor @Sendable () -> Bool
    let ownsAuthority: @MainActor @Sendable () -> Bool

    @TaskLocal static var current: Self?

    @MainActor
    static func check(requiresCurrentAuthority: Bool = false) throws {
        try Task.checkCancellation()
        guard let owner = current else { return }
        guard owner.ownsRequest(), !requiresCurrentAuthority || owner.ownsAuthority() else {
            throw CancellationError()
        }
    }

    @MainActor
    static func checkDecodedResponse(status: Int, error: APIEnvelopeError?) throws {
        try check(requiresCurrentAuthority: status == 401
            || DeviceRevocationDetector.matches(error: error)
            || IMAPIClient.effectiveErrorCode(for: error) == "security_blocked")
    }
}
// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END

enum TypedListResponseRoute: Equatable, Sendable { // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_BEGIN
    case other, userProfiles, organizationMembers, friends, groupMembers
    case groupDirectory // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111
    case organizationTree, favoriteAssets // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112

    nonisolated static func matching(method: String, path: String, response: Any.Type) -> Self {
        if UserProfilesRequestAuthority.matches(method: method, path: path, response: response) {
            return .userProfiles
        }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        if method == "POST", path == "/api/im/favorites/list", response == RemoteFavoriteAssetsResponse.self {
            return .favoriteAssets
        }
        guard method == "GET" else { return .other }
        if path == "/api/tenant/org/tree", response == RemoteOrganizationTree.self {
            return .organizationTree
        }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        if response == RemoteOrganizationMemberList.self {
            return path == "/api/tenant/org/members" || path.hasPrefix("/api/tenant/org/members?department_id=")
                ? .organizationMembers : .other
        }
        if response == RemoteList<RemoteFriendRelation>.self, path == "/api/tenant/friends" {
            return .friends
        }
        // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_BEGIN
        let directoryPrefix = "/api/tenant/groups?"
        if response == RemoteList<RemoteUserGroup>.self, path.hasPrefix(directoryPrefix) {
            let items = path.dropFirst(directoryPrefix.count).split(separator: "&", omittingEmptySubsequences: false)
            let offsetPrefix = "offset="
            let invalidScopeCharacters = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%")).inverted
            guard items.count == 3,
                  items[0].hasPrefix("scope="), items[0].removingPercentEncoding != nil,
                  items[0].rangeOfCharacter(from: invalidScopeCharacters) == nil,
                  items[1] == "limit=500", items[2].hasPrefix(offsetPrefix),
                  let offset = Int(items[2].dropFirst(offsetPrefix.count)), offset >= 0,
                  items[2] == "offset=\(offset)" else { return .other }
            return .groupDirectory
        }
        // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_END
        let groupPrefix = "/api/tenant/groups/"
        let membersSuffix = "/members"
        guard response == RemoteList<RemoteUserGroupMember>.self,
              let pathname = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first,
              pathname.hasPrefix(groupPrefix), pathname.hasSuffix(membersSuffix) else { return .other }
        let groupID = pathname.dropFirst(groupPrefix.count).dropLast(membersSuffix.count)
        return !groupID.isEmpty && !groupID.contains("/") ? .groupMembers : .other
    }

    @MainActor
    func checkAttempt(requiresCurrentAuthority: Bool = false) throws { // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
        switch self {
        case .other:
            return
        case .groupDirectory: // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
            try GroupDirectoryRequestOwner.check()
        case .userProfiles:
            try UserProfilesRequestAuthority.check()
        case .organizationMembers:
            try Task.checkCancellation()
            try OrganizationMembersRequestOwner.checkOwnership()
        case .friends, .groupMembers:
            try Task.checkCancellation()
        case .organizationTree, .favoriteAssets: // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
            try ScopedListRequestOwner.check(requiresCurrentAuthority: requiresCurrentAuthority)
        }
    }

    @MainActor
    func checkRoutingOwnership(requiresCurrentAuthority: Bool = false, after error: Error? = nil) throws { // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
        switch self {
        case .other, .friends, .groupMembers:
            return
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        case .organizationTree, .favoriteAssets:
            try ScopedListRequestOwner.check()
            if let error, error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if requiresCurrentAuthority, !permitsRouteEffects {
                // The current page can still show ordinary failures from before a same-session renewal.
                // The retired credential cannot contribute route evidence or be replayed.
                if let error { throw error }
                throw CancellationError()
            }
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
        case .groupDirectory:
            try GroupDirectoryRequestOwner.check()
            if let error, error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
        // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END
        case .userProfiles:
            try UserProfilesRequestAuthority.checkOwnership()
        case .organizationMembers:
            try OrganizationMembersRequestOwner.checkOwnership(requiresCurrentAuthority: requiresCurrentAuthority)
        }
    }

    // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
    @MainActor
    var permitsRouteEffects: Bool {
        switch self {
        case .organizationTree, .favoriteAssets:
            return ScopedListRequestOwner.current?.ownsAuthority() ?? true
        default:
            return true
        }
    }
    // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
} // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_END
// WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END

@MainActor
extension IMAPIClient {
    static func isSessionRefreshRequestPath(_ path: String) -> Bool {
        let requestPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return requestPath == "/api/platform/auth/session/refresh"
            || requestPath.hasPrefix("/api/platform/tenants/") && requestPath.hasSuffix("/session/refresh")
            || requestPath == "/api/tenant/auth/refresh"
            || requestPath == "/api/tenant/auth/session/refresh"
    }

    static func isPushDeviceRegistrationRequestPath(_ path: String, method: String) -> Bool {
        let requestPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "POST"
            && requestPath == "/api/tenant/devices"
    }

    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
    static func requestAuthorityCoalescingScope(
        _ requestAuthority: IMAuthSessionFence?, coalescingScope: String?
    ) -> String? {
        if let fence = requestAuthority {
            let fields = [coalescingScope == nil ? "absent" : "present", coalescingScope ?? "", fence.epoch, String(fence.credentialRevision), fence.principalKey,
                          fence.platformSessionID, fence.tenantSessionID, fence.authorityFamily.rawValue,
                          String(fence.authVersion), String(fence.sessionGeneration)]
            let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
            return "auth:" + SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return coalescingScope
    }
    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END

    func rawHTTPResult(
        for request: URLRequest,
        dedupeKey: String?,
		propagateTaskCancellation: Bool = false,
		expectedResponseOrigin: URL? = nil,
        contactOwner: ContactHTTPRequestOwner? = nil // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
    ) async throws -> RawHTTPResult {
        let httpTransport = self.httpTransport
        let producerTrace = SDKHTTPTrace.current // WDT_IOS1_SDK_GET_V3_20261111: capture creator before original detached Task.
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if let timing = HTTPRouteTiming.current, let expectedResponseOrigin {
            let result: HTTPTransportResult
            do {
                result = try await httpTransport.data(for: request, expectedOrigin: expectedResponseOrigin, routeTiming: timing)
            } catch {
                timing.failed(error)
                throw error
            }
            return RawHTTPResult(
                data: result.data, isHTTPResponse: result.isHTTPResponse, statusCode: result.statusCode,
                responseURL: result.responseURL, requestID: Self.requestID(from: result),
                retryAfterSeconds: Self.retryAfterSeconds(from: result), producerSourceCorrelation: producerTrace?.sourceCorrelation
            )
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        if propagateTaskCancellation || contactOwner != nil {
            try contactOwner?.check(requiresExactAuthority: true) // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
			let result: HTTPTransportResult
			if let expectedResponseOrigin {
				result = try await httpTransport.data(
					for: request,
					rejectingCrossOriginRedirectsFrom: expectedResponseOrigin
				)
			} else {
				result = try await httpTransport.data(for: request)
			}
            return RawHTTPResult(
                data: result.data,
                isHTTPResponse: result.isHTTPResponse,
                statusCode: result.statusCode,
				responseURL: result.responseURL,
                requestID: Self.requestID(from: result),
                retryAfterSeconds: Self.retryAfterSeconds(from: result),
                producerSourceCorrelation: producerTrace?.sourceCorrelation
            )
        }
        let claim = inFlightGETRequests.task(for: dedupeKey) {
            Task.detached(priority: .utility) { () throws -> RawHTTPResult in
                // WDT_IOS1_SDK_GET_V3_20261111_BEGIN — Carry context into the original physical producer, without another Task.
                let result = try await SDKHTTPTrace.$current.withValue(producerTrace) {
                    try await httpTransport.data(for: request)
                }
                // WDT_IOS1_SDK_GET_V3_20261111_END
                return RawHTTPResult(
                    data: result.data,
                    isHTTPResponse: result.isHTTPResponse,
                    statusCode: result.statusCode,
					responseURL: result.responseURL,
                    requestID: Self.requestID(from: result),
                    retryAfterSeconds: Self.retryAfterSeconds(from: result),
                producerSourceCorrelation: producerTrace?.sourceCorrelation
                )
            }
        }
        defer {
            inFlightGETRequests.finish(claim)
        }
        return try await claim.task.value
    }

    func decodeAPIResponse<T: Decodable>(from data: Data, observation: SDKHTTPTraceObserver? = nil) -> DecodedAPIResponse<T> {
        Self.decodeAPIResponse(from: data, using: wireCodec, observation: observation)
    }

    // WDT_CHAT_RESOURCE_PERF_20261023_BEGIN
    nonisolated static func shouldDecodeChatResponseOffMain(path: String) -> Bool {
        switch path.split(separator: "?", maxSplits: 1).first {
        case "/api/im/sync", "/api/im/message-receipts/sync", "/api/im/message-extras/sync":
            return true
        default:
            return false
        }
    }

    func decodeAPIResponseOffMain<T: Decodable>(from data: Data, observation: SDKHTTPTraceObserver? = nil) async -> DecodedAPIResponse<T> {
        let codec = wireCodec
        // No AppState or request side effects cross the actor boundary.
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                Self.decodeAPIResponse(from: data, using: codec, observation: observation) as DecodedAPIResponse<T>
            }
        }.value
    }

    // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_BEGIN
    struct TypedListDecodedResponse<Value: Decodable & Sendable>: Sendable {
        struct Envelope: Sendable {
            let ok: Bool?
            let data: Value?
            let error: APIEnvelopeError?
        }

        let errorEnvelope: APIErrorEnvelope?
        let loginSecurityEnvelope: APILoginSecurityEnvelope?
        let envelope: Envelope?

        var resolvedError: APIEnvelopeError? {
            errorEnvelope?.resolvedError ?? envelope?.error ?? loginSecurityEnvelope?.resolvedError
        }

        func classificationResponse<T: Decodable>() -> DecodedAPIResponse<T> {
            DecodedAPIResponse(errorEnvelope: errorEnvelope, loginSecurityEnvelope: loginSecurityEnvelope,
                envelope: envelope.map { APIEnvelope(ok: $0.ok, data: $0.data as? T, error: $0.error) })
        }
    }

    enum TypedListDecodeTransfer: Sendable { // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_BEGIN
        case userProfiles(TypedListDecodedResponse<RemoteUserProfilesResponse>)
        case organizationMembers(TypedListDecodedResponse<RemoteOrganizationMemberList>)
        case friends(TypedListDecodedResponse<RemoteList<RemoteFriendRelation>>)
        case groupMembers(TypedListDecodedResponse<RemoteList<RemoteUserGroupMember>>)
        case groupDirectory(TypedListDecodedResponse<RemoteList<RemoteUserGroup>>) // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        case organizationTree(TypedListDecodedResponse<RemoteOrganizationTree>)
        case favoriteAssets(TypedListDecodedResponse<RemoteFavoriteAssetsResponse>)
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END

        @MainActor
        func classificationResponse<T: Decodable>(status: Int) throws -> DecodedAPIResponse<T> {
            switch self {
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
            case .userProfiles(let profiles):
                try UserProfilesRequestAuthority.check()
                return profiles.classificationResponse()
            // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END
            case .organizationMembers(let members):
                try OrganizationMembersRequestOwner.checkDecodedResponse(status: status, error: members.resolvedError)
                return members.classificationResponse()
            case .friends(let friends):
                try Task.checkCancellation()
                return friends.classificationResponse()
            case .groupMembers(let members):
                try Task.checkCancellation()
                return members.classificationResponse()
            // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_BEGIN
            case .groupDirectory(let groups):
                try GroupDirectoryRequestOwner.check() // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
                return groups.classificationResponse()
            // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_END
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
            case .organizationTree(let tree):
                try ScopedListRequestOwner.checkDecodedResponse(status: status, error: tree.resolvedError)
                return tree.classificationResponse()
            case .favoriteAssets(let assets):
                try ScopedListRequestOwner.checkDecodedResponse(status: status, error: assets.resolvedError)
                return assets.classificationResponse()
            // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
            }
        }
    }

    func decodeTypedListTransferOffMain(
        from data: Data, route: TypedListResponseRoute, observation: SDKHTTPTraceObserver?
    ) async -> TypedListDecodeTransfer {
        switch route {
        case .userProfiles:
            return .userProfiles(await decodeTypedListResponseOffMain(from: data, observation: observation))
        case .organizationMembers:
            return .organizationMembers(await decodeTypedListResponseOffMain(from: data, observation: observation))
        case .friends:
            return .friends(await decodeTypedListResponseOffMain(from: data, observation: observation))
        case .groupMembers:
            return .groupMembers(await decodeTypedListResponseOffMain(from: data, observation: observation))
        // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_BEGIN
        case .groupDirectory:
            return .groupDirectory(await decodeTypedListResponseOffMain(from: data, observation: observation))
        // WDT_IOS1_TYPED_GROUP_DIRECTORY_PAGE_DECODE_20261111_END
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
        case .organizationTree:
            return .organizationTree(await decodeTypedListResponseOffMain(from: data, observation: observation))
        case .favoriteAssets:
            return .favoriteAssets(await decodeTypedListResponseOffMain(from: data, observation: observation))
        // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
        case .other:
            preconditionFailure("Typed list decode requires a matched route")
        }
    } // WDT_IOS1_TYPED_FRIEND_GROUP_MEMBER_LIST_DECODE_20261111_END

    private func decodeTypedListResponseOffMain<Value: Decodable & Sendable>(
        from data: Data, observation: SDKHTTPTraceObserver?
    ) async -> TypedListDecodedResponse<Value> {
        let codec = wireCodec
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let decoded: DecodedAPIResponse<Value> = Self.decodeAPIResponse(
                    from: data, using: codec, observation: observation
                )
                return TypedListDecodedResponse(
                    errorEnvelope: decoded.errorEnvelope,
                    loginSecurityEnvelope: decoded.loginSecurityEnvelope,
                    envelope: decoded.envelope.map {
                        TypedListDecodedResponse<Value>.Envelope(ok: $0.ok, data: $0.data, error: $0.error)
                    }
                )
            }
        }.value
    }
    // WDT_IOS1_TYPED_ORG_MEMBERS_DECODE_20261111_END

    // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_BEGIN
    func decodeConversationPageResponseOffMain(from data: Data, observation: SDKHTTPTraceObserver? = nil) async -> ConversationPageDecodedResponse {
        let codec = wireCodec
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
                let started = observation.map { _ in DispatchTime.now().uptimeNanoseconds }
                defer { Self.observeHTTPDecode(observation, started: started) }
                // WDT_IOS1_SDK_GET_V3_20261111_END
                return ConversationPageDecodedResponse(
                    errorEnvelope: try? codec.decode(APIErrorEnvelope.self, from: data),
                    loginSecurityEnvelope: try? codec.decode(APILoginSecurityEnvelope.self, from: data),
                    envelope: try? codec.decode(APIEnvelope<RemoteConversationPage>.self, from: data)
                )
            }
        }.value
    }
    // WDT_IOS1_TYPED_CONVERSATION_PAGE_DECODE_20261110_END

    // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_BEGIN
    struct ConversationSyncDecodedResponse: Sendable {
        struct Envelope: Sendable {
            let ok: Bool?
            let data: RemoteConversationSyncData?
            let error: APIEnvelopeError?
        }

        let errorEnvelope: APIErrorEnvelope?
        let loginSecurityEnvelope: APILoginSecurityEnvelope?
        let envelope: Envelope?
    }

    func decodeConversationSyncResponseOffMain(
        from data: Data, observation: SDKHTTPTraceObserver? = nil
    ) async -> ConversationSyncDecodedResponse {
        let codec = wireCodec
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let decoded: DecodedAPIResponse<RemoteConversationSyncData> = Self.decodeAPIResponse(
                    from: data, using: codec, observation: observation
                )
                return ConversationSyncDecodedResponse(
                    errorEnvelope: decoded.errorEnvelope,
                    loginSecurityEnvelope: decoded.loginSecurityEnvelope,
                    // Keep a present envelope even if its decoded data is nil.
                    envelope: decoded.envelope.map {
                        ConversationSyncDecodedResponse.Envelope(ok: $0.ok, data: $0.data, error: $0.error)
                    }
                )
            }
        }.value
    }
    // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_END

    nonisolated private static func decodeAPIResponse<T: Decodable>(
        from data: Data,
        using wireCodec: any WireCodec,
        observation: SDKHTTPTraceObserver? = nil
    ) -> DecodedAPIResponse<T> {
        // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
        let started = observation.map { _ in DispatchTime.now().uptimeNanoseconds }
        defer { observeHTTPDecode(observation, started: started) }
        // WDT_IOS1_SDK_GET_V3_20261111_END
        return DecodedAPIResponse(
            errorEnvelope: try? wireCodec.decode(APIErrorEnvelope.self, from: data),
            loginSecurityEnvelope: try? wireCodec.decode(APILoginSecurityEnvelope.self, from: data),
            envelope: try? wireCodec.decode(APIEnvelope<T>.self, from: data)
        )
    }
    // WDT_IOS1_SDK_GET_V3_20261111_BEGIN
    /// Synchronous at the original decode completion, before its existing actor hop.
    nonisolated private static func observeHTTPDecode(_ observer: SDKHTTPTraceObserver?, started: UInt64?) {
        guard let observer, let started else { return }
        let uptime = DispatchTime.now().uptimeNanoseconds
        let actualMain = Thread.isMainThread
        observer(uptime, uptime &- started, actualMain)
    }
    // WDT_IOS1_SDK_GET_V3_20261111_END
    // WDT_CHAT_RESOURCE_PERF_20261023_END

    nonisolated static func timeoutInterval(for path: String, method: String) -> TimeInterval {
        let normalizedPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedMethod == "GET" else { return 8 }
        if normalizedPath == "/.well-known/wenxintong-app.json"
            || normalizedPath == "/api/app/bootstrap"
            || normalizedPath == "/api/platform/apps/current-policy" {
            return 4
        }
        if normalizedPath == "/api/tenant/files"
            || normalizedPath == "/api/tenant/friends"
            || normalizedPath == "/api/tenant/groups"
            || normalizedPath == "/api/tenant/devices"
            || normalizedPath == "/api/tenant/inbox"
            || normalizedPath == "/api/tenant/user-stickers"
            || normalizedPath == "/api/tenant/sticker-packs"
            || normalizedPath.hasPrefix("/api/tenant/sticker-packs/") {
            return 15
        }
        return 8
    }

    nonisolated static func redactedPathForLog(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    nonisolated static func idempotentGETRequestKey(base: URL, path: String, method: String, bearer: String?, body: [String: Any]?, coalescingScope: String? = nil) -> String? {
        guard method.uppercased() == "GET", body == nil else { return nil }
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }
        guard !isClearOnReadGETPath(normalizedPath) else { return nil }
        let bearerKey = bearer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = ["GET", base.absoluteString, normalizedPath, bearerKey].joined(separator: "\u{1F}")
        guard let coalescingScope else { return key }
        // This namespace is local to an asset-store binding, never a wire header
        // or query parameter. Length-prefix it so callers cannot alias scopes.
        return "scoped-GET|\(coalescingScope.utf8.count):\(coalescingScope)|\(key)"
    }

    nonisolated static func isClearOnReadGETPath(_ path: String) -> Bool {
        let normalized = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return normalized == "/api/rtc/calls/events"
    }

    private nonisolated static let verboseHTTPLoggingEnabled =
        ProcessInfo.processInfo.arguments.contains("-WDTVerboseHTTPLogging")

    func logHTTPRequestStart(method: String, url: URL, bodyData: Data?, dedupeKey: String?) {
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
#if DEBUG
        guard Self.verboseHTTPLoggingEnabled, !Self.isRegistrationSubmissionURL(url) else { return }
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bodyBytes = bodyData?.count ?? 0
        let bodyText = Self.shouldSuppressFriendEndpointLogBody(method: normalizedMethod, url: url)
            ? ""
            : Self.redactedLogBody(bodyData)
        let dedupeText = dedupeKey == nil ? "none" : "get_inflight"
        print(Self.apiLogDivider(icon: "➡️", title: "REQUEST START"))
        print("[JHT API] ➡️ request_start method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) body_bytes=\(bodyBytes) dedupe=\(dedupeText)")
        if !bodyText.isEmpty {
            print("[JHT API] 📤 request_body method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) json=\(bodyText)")
        }
#endif
    }

    func logHTTPResponse(method: String, url: URL, statusCode: Int, requestID: String?, data: Data, elapsedMS: Int) {
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
#if DEBUG
        guard Self.verboseHTTPLoggingEnabled, !Self.isRegistrationSubmissionURL(url) else { return }
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let requestIDText = requestID?.isEmpty == false ? requestID! : "none"
        let statusIcon = Self.httpResponseLogIcon(statusCode)
        print(Self.apiLogDivider(icon: statusIcon, title: Self.httpResponseLogTitle(statusCode)))
        print("[JHT API] \(statusIcon) response method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) status=\(statusCode) request_id=\(requestIDText) bytes=\(data.count) elapsed_ms=\(elapsedMS)")
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改开始：真机性能分析期间限制大响应正文日志，避免日志系统放大卡顿
        let responseBodyLog = Self.redactedResponseBodyLog(
            method: normalizedMethod,
            url: url,
            statusCode: statusCode,
            data: data
        )
        if let suppressedReason = responseBodyLog.suppressedReason {
            print("[JHT API] \(statusIcon) response_body_suppressed method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) request_id=\(requestIDText) bytes=\(data.count) reason=\(suppressedReason)")
        } else if !responseBodyLog.bodyText.isEmpty {
            print("[JHT API] \(statusIcon) response_body method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) request_id=\(requestIDText) json=\(responseBodyLog.bodyText)")
        }
        // JHT_MOD_END TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改结束
#endif
    }

    nonisolated static func httpResponseLogIcon(_ statusCode: Int) -> String {
        (200..<300).contains(statusCode) ? "✅" : "❌"
    }

    nonisolated static func httpResponseLogTitle(_ statusCode: Int) -> String {
        (200..<300).contains(statusCode) ? "RESPONSE OK" : "RESPONSE ERROR"
    }

    nonisolated static func apiLogDivider(icon: String, title: String) -> String {
        "[JHT API] \(icon) ────────── \(title) ──────────"
    }

    // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改开始：真机性能分析期间限制大响应正文日志，避免日志系统放大卡顿
    nonisolated static func redactedResponseBodyLog(
        method: String,
        url: URL,
        statusCode: Int,
        data: Data
    ) -> (bodyText: String, suppressedReason: String?) {
        if shouldSuppressFriendEndpointLogBody(method: method, url: url) {
            return ("", nil)
        }
        guard (200..<300).contains(statusCode) else {
            return (redactedLogBody(data, maxCharacters: 2_000), nil)
        }
        if shouldSuppressHighVolumeResponseBodyLog(method: method, url: url) {
            return ("", "high_volume_endpoint")
        }
        if data.count > 4_096 {
            return ("", "large_body")
        }
        return (redactedLogBody(data, maxCharacters: 1_500), nil)
    }

    nonisolated static func shouldSuppressHighVolumeResponseBodyLog(method: String, url: URL) -> Bool {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMethod == "GET" || normalizedMethod == "POST" else { return false }
        switch path {
        case "/api/tenant/org/members",
             "/api/im/conversations/page",
             "/api/im/delivery-ack",
             "/api/im/message-receipts/sync",
             "/api/im/sync",
             "/api/tenant/inbox":
            return true
        default:
            return false
        }
    }
    // JHT_MOD_END TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改结束

    nonisolated static func shouldSuppressFriendEndpointLogBody(method: String, url: URL) -> Bool {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if path == "/api/tenant/friends", normalizedMethod == "GET" {
            return true
        }
        return path.hasPrefix("/api/tenant/friends/")
            && !path.hasPrefix("/api/tenant/friends/applications/")
    }

    nonisolated static func isRegistrationSubmissionURL(_ url: URL) -> Bool {
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path == "/api/platform/auth/register"
            || path == "/api/platform/auth/register/status"
            || path == "/api/platform/auth/register/session"
    }

    nonisolated static func redactedLogBody(_ data: Data?, maxCharacters: Int = 12_000) -> String {
        guard let data, !data.isEmpty else { return "" }
        let rawText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? ""
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let redacted = redactedSensitiveLogText(trimmed)
        guard redacted.count > maxCharacters else { return redacted }
        let index = redacted.index(redacted.startIndex, offsetBy: maxCharacters)
        return "\(redacted[..<index])...<truncated chars=\(redacted.count)>"
    }

    func logRequestFailure(method: String, url: URL, statusCode: Int?, errorCode: String, requestID: String?, error: Error?) {
        SyncFailureDiagnostic.httpObservation?.record(path: url.path, status: statusCode, code: errorCode)
        // The dedicated accept channel already preserves safe request metadata.
        // Do not also emit its dynamic application path, free text or payload.
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
        if let event = SyncFailureDiagnostic.SessionRequestFailure(
            method: method, path: url.path, status: statusCode, code: errorCode,
            requestSummary: requestID.map(Self.diagnosticFingerprint)
        ) {
            SyncFailureDiagnostic.persistSessionRequestFailure(event)
        }
        guard !Self.isRegistrationSubmissionURL(url) else { return }
        let status = statusCode.map(String.init) ?? "none"
        let requestIDText = requestID?.isEmpty == false ? requestID! : "none"
#if DEBUG
        if Self.verboseHTTPLoggingEnabled {
            let errorText = error.map { " error=\(Self.redactedSensitiveLogText($0.localizedDescription))" } ?? ""
            let wsBase = webSocketURL(context: IMAPIContext.load())
                .map { Self.redactedURLString($0, redactAllQueryValues: true) }
                ?? "unavailable"
            print(Self.apiLogDivider(icon: "❌", title: "REQUEST FAILED"))
            print("[JHT API] ❌ request_failed method=\(method) url=\(Self.redactedURLString(url, redactAllQueryValues: true)) status=\(status) code=\(errorCode) request_id=\(requestIDText) platformBase=\(Self.redactedURLString(platformBase, redactAllQueryValues: true)) tenantBase=\(Self.redactedURLString(tenantBase, redactAllQueryValues: true)) imBase=\(Self.redactedURLString(imBase, redactAllQueryValues: true)) wsBase=\(wsBase)\(errorText)")
            return
        }
#endif
        print("[JHT API] ❌ request_failed method=\(method) url=\(Self.redactedURLString(url, redactAllQueryValues: true)) status=\(status) code=\(errorCode) request_id=\(requestIDText)")
    }

    nonisolated static func rtcSignalDebug(_ message: @autoclosure () -> String) {
        let value = message()
#if DEBUG
        NSLog("[JHT RTC][API] %@", value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(
                category: "API",
                media: Self.rtcSignalMediaLabel(from: value),
                message: value
            )
        }
    }

    nonisolated private static func rtcSignalMediaLabel(from message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("video") || normalized.contains("media=video") || normalized.contains("media_mode=video") {
            return "video"
        }
        if normalized.contains("voice") || normalized.contains("audio") || normalized.contains("media=audio") || normalized.contains("media_mode=audio") {
            return "voice"
        }
        return "unknown"
    }

    nonisolated static func rtcShortDebugID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(4)) + "..." + String(trimmed.suffix(4))
    }

    nonisolated static func rtcDeviceDebugHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}

// WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110_END
// WDT_IOS1_DATA_HTTP_ENVELOPE_RECORDS_20261111_END
