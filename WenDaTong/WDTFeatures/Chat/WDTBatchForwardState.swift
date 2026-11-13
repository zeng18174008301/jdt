import IM4Domain
import Foundation

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
