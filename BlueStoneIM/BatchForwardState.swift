import Foundation

let batchForwardVoiceOwnershipReason = "仅可转发自己发送的语音"

enum BatchForwardSenderProvenance: String, Codable, Sendable {
    case authoritativeStored = "authoritative_stored"
    case clientSupplied = "client_supplied"
    case cachedUnverified = "cached_unverified"
    case unknown
}

enum BatchForwardTargetTab: String, Codable, CaseIterable, Sendable {
    case friend
    case group
}

enum BatchForwardMode: String, Codable, Sendable {
    case separate
}

struct BatchForwardScope: Equatable, Codable, Sendable {
    let tenantID: String
    let actorUID: String
    let sourceChannelID: String
    let sourceChannelType: String

    private enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case actorUID = "actor_uid"
        case sourceChannelID = "source_channel_id"
        case sourceChannelType = "source_channel_type"
    }
}

struct BatchForwardMessageSnapshot: Equatable, Codable, Sendable {
    let messageID: String
    let sourceChannelID: String
    let sourceChannelType: String
    let senderUID: String?
    let senderProvenance: BatchForwardSenderProvenance
    let channelSeq: Int64?
    let createdAtMillis: Int64?
    let historyPage: Int?
    let clientState: String
    let contentType: String
    let kind: String
    let mediaCategory: String
    let previewKind: String
    let nestedSemanticMarkers: [String]
    let fileName: String
    let mimeType: String

    init(
        messageID: String,
        sourceChannelID: String,
        sourceChannelType: String,
        senderUID: String?,
        senderProvenance: BatchForwardSenderProvenance,
        channelSeq: Int64? = nil,
        createdAtMillis: Int64? = nil,
        historyPage: Int? = nil,
        clientState: String = "sent",
        contentType: String = "",
        kind: String = "",
        mediaCategory: String = "",
        previewKind: String = "",
        nestedSemanticMarkers: [String] = [],
        fileName: String = "",
        mimeType: String = ""
    ) {
        self.messageID = messageID
        self.sourceChannelID = sourceChannelID
        self.sourceChannelType = sourceChannelType
        self.senderUID = senderUID
        self.senderProvenance = senderProvenance
        self.channelSeq = channelSeq
        self.createdAtMillis = createdAtMillis
        self.historyPage = historyPage
        self.clientState = clientState
        self.contentType = contentType
        self.kind = kind
        self.mediaCategory = mediaCategory
        self.previewKind = previewKind
        self.nestedSemanticMarkers = nestedSemanticMarkers
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

enum BatchForwardEligibility: Equatable, Sendable {
    case selectable
    case disabled(String)
}

struct BatchForwardTarget: Equatable, Codable, Sendable {
    let channelID: String
    let channelType: String
    let displayName: String
    let searchTerms: [String]

    init(
        channelID: String,
        channelType: String,
        displayName: String,
        searchTerms: [String] = []
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.displayName = displayName
        self.searchTerms = searchTerms
    }

    var tab: BatchForwardTargetTab? {
        switch BatchForwardSemantics.normalized(channelType) {
        case "direct", "friend", "single", "person":
            return .friend
        case "group":
            return .group
        default:
            return nil
        }
    }

    func canonicalChannelID(actorUID: String) -> String {
        BatchForwardSemantics.canonicalChannelID(
            channelID,
            channelType: channelType,
            actorUID: actorUID
        )
    }

    func identityKey(actorUID: String) -> String {
        "\(BatchForwardSemantics.canonicalChannelType(channelType))|\(canonicalChannelID(actorUID: actorUID))"
    }
}

struct BatchForwardTargetCandidate: Identifiable, Equatable, Sendable {
    let identityKey: String
    let target: BatchForwardTarget
    let subtitle: String
    let avatarSeed: UInt
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let memberCount: Int?

    var id: String { identityKey }
    var isGroup: Bool { target.tab == .group }
}

enum BatchForwardSemantics {
    private static let strongVoiceMarkers: Set<String> = [
        "voice",
        "voice_clip",
        "voice_message",
        "voice_message_file",
        "voice_note",
        "voicemessage",
        "audio_message",
        "audio_message_file",
        "audio_note",
        "recorded_voice",
        "recording",
        "ptt",
        "push_to_talk",
        "语音",
        "语音消息",
    ]

    private static let blockedKinds: Set<String> = [
        "system",
        "system_message",
        "control",
        "membership",
        "call",
        "call_event",
        "call_control",
        "rtc",
        "rtc_event",
        "merge_forward",
        "merged_forward",
        "forward_bundle",
    ]

    private static let allowedContentMarkers: Set<String> = [
        "text",
        "plain_text",
        "rich_text",
        "image",
        "photo",
        "video",
        "audio",
        "audio_file",
        "music",
        "file",
        "document",
        "attachment",
        "location",
        "contact",
        "card",
        "sticker",
        "emoji",
        "gif",
        "reply",
        "quote",
    ]

    private static let allowedStates: Set<String> = [
        "sent",
        "edited",
        "read",
        "delivered",
    ]

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    static func canonicalChannelType(_ value: String) -> String {
        switch normalized(value) {
        case "direct", "friend", "single", "person":
            return "direct"
        case "group":
            return "group"
        default:
            return normalized(value)
        }
    }

    static func canonicalChannelID(
        _ value: String,
        channelType: String,
        actorUID: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonicalChannelType(channelType) == "direct" else {
            return trimmed
        }
        let parts = trimmed
            .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "|" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) {
            return parts.sorted().joined(separator: ":")
        }
        let actor = actorUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !actor.isEmpty,
           trimmed != actor,
           !trimmed.contains(where: { $0 == ":" || $0 == "," || $0 == "|" }) {
            return [actor, trimmed].sorted().joined(separator: ":")
        }
        return trimmed
    }

    private static func containsStrongVoiceMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard !value.isEmpty else {
            return false
        }
        if strongVoiceMarkers.contains(value) {
            return true
        }
        let components = value.split { character in
            character == "." || character == "/" || character == ":" || character == "#"
        }
        return components.contains { strongVoiceMarkers.contains(String($0)) }
    }

