// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
import Foundation
import IM4Data

typealias RemoteMessageSearchResponse = IM4Data.RemoteMessageSearchResponse

typealias RemoteMessageSearchResult = IM4Data.RemoteMessageSearchResult

typealias RemoteTenantSearchResponse = IM4Data.RemoteTenantSearchResponse

typealias RemoteTenantSearchBucket = IM4Data.RemoteTenantSearchBucket

// RemoteTenantSearchResultsByType privatewirehelper movedwithcompleteSearchResponsecodec.

// RemoteTenantSearchDynamicCodingKey privatewirehelper movedwithcompleteSearchResponsecodec.

typealias RemoteTenantSearchResult = IM4Data.RemoteTenantSearchResult

extension RemoteTenantSearchResult: @retroactive Identifiable {
    public var id: String {
        "\(type):\(resultID)"
    }
}

extension RemoteTenantSearchResult {
    var displayModel: TenantSearchResultDisplayModel {
        TenantSearchResultDisplayModel(item: self)
    }

    var isBlockedFromChatSearchDisplay: Bool {
        TenantSearchResultGuard.isBlockedFromChatSearchDisplay(self)
    }

    func matchesSearchInvalidation(_ invalidation: SearchInvalidationEvent) -> Bool {
        guard !invalidation.isTenantScopeReset else { return true }
        let target = jumpTarget
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKind = target?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let fileID = invalidation.normalizedFileID {
            let resultFileID = target?.fileID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackFileID = resultID.hasPrefix("file:") ? String(resultID.dropFirst(5)) : resultID
            if resultFileID == fileID || fallbackFileID.trimmingCharacters(in: .whitespacesAndNewlines) == fileID {
                return true
            }
        }
        if let messageID = invalidation.normalizedMessageID {
            if target?.messageID?.trimmingCharacters(in: .whitespacesAndNewlines) == messageID {
                return true
            }
            if normalizedType == "messages" || normalizedKind == "message" || normalizedKind == "message_file" {
                if resultID.trimmingCharacters(in: .whitespacesAndNewlines) == messageID {
                    return true
                }
            }
        }
        if let channelID = invalidation.normalizedChannelID {
            let targetChannelID = target?.channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelMatches = targetChannelID == channelID
            let typeMatches = invalidation.normalizedChannelType == nil
                || invalidation.normalizedChannelType == target?.channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if channelMatches && typeMatches {
                if invalidation.isConversationRemoval {
                    return true
                }
                if let channelSeq = invalidation.channelSeq, channelSeq > 0 {
                    return target?.channelSeq == channelSeq
                }
            }
        }
        return false
    }
}

struct TenantSearchResultDisplayModel: Equatable, Sendable {
    let primaryText: String
    let primaryField: String
    let secondaryText: String?
    let secondaryField: String

    private struct DisplayCandidate {
        let text: String
        let field: String
    }

    init(item: RemoteTenantSearchResult) {
        let normalizedType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = Self.trimmed(item.title)
        let snippet = Self.trimmed(item.snippet)
        let subtitle = Self.trimmed(item.subtitle)
        let fallback = Self.fallbackTitle(for: normalizedType)
        if normalizedType == "message" || normalizedType == "messages" {
            let primary = snippet ?? title ?? fallback
            primaryText = primary
            primaryField = snippet == nil && title != nil ? "title" : "snippet"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.friendlySourceCandidate(for: item),
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(title, field: "title")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        } else if normalizedType == "file" || normalizedType == "files" {
            let primary = title ?? snippet ?? fallback
            primaryText = primary
            primaryField = title == nil && snippet != nil ? "snippet" : "title"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.friendlySourceCandidate(for: item),
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(snippet, field: "snippet")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        } else {
            let primary = title ?? snippet ?? fallback
            primaryText = primary
            primaryField = title == nil && snippet != nil ? "snippet" : "title"
            let candidate = Self.firstDistinctCandidate(from: [
                Self.candidate(subtitle, field: "subtitle"),
                Self.candidate(snippet, field: "snippet")
            ], primary: primary)
            secondaryText = candidate?.text
            secondaryField = candidate?.field ?? "subtitle"
        }
    }

