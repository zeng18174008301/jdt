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

extension AppState {
    func reconcileLocalMessageScope(from previous: IMAPIContext, to current: IMAPIContext) {
        let previousHash = try? LocalMessageScope(context: previous).scopeHash
        let currentHash = try? LocalMessageScope(context: current).scopeHash
        let sessionAuthorityChanged = previous.sessionEpoch != current.sessionEpoch
            || previous.tenantAuthSession?.sessionID != current.tenantAuthSession?.sessionID
            || previous.platformAuthSession?.sessionID != current.platformAuthSession?.sessionID
        guard previousHash != currentHash || sessionAuthorityChanged else { return }
        let preservesReauthenticatedScope = previousHash != nil && previousHash == currentHash
            && sessionReauthenticationCommit?.old == previous.authSessionFence
            && sessionReauthenticationCommit?.new == current.authSessionFence
        // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
        conversationStore.bindMessageScope(
            try? LocalMessageScope(context: current), preservesMessages: preservesReauthenticatedScope
        )
        // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
        conversationSelectionEpochFence.invalidate()
        let retiredGeneration = localMessageSessionGeneration
        if !preservesReauthenticatedScope { localMessageSessionGeneration &+= 1 }
        // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_BEGIN
        if let previousHash, !preservesReauthenticatedScope {
            let mediaRegistry = messagePersistence.scopeRetirementMediaRegistry
            do {
                _ = try messagePersistence.schedulePurgeExactScope(
                    context: previous,
                    through: retiredGeneration,
                    beforePurge: {
                        _ = await mediaRegistry.invalidate(
                            scopeHash: previousHash,
                            through: retiredGeneration
                        )
                    }
                )
            } catch {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("本机数据安全清理失败，已阻止旧作用域缓存访问")
            }
        }
        // WDT_IOS1_REGISTRATION_SCOPE_RETIREMENT_20261112_END
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = nil
        durableReadAckRecoveryTask?.cancel()
        durableReadAckRecoveryGeneration &+= 1
        durableReadAckRecoveryTask = nil
        durableReadAckRecoveryRestartRequested = false
        localMessageTicket = nil
        if !preservesReauthenticatedScope { localMessageProjectionRevision = 0 }
        profileContactRealtimeRefreshTask?.cancel()
        profileContactRealtimeRefreshTask = nil
        profileContactRevisionFence.rebind(scopeHash: "")
        if current.hasIMSession {
            profileContactRevisionFence.rebind(scopeHash: remoteDataScopeKey(for: current))
        }
    }

    func nextLocalMessageProjectionRevision() -> Int64 {
        localMessageProjectionRevision &+= 1
        return localMessageProjectionRevision
    }

    private func localMessageSnapshots(
        from source: [ConversationMessageSnapshot],
        requiresServerRevalidation: Bool = false
    ) -> [LocalMessageConversationSnapshot] {
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：快照批量投影委托给 Core/AppSupport builder，AppState 只提供上下文
        let lookup = makeConversationUserLookup()
        let inputs = source.map { conversation in
            localMessageProjectionInput(from: conversation, lookup: lookup)
        }
        return LocalMessageProjectionBuilder.snapshots(
            from: inputs,
            actorID: actorID,
            requiresServerRevalidation: requiresServerRevalidation
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    func localMessageSnapshot(
        from conversation: ConversationMessageSnapshot,
        actorID: String,
        projectedMessages: [ChatMessage]? = nil,
        requiresServerRevalidation: Bool = false
    ) -> LocalMessageConversationSnapshot {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：单会话快照构建委托给 Core/AppSupport builder
        LocalMessageProjectionBuilder.snapshot(
            from: localMessageProjectionInput(
                from: conversation,
                projectedMessages: projectedMessages
            ),
            actorID: actorID,
            requiresServerRevalidation: requiresServerRevalidation
        )
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：AppState 只负责解析原有 channel 上下文，实际投影在 support builder
    func localMessageProjectionInput(
        from conversation: ConversationMessageSnapshot,
        projectedMessages: [ChatMessage]? = nil,
        lookup: ConversationUserLookup? = nil
    ) -> LocalMessageProjectionInput {
        LocalMessageProjectionInput(
            conversation: conversation,
            channelID: remoteChannelID(for: conversation, lookup: lookup),
            channelType: apiChannelType(for: conversation.kind),
            projectedMessages: projectedMessages
        )
    }
    // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束

    private func persistentProjectionMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：消息持久化清洗逻辑从 AppState 拆出
        LocalMessageProjectionBuilder.persistentProjectionMessages(messages)
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    private func localMutationProjectionMessages(from conversation: ConversationMessageSnapshot) -> [ChatMessage] {
        // JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：本地变更 tail-window 选择从 AppState 拆出
        LocalMessageProjectionBuilder.localMutationProjectionMessages(from: conversation)
        // JHT_MOD_END APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改结束
    }

    private func localMutationSnapshot(for conversation: ConversationMessageSnapshot) -> LocalMessageConversationSnapshot {
        let actorID = (apiContext.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return localMessageSnapshot(
            from: conversation,
            actorID: actorID,
            projectedMessages: localMutationProjectionMessages(from: conversation)
        )
    }

    private func localMutationSnapshot(
        conversationID: String,
        scope: String
    ) -> LocalMessageConversationSnapshot? {
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        return localMutationSnapshot(for: cacheableConversation)
    }

    private func localMutationSnapshotsForAllVisibleConversations(scope: String) -> [LocalMessageConversationSnapshot] {
        guard isCurrentRemoteScope(scope) else { return [] }
        let cacheableConversations = shouldShowGroupMemberCount
            ? conversationStore.conversationMessageSnapshots()
            : conversationStore.conversationMessageSnapshots().map { $0.scrubbingGroupMemberTotals() }
        return cacheableConversations.map(localMutationSnapshot(for:))
    }

    // JHT_MOD_BEGIN APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改开始：序号计算委托给 helper，避免消息数组 map/max 临时分配
    func latestKnownSequence(for conversation: ConversationMessageSnapshot) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: conversation)
    }

    func latestKnownSequence(for remote: RemoteConversation) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: remote)
    }

