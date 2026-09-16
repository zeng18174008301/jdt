import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

struct RealtimeMessageIngestBuffer {
    struct GroupedMessages {
        let scopeKey: String
        let channelID: String
        let channelType: String
        let messages: [RemoteMessage]
    }

    private struct Entry {
        let message: RemoteMessage
        let scopeKey: String
        let order: Int
    }

    private var entries: [Entry] = []
    private var nextOrder = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func append(_ message: RemoteMessage, scopeKey: String) {
        entries.append(Entry(message: message, scopeKey: scopeKey, order: nextOrder))
        nextOrder += 1
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        nextOrder = 0
    }

    mutating func drainGrouped(currentScopeKey: String) -> [GroupedMessages] {
        let drained = entries
        clear()

        var groupOrder: [String] = []
        var grouped: [String: (scopeKey: String, channelID: String, channelType: String, messages: [RemoteMessage], firstOrder: Int)] = [:]
        for entry in drained where entry.scopeKey == currentScopeKey {
            let channelID = entry.message.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelType = entry.message.channelType.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(entry.scopeKey)|\(channelType.lowercased())|\(channelID)"
            if grouped[key] == nil {
                groupOrder.append(key)
                grouped[key] = (
                    scopeKey: entry.scopeKey,
                    channelID: channelID,
                    channelType: channelType,
                    messages: [],
                    firstOrder: entry.order
                )
            }
            grouped[key]?.messages.append(entry.message)
        }

        return groupOrder
            .compactMap { grouped[$0] }
            .sorted { $0.firstOrder < $1.firstOrder }
            .map {
                GroupedMessages(
                    scopeKey: $0.scopeKey,
                    channelID: $0.channelID,
                    channelType: $0.channelType,
                    messages: $0.messages
                )
            }
    }
}

func isMessagePinForbiddenMessage(_ message: String) -> Bool {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("message_pin_forbidden")
        || normalized.contains("only group owner or admin can pin")
        || normalized.contains("仅群主或管理员可以置顶消息")
        || normalized.contains("仅群主和管理员才能置顶")
}

func isGroupMemberNotFoundMessage(_ message: String) -> Bool {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("group_member_not_found")
        || normalized.contains("current user is not a group member")
        || message.contains("不是群成员")
        || message.contains("不在该群")
        || message.contains("已不在该群")
}

func isGroupMembershipSystemEvent(_ rawValue: String) -> Bool {
    let event = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !event.isEmpty else { return false }
    return [
        "group_member_invited",
        "group_member_invite",
        "group_member_added",
        "group_member_joined",
        "group_member_removed",
        "group_member_deleted",
        "group_member_kicked",
        "group_member_left",
        "group_member_quit",
        "group_member_exited",
        "group_joined",
        "group_left",
        "member_invited",
        "member_joined",
        "member_removed",
        "member_kicked",
        "member_left"
    ].contains(event)
}

// JHT_MOD_BEGIN APPSTATE_TIME_FORMATTER_DECOUPLE_PERF_20260913 - 修改开始：时间解析/格式化从 AppState 拆出并复用 formatter，减少消息/会话渲染重复分配
enum AppStateTimeFormatter {
    static func parseRemoteDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = fractionalISO8601Formatter.date(from: raw) {
            return date
        }
        return standardISO8601Formatter.date(from: raw)
    }

    static func parseRemoteAbsoluteDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isTimeOnlyDisplay(value) else { return nil }
        return parseRemoteDate(value) ?? inferCreatedAt(fromDisplayTime: value)
    }

    static func isTimeOnlyRemoteValue(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return isTimeOnlyDisplay(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func displayTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "刚刚" }
        guard let date = parseRemoteDate(raw) else { return raw }
        return displayTime(date)
    }

    static func displayTime(_ date: Date) -> String {
        let format = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日"
        let out = dateFormatter(format: format)
        out.locale = Locale(identifier: "zh_CN")
        out.calendar = Calendar.current
        out.timeZone = .current
        return out.string(from: date)
    }

    static func byteSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private static var fractionalISO8601Formatter: ISO8601DateFormatter {
        threadLocalFormatter(key: "AppStateTimeFormatter.fractionalISO8601") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }
    }

    private static var standardISO8601Formatter: ISO8601DateFormatter {
        threadLocalFormatter(key: "AppStateTimeFormatter.standardISO8601") {
            ISO8601DateFormatter()
        }
    }

    private static func dateFormatter(format: String) -> DateFormatter {
        threadLocalFormatter(key: "AppStateTimeFormatter.date.\(format)") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func threadLocalFormatter<T: AnyObject>(
        key: String,
        make: () -> T
    ) -> T {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[key] as? T {
            return formatter
        }
        let formatter = make()
        dictionary[key] = formatter
        return formatter
    }

    private static func isTimeOnlyDisplay(_ value: String) -> Bool {
        value.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func inferCreatedAt(fromDisplayTime raw: String, now: Date = Date()) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "刚刚" { return now }
        if value == "昨天" {
            return Calendar.current.date(byAdding: .day, value: -1, to: now)
        }

        let parts = value.split(separator: " ").map(String.init)
        if value.hasPrefix("今天"), let token = parts.last {
            return dateForTimeToken(token, dayOffset: 0, now: now)
        }
        if value.hasPrefix("昨天"), let token = parts.last {
            return dateForTimeToken(token, dayOffset: -1, now: now)
        }
        if let weekdayDate = dateForWeekdayDisplay(value, now: now) {
            return weekdayDate
        }
        if let monthDayDate = dateForMonthDayDisplay(value, now: now) {
            return monthDayDate
        }
        if let date = dateForTimeToken(value, dayOffset: 0, now: now) {
            return date > now ? Calendar.current.date(byAdding: .day, value: -1, to: date) : date
        }
        return nil
    }

    private static func dateForTimeToken(_ token: String, dayOffset: Int, now: Date) -> Date? {
        let parts = token.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        let calendar = Calendar.current
        guard let baseDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: baseDay)
    }

    private static func dateForWeekdayDisplay(_ value: String, now: Date) -> Date? {
        let weekdays = ["周日": 1, "周一": 2, "周二": 3, "周三": 4, "周四": 5, "周五": 6, "周六": 7]
        guard let key = weekdays.keys.first(where: { value.hasPrefix($0) }),
              let targetWeekday = weekdays[key] else { return nil }
        let calendar = Calendar.current
        let currentWeekday = calendar.component(.weekday, from: now)
        var dayOffset = targetWeekday - currentWeekday
        if dayOffset > 0 {
            dayOffset -= 7
        }
        let token = value.split(separator: " ").map(String.init).last ?? ""
        let candidate = dateForTimeToken(token, dayOffset: dayOffset, now: now)
            ?? calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))
        guard let candidate else { return nil }
        if candidate > now {
            return calendar.date(byAdding: .day, value: -7, to: candidate)
        }
        return candidate
    }

    private static func dateForMonthDayDisplay(_ value: String, now: Date) -> Date? {
        guard value.contains("月"), value.contains("日") else { return nil }
        let calendar = Calendar.current
        let datePart = value.split(separator: " ").map(String.init).first ?? value
        let numbers = datePart
            .replacingOccurrences(of: "月", with: " ")
            .replacingOccurrences(of: "日", with: "")
            .split(separator: " ")
            .compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        var components = calendar.dateComponents([.year], from: now)
        components.month = numbers[0]
        components.day = numbers[1]
        components.hour = 0
        components.minute = 0
        guard let date = calendar.date(from: components) else { return nil }
        if date > now {
            return calendar.date(byAdding: .year, value: -1, to: date)
        }
        return date
    }
}
// JHT_MOD_END APPSTATE_TIME_FORMATTER_DECOUPLE_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改开始：远端会话时间/排序纯计算从 AppState 拆出
enum RemoteConversationTimelineMapper {
    static func activityDate(remote: RemoteConversation, previous: Conversation?) -> Date? {
        let remoteCandidates = sortTimeCandidates(remote)
        for candidate in remoteCandidates where !AppStateTimeFormatter.isTimeOnlyRemoteValue(candidate) {
            if let date = AppStateTimeFormatter.parseRemoteDate(candidate) {
                return date
            }
        }
        let displayFallbackCandidates = remoteCandidates + [previous?.time]
        for candidate in displayFallbackCandidates {
            if let date = AppStateTimeFormatter.parseRemoteAbsoluteDate(candidate) {
                return date
            }
        }
        if let previous, previous.sortTimestamp > 0 {
            return Date(timeIntervalSince1970: previous.sortTimestamp)
        }
        return nil
    }