    private static func hasLegacyVoiceFileName(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("voice-") || value.hasPrefix("voice_") || value.hasPrefix("voice.")
    }

    private static func containsBlockedMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        if blockedKinds.contains(value) {
            return true
        }
        let components = value.split { character in
            character == "." || character == "/" || character == ":" || character == "#"
        }
        return components.contains { blockedKinds.contains(String($0)) }
    }

    private static func isAllowedContentMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard !value.isEmpty else {
            return true
        }
        if allowedContentMarkers.contains(value) || containsStrongVoiceMarker(value) {
            return true
        }
        return value.hasPrefix("text/")
            || value.hasPrefix("image/")
            || value.hasPrefix("video/")
            || value.hasPrefix("audio/")
            || value.hasPrefix("application/")
    }

    static func isVoice(_ message: BatchForwardMessageSnapshot) -> Bool {
        let nonKindMarkers = [
            message.contentType,
            message.mediaCategory,
            message.previewKind,
        ] + message.nestedSemanticMarkers
        if nonKindMarkers.contains(where: containsStrongVoiceMarker) {
            return true
        }
        if hasLegacyVoiceFileName(message.fileName) {
            return true
        }

        return containsStrongVoiceMarker(message.kind)
    }

    static func eligibility(
        of message: BatchForwardMessageSnapshot,
        actorUID: String
    ) -> BatchForwardEligibility {
        let state = normalized(message.clientState)
        guard allowedStates.contains(state) else {
            return .disabled("消息当前不可转发")
        }

        let semanticValues = [
            message.contentType,
            message.kind,
            message.mediaCategory,
            message.previewKind,
        ] + message.nestedSemanticMarkers
        if semanticValues.contains(where: containsBlockedMarker) {
            return .disabled("该消息类型不可转发")
        }
        let primaryContentMarkers = [
            message.contentType,
            message.kind,
            message.mediaCategory,
            message.previewKind,
        ]
        guard primaryContentMarkers.contains(where: { !normalized($0).isEmpty })
                || isVoice(message),
              primaryContentMarkers.allSatisfy(isAllowedContentMarker) else {
            return .disabled("该消息类型不可转发")
        }

        guard isVoice(message) else {
            return .selectable
        }
        guard message.senderProvenance == .authoritativeStored,
              let senderUID = message.senderUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !senderUID.isEmpty,
              senderUID == actorUID else {
            return .disabled(batchForwardVoiceOwnershipReason)
        }
        return .selectable
    }
}

