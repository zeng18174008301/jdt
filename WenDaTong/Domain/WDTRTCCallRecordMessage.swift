import IM4Features
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain

extension RTCCallRecordPayload {
    static func parse(
        contentType: String,
        channelType: String,
        fromUID: String,
        payload: [String: JSONValue]
    ) -> RTCCallRecordPayload? {
        guard normalized(contentType) == "rtc_call_record",
              normalized(channelType) == "direct",
              integer(payload["schema_version"]) == 1,
              let callID = requiredIdentifier(payload["call_id"]),
              let callType = string(payload["call_type"]).flatMap(RTCCallRecordType.init(rawValue:)),
              let callerUID = requiredIdentifier(payload["caller_uid"]),
              let calleeUID = requiredIdentifier(payload["callee_uid"]),
              callerUID != calleeUID,
              normalized(fromUID) == normalized(callerUID),
              let outcome = string(payload["final_outcome"]).flatMap(RTCCallRecordOutcome.init(rawValue:)),
              let startedAt = date(payload["started_at"]),
              let endedAt = date(payload["ended_at"]),
              endedAt >= startedAt,
              let durationSeconds = integer(payload["duration_seconds"]),
              durationSeconds >= 0,
              let reasonCode = safeReasonCode(payload["reason_code"])
        else {
            return nil
        }

        let answeredAt = optionalDate(payload["answered_at"])
        let mediaConnectedAt = optionalDate(payload["media_connected_at"])
        let endActorUID = optionalIdentifierField(payload["end_actor_uid"])
        let finalMediaMode = optionalMediaMode(payload["final_media_mode"])
        guard answeredAt.isValid,
              mediaConnectedAt.isValid,
              endActorUID.isValid,
              finalMediaMode.isValid,
              requiredSafeDisplayText(payload["text"]) != nil,
              let fallbackText = requiredSafeDisplayText(payload["fallback_text"]) else {
            return nil
        }

        return RTCCallRecordPayload(
            schemaVersion: 1,
            callID: callID,
            callType: callType,
            callerUID: callerUID,
            calleeUID: calleeUID,
            finalOutcome: outcome,
            startedAt: startedAt,
            answeredAt: answeredAt.value,
            mediaConnectedAt: mediaConnectedAt.value,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            reasonCode: reasonCode,
            fallbackText: fallbackText,
            endActorUID: endActorUID.value,
            finalMediaMode: finalMediaMode.value
        ).validated(contentType: contentType, channelType: channelType, fromUID: fromUID)
    }

    /// Codable decoding does not run wire validation. Recheck typed values before
    /// using a historical timestamp; preserve the original payload for collision checks.
    func validated(contentType: String, channelType: String, fromUID: String) -> Self? {
        guard Self.normalized(contentType) == "rtc_call_record",
              Self.normalized(channelType) == "direct",
              schemaVersion == 1,
              Self.requiredIdentifier(.string(callID)) == callID,
              Self.requiredIdentifier(.string(callerUID)) == callerUID,
              Self.requiredIdentifier(.string(calleeUID)) == calleeUID,
              callerUID != calleeUID,
              Self.normalized(fromUID) == Self.normalized(callerUID),
              durationSeconds >= 0,
              Self.safeReasonCode(.string(reasonCode)) == reasonCode,
              Self.requiredSafeDisplayText(.string(fallbackText)) == fallbackText,
              Self.optionalIdentifierField(endActorUID.map(JSONValue.string)).isValid,
              Self.optionalMediaMode(finalMediaMode.map(JSONValue.string)).isValid,
              Self.optionalMediaMode(finalMediaMode.map(JSONValue.string)).value == finalMediaMode,
              finalMediaMode.map({ $0 != callType.rawValue }) ?? true,
              Self.timestampsAreValid(
                  startedAt: startedAt, answeredAt: answeredAt,
                  mediaConnectedAt: mediaConnectedAt, endedAt: endedAt
              ),
              Self.outcomeFieldsAreValid(
                  outcome: finalOutcome, callerUID: callerUID, calleeUID: calleeUID,
                  answeredAt: answeredAt, mediaConnectedAt: mediaConnectedAt,
                  durationSeconds: durationSeconds, endActorUID: endActorUID
              ) else { return nil }
        return self
    }