    static func displayTime(
        remote: RemoteConversation,
        previous: Conversation?,
        activityDate: Date?
    ) -> String {
        if let last = remote.lastMessage,
           last.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
            return rtcMessageDisplayTime(last)
        }
        if let activityDate {
            return AppStateTimeFormatter.displayTime(activityDate)
        }
        let lastMessageAt = remote.lastMessageAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastMessageAt.isEmpty {
            return AppStateTimeFormatter.displayTime(lastMessageAt)
        }
        let messageCreatedAt = remote.lastMessage?.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !messageCreatedAt.isEmpty {
            return AppStateTimeFormatter.displayTime(messageCreatedAt)
        }
        let lastActivityAt = remote.lastActivityAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastActivityAt.isEmpty {
            return AppStateTimeFormatter.displayTime(lastActivityAt)
        }
        let updatedAt = remote.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !updatedAt.isEmpty {
            return AppStateTimeFormatter.displayTime(updatedAt)
        }
        return previous?.time ?? ""
    }

    static func sortTimestamp(remote: RemoteConversation, previous: Conversation? = nil) -> TimeInterval {
        activityDate(remote: remote, previous: previous)?.timeIntervalSince1970 ?? 0
    }

    static func latestSeq(remote: RemoteConversation) -> Int64 {
        max(remote.lastMsgSeq, remote.lastMessage?.channelSeq ?? 0)
    }

    static func freshnessPrecedes(_ lhs: RemoteConversation, _ rhs: RemoteConversation) -> Bool {
        let lhsSeq = latestSeq(remote: lhs)
        let rhsSeq = latestSeq(remote: rhs)
        if lhsSeq != rhsSeq { return lhsSeq > rhsSeq }
        let lhsTimestamp = sortTimestamp(remote: lhs)
        let rhsTimestamp = sortTimestamp(remote: rhs)
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp }
        if lhs.version != rhs.version { return lhs.version > rhs.version }
        return lhs.channelID < rhs.channelID
    }

    private static func sortTimeCandidates(_ remote: RemoteConversation) -> [String?] {
        [
            remote.lastMessageAt,
            remote.lastActivityAt,
            remote.lastMessage?.createdAt,
            remote.updatedAt
        ]
    }

    private static func rtcMessageDisplayTime(_ remote: RemoteMessage) -> String {
        let record = remote.channelSeq > 0 && !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RTCCallRecordPayload.parse(
                contentType: remote.contentType,
                channelType: remote.channelType,
                fromUID: remote.fromUID,
                payload: remote.payload
            )
            : nil
        let date = RTCCallRecordTimeProjection.messageDate(
            outerDate: AppStateTimeFormatter.parseRemoteDate(remote.createdAt),
            record: record,
            contentType: remote.contentType,
            channelType: remote.channelType,
            fromUID: remote.fromUID
        )
        return date.map { AppStateTimeFormatter.displayTime($0) } ?? "时间未知"
    }
}
// JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改开始：远端会话去重选择拆到纯 helper，减少 AppState 内重复状态扫描
enum RemoteConversationCanonicalizer {
    static func canonical(
        _ remoteConversations: [RemoteConversation],
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup?
    ) -> [RemoteConversation] {
        var byChannelID: [String: RemoteConversation] = [:]
        byChannelID.reserveCapacity(remoteConversations.count)
        for remote in remoteConversations {
            let channelID = ConversationChannelIdentityMapper.normalizedRemoteChannelID(
                remote.channelID,
                channelType: remote.channelType,
                currentID: currentID,
                currentIDs: currentIDs,
                lookup: lookup
            )
            guard !channelID.isEmpty else { continue }
            if let current = byChannelID[channelID] {
                if RemoteConversationTimelineMapper.freshnessPrecedes(remote, current) {
                    byChannelID[channelID] = remote
                }
            } else {
                byChannelID[channelID] = remote
            }
        }
        return Array(byChannelID.values)
    }
}
// JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改开始：频道/会话 ID 纯映射从 AppState 拆出，保留原有规则
struct ConversationChannelGroupIdentity: Sendable {
    let id: String
    let name: String
}

enum ConversationChannelIdentityMapper {
    static func user(_ user: IMUser, matchesIdentifier identifier: String) -> Bool {
        let normalizedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .contains(normalizedID)
    }