struct BatchForwardTargetRequest: Equatable, Codable, Sendable {
    let channelID: String
    let channelType: String

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
    }
}

struct BatchForwardRequest: Equatable, Codable, Sendable {
    let clientBatchID: String
    let sourceChannelID: String
    let sourceChannelType: String
    let sourceMessageIDs: [String]
    let targets: [BatchForwardTargetRequest]
    let mode: BatchForwardMode

    private enum CodingKeys: String, CodingKey {
        case clientBatchID = "client_batch_id"
        case sourceChannelID = "source_channel_id"
        case sourceChannelType = "source_channel_type"
        case sourceMessageIDs = "source_message_ids"
        case targets
        case mode
    }
}

struct BatchForwardSubmitCommand: Equatable, Sendable {
    let request: BatchForwardRequest
    let headers: [String: String]
}

struct BatchForwardCreatedMessage: Equatable, Codable, Sendable {
    let sourceOrdinal: Int
    let sourceMessageID: String
    let messageID: String

    private enum CodingKeys: String, CodingKey {
        case sourceOrdinal = "source_ordinal"
        case sourceMessageID = "source_message_id"
        case messageID = "message_id"
    }
}

struct BatchForwardTargetResult: Equatable, Codable, Sendable {
    let targetOrdinal: Int
    let channelID: String
    let channelType: String
    let messages: [BatchForwardCreatedMessage]

    private enum CodingKeys: String, CodingKey {
        case targetOrdinal = "target_ordinal"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case messages
    }
}

struct BatchForwardCommittedResult: Equatable, Codable, Sendable {
    let contractVersion: Int
    let batchID: String
    let clientBatchID: String
    let sourceCount: Int
    let targetCount: Int
    let createdCount: Int
    let state: String
    let idempotentReplay: Bool
    let authoritativeSourceMessageIDs: [String]
    let targets: [BatchForwardTargetResult]

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case batchID = "batch_id"
        case clientBatchID = "client_batch_id"
        case sourceCount = "source_count"
        case targetCount = "target_count"
        case createdCount = "created_count"
        case state
        case idempotentReplay = "idempotent_replay"
        case authoritativeSourceMessageIDs = "authoritative_source_message_ids"
        case targets
    }

    var serverCreatedMessageIDs: [String] {
        targets.flatMap(\.messages).map(\.messageID)
    }
}

enum BatchForwardSubmissionPhase: Equatable, Sendable {
    case idle
    case submitting(clientBatchID: String)
    case retryableFailure(String?)
    case uncertain(String?)
    case committed(batchID: String)
}

enum BatchForwardSelectionResult: Equatable, Sendable {
    case selected
    case removed
    case rejected(String)
}

enum BatchForwardBeginResult: Equatable, Sendable {
    case ready(BatchForwardSubmitCommand)
    case ignoredInFlight
    case invalid(String)
}

enum BatchForwardApplyResult: Equatable, Sendable {
    case applied
    case rejected(String)
}