    static func safeFallbackText(
        payload: [String: JSONValue],
        callType: RTCCallRecordType? = nil
    ) -> String {
        for key in ["fallback_text", "text"] {
            if let candidate = requiredSafeDisplayText(payload[key]) {
                return candidate
            }
        }
        if let callType {
            return "[\(callType.title)] 通话记录"
        }
        return "[通话记录]"
    }

    func peerUID(viewerIsCaller: Bool) -> String {
        viewerIsCaller ? calleeUID : callerUID
    }

    func presentation(viewerIsCaller: Bool, timeZone: TimeZone = .current) -> RTCCallRecordPresentation {
        let verified = validated(contentType: "rtc_call_record", channelType: "direct", fromUID: callerUID)
        return RTCCallRecordPresentation(record: self, viewerIsCaller: viewerIsCaller,
            dialedAtText: RTCCallRecordTimeProjection.dialedAtText(verified?.startedAt, timeZone: timeZone))
    }

    private struct OptionalDateResult {
        let value: Date?
        let isValid: Bool
    }

    private struct OptionalStringResult {
        let value: String?
        let isValid: Bool
    }

    private static func optionalDate(_ value: JSONValue?) -> OptionalDateResult {
        guard let value else { return OptionalDateResult(value: nil, isValid: true) }
        if case .null = value { return OptionalDateResult(value: nil, isValid: true) }
        guard let parsed = date(value) else { return OptionalDateResult(value: nil, isValid: false) }
        return OptionalDateResult(value: parsed, isValid: true)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func requiredIdentifier(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.count <= 160,
              raw.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return raw
    }

    private static func optionalIdentifierField(_ value: JSONValue?) -> OptionalStringResult {
        guard let value else { return OptionalStringResult(value: nil, isValid: true) }
        if case .null = value { return OptionalStringResult(value: nil, isValid: true) }
        guard let identifier = requiredIdentifier(value) else {
            return OptionalStringResult(value: nil, isValid: false)
        }
        return OptionalStringResult(value: identifier, isValid: true)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let number):
            return number
        case .double(let number) where number.isFinite && number.rounded() == number:
            return Int(exactly: number)
        case .string(let raw):
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func date(_ value: JSONValue?) -> Date? {
        RTCCallRecordTimeProjection.parseServerTimestamp(value?.stringValue)
    }

    private static func safeReasonCode(_ value: JSONValue?) -> String? {
        guard let reason = string(value), reason.count <= 64,
              reason.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return reason
    }

    private static func optionalMediaMode(_ value: JSONValue?) -> OptionalStringResult {
        guard let value else { return OptionalStringResult(value: nil, isValid: true) }
        if case .null = value { return OptionalStringResult(value: nil, isValid: true) }
        guard let mode = string(value), ["audio", "video"].contains(mode) else {
            return OptionalStringResult(value: nil, isValid: false)
        }
        return OptionalStringResult(value: mode, isValid: true)
    }

    private static func timestampsAreValid(
        startedAt: Date,
        answeredAt: Date?,
        mediaConnectedAt: Date?,
        endedAt: Date
    ) -> Bool {
        guard [startedAt, answeredAt, mediaConnectedAt, endedAt].compactMap({ $0 })
                  .allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              endedAt >= startedAt,
              answeredAt.map({ $0 >= startedAt && $0 <= endedAt }) ?? true,
              mediaConnectedAt.map({ $0 >= startedAt && $0 <= endedAt }) ?? true else {
            return false
        }
        if let answeredAt, let mediaConnectedAt, mediaConnectedAt < answeredAt {
            return false
        }
        return true
    }

    private static func outcomeFieldsAreValid(
        outcome: RTCCallRecordOutcome,
        callerUID: String,
        calleeUID: String,
        answeredAt: Date?,
        mediaConnectedAt: Date?,
        durationSeconds: Int,
        endActorUID: String?
    ) -> Bool {
        if let endActorUID, endActorUID != callerUID, endActorUID != calleeUID {
            return false
        }
        switch outcome {
        case .completed:
            return answeredAt != nil && mediaConnectedAt != nil && endActorUID != nil
        case .callerCanceled:
            return answeredAt == nil && mediaConnectedAt == nil && durationSeconds == 0 && endActorUID == callerUID
        case .calleeRejected:
            return answeredAt == nil && mediaConnectedAt == nil && durationSeconds == 0 && endActorUID == calleeUID
        case .noAnswer, .busy:
            return answeredAt == nil && mediaConnectedAt == nil && durationSeconds == 0 && endActorUID == nil
        case .setupFailed:
            return mediaConnectedAt == nil && durationSeconds == 0
        case .interrupted:
            return answeredAt != nil && mediaConnectedAt != nil
        }
    }

    private static func requiredSafeDisplayText(_ value: JSONValue?) -> String? {
        guard let sanitized = sanitizedDisplayText(value?.stringValue),
              sanitized.contains("通话"),
              isRoleNeutralLegacyDisplayText(sanitized),
              !containsSensitiveMaterial(sanitized) else {
            return nil
        }
        return sanitized
    }

    private static func isRoleNeutralLegacyDisplayText(_ value: String) -> Bool {
        let displayOnlyPattern = #"^[\p{script=Han}\p{N}\s\[\]【】（）()·：:，。！？、]+$"#
        guard value.range(of: displayOnlyPattern, options: .regularExpression) != nil else {
            return false
        }
        let blockedTerms = [
            "令牌", "密钥", "密码", "凭证", "房间", "服务器", "候选地址", "网关",
            "设备编号", "设备标识", "序列号", "网络地址", "调试", "日志", "堆栈", "异常",
            "许可证", "授权码"
        ]
        return !blockedTerms.contains(where: value.contains)
    }

    private static func containsSensitiveMaterial(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let blockedFragments = [
            "room_id", "roomid", "rtc_token", "rtctoken", "turn:", "stun:",
            "ice_", "candidate:", "sdp", "device_id", "deviceid", "serial_number",
            "push_token", "pushtoken", "stack trace", "exception", "private_key",
            "license_key", "license=", "api_key", "api-key", "secret", "password", "credential", "token=", "token:",
            "http://", "https://"
        ]
        guard !blockedFragments.contains(where: normalized.contains) else { return true }
        let sensitiveLabelPattern = #"(?i)\b(?:rtc[\s_-]*token|room[\s_-]*id|device[\s_-]*(?:id|serial)|push[\s_-]*token|bearer\s+\S+|token\s+\S+)\b"#
        if normalized.range(of: sensitiveLabelPattern, options: .regularExpression) != nil { return true }
        let privateAddressPattern = #"(?i)(?:\b10(?:\.\d{1,3}){3}\b|\b127(?:\.\d{1,3}){3}\b|\b169\.254(?:\.\d{1,3}){2}\b|\b192\.168(?:\.\d{1,3}){2}\b|\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b|\blocalhost\b)"#
        if normalized.range(of: privateAddressPattern, options: .regularExpression) != nil { return true }
        let privateNetworkPattern = #"(?i)(?:\b[a-z0-9.-]+\.(?:internal|local|lan)\b|\b(?:fc|fd)[0-9a-f]{2}:[0-9a-f:]+\b|\bfe[89ab][0-9a-f]:[0-9a-f:]+\b|::1\b)"#
        if normalized.range(of: privateNetworkPattern, options: .regularExpression) != nil { return true }
        let jwtPattern = #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#
        return value.range(of: jwtPattern, options: .regularExpression) != nil
    }

    private static func sanitizedDisplayText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 180 { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: 180)
        return "\(collapsed[..<end])…"
    }
}