    static func currentIdentitySet(
        currentUser: IMUser,
        apiIMUID: String?,
        accountID: String?
    ) -> Set<String> {
        Set([
            currentUser.id,
            currentUser.userID,
            currentUser.username,
            apiIMUID ?? "",
            accountID ?? ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    static func remoteChannelID(
        for conversation: Conversation,
        currentUser: IMUser,
        apiIMUID: String?,
        groups: [ConversationChannelGroupIdentity],
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        switch conversation.kind {
        case .direct:
            let currentID = (apiIMUID?.isEmpty == false ? apiIMUID : currentUser.id) ?? currentUser.id
            let currentIDs = Set([currentID, currentUser.id, apiIMUID ?? ""].filter { !$0.isEmpty })
            let existingParts = directChannelParts(conversation.id)
            if existingParts.count >= 2,
               existingParts.contains(where: { currentIDs.contains($0) }),
               existingParts.contains(where: { !currentIDs.contains($0) }) {
                return normalizedRemoteChannelID(
                    conversation.id,
                    channelType: "direct",
                    currentID: currentID,
                    currentIDs: currentIDs,
                    lookup: lookup,
                    fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
                )
            }
            let peer = conversation.participants
                .map(\.id)
                .first { !$0.isEmpty && !currentIDs.contains($0) }
                ?? existingParts.first { !$0.isEmpty && !currentIDs.contains($0) }
                ?? (!conversation.id.isEmpty && !currentIDs.contains(conversation.id) ? conversation.id : "")
            let canonicalPeer = canonicalDirectParticipantID(
                peer,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
            guard !currentID.isEmpty, !peer.isEmpty, currentID != peer else {
                return conversation.id
            }
            return [currentID, canonicalPeer].sorted().joined(separator: ":")
        case .group:
            return groups.first(where: { $0.id == conversation.id || $0.name == conversation.title })?.id ?? conversation.id
        case .system:
            return "system_notification"
        }
    }

    static func normalizedRemoteChannelID(
        _ channelID: String,
        channelType: String,
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let trimmedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversationKind(from: channelType, channelID: trimmedID) == .system {
            return "system_notification"
        }
        if conversationKind(from: channelType, channelID: trimmedID) == .direct {
            return canonicalDirectChannelID(
                trimmedID,
                currentID: currentID,
                currentIDs: currentIDs,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
        }
        return trimmedID
    }

    static func directChannelParts(_ channelID: String) -> [String] {
        channelID
            .split { char in char == ":" || char == "|" || char == "," }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func apiChannelType(for kind: ConversationKind) -> String {
        switch kind {
        case .direct: return "direct"
        case .group: return "group"
        case .system: return "system"
        }
    }

    static func conversationKind(from channelType: String, channelID: String = "") -> ConversationKind {
        let normalizedType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedType == "group" { return .group }
        if normalizedType == "system" || normalizedType == "system_notification" || normalizedType == "system_message" {
            return .system
        }
        if normalizedID == "system_notification"
            || normalizedID == "system_message"
            || normalizedID.hasPrefix("system_")
            || normalizedID.contains(":system_") {
            return .system
        }
        return .direct
    }

    private static func canonicalDirectChannelID(
        _ channelID: String,
        currentID: String,
        currentIDs: Set<String>,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let trimmedID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return "" }
        let parts = directChannelParts(trimmedID)
        if parts.count >= 2 {
            if let peer = parts.first(where: { !currentIDs.contains($0) }),
               !currentID.isEmpty {
                let canonicalPeer = canonicalDirectParticipantID(
                    peer,
                    lookup: lookup,
                    fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
                )
                return [currentID, canonicalPeer].filter { !$0.isEmpty }.sorted().joined(separator: ":")
            }
            return Array(Set(parts)).sorted().joined(separator: ":")
        }
        if let only = parts.first,
           !currentID.isEmpty,
           !currentIDs.contains(only) {
            let canonicalPeer = canonicalDirectParticipantID(
                only,
                lookup: lookup,
                fallbackCanonicalParticipantID: fallbackCanonicalParticipantID
            )
            return [currentID, canonicalPeer].filter { !$0.isEmpty }.sorted().joined(separator: ":")
        }
        return trimmedID
    }

    private static func canonicalDirectParticipantID(
        _ rawID: String,
        lookup: ConversationUserLookup? = nil,
        fallbackCanonicalParticipantID: ((String) -> String)? = nil
    ) -> String {
        let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        guard let user = lookup?.user(for: normalized) else {
            return fallbackCanonicalParticipantID?(normalized) ?? normalized
        }
        if !user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.id
        }
        if !user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.userID
        }
        return normalized
    }
}
// JHT_MOD_END APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改开始：展示层纯工具从 AppState 拆出，保持原算法
enum AppStatePresentationHelper {
    static func messageKind(from contentType: String) -> MessageKind {
        switch contentType.lowercased() {
        case "rtc_call_record": return .rtcCallRecord
        case "image": return .image
        case "file", "attachment": return .file
        case "voice", "audio": return .voice
        case "video": return .video
        case "location": return .location
        case "contact_card": return .contactCard
        case "system": return .system
        default: return .text
        }
    }

    static func stableSeed(_ value: String) -> UInt {
        let palette: [UInt] = [0x5D6BFF, 0x7C6BFF, 0x23C48E, 0x18B6D7, 0xFFB246, 0xFF6E91, 0x50D2FF]
        let sum = value.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[abs(sum) % palette.count]
    }
}
// JHT_MOD_END APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改开始：JSON payload 基础读取从 AppState 拆出，保持原解析规则
enum RemotePayloadReader {
    static func string(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    static func attachmentObjects(_ payload: [String: JSONValue]) -> [[String: JSONValue]] {
        var objects = [payload]
        for key in [
            "file", "attachment", "attachments", "media", "sticker", "resource", "original", "thumbnail",
            "metadata", "file_metadata", "attachment_metadata", "sticker_metadata"
        ] {
            guard let value = payload[key] else { continue }
            if case .object(let object) = value {
                objects.append(object)
            } else if case .array(let values) = value {
                for item in values {
                    if case .object(let object) = item {
                        objects.append(object)
                    }
                }
            }
        }
        return objects
    }

    static func attachmentString(_ payload: [String: JSONValue], _ keys: [String], fallback: String = "") -> String {
        for object in attachmentObjects(payload) {
            let value = string(object, keys)
            if !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    static func encodedAttachmentResourceID(from payload: [String: JSONValue]) -> String? {
        let fileID = attachmentString(payload, ["file_id"])
        if !fileID.isEmpty { return fileID }
        let attachmentID = attachmentString(payload, ["attachment_id"])
        if !attachmentID.isEmpty { return "attachment_id:\(attachmentID)" }
        let mediaID = attachmentString(payload, ["media_id"])
        if !mediaID.isEmpty { return "media_id:\(mediaID)" }
        return nil
    }

    static func attachmentBool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        for object in attachmentObjects(payload) {
            if let value = bool(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentInt64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        for object in attachmentObjects(payload) {
            if let value = int64(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentDouble(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        for object in attachmentObjects(payload) {
            if let value = double(object, keys) {
                return value
            }
        }
        return nil
    }

    static func attachmentIntArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        for object in attachmentObjects(payload) {
            let values = intArray(object, keys)
            if !values.isEmpty {
                return values
            }
        }
        return []
    }

    static func bool(_ payload: [String: JSONValue], _ keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key]?.boolValue {
                return value
            }
        }
        return nil
    }

    static func int64(_ payload: [String: JSONValue], _ keys: [String]) -> Int64? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let intValue):
                return Int64(intValue)
            case .double(let doubleValue):
                return Int64(doubleValue)
            case .string(let stringValue):
                if let parsed = Int64(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }

    static func double(_ payload: [String: JSONValue], _ keys: [String]) -> Double? {
        for key in keys {
            guard let value = payload[key] else { continue }
            switch value {
            case .int(let intValue):
                return Double(intValue)
            case .double(let doubleValue):
                return doubleValue
            case .string(let stringValue):
                if let parsed = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            default:
                continue
            }
        }
        return nil
    }

    static func intArray(_ payload: [String: JSONValue], _ keys: [String]) -> [Int] {
        for key in keys {
            guard let value = payload[key] else { continue }
            guard case .array(let values) = value else { continue }
            let parsed = values.compactMap { item -> Int? in
                switch item {
                case .int(let intValue):
                    return intValue
                case .double(let doubleValue):
                    return Int(round(doubleValue))
                case .string(let stringValue):
                    return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                default:
                    return nil
                }
            }
            if !parsed.isEmpty {
                return parsed
            }
        }
        return []
    }

    static func stringArray(_ payload: [String: JSONValue], _ keys: [String]) -> [String] {
        for key in keys {
            guard let value = payload[key] else { continue }
            let values: [String]
            if case .array(let array) = value {
                values = array.compactMap {
                    $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if let stringValue = value.stringValue {
                values = stringValue
                    .split { ["、", ",", "，", ";", "；"].contains(String($0)) }
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                values = []
            }
            let filtered = values.filter { !$0.isEmpty }
            if !filtered.isEmpty {
                return Array(NSOrderedSet(array: filtered).compactMap { $0 as? String })
            }
        }
        return []
    }

    static func attachmentDuration(from payload: [String: JSONValue]) -> Double? {
        if let seconds = attachmentDouble(payload, ["duration_seconds", "duration"]) {
            return seconds
        }
        if let milliseconds = attachmentDouble(payload, ["duration_ms"]) {
            return milliseconds / 1000.0
        }
        return nil
    }

    static func attachmentWaveform(from payload: [String: JSONValue]) -> [Int] {
        VoiceMessagePayload.normalizedWaveform(attachmentIntArray(payload, ["waveform", "waveform_samples", "peaks"]))
    }
}
// JHT_MOD_END APPSTATE_PAYLOAD_READER_SPLIT_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件/收藏列表纯判断从 AppState 拆出，并复用静态分类集合
enum FileItemProjectionHelper {
    private static let attachmentSummaryKeywords = ["文件", "图片", "视频"]
    private static let attachmentSummaryExtensions = [
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".txt", ".md",
        ".csv", ".zip", ".rar", ".7z", ".png", ".jpg", ".jpeg", ".gif", ".webp",
        ".mp4", ".mov", ".webm", ".mp3", ".m4a", ".wav"
    ]

    private static let favoriteUnavailableStatuses: Set<String> = [
        "deleted", "delete", "removed", "recalled", "recall", "revoked",
        "expired", "invalid", "unavailable", "disabled", "failed"
    ]
    private static let favoriteMediaContentTypes: Set<String> = [
        "image", "video", "audio", "voice", "pdf", "archive"
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "md"]

    static func attachmentPreviewAllowed(
        previewURL: String,
        previewKind: String,
        contentDisposition: String,
        backendAvailable: Bool?
    ) -> Bool {
        let trimmedPreviewURL = previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreviewURL.isEmpty else { return false }
        let normalizedPreviewKind = previewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedPreviewKind == "download" {
            return false
        }
        let normalizedDisposition = contentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedDisposition.hasPrefix("attachment") {
            return false
        }
        if let backendAvailable {
            return backendAvailable
        }
        return true
    }

    static func favoriteAssetFallbackMessageID(_ remote: RemoteFavoriteAssetItem) -> String {
        [
            remote.messageID,
            remote.cursor,
            remote.channelID,
            remote.channelSeq > 0 ? String(remote.channelSeq) : ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    static func favoriteAssetMediaCategory(
        payloadCategory: String,
        contentType: String,
        fallback: FavoriteAssetCategory
    ) -> String {
        if !payloadCategory.isEmpty {
            let category = FavoriteAssetCategory(serverValue: payloadCategory)
            return category.requestValue == "all" ? payloadCategory : category.requestValue
        }
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if favoriteMediaContentTypes.contains(normalizedContentType) {
            return normalizedContentType == "voice" ? "audio" : normalizedContentType
        }
        return fallback == .all ? "" : fallback.requestValue
    }

    static func favoriteAssetIsUnavailable(_ remote: RemoteFavoriteAssetItem) -> Bool {
        let status = remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !status.isEmpty else { return false }
        return favoriteUnavailableStatuses.contains(status)
            || status.contains("deleted")
            || status.contains("recalled")
            || status.contains("expired")
    }

    static func fileListMessageSummaryLooksLikeAttachment(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if attachmentSummaryKeywords.contains(where: { value.contains($0) }) {
            return true
        }
        return attachmentSummaryExtensions.contains { value.contains($0) }
    }

    static func fileItemsReferToSameAttachment(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        let lhsRemoteID = lhs.remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsRemoteID = rhs.remoteLookupID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lhsRemoteID.isEmpty, !rhsRemoteID.isEmpty {
            return lhsRemoteID == rhsRemoteID
        }
        let lhsChannelID = lhs.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsChannelID = rhs.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhsChannelID.isEmpty,
              lhsChannelID == rhsChannelID,
              lhs.channelType == rhs.channelType else {
            return false
        }
        let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhsName.isEmpty, lhsName == rhsName else { return false }
        if let lhsSize = lhs.sizeBytes, let rhsSize = rhs.sizeBytes, lhsSize > 0, rhsSize > 0 {
            return lhsSize == rhsSize
        }
        return true
    }

    static func attachmentFallbackFileID(for message: ChatMessage, conversation: Conversation) -> String {
        let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !messageID.isEmpty {
            return "local-attachment|\(conversation.id)|\(messageID)"
        }
        if message.channelSeq > 0 {
            return "local-attachment|\(conversation.id)|seq-\(message.channelSeq)"
        }
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        return "local-attachment|\(conversation.id)|\(name)|\(message.time)"
    }

    static func fileItem(_ fileItem: FileItem, matchesQuery query: String, category: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryMatches = trimmedQuery.isEmpty
            || fileItem.name.localizedCaseInsensitiveContains(trimmedQuery)
            || fileItem.owner.localizedCaseInsensitiveContains(trimmedQuery)
            || fileItem.source.localizedCaseInsensitiveContains(trimmedQuery)
        guard queryMatches else { return false }
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedCategory.isEmpty else { return true }
        let mediaCategory = fileItem.mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mimeType = fileItem.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = fileItem.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (fileItem.fileExtension.isEmpty ? (fileItem.name as NSString).pathExtension : fileItem.fileExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedCategory {
        case "image":
            return mediaCategory == "image" || mimeType.hasPrefix("image/") || imageExtensions.contains(ext)
        case "video":
            return mediaCategory == "video" || mimeType.hasPrefix("video/") || videoExtensions.contains(ext)
        case "audio":
            return mediaCategory == "audio" || mimeType.hasPrefix("audio/") || audioExtensions.contains(ext)
        case "archive":
            return mediaCategory == "archive" || archiveExtensions.contains(ext)
        case "pdf":
            return mediaCategory == "pdf" || mimeType.contains("pdf") || type == "pdf" || ext == "pdf"
        case "document":
            return mediaCategory == "document"
                || mimeType.contains("spreadsheet")
                || mimeType.contains("excel")
                || mimeType.contains("word")
                || mimeType.contains("document")
                || documentExtensions.contains(ext)
        default:
            return true
        }
    }

    static func fileTypeLabel(name: String, mimeType: String, category: String, fallback: String) -> String {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        case "audio": return "音频"
        case "spreadsheet": return "表格"
        case "document": break
        case "archive": return "压缩包"
        default: break
        }
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMime.hasPrefix("image/") { return "图片" }
        if normalizedMime.hasPrefix("video/") { return "视频" }
        if normalizedMime.hasPrefix("audio/") { return "音频" }
        if normalizedMime.contains("pdf") { return "PDF" }
        if normalizedMime.contains("spreadsheet") || normalizedMime.contains("excel") { return "表格" }
        if normalizedMime.contains("word") || normalizedMime.contains("document") { return "文档" }
        let ext = (name as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return fallback.isEmpty ? "文件" : fallback.uppercased()
    }
}
// JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束

// JHT_MOD_BEGIN APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改开始：会话序号计算从 AppState 拆出并避免临时数组分配
enum ConversationSequenceInspector {
    // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：复用单次扫描，避免 map().max() 生成临时数组
    static func maximumInt64<S: Sequence>(_ values: S) -> Int64? where S.Element == Int64 {
        var latest: Int64?
        for value in values {
            if let current = latest {
                if value > current {
                    latest = value
                }
            } else {
                latest = value
            }
        }
        return latest
    }

    static func maximumChannelSeq(in messages: [ChatMessage]) -> Int64? {
        maximumInt64(messages.lazy.map(\.channelSeq))
    }

    static func maximumChannelSeq(in remoteMessages: [RemoteMessage]) -> Int64? {
        maximumInt64(remoteMessages.lazy.map(\.channelSeq))
    }
    // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束

    static func latestKnownSequence(for conversation: Conversation) -> Int64 {
        var latest = max(
            conversation.lastMsgSeq,
            conversation.messageCoveredThroughSeq,
            conversation.lastReadSeq,
            conversation.firstUnreadSeq,
            conversation.unreadAnchorSeq,
            conversation.mentionSummaryChannelSeq
        )
        for message in conversation.messages where message.channelSeq > latest {
            latest = message.channelSeq
        }
        return latest
    }

    static func latestKnownSequence(for remote: RemoteConversation) -> Int64 {
        max(
            remote.lastMsgSeq,
            remote.lastReadSeq,
            remote.firstUnreadSeq,
            remote.unreadAnchorSeq,
            remote.mentionSummary?.channelSeq ?? 0,
            remote.lastMessage?.channelSeq ?? 0
        )
    }

    static func latestKnownSequence(for remoteMessages: [RemoteMessage]) -> Int64 {
        var latest: Int64 = 0
        for message in remoteMessages where message.channelSeq > latest {
            latest = message.channelSeq
        }
        return latest
    }
}
// JHT_MOD_END APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改结束

@MainActor
enum SystemNotificationSound {
    private static let defaultMessageSound = SystemSoundID(1007)
    private static var callPromptPlayer: AVAudioPlayer?
    private static var promptStopTask: Task<Void, Never>?
    private static var activePromptKind: CallPromptKind?
    private static var systemOwnsIncomingRingtone = false
    private static var outgoingRingbackSuppressed = false

    static func playMessage() {
        AudioServicesPlayAlertSound(defaultMessageSound)
    }

    static func startIncomingCallFallback() {
        stopIncomingCallFallback()
        guard !isRunningUnitTests else { return }
        startPlayer(.incomingRingtone, loops: -1)
    }

    static func stopIncomingCallFallback() {
        guard activePromptKind == .incomingRingtone else { return }
        stopPromptPlayer()
    }

    static func render(_ commands: [CallPromptCommand]) {
        for command in commands {
            switch command {
            case .stopAll:
                stopAllCallPrompts()
            case .prepare:
                break
            case .startLoop(let kind):
                startLoop(kind)
            case .playOneShot(let kind, let maximumDuration):
                playOneShot(kind, maximumDuration: maximumDuration)
            case .releasePromptAudioSession:
                // System sounds do not claim the call media audio session.
                break
            }
        }
    }

    static func stopAllCallPrompts() {
        stopPromptPlayer()
    }

    static func setSystemOwnsIncomingRingtone(_ ownsRingtone: Bool) {
        systemOwnsIncomingRingtone = ownsRingtone
        if ownsRingtone {
            stopIncomingCallFallback()
        }
    }

    static func setOutgoingRingbackSuppressed(_ suppressed: Bool) {
        outgoingRingbackSuppressed = suppressed
        if suppressed, activePromptKind == .outgoingRingback {
            stopPromptPlayer()
        }
    }

    private static func startLoop(_ kind: CallPromptKind) {
        guard !isRunningUnitTests else { return }
        switch kind {
        case .incomingRingtone:
            if !systemOwnsIncomingRingtone {
                startIncomingCallFallback()
            }
        case .outgoingRingback:
            guard !outgoingRingbackSuppressed else { return }
            startPlayer(.outgoingRingback, loops: -1)
        case .busy, .connected, .ended:
            playOneShot(kind, maximumDuration: 2.5)
        }
    }

    private static func playOneShot(_ kind: CallPromptKind, maximumDuration: TimeInterval) {
        guard !isRunningUnitTests else { return }
        outgoingRingbackSuppressed = false
        startPlayer(kind, loops: kind == .busy ? 4 : 0)
        let boundedDuration = max(0.05, maximumDuration)
        promptStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(boundedDuration * 1_000_000_000))
            guard !Task.isCancelled, activePromptKind == kind else { return }
            stopPromptPlayer()
        }
    }

    private static func startPlayer(_ kind: CallPromptKind, loops: Int) {
        stopPromptPlayer()
        let player: AVAudioPlayer?
        if let url = bundledToneURL(for: kind) {
            player = try? AVAudioPlayer(contentsOf: url)
        } else if let data = generatedToneData(for: kind) {
            player = try? AVAudioPlayer(data: data)
        } else {
            player = nil
        }
        guard let player else {
            return
        }
        player.numberOfLoops = loops
        player.volume = 0.32
        player.prepareToPlay()
        guard player.play() else { return }
        callPromptPlayer = player
        activePromptKind = kind
    }

    private static func bundledToneURL(for kind: CallPromptKind) -> URL? {
        let resourceName: String
        switch kind {
        case .outgoingRingback:
            resourceName = "rtc_outgoing_ringback"
        case .incomingRingtone:
            resourceName = "rtc_incoming_ringtone"
        case .busy:
            resourceName = "rtc_call_busy"
        case .connected:
            resourceName = "rtc_call_connected"
        case .ended:
            resourceName = "rtc_call_ended"
        }
        for fileExtension in ["caf", "wav", "m4a", "mp3"] {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }

    private static func stopPromptPlayer() {
        promptStopTask?.cancel()
        promptStopTask = nil
        callPromptPlayer?.stop()
        callPromptPlayer = nil
        activePromptKind = nil
    }

    /// Creates short, generic PCM cues at runtime. No bundled or third-party audio asset is used,
    /// and AVAudioPlayer gives every lifecycle transition an immediate stop operation.
    private static func generatedToneData(for kind: CallPromptKind) -> Data? {
        let segments: [(frequency: Double, duration: Double)]
        switch kind {
        case .outgoingRingback:
            segments = [(440, 0.28), (0, 0.82)]
        case .incomingRingtone:
            segments = [(660, 0.34), (0, 0.16), (660, 0.34), (0, 1.36)]
        case .busy:
            segments = [(480, 0.24), (0, 0.24)]
        case .connected:
            segments = [(880, 0.13)]
        case .ended:
            segments = [(440, 0.14), (330, 0.22)]
        }
        let sampleRate: UInt32 = 22_050
        let fadeSamples = max(1, Int(Double(sampleRate) * 0.006))
        var samples: [Int16] = []
        for segment in segments {
            let count = max(1, Int(segment.duration * Double(sampleRate)))
            for index in 0..<count {
                guard segment.frequency > 0 else {
                    samples.append(0)
                    continue
                }
                let leading = min(1, Double(index) / Double(fadeSamples))
                let trailing = min(1, Double(count - index - 1) / Double(fadeSamples))
                let envelope = max(0, min(leading, trailing))
                let angle = 2 * Double.pi * segment.frequency * Double(index) / Double(sampleRate)
                samples.append(Int16(sin(angle) * Double(Int16.max) * 0.22 * envelope))
            }
        }
        guard !samples.isEmpty else { return nil }
        let pcmByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36) + pcmByteCount, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(pcmByteCount, to: &data)
        for sample in samples {
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

struct PendingAttachmentUpload {
    let kind: MessageKind
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let data: Data?
    let fileURL: URL?
    let removeFileWhenFinished: Bool
    let conversationID: String
    let quote: String?
    let replyContext: MessageReplyContext?
    let voiceDurationMS: Int?
    let voiceWaveform: [Int]
    let onPolicyRejected: (@MainActor () -> Void)?

    init(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64,
        data: Data? = nil,
        fileURL: URL? = nil,
        removeFileWhenFinished: Bool = false,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext?,
        voiceDurationMS: Int? = nil,
        voiceWaveform: [Int] = [],
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) {
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.fileURL = fileURL
        self.removeFileWhenFinished = removeFileWhenFinished
        self.conversationID = conversationID
        self.quote = quote
        self.replyContext = replyContext
        self.voiceDurationMS = voiceDurationMS
        self.voiceWaveform = VoiceMessagePayload.normalizedWaveform(voiceWaveform)
        self.onPolicyRejected = onPolicyRejected
    }

    func removeOwnedFile() {
        guard removeFileWhenFinished else { return }
        PendingAttachmentFileStore.removeManagedFile(at: fileURL)
    }
}

enum AttachmentUploadPhase: String, Equatable {
    case config
    case presign
    case put
    case finalize
    case send

    var failedStatus: String {
        "failed_\(rawValue)"
    }

    static func failurePhase(from status: String) -> AttachmentUploadPhase? {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("failed_") else { return nil }
        return AttachmentUploadPhase(rawValue: String(normalized.dropFirst("failed_".count)))
    }
}

struct AttachmentUploadCheckpoint {
    var fileID: String
    var putCompleted: Bool
    var completedFile: RemoteAvatarFile?
}

extension AttachmentUploadFailure {
    init(error: Error) {
        if error is LocalMessageDatabaseError { self.init(code: .localPersistence); return }
        if error is CocoaError { self.init(code: .localFile); return }
        if error is EncodingError { self.init(code: .requestEncoding); return }
        if error is DecodingError { self.init(code: .decode); return }
        if error is CancellationError { self.init(code: .cancelled); return }
        if let error = error as? URLError {
            let code: Code
            switch error.code {
            case .timedOut: code = .timeout
            case .cannotFindHost, .dnsLookupFailed: code = .dns
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: code = .offline
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired: code = .tls
            case .cancelled: code = .cancelled
            default: code = .transport
            }
            self.init(code: code)
            return
        }
        guard let error = error as? IMAPIError else { self.init(code: .unknown); return }
        switch error {
        case .missingContext: self.init(code: .missingContext)
        case .badURL: self.init(code: .route)
        case .httpStatus(let status, _): self.init(code: .http, httpStatus: status)
        case .businessForbidden(let code, _, _), .conflict(let code, _),
             .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _):
            self.init(code: .policy, serverCode: code)
        case .unauthorized: self.init(code: .policy, serverCode: "unauthorized")
        case .forbidden: self.init(code: .policy, serverCode: "forbidden")
        case .forcedAuthRequired: self.init(code: .policy)
        case .securityBlocked: self.init(code: .policy, serverCode: "security_blocked")
        case .emptyResponse: self.init(code: .invalidResponse)
        case .server: self.init(code: .unknown)
        }
    }
}

@MainActor
final class VoiceMessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var didFinish: (@MainActor (ObjectIdentifier, Bool) -> Void)?
    var didFailToDecode: (@MainActor (ObjectIdentifier) -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.didFinish?(playerID, flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.didFailToDecode?(playerID)
        }
    }
}

// JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：本地附件预览结果允许后台计算后安全回传主线程
struct LocalAttachmentPreviewResources: Sendable {
// JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
    let previewURL: URL?
    let downloadURL: URL?
    let thumbnailURL: URL?
    let width: Int?
    let height: Int?

    var hasUsableLocalFile: Bool {
        [previewURL, downloadURL, thumbnailURL]
            .contains { $0?.usableLocalFileURL != nil }
    }
}

// JHT_MOD_BEGIN ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：附件本地预览生成从 AppState/MainActor 抽到 support helper
enum AttachmentPreviewResourceBuilder {
    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：发送入口先生成轻量本地资源，重的尺寸/缩略图后台补齐
    static func lightweightLocalFileResources(
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard localURL.usableLocalFileURL != nil else { return nil }
        switch mediaCategory {
        case "image":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: localURL,
                width: nil,
                height: nil
            )
        case "video", "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    static func outgoingPreviewResourcesOffMain(
        messageID: String,
        name: String,
        data: Data?,
        fileURL: URL?,
        mediaCategory: String
    ) async -> LocalAttachmentPreviewResources? {
        await Task.detached(priority: .utility) {
            if let fileURL {
                return localFilePreviewResources(
                    messageID: messageID,
                    localURL: fileURL,
                    mediaCategory: mediaCategory
                )
            }
            guard let data else { return nil }
            return dataPreviewResources(
                messageID: messageID,
                name: name,
                data: data,
                mediaCategory: mediaCategory
            )
        }.value
    }

    static func dataPreviewResources(
        messageID: String,
        name: String,
        data: Data,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard let attachmentURL = writeTemporaryAttachmentData(data, messageID: messageID, name: name) else { return nil }
        switch mediaCategory {
        case "image":
            let image = UIImage(data: data)
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: attachmentURL,
                width: image.map { Int($0.size.width) },
                height: image.map { Int($0.size.height) }
            )
        case "video":
            let thumbnail = videoThumbnailURL(for: attachmentURL, messageID: messageID)
            let size = thumbnail.flatMap { UIImage(contentsOfFile: $0.path)?.size }
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: thumbnail,
                width: size.map { Int($0.width) },
                height: size.map { Int($0.height) }
            )
        case "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: attachmentURL,
                downloadURL: attachmentURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: attachmentURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    static func localFilePreviewResources(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        downloadedPreviewResources(
            messageID: messageID,
            localURL: localURL,
            mediaCategory: mediaCategory
        )
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    static func downloadedPreviewResourcesOffMain(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) async -> LocalAttachmentPreviewResources? {
        await Task.detached(priority: .utility) {
            downloadedPreviewResources(
                messageID: messageID,
                localURL: localURL,
                mediaCategory: mediaCategory
            )
        }.value
    }

    private static func downloadedPreviewResources(
        messageID: String,
        localURL: URL,
        mediaCategory: String
    ) -> LocalAttachmentPreviewResources? {
        guard localURL.usableLocalFileURL != nil else { return nil }
        switch mediaCategory {
        case "image":
            let imageSize = RemoteImageDecoder.pixelSize(fromFileURL: localURL)
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: localURL,
                width: imageSize.map { Int($0.width) },
                height: imageSize.map { Int($0.height) }
            )
        case "video":
            let thumbnail = videoThumbnailURL(for: localURL, messageID: messageID)
            let size = thumbnail.flatMap { UIImage(contentsOfFile: $0.path)?.size }
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: thumbnail,
                width: size.map { Int($0.width) },
                height: size.map { Int($0.height) }
            )
        case "pdf":
            return LocalAttachmentPreviewResources(
                previewURL: localURL,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        default:
            return LocalAttachmentPreviewResources(
                previewURL: nil,
                downloadURL: localURL,
                thumbnailURL: nil,
                width: nil,
                height: nil
            )
        }
    }

    private static func videoThumbnailURL(for videoURL: URL, messageID: String) -> URL? {
        do {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.12, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
            let url = videoURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(messageID)_thumbnail.jpg", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：发送本地 data 的临时文件写入从 AppState 拆到 support helper
    private static func writeTemporaryAttachmentData(_ data: Data, messageID: String, name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMPendingAttachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(messageID)_\(sanitizedAttachmentFileName(name))"
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func sanitizedAttachmentFileName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
}
// JHT_MOD_END ATTACHMENT_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改开始：缩略图缓存临时文件 IO 从 AppState/MainActor 抽离
enum AttachmentTemporaryFileWriter {
    static func writeThumbnailDataOffMain(_ data: Data) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("media-thumbnail-\(UUID().uuidString.lowercased())", isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }.value
    }

    static func removeTemporaryFileOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    // JHT_MOD_BEGIN ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改开始：附件完整性校验和下载 staging 清理放到后台执行
    static func verifyFileOffMain(_ url: URL, integrity: MediaFileIntegrityAuthority) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try integrity.verify(fileAt: url)
        }.value
    }

    static func firstVerifiedFileOffMain(
        in candidates: [URL],
        integrity: MediaFileIntegrityAuthority
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            candidates.first { (try? integrity.verify(fileAt: $0)) != nil }
        }.value
    }

    static func removeDownloadStagingDirectoryIfNeededOffMain(for url: URL) async {
        guard isDownloadStagingURL(url) else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }.value
    }

    private static func isDownloadStagingURL(_ url: URL) -> Bool {
        url.path.contains("/BlueStoneIMAttachmentDownloadStaging/")
    }
    // JHT_MOD_END ATTACHMENT_COMMIT_CLEANUP_IO_PERF_20260912 - 修改结束
}
// JHT_MOD_END ATTACHMENT_THUMBNAIL_CACHE_IO_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：统一媒体缓存文件 IO 从 AppState/MainActor 抽离
struct MediaCacheFileRemovalOutcome: Sendable {
    let didComplete: Bool
    let fileExisted: Bool
}

enum MediaCacheFileIO {
    static func fileExistsOffMain(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: url.path)
        }.value
    }

    static func removeFileIfExistsOffMain(_ url: URL) async -> MediaCacheFileRemovalOutcome {
        await Task.detached(priority: .utility) {
            let existed = FileManager.default.fileExists(atPath: url.path)
            do {
                if existed {
                    try FileManager.default.removeItem(at: url)
                }
                return MediaCacheFileRemovalOutcome(didComplete: true, fileExisted: existed)
            } catch {
                return MediaCacheFileRemovalOutcome(didComplete: false, fileExisted: existed)
            }
        }.value
    }

    static func removeFileIgnoringErrorsOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
// JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：本地消息快照投影从 AppState 拆到独立 support builder
struct LocalMessageProjectionInput: Sendable {
    let conversation: Conversation
    let channelID: String
    let channelType: String
    let projectedMessages: [ChatMessage]?
}

enum LocalMessageProjectionBuilder {
    static let localMutationTailLimit = 80

    static func snapshot(
        from input: LocalMessageProjectionInput,
        actorID: String,
        requiresServerRevalidation: Bool = false
    ) -> LocalMessageConversationSnapshot {
        LocalMessageConversationSnapshot(
            conversation: input.conversation,
            channelID: input.channelID,
            channelType: input.channelType,
            currentActorID: actorID,
            projectedMessages: persistentProjectionMessages(
                input.projectedMessages ?? input.conversation.messages
            ),
            requiresServerRevalidation: requiresServerRevalidation
        )
    }

    static func snapshots(
        from inputs: [LocalMessageProjectionInput],
        actorID: String,
        requiresServerRevalidation: Bool = false
    ) -> [LocalMessageConversationSnapshot] {
        inputs.map { input in
            snapshot(
                from: input,
                actorID: actorID,
                requiresServerRevalidation: requiresServerRevalidation
            )
        }
    }

    static func snapshotOffMain(
        from input: LocalMessageProjectionInput,
        actorID: String,
        requiresServerRevalidation: Bool = false
    ) async -> LocalMessageConversationSnapshot {
        await Task.detached(priority: .utility) {
            snapshot(
                from: input,
                actorID: actorID,
                requiresServerRevalidation: requiresServerRevalidation
            )
        }.value
    }

    static func snapshotsOffMain(
        from inputs: [LocalMessageProjectionInput],
        actorID: String,
        requiresServerRevalidation: Bool = false
    ) async -> [LocalMessageConversationSnapshot] {
        await Task.detached(priority: .utility) {
            snapshots(
                from: inputs,
                actorID: actorID,
                requiresServerRevalidation: requiresServerRevalidation
            )
        }.value
    }

    static func localMutationSnapshotsOffMain(
        from inputs: [LocalMessageProjectionInput],
        actorID: String
    ) async -> [LocalMessageConversationSnapshot] {
        await Task.detached(priority: .utility) {
            inputs.map { input in
                snapshot(
                    from: LocalMessageProjectionInput(
                        conversation: input.conversation,
                        channelID: input.channelID,
                        channelType: input.channelType,
                        projectedMessages: input.projectedMessages
                            ?? localMutationProjectionMessages(from: input.conversation)
                    ),
                    actorID: actorID
                )
            }
        }.value
    }

    static func persistentProjectionMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            var sanitized = message
            // Signed/expiring transport URLs are memory-only. Stable resource metadata is
            // sufficient to re-authorize and resolve a fresh URL after restart.
            sanitized.attachmentPreviewURL = ""
            sanitized.attachmentDownloadURL = ""
            sanitized.attachmentThumbnailURL = ""
            sanitized.attachmentPosterURL = ""
            sanitized.attachmentCoverURL = ""
            return sanitized
        }
    }

    static func localMutationProjectionMessages(from conversation: Conversation) -> [ChatMessage] {
        let messages = conversation.messages
        guard messages.count > localMutationTailLimit else { return messages }
        let tailStartIndex = max(0, messages.count - localMutationTailLimit)
        return messages.enumerated().compactMap { index, message in
            guard index >= tailStartIndex || isPendingLocalMessage(message) else { return nil }
            return message
        }
    }

    static func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }
}
// JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束

// JHT_MOD_BEGIN CACHED_CONVERSATION_RESTORE_ASYNC_PERF_20260912 - 修改开始：缓存会话模型恢复从 AppState/MainActor 抽离
enum CachedConversationRestoreBuilder {
    static func scrubbedModelsOffMain(
        from cachedConversations: [CachedConversation]
    ) async -> [Conversation] {
        await Task.detached(priority: .utility) {
            cachedConversations.map { $0.model.scrubbingGroupMemberTotals() }
        }.value
    }

    static func scrubbedConversationsOffMain(
        _ conversations: [Conversation]
    ) async -> [Conversation] {
        await Task.detached(priority: .utility) {
            conversations.map { $0.scrubbingGroupMemberTotals() }
        }.value
    }
}
// JHT_MOD_END CACHED_CONVERSATION_RESTORE_ASYNC_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：联系人/资料持久化投影从 AppState/MainActor 抽到后台 builder
enum ProfileContactProjectionBuilder {
    static func projectionOffMain(
        scope: String,
        revision: UInt64,
        contacts: [IMUser],
        remarks: [String: String],
        blacklist: [BlacklistItem],
        originalNamesByScopedUserKey: [String: String]
    ) async -> LocalProfileContactProjection {
        await Task.detached(priority: .utility) {
            let originalNameScopePrefix = "\(scope)|"
            let originalNames = originalNamesByScopedUserKey.reduce(into: [String: String]()) { result, entry in
                guard entry.key.hasPrefix(originalNameScopePrefix) else { return }
                let identifier = String(entry.key.dropFirst(originalNameScopePrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !identifier.isEmpty else { return }
                result[identifier] = entry.value
            }
            return LocalProfileContactProjection(
                revision: revision,
                contacts: contacts.map(PersistedContactUser.init),
                remarks: remarks,
                blacklist: blacklist.map(PersistedBlacklistItem.init),
                originalNames: originalNames
            )
        }.value
    }
}
// JHT_MOD_END PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：聊天历史分页的数据准备从 AppState/MainActor 抽离
struct MessageHistoryWindowIndex: Sendable {
    let existingIDs: Set<String>
    let existingSeqs: Set<Int64>
}

enum MessageHistoryPreparationBuilder {
    static func olderWindowIndexOffMain(
        messages: [ChatMessage],
        oldestSeq: Int64
    ) async -> MessageHistoryWindowIndex {
        await Task.detached(priority: .utility) {
            var existingIDs = Set<String>()
            var existingSeqs = Set<Int64>()
            for message in messages where message.channelSeq > 0 && message.channelSeq < oldestSeq {
                existingIDs.insert(message.id)
                existingSeqs.insert(message.channelSeq)
            }
            return MessageHistoryWindowIndex(existingIDs: existingIDs, existingSeqs: existingSeqs)
        }.value
    }

    static func newerWindowIndexOffMain(
        messages: [ChatMessage]
    ) async -> MessageHistoryWindowIndex {
        await Task.detached(priority: .utility) {
            MessageHistoryWindowIndex(
                existingIDs: Set(messages.map(\.id)),
                existingSeqs: Set(messages.map(\.channelSeq).filter { $0 > 0 })
            )
        }.value
    }

    static func cachedMessageModelsOffMain(_ messages: [CachedMessage]) async -> [ChatMessage] {
        await Task.detached(priority: .utility) {
            messages.map(\.model)
        }.value
    }
}
// JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束

@MainActor
final class ToastDismissTaskStore {
    private var task: Task<Void, Never>?

    var hasTask: Bool {
        task != nil
    }

    func replace(with newTask: Task<Void, Never>) {
        task?.cancel()
        task = newTask
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class LaunchSplashDismissTaskStore {
    private var task: Task<Void, Never>?

    var hasTask: Bool {
        task != nil
    }

    func replace(with newTask: Task<Void, Never>) {
        task?.cancel()
        task = newTask
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

final class MainShellBootstrapTraceState {
    private var startedAt: CFAbsoluteTime?
    private var hasLoggedAppearance = false
    private var hasLoggedInteractive = false

    func begin(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        startedAt = now
        hasLoggedAppearance = false
        hasLoggedInteractive = false
    }

    func claimAppearance(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int? {
        guard !hasLoggedAppearance else { return nil }
        hasLoggedAppearance = true
        return elapsedMs(at: now)
    }

    func claimInteractive(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int? {
        guard !hasLoggedInteractive else { return nil }
        hasLoggedInteractive = true
        return elapsedMs(at: now)
    }

    private func elapsedMs(at now: CFAbsoluteTime) -> Int {
        guard let startedAt else { return 0 }
        return Int((now - startedAt) * 1000)
    }
}

let mainTabSelectionLog = OSLog(
    subsystem: "com.jianhuitongqiyetest.app",
    category: "main-tab"
)
let mainTabSelectionLogger = Logger(
    subsystem: "com.jianhuitongqiyetest.app",
    category: "main-tab"
)

@MainActor
final class MainTabSelectionState: ObservableObject {
    private struct PendingTransition {
        let from: MainTab
        let to: MainTab
        let source: String
        let startedAt: CFAbsoluteTime
        let signpostID: OSSignpostID
    }

    @Published private(set) var activeTab: MainTab
    private let now: () -> CFAbsoluteTime
    private var pendingTransition: PendingTransition?

    private(set) var selectionRevision = 0
    private(set) var completedTransitionCount = 0
    private(set) var lastStateChangeElapsedMilliseconds: Int?
    private(set) var lastContentAppearanceElapsedMilliseconds: Int?
    private(set) var maximumContentAppearanceElapsedMilliseconds = 0

    init(
        initialTab: MainTab = .chats,
        now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        activeTab = initialTab
        self.now = now
    }

    var binding: Binding<MainTab> {
        Binding(
            get: { self.activeTab },
            set: { self.select($0, source: "tab_bar") }
        )
    }

    @discardableResult
    func select(_ tab: MainTab, source: String) -> Bool {
        guard tab != activeTab else { return false }
        finishPendingTransitionAsSuperseded()

        let previousTab = activeTab
        let startedAt = now()
        let signpostID = OSSignpostID(log: mainTabSelectionLog)
        os_signpost(
            .begin,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: signpostID,
            "from=%{public}s to=%{public}s source=%{public}s",
            previousTab.rawValue,
            tab.rawValue,
            source
        )
        pendingTransition = PendingTransition(
            from: previousTab,
            to: tab,
            source: source,
            startedAt: startedAt,
            signpostID: signpostID
        )

        activeTab = tab
        selectionRevision += 1
        let stateElapsed = elapsedMilliseconds(since: startedAt)
        lastStateChangeElapsedMilliseconds = stateElapsed
        mainTabSelectionLogger.notice(
            "state_changed from=\(previousTab.rawValue, privacy: .public) to=\(tab.rawValue, privacy: .public) source=\(source, privacy: .public) elapsed_ms=\(stateElapsed)"
        )
        return true
    }

    func noteContentAppeared(_ tab: MainTab) {
        guard let pendingTransition, pendingTransition.to == tab else { return }
        self.pendingTransition = nil

        let elapsed = elapsedMilliseconds(since: pendingTransition.startedAt)
        completedTransitionCount += 1
        lastContentAppearanceElapsedMilliseconds = elapsed
        maximumContentAppearanceElapsedMilliseconds = max(
            maximumContentAppearanceElapsedMilliseconds,
            elapsed
        )
        os_signpost(
            .end,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: pendingTransition.signpostID,
            "from=%{public}s to=%{public}s source=%{public}s elapsed_ms=%{public}d status=appeared",
            pendingTransition.from.rawValue,
            pendingTransition.to.rawValue,
            pendingTransition.source,
            elapsed
        )
        mainTabSelectionLogger.notice(
            "content_appeared from=\(pendingTransition.from.rawValue, privacy: .public) to=\(pendingTransition.to.rawValue, privacy: .public) source=\(pendingTransition.source, privacy: .public) elapsed_ms=\(elapsed)"
        )
    }

    private func finishPendingTransitionAsSuperseded() {
        guard let pendingTransition else { return }
        self.pendingTransition = nil
        let elapsed = elapsedMilliseconds(since: pendingTransition.startedAt)
        os_signpost(
            .end,
            log: mainTabSelectionLog,
            name: "MainTabTransition",
            signpostID: pendingTransition.signpostID,
            "from=%{public}s to=%{public}s source=%{public}s elapsed_ms=%{public}d status=superseded",
            pendingTransition.from.rawValue,
            pendingTransition.to.rawValue,
            pendingTransition.source,
            elapsed
        )
    }

    private func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        max(0, Int(((now() - startedAt) * 1_000).rounded()))
    }
}

final class AuthFlowGenerationState {
    private var generation = 0

    func currentToken() -> Int {
        generation
    }

    @discardableResult
    func issueToken() -> Int {
        generation += 1
        return generation
    }

    func invalidate() {
        generation += 1
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

// JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：临时企业码挑战仅保存在内存中，退出/重登后即丢弃
struct LoginTenantCodeChallenge {
    let generation: Int
    let credentialMode: LoginMode
    let identifier: String
    let password: String
    let context: IMAPIContext

    var appID: String {
        IMAPIContext.normalizedIOSAppID(context.appID)
    }

    var deviceID: String {
        context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isCurrent(
        generation expectedGeneration: Int,
        appID expectedAppID: String,
        deviceID expectedDeviceID: String
    ) -> Bool {
        generation == expectedGeneration
            && appID == IMAPIContext.normalizedIOSAppID(expectedAppID)
            && deviceID == expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

enum SplashPresentationIntent: String, Equatable, Sendable {
    case refreshOnly
    case coldLaunch
    case tenantEntry
    case foregroundColdEquivalent

    var allowsPresentation: Bool {
        switch self {
        case .coldLaunch, .foregroundColdEquivalent:
            return true
        case .refreshOnly, .tenantEntry:
            return false
        }
    }

    var presentationWindowSeconds: TimeInterval? {
        switch self {
        case .refreshOnly, .tenantEntry:
            return nil
        case .coldLaunch:
            return 5
        case .foregroundColdEquivalent:
            return 5
        }
    }
}

enum PostLoginWorkbenchAdmissionOutcome: Equatable {
    case admitted
    case duplicate
    case rejectedMissingSession
}

struct PostLoginWorkbenchAdmissionState {
    private var activeScope: String?

    mutating func consume(hasIMSession: Bool, scope: String) -> PostLoginWorkbenchAdmissionOutcome {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasIMSession, !normalizedScope.isEmpty else {
            return .rejectedMissingSession
        }
        guard activeScope != normalizedScope else {
            return .duplicate
        }
        activeScope = normalizedScope
        return .admitted
    }

    mutating func reset() {
        activeScope = nil
    }
}

final class DeviceRevocationHandlingState {
    private var isHandling = false

    var isHandlingRevocation: Bool {
        isHandling
    }

    func begin() -> Bool {
        guard !isHandling else { return false }
        isHandling = true
        return true
    }

    func finish() {
        isHandling = false
    }
}

// JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DIRECT_FRIEND_CONTEXT_EQUATABLE - 修改开始：支持好友不可用状态去重时识别 action/context 变化
struct DirectFriendRequestContext: Equatable {
// JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DIRECT_FRIEND_CONTEXT_EQUATABLE - 修改结束
    let targetUID: String
    let canApplyFriend: Bool?
    let friendRequestStatus: String
    let reasonCode: String
    let friendAction: String
    let friendFlow: String

    init(
        targetUID: String,
        canApplyFriend: Bool?,
        friendRequestStatus: String,
        reasonCode: String,
        friendAction: String = "",
        friendFlow: String = ""
    ) {
        self.targetUID = targetUID
        self.canApplyFriend = canApplyFriend
        self.friendRequestStatus = friendRequestStatus
        self.reasonCode = reasonCode
        self.friendAction = friendAction
        self.friendFlow = friendFlow
    }

    var normalizedStatus: String {
        friendRequestStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedReason: String {
        reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isPending: Bool {
        ["pending", "pending_out", "applied", "waiting", "reviewing"].contains(normalizedStatus)
    }

    var blocksApply: Bool {
        let blockedFragments = [
            "blocked",
            "disabled",
            "blacklist",
            "account_locked",
            "account_disabled",
            "account_cancelled",
            "account_canceled",
            "target_user_unavailable",
            "target_user_disabled",
            "target_user_cancelled",
            "target_user_canceled",
            "target_type_not_allowed",
            "friend_target_not_allowed",
            "system_user",
            "bot_user",
            "service_user",
            "test_user"
        ]
        return blockedFragments.contains { normalizedStatus.contains($0) || normalizedReason.contains($0) }
    }

    var allowsApply: Bool {
        guard !targetUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isPending,
              !blocksApply else {
            return false
        }
        let action = friendAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if action == "none" { return false }
        if action == "request" || action == "direct_add" { return true }
        return canApplyFriend ?? true
    }

    var disabledMessage: String {
        if isPending {
            return FriendAddPresentation.sentMessage
        }
        if normalizedStatus.contains("cancel") || normalizedReason.contains("cancel") {
            return "该用户已注销，无法互动"
        }
        if blocksApply {
            return "当前关系状态暂不可申请好友"
        }
        return "需先添加好友后才能发起私聊"
    }

    var actionTitle: String {
        FriendAddPresentation.actionTitle
    }
}

enum MessageReportSubmissionResult {
    case submitted(RemoteMessageReport)
    case alreadyReported(RemoteMessageReport)
    case failed
}

extension URL {
    var usableLocalFileURL: URL? {
        guard isFileURL,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return self
    }
}


enum AttachmentDownloadCachePolicy {
    static func legacyRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("BlueStoneIMAttachmentDownloads", isDirectory: true)
    }

    static func destinationURL(remoteURL: URL?, suggestedName: String, cacheKey: String, fallbackExtension: String) throws -> URL {
        let root = try legacyRootURL()
        let remoteKey = remoteURL?.absoluteString ?? UUID().uuidString
        let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remoteKey : cacheKey
        let directory = root.appendingPathComponent(stableHash(stableKey), isDirectory: true)
        let resolvedFallbackExtension = fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (remoteURL?.pathExtension ?? "")
            : fallbackExtension
        return directory.appendingPathComponent(sanitizedFileName(suggestedName, fallbackExtension: resolvedFallbackExtension), isDirectory: false)
    }

    static func canReuseCachedDownload(at url: URL, expectedSizeBytes: Int64?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { return false }
        if let expectedSizeBytes, expectedSizeBytes > 0 {
            return fileSize == expectedSizeBytes
        }
        return true
    }

    static func stagingURL(suggestedName: String, fallbackExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMAttachmentDownloadStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory.appendingPathComponent(
            sanitizedFileName(suggestedName, fallbackExtension: fallbackExtension),
            isDirectory: false
        )
    }

    static func purgeTransientStaging() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueStoneIMAttachmentDownloadStaging", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    static func legacyCandidateURLs(fileManager: FileManager = .default) -> [URL] {
        guard let root = try? legacyRootURL(fileManager: fileManager),
              fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard result.count < 10_000,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(url)
        }
        return result
    }

    static func purgeLegacyDownloads(fileManager: FileManager = .default) {
        guard let root = try? legacyRootURL(fileManager: fileManager),
              fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func sanitizedFileName(_ rawValue: String, fallbackExtension: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment-file" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.contains(".") || fallbackExtension.isEmpty {
            return sanitized.isEmpty ? "attachment-file" : sanitized
        }
        return "\(sanitized).\(fallbackExtension)"
    }
}

typealias AttachmentDownloadSessionFactory = @Sendable (_ delegate: any URLSessionDownloadDelegate) -> URLSession

struct AttachmentDownloadHTTPStatusError: MediaHTTPStatusProvidingError, Equatable {
    let statusCode: Int
    let requestURL: URL?
}

// JHT_MOD_BEGIN ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改开始：附件下载执行从 AppState/MainActor 抽到 support executor
enum AttachmentDownloadExecutor {
    static func temporaryFile(
        remoteURL: URL,
        suggestedName: String,
        cacheKey: String,
        fallbackExtension: String,
        expectedSizeBytes: Int64?,
        sessionFactory: @escaping AttachmentDownloadSessionFactory,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = AttachmentDownloadProgressDelegate(
            suggestedName: suggestedName,
            cacheKey: cacheKey,
            fallbackExtension: fallbackExtension,
            expectedSizeBytes: expectedSizeBytes,
            sessionFactory: sessionFactory,
            progress: progress
        )
        return try await downloader.start(remoteURL: remoteURL)
    }
}
// JHT_MOD_END ATTACHMENT_DOWNLOAD_NON_MAIN_PERF_20260912 - 修改结束

final class AttachmentDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let suggestedName: String
    private let cacheKey: String
    private let fallbackExtension: String
    private let expectedSizeBytes: Int64?
    private let progress: @Sendable (Double) -> Void
    private let sessionFactory: AttachmentDownloadSessionFactory
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var didFinish = false
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_STATE - 修改开始：下载回调进度节流状态，减少图片下载时主线程进度任务堆积
    private var lastProgressEmissionFraction: Double = 0
    private var lastProgressEmissionAt: CFAbsoluteTime = 0
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_STATE - 修改结束：下载回调进度节流状态，减少图片下载时主线程进度任务堆积

    init(
        suggestedName: String,
        cacheKey: String,
        fallbackExtension: String,
        expectedSizeBytes: Int64?,
        sessionFactory: @escaping AttachmentDownloadSessionFactory = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        },
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.suggestedName = suggestedName
        self.cacheKey = cacheKey
        self.fallbackExtension = fallbackExtension
        self.expectedSizeBytes = expectedSizeBytes
        self.sessionFactory = sessionFactory
        self.progress = progress
    }

    func start(remoteURL: URL) async throws -> URL {
        if remoteURL.isFileURL {
            progress(1)
            return remoteURL
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = sessionFactory(self)
                let task = session.downloadTask(with: remoteURL)
                self.session = session
                self.task = task
                lock.unlock()
                // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_START - 修改开始：初始下载进度走统一节流入口
                emitProgress(0.02)
                // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_START - 修改结束：初始下载进度走统一节流入口
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        session?.invalidateAndCancel()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_APPLY - 修改开始：合并下载过程中的细碎进度回调，避免图片消息滚动时频繁刷新
        emitProgress(max(0.02, min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.98)))
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_APPLY - 修改结束：合并下载过程中的细碎进度回调，避免图片消息滚动时频繁刷新
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let httpResponse = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw AttachmentDownloadHTTPStatusError(
                    statusCode: httpResponse.statusCode,
                    requestURL: downloadTask.originalRequest?.url
                )
            }
            let destination = try AttachmentDownloadCachePolicy.stagingURL(
                suggestedName: suggestedName,
                fallbackExtension: fallbackExtension
            )
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: location, to: destination)
            guard AttachmentDownloadCachePolicy.canReuseCachedDownload(at: destination, expectedSizeBytes: expectedSizeBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_FINISH - 修改开始：完成进度仍即时发出
            emitProgress(1)
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_FINISH - 修改结束：完成进度仍即时发出
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_HELPER - 修改开始：下载进度回调节流，保留开始/完成并合并高频小幅变化
    private func emitProgress(_ fraction: Double) {
        guard let fraction = nextProgressEmission(fraction) else { return }
        progress(fraction)
    }

    private func nextProgressEmission(
        _ fraction: Double,
        minimumDelta: Double = 0.025,
        minimumInterval: CFTimeInterval = 0.12
    ) -> Double? {
        let boundedFraction = max(0, min(fraction, 1))
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        let shouldEmit = lastProgressEmissionAt == 0
            || boundedFraction >= 0.995
            || abs(boundedFraction - lastProgressEmissionFraction) >= minimumDelta
            || now - lastProgressEmissionAt >= minimumInterval
        guard shouldEmit else { return nil }
        lastProgressEmissionFraction = boundedFraction
        lastProgressEmissionAt = now
        return boundedFraction
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_DOWNLOAD_CALLBACK_THROTTLE_HELPER - 修改结束：下载进度回调节流，保留开始/完成并合并高频小幅变化

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

}