struct BatchForwardState: Equatable, Sendable {
    private(set) var scope: BatchForwardScope
    private(set) var sourcesByID: [String: BatchForwardMessageSnapshot] = [:]
    private(set) var selectedSourceIDsInClickOrder: [String] = []
    private(set) var focusedSourceID: String?
    private(set) var targetsByIdentity: [String: BatchForwardTarget] = [:]
    private(set) var selectedTargetIdentityKeysInOrder: [String] = []
    private(set) var activeTargetTab: BatchForwardTargetTab = .friend
    private(set) var targetSearchQuery = ""
    private(set) var expandedTargetTabs: Set<BatchForwardTargetTab> = []
    private(set) var clientBatchID: String?
    private(set) var boundIntentSignature: String?
    private(set) var submissionPhase: BatchForwardSubmissionPhase = .idle
    private(set) var lastCommittedResult: BatchForwardCommittedResult?

    init(scope: BatchForwardScope) {
        self.scope = scope
    }

    var selectedSourceIDSet: Set<String> {
        Set(selectedSourceIDsInClickOrder)
    }

    var selectedTargets: [BatchForwardTarget] {
        selectedTargetIdentityKeysInOrder.compactMap { targetsByIdentity[$0] }
    }

    var reconciledServerMessageIDs: [String] {
        lastCommittedResult?.serverCreatedMessageIDs ?? []
    }

    mutating func replaceScope(_ newScope: BatchForwardScope) {
        guard newScope != scope else {
            return
        }
        scope = newScope
        sourcesByID = [:]
        targetsByIdentity = [:]
        cancel()
    }

    mutating func ingestSourcePage(_ messages: [BatchForwardMessageSnapshot]) {
        for message in messages {
            sourcesByID[message.messageID] = message
        }
    }

    mutating func ingestTargets(_ targets: [BatchForwardTarget]) {
        for target in targets where target.tab != nil {
            let canonical = BatchForwardTarget(
                channelID: target.canonicalChannelID(actorUID: scope.actorUID),
                channelType: BatchForwardSemantics.canonicalChannelType(target.channelType),
                displayName: target.displayName,
                searchTerms: target.searchTerms
            )
            targetsByIdentity[canonical.identityKey(actorUID: scope.actorUID)] = canonical
        }
    }

    mutating func toggleSource(_ messageID: String) -> BatchForwardSelectionResult {
        guard !isSubmitting else {
            return .rejected("批量转发正在提交")
        }
        if let index = selectedSourceIDsInClickOrder.firstIndex(of: messageID) {
            selectedSourceIDsInClickOrder.remove(at: index)
            if focusedSourceID == messageID {
                focusedSourceID = selectedSourceIDsInClickOrder.last
            }
            return .removed
        }
        guard let message = sourcesByID[messageID] else {
            return .rejected("消息不存在或尚未加载")
        }
        guard message.sourceChannelID == scope.sourceChannelID,
              BatchForwardSemantics.canonicalChannelType(message.sourceChannelType)
                == BatchForwardSemantics.canonicalChannelType(scope.sourceChannelType) else {
            return .rejected("消息不属于当前来源会话")
        }
        switch BatchForwardSemantics.eligibility(of: message, actorUID: scope.actorUID) {
        case .selectable:
            selectedSourceIDsInClickOrder.append(messageID)
            focusedSourceID = messageID
            return .selected
        case let .disabled(reason):
            return .rejected(reason)
        }
    }

    mutating func focusSource(_ messageID: String?) {
        guard !isSubmitting else {
            return
        }
        if let messageID, selectedSourceIDSet.contains(messageID) {
            focusedSourceID = messageID
        } else if messageID == nil {
            focusedSourceID = nil
        }
    }

    mutating func toggleTarget(_ identityKey: String) -> BatchForwardSelectionResult {
        guard !isSubmitting else {
            return .rejected("批量转发正在提交")
        }
        if let index = selectedTargetIdentityKeysInOrder.firstIndex(of: identityKey) {
            selectedTargetIdentityKeysInOrder.remove(at: index)
            return .removed
        }
        guard let target = targetsByIdentity[identityKey], target.tab != nil else {
            return .rejected("目标会话不存在或类型不受支持")
        }
        selectedTargetIdentityKeysInOrder.append(identityKey)
        return .selected
    }

    mutating func setActiveTargetTab(_ tab: BatchForwardTargetTab) {
        activeTargetTab = tab
    }

