// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
import Foundation
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias SearchInvalidationEvent = IM4Data.SearchInvalidationEvent

// App-only normalization, invalidation policy and payload/removed-conversation projection stay here.
extension SearchInvalidationEvent {
    var normalizedTenantID: String? {
        let value = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedChannelID: String? {
        let value = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedChannelType: String? {
        let value = channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedMessageID: String? {
        let value = messageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var normalizedFileID: String? {
        let value = fileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    var isConversationRemoval: Bool {
        let normalizedEvent = eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAction = clientAction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedEvent.contains("removed_conversation")
            || normalizedEvent.contains("conversation_removed")
            || normalizedEvent.contains("permission_lost")
            || normalizedAction.contains("remove_conversation")
            || normalizedReason.contains("removed_conversation")
            || normalizedReason.contains("permission_lost")
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    var removesMessageDateVisibility: Bool {
        let event = eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let action = clientAction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch event {
        case "message_updated":
            return false
        case "message_recalled", "message_deleted_for_all", "message_admin_deleted", "message_search_hidden":
            return true
        default:
            return action == "delete_or_hide_message_search_cache" || (event == "message" && action == "remove")
        }
    }
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END

    var dedupeKey: String {
        let explicit = invalidationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return [tenantID, explicit].filter { !$0.isEmpty }.joined(separator: "|")
        }
        return [
            tenantID,
            eventType,
            channelType ?? "",
            channelID ?? "",
            channelSeq.map(String.init) ?? "",
            messageID ?? "",
            fileID ?? ""
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "|")
    }







    init?(
        payload: [String: JSONValue],
        fallbackTenantID: String = "",
        fallbackChannelID: String? = nil,
        fallbackChannelType: String? = nil,
        fallbackChannelSeq: Int64? = nil,
        fallbackMessageID: String? = nil,
        fallbackUpdatedAt: String? = nil
    ) {
        let searchInvalidation = payload["search_invalidation"]?.boolValue ?? false
        let eventType = Self.firstString(payload, keys: ["event_type", "eventType", "search_invalidation_type", "searchInvalidationType"])
        let action = Self.firstString(payload, keys: ["client_action", "clientAction", "search_invalidation_action", "searchInvalidationAction"])
        let hasCompatibilityMarker = Self.firstString(payload, keys: ["search_invalidation_type", "searchInvalidationType", "search_invalidation_action", "searchInvalidationAction"]) != nil
        guard searchInvalidation || hasCompatibilityMarker else { return nil }
        self.init(
            tenantID: Self.firstString(payload, keys: ["tenant_id", "tenantId"]) ?? fallbackTenantID,
            invalidationKey: Self.firstString(payload, keys: ["invalidation_key", "invalidationKey"]) ?? "",
            eventType: eventType ?? "",
            reason: Self.firstString(payload, keys: ["reason"]) ?? "",
            channelID: Self.firstString(payload, keys: ["channel_id", "channelId"]) ?? fallbackChannelID,
            channelType: Self.firstString(payload, keys: ["channel_type", "channelType"]) ?? fallbackChannelType,
            channelSeq: Self.firstInt64(payload, keys: ["channel_seq", "channelSeq"]) ?? fallbackChannelSeq,
            messageID: Self.firstString(payload, keys: ["message_id", "messageId", "msg_id", "msgId"]) ?? fallbackMessageID,
            fileID: Self.firstString(payload, keys: ["file_id", "fileId"]),
            version: Self.firstInt64(payload, keys: ["version"]) ?? 0,
            updatedAt: Self.firstString(payload, keys: ["updated_at", "updatedAt"]) ?? fallbackUpdatedAt,
            clientAction: action,
            isTenantScopeReset: payload["reset"]?.boolValue == true || payload["clear"]?.boolValue == true
        )
    }

    init(removedConversation: RemoteRemovedConversation, fallbackTenantID: String = "") {
        self.init(
            tenantID: removedConversation.tenantID.isEmpty ? fallbackTenantID : removedConversation.tenantID,
            invalidationKey: [
                "removed_conversation",
                removedConversation.channelType,
                removedConversation.channelID
            ].filter { !$0.isEmpty }.joined(separator: ":"),
            eventType: "removed_conversation",
            reason: removedConversation.reason,
            channelID: removedConversation.channelID,
            channelType: removedConversation.channelType,
            version: removedConversation.version,
            updatedAt: removedConversation.updatedAt,
            clientAction: "remove_conversation"
        )
    }

    static func tenantScopeReset(tenantID: String = "", reason: String) -> SearchInvalidationEvent {
        SearchInvalidationEvent(
            tenantID: tenantID,
            invalidationKey: "tenant_scope_reset:\(reason)",
            eventType: "tenant_scope_reset",
            reason: reason,
            clientAction: "clear_search_state",
            isTenantScopeReset: true
        )
    }

    private static func firstString(_ payload: [String: JSONValue], keys: [String]) -> String? {
        keys.compactMap { payload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func firstInt64(_ payload: [String: JSONValue], keys: [String]) -> Int64? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let raw):
                return Int64(raw)
            case .double(let raw):
                return Int64(raw)
            case .string(let raw):
                if let parsed = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }

}
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteSearchInvalidationResponse = IM4Data.RemoteSearchInvalidationResponse
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

typealias RemoteTenantConversationSearch = IM4Data.RemoteTenantConversationSearch

struct TenantConversationSearchPaginationState: Equatable, Sendable {
    let typeCursors: [String: String]
    let hitChannelSeqs: [Int64]
    let total: Int

    var hasMore: Bool {
        !typeCursors.isEmpty
    }

    init(response: RemoteTenantSearchResponse, items: [RemoteTenantSearchResult]) {
        let messageCursor = Self.nonEmpty(response.resultsByType["messages"]?.nextCursor)
            ?? Self.nonEmpty(response.conversationSearch?.nextCursor)
        let fileCursor = Self.nonEmpty(response.resultsByType["files"]?.nextCursor)
        var cursors: [String: String] = [:]
        if let messageCursor {
            cursors["messages"] = messageCursor
        }
        if let fileCursor {
            cursors["files"] = fileCursor
        }
        typeCursors = cursors

        let responseSeqs = response.conversationSearch?.hitChannelSeqs ?? []
        hitChannelSeqs = Self.uniqueSeqs(responseSeqs + items.compactMap { $0.jumpTarget?.channelSeq })

        let bucketTotal = ["messages", "files"].reduce(0) { total, type in
            total + (response.resultsByType[type]?.count ?? 0)
        }
        total = max(response.conversationSearch?.total ?? 0, bucketTotal, items.count)
    }

    func genericCursor(for types: [String]) -> String? {
        let normalized = types
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard normalized.count == 1 else { return nil }
        return typeCursors[normalized[0]]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func uniqueSeqs(_ values: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        for value in values where value > 0 && seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

typealias RemoteTenantConversationDateAnchor = IM4Data.RemoteTenantConversationDateAnchor

extension RemoteTenantConversationDateAnchor {
    var bestJumpTarget: RemoteTenantSearchJumpTarget? {
        let seq = channelSeq ?? nearestChannelSeq
        let message = messageID ?? nearestMessageID
        guard seq != nil || message != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: nil,
            channelType: nil,
            channelSeq: seq,
            messageID: message,
            fileID: nil,
            detailEndpoint: nil,
            imUID: nil,
            userID: nil,
            peerIMUID: nil
        )
    }
}

typealias TenantSearchAnalyticsEvent = IM4Data.TenantSearchAnalyticsEvent

extension TenantSearchAnalyticsEvent {
    var body: [String: Any] {
        var payload: [String: Any] = [
            "event_type": eventType,
            "scope": scope,
            "types": types,
            "query_length": max(queryLength, 0),
            "filters": filters
        ]
        if let searchID, !searchID.isEmpty { payload["search_id"] = searchID }
        if let requestID, !requestID.isEmpty { payload["request_id"] = requestID }
        if let resultType, !resultType.isEmpty { payload["result_type"] = resultType }
        if let resultID, !resultID.isEmpty { payload["result_id"] = resultID }
        if let resultRank { payload["result_rank"] = resultRank }
        if let elapsedMS { payload["elapsed_ms"] = elapsedMS }
        return payload
    }
}
// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END