    func latestKnownSequence(for remoteMessages: [RemoteMessage]) -> Int64 {
        ConversationSequenceInspector.latestKnownSequence(for: remoteMessages)
    }
    // JHT_MOD_END APPSTATE_CONVERSATION_SEQUENCE_HELPER_PERF_20260913 - 修改结束

    func locallyHiddenRecord(
        channelID: String,
        channelType: String,
        records: [String: LocalHiddenConversationRecord],
        lookup: ConversationUserLookup? = nil
    ) -> LocalHiddenConversationRecord? {
        let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType, lookup: lookup)
        let normalizedType = LocalHiddenConversationRecord.normalizedChannelType(channelType)
        let key = LocalHiddenConversationRecord.recordKey(
            channelID: normalizedID,
            channelType: normalizedType
        )
        if let record = records[key] {
            return record
        }
        return records.values.first { record in
            record.channelType == normalizedType
                && normalizedRemoteChannelID(record.channelID, channelType: record.channelType, lookup: lookup) == normalizedID
        }
    }

    func locallyHiddenRecord(
        matching conversation: ConversationMessageSnapshot,
        records: [String: LocalHiddenConversationRecord],
        lookup: ConversationUserLookup? = nil
    ) -> LocalHiddenConversationRecord? {
        let channelType = apiChannelType(for: conversation.kind)
        if let record = locallyHiddenRecord(
            channelID: remoteChannelID(for: conversation, lookup: lookup),
            channelType: channelType,
            records: records,
            lookup: lookup
        ) {
            return record
        }
        let conversationID = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationID.isEmpty else { return nil }
        return records.values.first { $0.conversationID == conversationID }
    }

    func removeLocalHiddenRecord(
        _ record: LocalHiddenConversationRecord,
        from records: inout [String: LocalHiddenConversationRecord]
    ) {
        records = records.filter { element in
            let key = element.key
            let value = element.value
            return key != record.key
                && !(value.channelID == record.channelID && value.channelType == record.channelType)
                && (record.conversationID.isEmpty || value.conversationID != record.conversationID)
        }
    }

    func visibleConversationsAfterLocalHiding(
        _ sourceConversations: [ConversationMessageSnapshot],
        scope: String,
        lookup: ConversationUserLookup? = nil
    ) -> [ConversationMessageSnapshot] {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sourceConversations
        }
        var records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return sourceConversations }
        var didUpdateRecords = false
        let visible = sourceConversations.filter { conversation in
            guard let record = locallyHiddenRecord(matching: conversation, records: records, lookup: lookup) else {
                return true
            }
            let latestSeq = latestKnownSequence(for: conversation)
            if latestSeq > record.hiddenThroughSeq, latestSeq > 0 {
                removeLocalHiddenRecord(record, from: &records)
                didUpdateRecords = true
                return true
            }
            return false
        }
        if didUpdateRecords {
            LocalHiddenConversationStore.save(records, scope: scope)
        }
        return visible
    }

    func visibleRemoteConversationsAfterLocalHiding(
        _ remoteConversations: [RemoteConversation],
        scope: String,
        lookup: ConversationUserLookup? = nil
    ) -> [RemoteConversation] {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return remoteConversations
        }
        var records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return remoteConversations }
        var didUpdateRecords = false
        let visible = remoteConversations.filter { remote in
            let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
            guard let record = locallyHiddenRecord(
                channelID: channelID,
                channelType: remote.channelType,
                records: records,
                lookup: lookup
            ) else {
                return true
            }
            let latestSeq = latestKnownSequence(for: remote)
            if latestSeq > record.hiddenThroughSeq, latestSeq > 0 {
                removeLocalHiddenRecord(record, from: &records)
                didUpdateRecords = true
                return true
            }
            return false
        }
        if didUpdateRecords {
            LocalHiddenConversationStore.save(records, scope: scope)
        }
        return visible
    }

    func isGroupConversationLocallyHidden(groupID: String) -> Bool {
        guard apiContext.hasIMSession else { return false }
        let scope = remoteDataScopeKey(for: apiContext)
        let records = LocalHiddenConversationStore.load(scope: scope)
        guard !records.isEmpty else { return false }
        return locallyHiddenRecord(channelID: groupID, channelType: "group", records: records) != nil
    }

    func hideConversationLocally(_ conversation: ConversationMessageSnapshot, scope: String) {
        let channelType = apiChannelType(for: conversation.kind)
        let channelID = remoteChannelID(for: conversation)
        guard !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LocalHiddenConversationStore.hide(
            LocalHiddenConversationRecord(
                conversationID: conversation.id,
                channelID: channelID,
                channelType: channelType,
                hiddenThroughSeq: latestKnownSequence(for: conversation)
            ),
            scope: scope
        )
    }

    func clearLocalHiddenConversation(channelID: String, channelType: String, scope: String) {
        let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType)
        guard !normalizedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LocalHiddenConversationStore.remove(
            channelID: normalizedID,
            channelType: channelType,
            scope: scope
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