enum RTCCallRecordTimeProjection {
    // WDT_IOS1_CALL_DURATION_20261023_BEGIN
    static func exactDurationSeconds(_ value: Int) -> TimeInterval? {
        guard value >= 0, let seconds = TimeInterval(exactly: value),
              Int(exactly: seconds) == value else { return nil }
        return seconds
    }

    static func validatedDurationSeconds(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0,
              Int(exactly: value.rounded()) != nil else { return nil }
        return value
    }

    // Protects records decoded directly from old caches, which bypass history projection.
    static func durationText(seconds: TimeInterval?) -> String {
        guard let seconds = validatedDurationSeconds(seconds),
              let total = Int(exactly: seconds.rounded()) else { return "未记录" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 { return "\(hours)小时\(minutes)分\(remainingSeconds)秒" }
        if minutes > 0 { return "\(minutes)分\(remainingSeconds)秒" }
        return "\(remainingSeconds)秒"
    }
    // WDT_IOS1_CALL_DURATION_20261023_END

    static func parseServerTimestamp(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// Display projection only: callers retain the original createdAt, sequence and cursor.
    static func messageDate(
        outerDate: Date?, record: RTCCallRecordPayload?,
        contentType: String, channelType: String, fromUID: String
    ) -> Date? {
        if let record = record?.validated(contentType: contentType, channelType: channelType, fromUID: fromUID) {
            return record.endedAt
        }
        if let outerDate, outerDate.timeIntervalSince1970.isFinite { return outerDate }
        return nil
    }

    /// Match AppState's message/list formatting. `now` classifies today only;
    /// it is never a source for a missing historical timestamp.
    static func displayTime(_ date: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date, date.timeIntervalSince1970.isFinite else { return "时间未知" }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let format = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日"
        return formatted(date, format: format, timeZone: timeZone)
    }

    static func dialedAtText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        RTCCallRecordPresentation.dialedAtText(date, timeZone: timeZone)
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

enum RTCCallRecordMessageDeduplicator {
    enum ListSummaryMergeDecision: Equatable {
        case append
        case exactDuplicate
        case conflict(sequence: Int64)
    }

    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110: original pure seven-field value; all RTC policy remains in App.
    typealias Authority = IM4Domain.RTCCallRecordAuthority

    static func authority(for message: ChatMessage) -> Authority? {
        guard let record = message.rtcCallRecord else { return nil }
        return Authority(
            callID: record.callID,
            messageID: message.id.trimmingCharacters(in: .whitespacesAndNewlines),
            channelSeq: message.channelSeq,
            senderID: message.senderId.trimmingCharacters(in: .whitespacesAndNewlines),
            isOutgoing: message.isOutgoing,
            contentType: message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            record: record
        )
    }

    static func listSummaryMergeDecision(
        existingMessages: [ChatMessage],
        candidate: ChatMessage
    ) -> ListSummaryMergeDecision {
        let candidateID = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existingIdentity = existingMessages.first(where: { existing in
            (!candidateID.isEmpty && existing.id.trimmingCharacters(in: .whitespacesAndNewlines) == candidateID)
                || (candidate.channelSeq > 0 && existing.channelSeq == candidate.channelSeq)
        }) else {
            return .append
        }
        if let existingAuthority = authority(for: existingIdentity),
           let candidateAuthority = authority(for: candidate),
           existingAuthority == candidateAuthority {
            return .exactDuplicate
        }
        let positiveSequences = [existingIdentity.channelSeq, candidate.channelSeq].filter { $0 > 0 }
        guard positiveSequences.count == 2 else { return .conflict(sequence: 0) }
        return .conflict(sequence: positiveSequences.min() ?? 0)
    }

    static func deduplicated(_ messages: [ChatMessage]) -> [ChatMessage] {
        var authorityByCallID: [String: Authority] = [:]
        return messages.filter { message in
            guard let authority = authority(for: message) else { return true }
            guard authorityByCallID[authority.callID] == nil else { return false }
            authorityByCallID[authority.callID] = authority
            return true
        }
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END
