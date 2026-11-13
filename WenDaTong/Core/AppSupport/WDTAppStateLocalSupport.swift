import Combine // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
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

enum DebugConsoleDiagnostics {
    nonisolated static let verbose: Bool = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-WDTVerboseDiagnostics")
#else
        false
#endif
    }()

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        print(message())
    }
}

struct RealtimeMessageIngestBuffer {
    struct GroupedMessages {
        let scopeKey: String
        let channelID: String
        let channelType: String
        let messages: [RemoteMessage]
        let signposts: [RealtimeMessageFlowSignpost]
    }

    private struct Entry {
        let message: RemoteMessage
        let scopeKey: String
        let order: Int
        let signpost: RealtimeMessageFlowSignpost?
        let acknowledgement: Bool // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        let diagnostic: RealtimeEnvelopeDiagnosticObservation?
    }
    struct Work {
        let groups: [GroupedMessages]
        let acknowledgement: Bool
        let diagnostic: RealtimeEnvelopeDiagnosticObservation?
    }

    private var entries: [Entry] = []
    private var nextOrder = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func signposts(excluding scopeKey: String? = nil) -> [RealtimeMessageFlowSignpost] {
        entries.filter { scopeKey == nil || $0.scopeKey != scopeKey }.compactMap(\.signpost)
    }
    func signpostsNotPreservedByClear(currentScopeKey: String) -> [RealtimeMessageFlowSignpost] {
        entries.filter { !($0.acknowledgement && $0.scopeKey == currentScopeKey) }.compactMap(\.signpost)
    }

    mutating func append(_ message: RemoteMessage, scopeKey: String, acknowledgement: Bool = false,
                         diagnostic: RealtimeEnvelopeDiagnosticObservation? = nil, signpost: RealtimeMessageFlowSignpost? = nil) {
        entries.append(Entry(message: message, scopeKey: scopeKey, order: nextOrder,
                             signpost: signpost, acknowledgement: acknowledgement, diagnostic: diagnostic))
        nextOrder += 1
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        nextOrder = 0
    }

    mutating func drainGrouped(currentScopeKey: String) -> [GroupedMessages] {
        let drained = entries
        clear()

        return Self.groupedEntries(drained, currentScopeKey: currentScopeKey)
    }

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    mutating func drainWork(currentScopeKey: String) -> [Work] {
        let drained = entries.filter { $0.scopeKey == currentScopeKey }; clear()
        var result: [Work] = [], pending: [Entry] = []
        for entry in drained {
            if entry.acknowledgement {
                if !pending.isEmpty {
                    result.append(Work(groups: Self.groupedEntries(pending, currentScopeKey: currentScopeKey), acknowledgement: false, diagnostic: nil))
                    pending = []
                }
                result.append(Work(groups: [GroupedMessages(scopeKey: entry.scopeKey, channelID: entry.message.channelID,
                    channelType: entry.message.channelType, messages: [entry.message], signposts: entry.signpost.map { [$0] } ?? [])], acknowledgement: true, diagnostic: entry.diagnostic))
            } else { pending.append(entry) }
        }
        if !pending.isEmpty { result.append(Work(groups: Self.groupedEntries(pending, currentScopeKey: currentScopeKey), acknowledgement: false, diagnostic: nil)) }
        return result
    }
    mutating func clearMessagesPreservingAcceptedAcknowledgements(currentScopeKey: String) {
        entries = entries.filter { $0.acknowledgement && $0.scopeKey == currentScopeKey }
        // Original order values remain meaningful only inside this native buffer.
        if entries.isEmpty { nextOrder = 0 }
    }
    private static func groupedEntries(_ drained: [Entry], currentScopeKey: String) -> [GroupedMessages] {
        var groupOrder: [String] = []
        var grouped: [String: (scopeKey: String, channelID: String, channelType: String, messages: [RemoteMessage], signposts: [RealtimeMessageFlowSignpost], firstOrder: Int)] = [:]
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
                    messages: [], signposts: [],
                    firstOrder: entry.order
                )
            }
            grouped[key]?.messages.append(entry.message)
            if let signpost = entry.signpost { grouped[key]?.signposts.append(signpost) }
        }

        return groupOrder
            .compactMap { grouped[$0] }
            .sorted { $0.firstOrder < $1.firstOrder }
            .map {
                GroupedMessages(
                    scopeKey: $0.scopeKey,
                    channelID: $0.channelID,
                    channelType: $0.channelType,
                    messages: $0.messages, signposts: $0.signposts
                )
            }
    }
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
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
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END
