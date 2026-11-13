import IM4Domain
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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

// WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
@MainActor
final class BatchForwardPresentationStore {
    struct Draft: Equatable {
        let sourceConversationID: String
        let state: BatchForwardState
        let selectedSourceIDs: Set<String>

        init(sourceConversationID: String, state: BatchForwardState) {
            self.sourceConversationID = sourceConversationID
            self.state = state
            selectedSourceIDs = state.selectedSourceIDSet
        }
    }

    struct SourceSelection: Equatable {
        let conversationID: String
        let ids: Set<String>
    }

    @Published private(set) var draft: Draft?

    func begin(_ state: BatchForwardState, sourceConversationID: String) {
        draft = Draft(sourceConversationID: sourceConversationID, state: state)
    }

    func update(_ state: BatchForwardState) {
        guard let draft else { return }
        self.draft = Draft(sourceConversationID: draft.sourceConversationID, state: state)
    }

    func clear() {
        if draft != nil { draft = nil }
    }

    func draft(for conversationID: String) -> Draft? {
        Self.draft(draft, matching: conversationID)
    }

    func draftUpdates(for conversationID: String) -> AnyPublisher<Draft?, Never> {
        $draft.map { Self.draft($0, matching: conversationID) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func selectionUpdates(for conversationID: String) -> AnyPublisher<SourceSelection, Never> {
        $draft.map {
            SourceSelection(conversationID: conversationID, ids: Self.draft($0, matching: conversationID)?.selectedSourceIDs ?? [])
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private static func draft(_ draft: Draft?, matching conversationID: String) -> Draft? {
        draft?.sourceConversationID == conversationID ? draft : nil
    }
}
// WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END

extension AppState {
    func batchForwardEligibility(
        for message: ChatMessage,
        in conversationID: String,
        policy: MessageActionsPolicy? = nil // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    ) -> BatchForwardEligibility {
        if let reason = messageActionPolicyUnavailableReason(.forward, policy: policy) { return .disabled(reason) } // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              let snapshot = batchForwardSnapshot(message, in: conversation) else {
            return .disabled("消息不存在或尚未加载")
        }
        return BatchForwardSemantics.eligibility(
            of: snapshot,
            actorUID: batchForwardActorUID()
        )
    }

    func beginBatchForward(
        conversationID: String,
        initialMessageID: String
    ) {
        guard !batchForwardActorUID().isEmpty else {
            setToast("登录会话不可用，请重新登录")
            return
        }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversation.kind == .direct || conversation.kind == .group else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前会话不支持批量转发")
            return
        }
        guard let scope = batchForwardScope(for: conversation) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        if let reason = messageActionPolicyUnavailableReason(.forward) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        var next: BatchForwardState
        if let current = batchForwardState,
           current.scope == scope,
           batchForwardSourceConversationID == conversationID {
            next = current
        } else {
            next = BatchForwardState(scope: scope)
        }
        next.ingestSourcePage(
            conversation.messages.compactMap { batchForwardSnapshot($0, in: conversation) }
        )
        next.ingestTargets(batchForwardTargetCandidates().map(\.target))
        switch next.toggleSource(initialMessageID) {
        case .selected, .removed:
            batchForwardStore.begin(next, sourceConversationID: conversationID) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
        case .rejected(let reason):
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
        }
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_BEGIN
    func refreshBatchForwardContext(conversationID: String, conversations snapshot: [ConversationMessageSnapshot]? = nil) {
        let sourceConversations = snapshot ?? conversationStore.conversationMessageSnapshots()
        if let sourceConversationID = batchForwardSourceConversationID,
           sourceConversationID != conversationID {
            resetBatchForwardDraftForScopeChange()
            return
        }
        guard batchForwardSourceConversationID == conversationID,
              let conversation = sourceConversations.first(where: { $0.id == conversationID }),
              var next = batchForwardState else {
            return
        }
        next.ingestSourcePage(
            conversation.messages.compactMap { batchForwardSnapshot($0, in: conversation) }
        )
        next.ingestTargets(batchForwardTargetCandidates(from: sourceConversations).map(\.target))
        if next != batchForwardState { batchForwardStore.update(next) } // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_END

    // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_BEGIN
    func refreshBatchForwardSource(conversationID: String, source: ConversationMessageSnapshot?) {
        guard batchForwardSourceConversationID == conversationID,
              let source, source.id == conversationID,
              var next = batchForwardState else { return }
        guard let scope = batchForwardScope(for: source), scope == next.scope else {
            resetBatchForwardDraftForScopeChange()
            return
        }
        // Ingest the real scoped window; keep selected sources from older pages.
        next.ingestSourcePage(source.messages.compactMap { batchForwardSnapshot($0, in: source) })
        if next != batchForwardState { batchForwardStore.update(next) }
    }

    func refreshBatchForwardTargets(conversationID: String, conversations: [Conversation]) {
        guard batchForwardSourceConversationID == conversationID,
              var next = batchForwardState else { return }
        // These empty operation values are target metadata only, never source pages.
        let targets = conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) }
        next.ingestTargets(batchForwardTargetCandidates(from: targets).map(\.target))
        if next != batchForwardState { batchForwardStore.update(next) }
    }
    // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_END

    func leaveBatchForwardSourceConversation(_ conversationID: String) {
        guard batchForwardSourceConversationID == conversationID else {
            return
        }
        resetBatchForwardDraftForScopeChange()
    }

    func toggleBatchForwardSource(
        messageID: String,
        conversationID: String
    ) {
        guard messageActionPolicyUnavailableReason(.forward) == nil else { return }
        guard batchForwardSourceConversationID == conversationID,
              var next = batchForwardState else {
            return
        }
        switch next.toggleSource(messageID) {
        case .selected, .removed:
            batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
        case .rejected(let reason):
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
        }
    }

    func batchForwardTarget(for conversation: ConversationMessageSnapshot) -> BatchForwardTarget? {
        guard conversation.kind == .direct || conversation.kind == .group else {
            return nil
        }
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else {
            return nil
        }
        let participantTerms = conversation.participants.flatMap {
            [$0.id, $0.userID, $0.username, $0.name]
        }
        return BatchForwardTarget(
            channelID: channelID,
            channelType: apiChannelType(for: conversation.kind),
            displayName: conversation.title,
            searchTerms: [
                conversation.subtitle,
                conversation.lastMessage
            ] + participantTerms
        )
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
    func batchForwardTargetCandidates(
        from targetConversations: [ConversationMessageSnapshot]? = nil
    ) -> [BatchForwardTargetCandidate] {
        // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
        var ordered: [BatchForwardTargetCandidate] = []
        var indexByIdentity: [String: Int] = [:]

        func append(_ candidate: BatchForwardTargetCandidate?) {
            guard let candidate else { return }
            if let index = indexByIdentity[candidate.identityKey] {
                ordered[index] = candidate
            } else {
                indexByIdentity[candidate.identityKey] = ordered.count
                ordered.append(candidate)
            }
        }

        // Preserve conversation order for recent/frequent ranking, then enrich
        // and complete the same canonical identities from the full friend/group
        // stores. The source conversation remains a valid target.
        (targetConversations ?? conversationStore.conversationMessageSnapshots()).forEach { append(batchForwardTargetCandidate(for: $0)) } // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110
        contacts.forEach { append(batchForwardTargetCandidate(for: $0)) }
        groups.forEach { append(batchForwardTargetCandidate(for: $0)) }
        return ordered
    }

    func forwardTenantFile(_ file: FileItem, to target: BatchForwardTarget) async -> Bool {
        if let reason = messageActionPolicyUnavailableReason(.forward) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return false
        }
        let fileID = file.remoteLookupID
        let actorUID = batchForwardActorUID()
        let channelID = target.canonicalChannelID(actorUID: actorUID)
        let channelType = BatchForwardSemantics.canonicalChannelType(target.channelType)
        guard !fileID.isEmpty, !channelID.isEmpty, ["direct", "group"].contains(channelType) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("文件或目标会话不可用，请刷新后重试")
            return false
        }
        guard !forwardingTenantFileIDs.contains(fileID) else { return false }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态失效，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let idempotencyScope = "\(scope)|\(fileID)|\(channelType)|\(channelID)"
        let clientMessageID = tenantFileForwardClientMessageIDs[idempotencyScope]
            ?? "ios_file_forward_\(UUID().uuidString.lowercased())"
        tenantFileForwardClientMessageIDs[idempotencyScope] = clientMessageID
        forwardingTenantFileIDs.insert(fileID)
        defer { forwardingTenantFileIDs.remove(fileID) }
        do {
            let message = try await api.forwardTenantFile(
                context: context,
                fileID: fileID,
                targetChannelID: channelID,
                targetChannelType: channelType,
                clientMessageID: clientMessageID
            )
            guard isCurrentRemoteScope(scope) else { return false }
            applyRemoteMessages(
                [message],
                channelID: message.channelID.isEmpty ? channelID : message.channelID,
                channelType: message.channelType.isEmpty ? channelType : message.channelType
            )
            tenantFileForwardClientMessageIDs.removeValue(forKey: idempotencyScope)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("文件已转发至 \(target.displayName)")
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "文件转发失败，请重试")
            return false
        }
    }