    static func normalizedComparableText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstDistinctCandidate(from candidates: [DisplayCandidate?], primary: String) -> DisplayCandidate? {
        let normalizedPrimary = normalizedComparableText(primary)
        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = normalizedComparableText(candidate.text)
            if !normalized.isEmpty && normalized != normalizedPrimary {
                return candidate
            }
        }
        return nil
    }

    private static func candidate(_ value: String?, field: String) -> DisplayCandidate? {
        guard let text = userFriendlyText(value) else { return nil }
        return DisplayCandidate(text: text, field: field)
    }

    private static func userFriendlyText(_ value: String?) -> String? {
        guard let text = trimmed(value), !isTechnicalSourceText(text) else { return nil }
        return text
    }

    private static func friendlySourceCandidate(for item: RemoteTenantSearchResult) -> DisplayCandidate? {
        guard let text = friendlySourceText(for: item) else { return nil }
        return DisplayCandidate(text: text, field: "subtitle")
    }

    private static func friendlySourceText(for item: RemoteTenantSearchResult) -> String? {
        let source = item.source
        let conversation = firstFriendlySourceValue(source, keys: [
            "conversation_title", "conversationTitle",
            "conversation_name", "conversationName",
            "channel_title", "channelTitle",
            "channel_name", "channelName",
            "group_name", "groupName",
            "source_label", "sourceLabel",
            "label"
        ]) ?? channelTypeFallback(item.jumpTarget?.channelType)
        let actor = firstFriendlySourceValue(source, keys: [
            "sender_display_name", "senderDisplayName",
            "sender_name", "senderName",
            "from_name", "fromName",
            "uploader_name", "uploaderName",
            "owner_name", "ownerName",
            "display_name", "displayName",
            "nickname"
        ])
        let time = firstFriendlySourceValue(source, keys: [
            "display_time", "displayTime",
            "time"
        ])
        let components = [conversation, actor, time].compactMap { userFriendlyText($0) }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func firstFriendlySourceValue(_ source: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let text = userFriendlyText(source[key]?.stringValue) {
                return text
            }
        }
        return nil
    }

    private static func channelTypeFallback(_ channelType: String?) -> String? {
        switch channelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "group": return "群聊"
        case "direct": return "单聊"
        case "system": return "系统消息"
        default: return nil
        }
    }

    private static func isTechnicalSourceText(_ value: String) -> Bool {
        let normalized = normalizedComparableText(value)
        if normalized.range(of: #"^(group|direct|system|channel|conversation)\s*#\s*\S+$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^(group|direct|system|channel|conversation)[_-][a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: #"^(uid|im_uid|user|account)[\s:#_-]*[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func fallbackTitle(for type: String) -> String {
        switch type {
        case "contact", "contacts": return "联系人"
        case "group", "groups": return "群聊"
        case "conversation", "conversations": return "会话"
        case "message", "messages": return "聊天记录"
        case "file", "files": return "文件"
        default: return "搜索结果"
        }
    }
}

enum TenantSearchResultGuard {
    static func isBlockedFromChatSearchDisplay(_ item: RemoteTenantSearchResult) -> Bool {
        let normalizedType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "message" || normalizedType == "messages" else { return false }
        let blockedTokens: Set<String> = [
            "sensitive_hit",
            "blocked_by_sensitive_word",
            "sensitive_blocked",
            "risk_notice",
            "sensitive_notice",
            "friend_sensitive_notice"
        ]
        if blockedTokens.contains(item.jumpTarget?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") {
            return true
        }
        if stringValues(in: item.source).contains(where: { blockedTokens.contains($0) }) {
            return true
        }
        let boolKeys = ["sensitive_hit", "blocked_by_sensitive_word", "sensitive_blocked", "risk_notice", "sensitive_notice"]
        if boolKeys.contains(where: { item.source[$0]?.boolValue == true }) {
            return true
        }
        let kind = normalizedSourceString(item.source["kind"])
            ?? normalizedSourceString(item.source["message_kind"])
            ?? normalizedSourceString(item.source["event_type"])
        if let kind, blockedTokens.contains(kind) {
            return true
        }
        let contentType = normalizedSourceString(item.source["content_type"])
            ?? normalizedSourceString(item.source["contentType"])
        return contentType == "system"
    }

    private static func normalizedSourceString(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func stringValues(in value: JSONValue) -> [String] {
        switch value {
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? [] : [normalized]
        case .object(let object):
            return stringValues(in: object)
        case .array(let values):
            return values.flatMap(stringValues)
        default:
            return []
        }
    }

    private static func stringValues(in object: [String: JSONValue]) -> [String] {
        object.flatMap { entry in
            let normalizedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return [normalizedKey] + stringValues(in: entry.value)
        }
    }
}

typealias RemoteTenantSearchParsedFilter = IM4Data.RemoteTenantSearchParsedFilter

extension RemoteTenantSearchParsedFilter: @retroactive Identifiable {
    public var id: String {
        [type, key, operatorName ?? "", value, raw ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ":")
    }
}

extension RemoteTenantSearchParsedFilter {
    var displayTitle: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return normalizedValue }
        guard !normalizedValue.isEmpty else { return normalizedKey }
        return "\(normalizedKey): \(normalizedValue)"
    }
}

typealias RemoteTenantSearchHighlightRange = IM4Data.RemoteTenantSearchHighlightRange

typealias RemoteTenantSearchJumpTarget = IM4Data.RemoteTenantSearchJumpTarget
// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END