    mutating func setTargetSearchQuery(_ query: String) {
        targetSearchQuery = query
    }

    mutating func setTargetTabExpanded(_ tab: BatchForwardTargetTab, expanded: Bool) {
        if expanded {
            expandedTargetTabs.insert(tab)
        } else {
            expandedTargetTabs.remove(tab)
        }
    }

    func visibleTargets(
        candidates: [BatchForwardTarget],
        initialLimit: Int = 20
    ) -> [BatchForwardTarget] {
        let query = BatchForwardSemantics.normalized(targetSearchQuery)
        let filtered = candidates.filter { target in
            guard target.tab == activeTargetTab else {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            let haystack = ([target.channelID, target.displayName] + target.searchTerms)
                .map(BatchForwardSemantics.normalized)
            return haystack.contains { $0.contains(query) }
        }
        if expandedTargetTabs.contains(activeTargetTab) {
            return filtered
        }
        return Array(filtered.prefix(max(0, initialLimit)))
    }

    mutating func beginSubmission(
        makeClientBatchID: () -> String
    ) -> BatchForwardBeginResult {
        guard !isSubmitting else {
            return .ignoredInFlight
        }
        switch validatedDraft() {
        case let .failure(reason):
            return .invalid(reason)
        case let .success(draft):
            let signature = intentSignature(sourceIDs: draft.sourceIDs, targets: draft.targets)
            let nextClientBatchID: String
            if boundIntentSignature == signature,
               let existing = clientBatchID,
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextClientBatchID = existing
            } else {
                guard let generated = Self.canonicalRFC4122UUID(makeClientBatchID()) else {
                    return .invalid("client_batch_id 必须是 RFC4122 UUID")
                }
                nextClientBatchID = generated
                clientBatchID = generated
                boundIntentSignature = signature
            }
            let request = BatchForwardRequest(
                clientBatchID: nextClientBatchID,
                sourceChannelID: scope.sourceChannelID,
                sourceChannelType: BatchForwardSemantics.canonicalChannelType(
                    scope.sourceChannelType
                ),
                sourceMessageIDs: draft.sourceIDs,
                targets: draft.targets.map {
                    BatchForwardTargetRequest(
                        channelID: $0.channelID,
                        channelType: BatchForwardSemantics.canonicalChannelType($0.channelType)
                    )
                },
                mode: .separate
            )
            submissionPhase = .submitting(clientBatchID: nextClientBatchID)
            return .ready(
                BatchForwardSubmitCommand(
                    request: request,
                    headers: ["Idempotency-Key": nextClientBatchID]
                )
            )
        }
    }

    mutating func markRetryableFailure(_ message: String? = nil) {
        guard isSubmitting else {
            return
        }
        submissionPhase = .retryableFailure(message)
    }

    mutating func markUncertain(_ message: String? = nil) {
        guard isSubmitting || isRetryable else {
            return
        }
        submissionPhase = .uncertain(message)
    }

