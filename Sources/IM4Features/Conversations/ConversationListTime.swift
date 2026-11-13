// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import Foundation

public func featureConversationListDisplayTimestamp(_ time: String, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
    let value = time.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value == "刚刚" {
        return now.timeIntervalSince1970
    }
    if value.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
        guard let timestamp = conversationListTimestampForTimeToken(value, dayOffset: 0, now: now, calendar: calendar) else {
            return nil
        }
        if timestamp > now.addingTimeInterval(60).timeIntervalSince1970,
           let adjustedDate = calendar.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: timestamp)) {
            return adjustedDate.timeIntervalSince1970
        }
        return timestamp
    }
    if let monthDayTimestamp = conversationListMonthDayTimestamp(in: value, now: now, calendar: calendar) {
        return monthDayTimestamp
    }
    if value.hasPrefix("昨天") {
        let token = value.split(separator: " ").map(String.init).last ?? ""
        return conversationListTimestampForTimeToken(token, dayOffset: -1, now: now, calendar: calendar)
            ?? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))?.timeIntervalSince1970
    }
    if value.hasPrefix("今天") {
        let token = value.split(separator: " ").map(String.init).last ?? ""
        return conversationListTimestampForTimeToken(token, dayOffset: 0, now: now, calendar: calendar)
    }
    return nil
}

// JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：列表行时间格式化支持轻量展示模型，避免把完整会话对象带入行视图
public func featureConversationListDisplayTime(rawTime: String, sortTimestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> String {
    if sortTimestamp > 0 {
        let timestamp = featureConversationListNormalizedTimestamp(sortTimestamp, now: now, calendar: calendar)
        return featureConversationListDisplayTime(for: Date(timeIntervalSince1970: timestamp), now: now, calendar: calendar)
    }
    let normalizedRawTime = rawTime.trimmingCharacters(in: .whitespacesAndNewlines)
    if let timestamp = featureConversationListDisplayTimestamp(normalizedRawTime, now: now, calendar: calendar) {
        return featureConversationListDisplayTime(for: Date(timeIntervalSince1970: timestamp), now: now, calendar: calendar)
    }
    return normalizedRawTime
}
// JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

public func featureConversationListNormalizedTimestamp(_ timestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
    guard timestamp > 0 else { return timestamp }
    let nowTimestamp = now.timeIntervalSince1970
    guard timestamp > nowTimestamp + 60 else { return timestamp }
    let date = Date(timeIntervalSince1970: timestamp)
    guard let adjusted = calendar.date(byAdding: .day, value: -1, to: date),
          adjusted.timeIntervalSince1970 <= nowTimestamp else {
        return timestamp
    }
    return adjusted.timeIntervalSince1970
}

private func featureConversationListDisplayTime(for date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
        return ConversationListDateFormatterPool.string(from: date, format: "HH:mm", calendar: calendar)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "昨天 \(ConversationListDateFormatterPool.string(from: date, format: "HH:mm", calendar: calendar))"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return ConversationListDateFormatterPool.string(from: date, format: "M月d日", calendar: calendar)
    } else {
        return ConversationListDateFormatterPool.string(from: date, format: "yyyy/M/d", calendar: calendar)
    }
}

private enum ConversationListDateFormatterPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCalendar: Calendar?
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, calendar: Calendar) -> String {
        lock.lock()
        defer { lock.unlock() }
        if cachedCalendar != calendar {
            cachedCalendar = calendar
            formatters.removeAll()
        }
        let formatter = formatters[format] ?? {
            let value = DateFormatter()
            value.locale = Locale(identifier: "zh_CN")
            value.calendar = calendar
            value.timeZone = calendar.timeZone
            value.dateFormat = format
            formatters[format] = value
            return value
        }()
        return formatter.string(from: date)
    }
}

private func conversationListMonthDayTimestamp(in value: String, now: Date, calendar: Calendar) -> TimeInterval? {
    let monthDayPattern = #"(\d{1,2})月(\d{1,2})日"#
    guard let match = value.range(of: monthDayPattern, options: .regularExpression) else { return nil }
    let numbers = String(value[match])
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
    guard var date = calendar.date(from: components) else { return nil }
    if date > now, let previousYear = calendar.date(byAdding: .year, value: -1, to: date) {
        date = previousYear
    }
    return date.timeIntervalSince1970
}

private func conversationListTimestampForTimeToken(_ token: String, dayOffset: Int, now: Date, calendar: Calendar) -> TimeInterval? {
    let parts = token.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2,
          (0..<24).contains(parts[0]),
          (0..<60).contains(parts[1]) else {
        return nil
    }
    guard let baseDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
          let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts.count >= 3 ? parts[2] : 0, of: baseDay) else {
        return nil
    }
    return date.timeIntervalSince1970
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
