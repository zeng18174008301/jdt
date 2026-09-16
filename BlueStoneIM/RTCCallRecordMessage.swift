import Foundation

enum RTCCallRecordType: String, Codable, Hashable, Sendable {
    case audio
    case video

    var title: String {
        switch self {
        case .audio: return "语音通话"
        case .video: return "视频通话"
        }
    }

    var systemImageName: String {
        switch self {
        case .audio: return "phone.fill"
        case .video: return "video.fill"
        }
    }
}

enum RTCCallRecordOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case completed
    case callerCanceled = "caller_canceled"
    case calleeRejected = "callee_rejected"
    case noAnswer = "no_answer"
    case busy
    case setupFailed = "setup_failed"
    case interrupted
}

struct RTCCallRecordPayload: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let callID: String
    let callType: RTCCallRecordType
    let callerUID: String
    let calleeUID: String
    let finalOutcome: RTCCallRecordOutcome
    let startedAt: Date
    let answeredAt: Date?
    let mediaConnectedAt: Date?
    let endedAt: Date
    let durationSeconds: Int
    let reasonCode: String
    let fallbackText: String
    let endActorUID: String?
    let finalMediaMode: String?

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
        RTCCallRecordPresentation(record: self, viewerIsCaller: viewerIsCaller, timeZone: timeZone)
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
        guard let date, date.timeIntervalSince1970.isFinite else { return "拨打时间未知" }
        return "拨打于 \(formatted(date, format: "yyyy-MM-dd HH:mm", timeZone: timeZone))"
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

enum RTCCallRecordTone: String, Codable, Hashable, Sendable {
    case neutral
    case brand
    case muted
    case danger
    case warning
}

struct RTCCallRecordPresentation: Hashable, Sendable {
    let title: String
    let directionLabel: String
    let statusText: String
    let dialedAtText: String
    let tone: RTCCallRecordTone
    let systemImageName: String

    init(record: RTCCallRecordPayload, viewerIsCaller: Bool, timeZone: TimeZone = .current) {
        title = record.callType.title
        directionLabel = viewerIsCaller ? "呼出" : "呼入"
        systemImageName = record.callType.systemImageName
        let verified = record.validated(contentType: "rtc_call_record", channelType: "direct", fromUID: record.callerUID)
        dialedAtText = RTCCallRecordTimeProjection.dialedAtText(verified?.startedAt, timeZone: timeZone)
        switch record.finalOutcome {
        case .completed:
            statusText = "通话时长 \(Self.duration(record.durationSeconds))"
            tone = .neutral
        case .callerCanceled:
            statusText = viewerIsCaller ? "已取消" : "对方已取消"
            tone = .muted
        case .calleeRejected:
            statusText = viewerIsCaller ? "对方已拒绝" : "已拒绝"
            tone = .danger
        case .noAnswer:
            statusText = viewerIsCaller ? "无人接听" : "未接来电"
            tone = viewerIsCaller ? .muted : .danger
        case .busy:
            statusText = viewerIsCaller ? "对方忙线" : "忙线未接来电"
            tone = .warning
        case .setupFailed:
            statusText = viewerIsCaller ? "连接失败" : "对方连接失败"
            tone = .danger
        case .interrupted:
            statusText = "通话中断 · \(Self.duration(record.durationSeconds))"
            tone = .warning
        }
    }

    var conversationPreview: String {
        "\(title) · \(statusText)"
    }

    func accessibilityLabel(peerName: String, viewerIsCaller: Bool, outcome: RTCCallRecordOutcome) -> String {
        let type = title.replacingOccurrences(of: "通话", with: "")
        let event: String
        switch (outcome, viewerIsCaller) {
        case (.noAnswer, false): event = "未接\(type)来电"
        case (.busy, false): event = "忙线未接\(type)来电"
        default: event = "\(title)，\(statusText)"
        }
        let normalizedPeer = peerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [event, directionLabel, normalizedPeer, dialedAtText, "再次呼叫需确认"].filter { !$0.isEmpty }.joined(separator: "，")
    }

    private static func duration(_ seconds: Int) -> String {
        let bounded = max(0, seconds)
        let hours = bounded / 3_600
        let minutes = (bounded % 3_600) / 60
        let remainder = bounded % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

enum RTCCallRecordMessageDeduplicator {
    enum ListSummaryMergeDecision: Equatable {
        case append
        case exactDuplicate
        case conflict(sequence: Int64)
    }

    struct Authority: Hashable {
        let callID: String
        let messageID: String
        let channelSeq: Int64
        let senderID: String
        let isOutgoing: Bool
        let contentType: String
        let record: RTCCallRecordPayload
    }

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