    func batchForwardVisibleTargetCandidates(
        from candidates: [BatchForwardTargetCandidate],
        initialLimit: Int = 20
    ) -> [BatchForwardTargetCandidate] {
        guard let batchForwardState else {
            return []
        }
        let visibleKeys = Set(
            batchForwardState
                .visibleTargets(
                    candidates: candidates.map(\.target),
                    initialLimit: initialLimit
                )
                .map { $0.identityKey(actorUID: batchForwardState.scope.actorUID) }
        )
        return candidates.filter { candidate in
            visibleKeys.contains(candidate.identityKey)
        }
    }

    func isBatchForwardTargetSelected(_ conversation: ConversationMessageSnapshot) -> Bool {
        guard let target = batchForwardTarget(for: conversation) else {
            return false
        }
        return isBatchForwardTargetSelected(target)
    }

    func isBatchForwardTargetSelected(_ target: BatchForwardTarget) -> Bool {
        guard let batchForwardState else { return false }
        return batchForwardState.selectedTargetIdentityKeysInOrder.contains(
            target.identityKey(actorUID: batchForwardState.scope.actorUID)
        )
    }

    func toggleBatchForwardTarget(_ conversation: ConversationMessageSnapshot) {
        guard let target = batchForwardTarget(for: conversation) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("目标会话不可用，请刷新后重试")
            return
        }
        toggleBatchForwardTarget(target)
    }

    func toggleBatchForwardTarget(_ target: BatchForwardTarget) {
        guard var next = batchForwardState else { return }
        next.ingestTargets([target])
        let identityKey = target.identityKey(actorUID: next.scope.actorUID)
        switch next.toggleTarget(identityKey) {
        case .selected, .removed:
            batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
        case .rejected(let reason):
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
        }
    }

    private func batchForwardTargetCandidate(
        for conversation: ConversationMessageSnapshot
    ) -> BatchForwardTargetCandidate? {
        guard let target = batchForwardTarget(for: conversation) else {
            return nil
        }
        let peer = conversation.kind == .direct
            ? conversation.participants.first(where: {
                !isCurrentUserIdentity($0.id)
                    && !isCurrentUserIdentity($0.userID)
                    && !isCurrentUserIdentity($0.username)
            }) ?? conversation.participants.first
            : nil
        let subtitle: String
        if conversation.kind == .group {
            let count = visibleGroupMemberCount(
                conversation.memberCount,
                conversation.participants.count
            )
            subtitle = count.map { "\($0) 人 · 群聊" } ?? "群聊"
        } else {
            let status = peer?.status.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subtitle = status.isEmpty ? "好友" : status
        }
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: subtitle,
            avatarSeed: peer?.avatarSeed ?? conversation.accentHex,
            avatarURL: peer?.displayAvatarURL ?? conversation.avatarURL,
            avatarVersion: peer?.avatarVersion ?? conversation.avatarVersion,
            avatarUpdatedAt: peer?.avatarUpdatedAt ?? conversation.avatarUpdatedAt,
            memberCount: conversation.kind == .group ? conversation.memberCount : nil
        )
    }

    private func batchForwardTargetCandidate(
        for contact: IMUser
    ) -> BatchForwardTargetCandidate? {
        guard !contact.isCancelledUser else { return nil }
        let identities = userIdentityCandidates(for: contact)
        guard !identities.isEmpty,
              identities.allSatisfy({ !isCurrentUserIdentity($0) }),
              let peerID = identities.first else {
            return nil
        }
        let displayName = remarkPreferredDisplayName(
            for: contact,
            fallback: peerID
        )
        let target = BatchForwardTarget(
            channelID: peerID,
            channelType: "direct",
            displayName: displayName,
            searchTerms: identities + [
                contact.name,
                contact.title,
                contact.department,
                contact.status
            ]
        )
        let status = contact.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = contact.department.trimmingCharacters(in: .whitespacesAndNewlines)
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: !status.isEmpty ? status : (!department.isEmpty ? department : "好友"),
            avatarSeed: contact.avatarSeed == 0 ? stableSeed(peerID) : contact.avatarSeed,
            avatarURL: contact.displayAvatarURL,
            avatarVersion: contact.avatarVersion,
            avatarUpdatedAt: contact.avatarUpdatedAt,
            memberCount: nil
        )
    }

    private func batchForwardTargetCandidate(
        for group: GroupInfo
    ) -> BatchForwardTargetCandidate? {
        let groupID = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupID.isEmpty else { return nil }
        let displayName = group.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = BatchForwardTarget(
            channelID: groupID,
            channelType: "group",
            displayName: displayName.isEmpty ? groupID : displayName,
            searchTerms: [
                group.notice,
                group.owner,
                group.ownerID
            ] + group.members.flatMap {
                [$0.id, $0.userID, $0.username, $0.name]
            }
        )
        let count = group.visibleMemberCount
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: count.map { "\($0) 人 · 群聊" } ?? "群聊",
            avatarSeed: stableSeed(groupID),
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt,
            memberCount: count
        )
    }

    private func canonicalBatchForwardTargetCandidate(
        target: BatchForwardTarget,
        subtitle: String,
        avatarSeed: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        memberCount: Int?
    ) -> BatchForwardTargetCandidate? {
        let actorUID = batchForwardState?.scope.actorUID ?? batchForwardActorUID()
        guard !actorUID.isEmpty else { return nil }
        let canonical = BatchForwardTarget(
            channelID: target.canonicalChannelID(actorUID: actorUID),
            channelType: BatchForwardSemantics.canonicalChannelType(target.channelType),
            displayName: target.displayName,
            searchTerms: target.searchTerms
        )
        let identityKey = canonical.identityKey(actorUID: actorUID)
        guard canonical.tab != nil,
              !canonical.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return BatchForwardTargetCandidate(
            identityKey: identityKey,
            target: canonical,
            subtitle: subtitle,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            memberCount: memberCount
        )
    }

    func removeBatchForwardTarget(identityKey: String) {
        guard var next = batchForwardState,
              next.selectedTargetIdentityKeysInOrder.contains(identityKey) else {
            return
        }
        _ = next.toggleTarget(identityKey)
        batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func setBatchForwardTargetTab(_ tab: BatchForwardTargetTab) {
        guard var next = batchForwardState else { return }
        next.setActiveTargetTab(tab)
        batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func setBatchForwardTargetSearchQuery(_ query: String) {
        guard var next = batchForwardState else { return }
        next.setTargetSearchQuery(query)
        batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func setBatchForwardTargetTabExpanded(
        _ tab: BatchForwardTargetTab,
        expanded: Bool
    ) {
        guard var next = batchForwardState else { return }
        next.setTargetTabExpanded(tab, expanded: expanded)
        batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func cancelBatchForward() {
        guard var next = batchForwardState else { return }
        if case .submitting = next.submissionPhase {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("批量转发正在提交")
            return
        }
        next.cancel()
        invalidateBatchForwardSubmission()
        batchForwardStore.clear() // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func submitBatchForward() {
        if let reason = messageActionPolicyUnavailableReason(.forward) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        guard var next = batchForwardState else { return }
        let begin = next.beginSubmission { UUID().uuidString }
        batchForwardStore.update(next) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
        guard case .ready(let command) = begin else {
            if case .invalid(let reason) = begin {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            }
            return
        }
        let context = apiContext
        let remoteScope = remoteDataScopeKey(for: context)
        let sourceConversationID = batchForwardSourceConversationID
        let submissionScope = next.scope
        let submittedTargets = next.selectedTargets
        invalidateBatchForwardSubmission()
        let submissionGeneration = batchForwardSubmissionGeneration
        batchForwardSubmissionTask = Task { @MainActor [weak self] in
            guard let self, let sourceConversationID else { return }
            defer {
                if self.batchForwardSubmissionGeneration == submissionGeneration {
                    self.batchForwardSubmissionTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await self.api.forwardBatch(
                    context: context,
                    command: command
                )
                try Task.checkCancellation()
                guard self.isCurrentBatchForwardSubmission(
                    generation: submissionGeneration,
                    remoteScope: remoteScope,
                    sourceConversationID: sourceConversationID,
                    submissionScope: submissionScope
                ),
                      var current = self.batchForwardState,
                      current.clientBatchID == command.request.clientBatchID else {
                    return
                }
                switch current.applyCommittedResult(result) {
                case .applied:
                    self.batchForwardStore.update(current) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    try Task.checkCancellation()
                    guard self.isCurrentBatchForwardSubmission(
                        generation: submissionGeneration,
                        remoteScope: remoteScope,
                        sourceConversationID: sourceConversationID,
                        submissionScope: submissionScope
                    ) else {
                        return
                    }
                    for target in submittedTargets {
                        guard let targetConversationID = self.batchForwardConversation(
                            matching: target
                        )?.id else {
                            continue
                        }
                        self.syncConversationMessagesIfNeeded(
                            targetConversationID,
                            force: true,
                            silent: true,
                            showLoadingIndicator: false
                        )
                    }
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("已转发 \(result.sourceCount) 条消息到 \(result.targetCount) 个会话")
                case .rejected(let reason):
                    self.batchForwardStore.update(current) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("服务端结果待确认：\(reason)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentBatchForwardSubmission(
                    generation: submissionGeneration,
                    remoteScope: remoteScope,
                    sourceConversationID: sourceConversationID,
                    submissionScope: submissionScope
                ),
                      var current = self.batchForwardState,
                      current.clientBatchID == command.request.clientBatchID else {
                    return
                }
                let message = self.userFacingError(error)
                if self.batchForwardFailureIsUncertain(error) {
                    current.markUncertain(message)
                } else {
                    current.markRetryableFailure(message)
                }
                self.batchForwardStore.update(current) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
                self.handleRemoteError(error, fallback: "批量转发失败")
            }
        }
    }

    private func isCurrentBatchForwardSubmission(
        generation: UInt64,
        remoteScope: String,
        sourceConversationID: String,
        submissionScope: BatchForwardScope
    ) -> Bool {
        !Task.isCancelled
            && batchForwardSubmissionGeneration == generation
            && isCurrentRemoteScope(remoteScope)
            && batchForwardSourceConversationID == sourceConversationID
            && batchForwardState?.scope == submissionScope
    }

    private func batchForwardScope(for conversation: ConversationMessageSnapshot) -> BatchForwardScope? {
        let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actorUID = batchForwardActorUID()
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, !actorUID.isEmpty, !channelID.isEmpty else {
            return nil
        }
        return BatchForwardScope(
            tenantID: tenantID,
            actorUID: actorUID,
            sourceChannelID: channelID,
            sourceChannelType: apiChannelType(for: conversation.kind)
        )
    }

    private func batchForwardActorUID() -> String {
        apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func batchForwardSnapshot(
        _ message: ChatMessage,
        in conversation: ConversationMessageSnapshot
    ) -> BatchForwardMessageSnapshot? {
        let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageID.isEmpty, !channelID.isEmpty else {
            return nil
        }
        let clientState: String
        if message.isDeletedLocally {
            clientState = "deleted"
        } else {
            switch message.status {
            case .sending: clientState = "sending"
            case .failed: clientState = "failed"
            case .recalled: clientState = "recalled"
            case .sent, .read: clientState = "sent"
            }
        }
        let nestedMarkers = [
            message.systemEventType,
            message.systemDisplayStyle,
            message.attachmentMeta,
            message.attachmentUploadStatus
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return BatchForwardMessageSnapshot(
            messageID: messageID,
            sourceChannelID: channelID,
            sourceChannelType: apiChannelType(for: conversation.kind),
            senderUID: message.senderId,
            senderProvenance: message.senderProvenance,
            channelSeq: message.channelSeq > 0 ? message.channelSeq : nil,
            createdAtMillis: message.createdAt.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            clientState: clientState,
            contentType: message.contentType,
            kind: message.kind.rawValue,
            mediaCategory: attachmentMediaCategory(for: message),
            previewKind: message.attachmentPreviewKind,
            nestedSemanticMarkers: nestedMarkers,
            fileName: message.attachmentName ?? "",
            mimeType: message.attachmentMimeType
        )
    }

    private func batchForwardConversation(
        matching target: BatchForwardTarget
    ) -> ConversationMessageSnapshot? {
        let actorUID = batchForwardState?.scope.actorUID ?? batchForwardActorUID()
        let identityKey = target.identityKey(actorUID: actorUID)
        return conversationStore.conversationMessageSnapshots().first {
            guard let candidate = batchForwardTarget(for: $0) else { return false }
            return candidate.identityKey(actorUID: actorUID) == identityKey
        }
    }

    func batchForwardFailureIsUncertain(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        guard let apiError = error as? IMAPIError else {
            return true
        }
        switch apiError {
        case .httpStatus(let status, _):
            return status >= 500
        case .server, .emptyResponse:
            return true
        case .missingContext, .badURL, .unauthorized, .forbidden,
             .forcedAuthRequired, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity, .rateLimited:
            return false
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