    mutating func applyCommittedResult(
        _ result: BatchForwardCommittedResult
    ) -> BatchForwardApplyResult {
        guard let expectedClientBatchID = clientBatchID else {
            return rejectCommitted("缺少当前 client_batch_id")
        }
        switch validatedDraft() {
        case let .failure(reason):
            return rejectCommitted(reason)
        case let .success(draft):
            guard result.contractVersion == 1 else {
                return rejectCommitted("响应 contract_version 无效")
            }
            guard BatchForwardSemantics.normalized(result.state) == "committed",
                  !result.batchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return rejectCommitted("响应未完整提交")
            }
            guard let responseClientBatchID = Self.canonicalRFC4122UUID(result.clientBatchID),
                  responseClientBatchID == expectedClientBatchID else {
                return rejectCommitted("响应 client_batch_id 不匹配")
            }
            guard result.sourceCount == draft.sourceIDs.count,
                  result.targetCount == draft.targets.count,
                  result.createdCount == draft.sourceIDs.count * draft.targets.count else {
                return rejectCommitted("响应计数不匹配")
            }
            guard result.authoritativeSourceMessageIDs.count == draft.sourceIDs.count,
                  Set(result.authoritativeSourceMessageIDs).count
                    == result.authoritativeSourceMessageIDs.count,
                  Set(result.authoritativeSourceMessageIDs) == Set(draft.sourceIDs) else {
                return rejectCommitted("authoritative_source_message_ids 不完整")
            }
            guard result.targets.count == draft.targets.count else {
                return rejectCommitted("目标映射数量不匹配")
            }

            var createdIDs = Set<String>()
            for targetOrdinal in draft.targets.indices {
                let expectedTarget = draft.targets[targetOrdinal]
                let actualTarget = result.targets[targetOrdinal]
                guard actualTarget.targetOrdinal == targetOrdinal,
                      BatchForwardSemantics.canonicalChannelID(
                        actualTarget.channelID,
                        channelType: actualTarget.channelType,
                        actorUID: scope.actorUID
                      ) == expectedTarget.channelID,
                      BatchForwardSemantics.canonicalChannelType(actualTarget.channelType)
                        == BatchForwardSemantics.canonicalChannelType(expectedTarget.channelType) else {
                    return rejectCommitted("目标映射顺序不匹配")
                }
                guard actualTarget.messages.count
                        == result.authoritativeSourceMessageIDs.count else {
                    return rejectCommitted("source_ordinal 映射数量不匹配")
                }
                for sourceOrdinal in result.authoritativeSourceMessageIDs.indices {
                    let mapping = actualTarget.messages[sourceOrdinal]
                    guard mapping.sourceOrdinal == sourceOrdinal,
                          mapping.sourceMessageID
                            == result.authoritativeSourceMessageIDs[sourceOrdinal] else {
                        return rejectCommitted("source_ordinal 必须从零连续递增")
                    }
                    let createdID = mapping.messageID
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !createdID.isEmpty, createdIDs.insert(createdID).inserted else {
                        return rejectCommitted("服务端消息映射包含空值或重复值")
                    }
                }
            }

            lastCommittedResult = canonicalCommittedResult(
                result,
                clientBatchID: responseClientBatchID
            )
            submissionPhase = .committed(batchID: result.batchID)
            clearDraftAfterCommit()
            return .applied
        }
    }

    mutating func cancel() {
        selectedSourceIDsInClickOrder = []
        focusedSourceID = nil
        selectedTargetIdentityKeysInOrder = []
        clientBatchID = nil
        boundIntentSignature = nil
        submissionPhase = .idle
        lastCommittedResult = nil
    }

    private var isSubmitting: Bool {
        if case .submitting = submissionPhase {
            return true
        }
        return false
    }

    private var isRetryable: Bool {
        if case .retryableFailure = submissionPhase {
            return true
        }
        return false
    }

    private struct ValidatedDraft {
        let sourceIDs: [String]
        let targets: [BatchForwardTarget]
    }

    private enum DraftValidation {
        case success(ValidatedDraft)
        case failure(String)
    }

    private func validatedDraft() -> DraftValidation {
        guard !scope.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scope.actorUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scope.sourceChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("批量转发作用域不完整")
        }
        let canonicalSourceType = BatchForwardSemantics.canonicalChannelType(
            scope.sourceChannelType
        )
        guard canonicalSourceType == "direct" || canonicalSourceType == "group" else {
            return .failure("来源会话类型不受支持")
        }
        let sourceIDs = selectedSourceIDSet
            .compactMap { sourcesByID[$0] }
            .sorted(by: authoritativeSourcePrecedes)
            .map(\.messageID)
        guard (1...50).contains(sourceIDs.count) else {
            return .failure("请选择 1–50 条消息")
        }
        let targets = selectedTargets
        guard (1...20).contains(targets.count) else {
            return .failure("请选择 1–20 个目标")
        }
        guard sourceIDs.count * targets.count <= 200 else {
            return .failure("单次批量转发最多创建 200 条消息")
        }
        for sourceID in sourceIDs {
            guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("source_message_id 不能为空")
            }
            guard let message = sourcesByID[sourceID] else {
                return .failure("所选消息不存在或尚未加载")
            }
            guard message.sourceChannelID == scope.sourceChannelID,
                  BatchForwardSemantics.canonicalChannelType(message.sourceChannelType)
                    == BatchForwardSemantics.canonicalChannelType(scope.sourceChannelType) else {
                return .failure("所选消息不属于当前来源会话")
            }
            if case let .disabled(reason) = BatchForwardSemantics.eligibility(
                of: message,
                actorUID: scope.actorUID
            ) {
                return .failure(reason)
            }
        }
        guard targets.allSatisfy({
            !$0.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.tab != nil
        }) else {
            return .failure("目标会话类型不受支持")
        }
        return .success(ValidatedDraft(sourceIDs: sourceIDs, targets: targets))
    }

    private func authoritativeSourcePrecedes(
        _ lhs: BatchForwardMessageSnapshot,
        _ rhs: BatchForwardMessageSnapshot
    ) -> Bool {
        switch (lhs.channelSeq, rhs.channelSeq) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.messageID < rhs.messageID
        }
    }

    private func intentSignature(
        sourceIDs: [String],
        targets: [BatchForwardTarget]
    ) -> String {
        func field(_ value: String) -> String {
            "\(value.utf8.count):\(value)"
        }
        let pieces = [
            scope.tenantID,
            scope.actorUID,
            scope.sourceChannelID,
            BatchForwardSemantics.canonicalChannelType(scope.sourceChannelType),
            BatchForwardMode.separate.rawValue,
        ] + sourceIDs + targets.flatMap {
            [$0.channelID, BatchForwardSemantics.canonicalChannelType($0.channelType)]
        }
        return pieces.map(field).joined(separator: "|")
    }

    private mutating func rejectCommitted(_ reason: String) -> BatchForwardApplyResult {
        submissionPhase = .uncertain(reason)
        return .rejected(reason)
    }

    private mutating func clearDraftAfterCommit() {
        selectedSourceIDsInClickOrder = []
        focusedSourceID = nil
        selectedTargetIdentityKeysInOrder = []
        clientBatchID = nil
        boundIntentSignature = nil
    }

    private func canonicalCommittedResult(
        _ result: BatchForwardCommittedResult,
        clientBatchID: String
    ) -> BatchForwardCommittedResult {
        BatchForwardCommittedResult(
            contractVersion: result.contractVersion,
            batchID: result.batchID,
            clientBatchID: clientBatchID,
            sourceCount: result.sourceCount,
            targetCount: result.targetCount,
            createdCount: result.createdCount,
            state: result.state,
            idempotentReplay: result.idempotentReplay,
            authoritativeSourceMessageIDs: result.authoritativeSourceMessageIDs,
            targets: result.targets.map { target in
                BatchForwardTargetResult(
                    targetOrdinal: target.targetOrdinal,
                    channelID: BatchForwardSemantics.canonicalChannelID(
                        target.channelID,
                        channelType: target.channelType,
                        actorUID: scope.actorUID
                    ),
                    channelType: BatchForwardSemantics.canonicalChannelType(
                        target.channelType
                    ),
                    messages: target.messages
                )
            }
        )
    }

    private static func canonicalRFC4122UUID(_ value: String) -> String? {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let characters = Array(canonical)
        guard characters.count == 36,
              characters[8] == "-",
              characters[13] == "-",
              characters[18] == "-",
              characters[23] == "-" else {
            return nil
        }
        let hyphenIndexes: Set<Int> = [8, 13, 18, 23]
        let hexadecimal = Set("0123456789abcdef")
        guard characters.indices.allSatisfy({
            hyphenIndexes.contains($0) || hexadecimal.contains(characters[$0])
        }) else {
            return nil
        }
        guard "12345678".contains(characters[14]),
              "89ab".contains(characters[19]) else {
            return nil
        }
        guard UUID(uuidString: canonical) != nil else {
            return nil
        }
        return canonical
    }
}
