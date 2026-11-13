import IM4Stores
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

// JHT_MOD_BEGIN APPSTATE_LOCAL_MESSAGE_PROJECTION_SPLIT_20260912 - 修改开始：本地消息快照投影从 AppState 拆到独立 support builder
struct LocalMessageProjectionInput: Sendable {
    let conversation: ConversationMessageSnapshot
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

    static func localMutationProjectionMessages(from conversation: ConversationMessageSnapshot) -> [ChatMessage] {
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

// WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: pure cached conversation history projection detached from UI/store actors.
enum CachedConversationHistoryProjection {
    static func preparedForLocalHistoryProjection(_ conversation: ConversationMessageSnapshot) -> ConversationMessageSnapshot {
        IM4Stores.CachedConversationHistoryProjection.preparedForLocalHistoryProjection(conversation, conversationListPreview: { $0.conversationListPreview })
    }
}
// WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END

// JHT_MOD_BEGIN CACHED_CONVERSATION_RESTORE_ASYNC_PERF_20260912 - 修改开始：缓存会话模型恢复从 AppState/MainActor 抽离
enum CachedConversationRestoreBuilder {
    // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: combine pure cached restore mapping in detached work.
    static func scrubbedModelsPreparedForLocalHistoryProjectionOffMain(
        from cachedConversations: [CachedConversation]
    ) async -> [ConversationMessageSnapshot] {
        await Task.detached(priority: .utility) {
            cachedConversations.map {
                CachedConversationHistoryProjection.preparedForLocalHistoryProjection(
                    $0.model.scrubbingGroupMemberTotals()
                )
            }
        }.value
    }
    // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END

    static func scrubbedModelsOffMain(
        from cachedConversations: [CachedConversation]
    ) async -> [ConversationMessageSnapshot] {
        await Task.detached(priority: .utility) {
            cachedConversations.map { $0.model.scrubbingGroupMemberTotals() }
        }.value
    }

    // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: combine pure legacy cached restore mapping in detached work.
    static func scrubbedConversationsPreparedForLocalHistoryProjectionOffMain(
        _ conversations: [ConversationMessageSnapshot]
    ) async -> [ConversationMessageSnapshot] {
        await Task.detached(priority: .utility) {
            conversations.map {
                CachedConversationHistoryProjection.preparedForLocalHistoryProjection(
                    $0.scrubbingGroupMemberTotals()
                )
            }
        }.value
    }
    // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END

    static func scrubbedConversationsOffMain(
        _ conversations: [ConversationMessageSnapshot]
    ) async -> [ConversationMessageSnapshot] {
        await Task.detached(priority: .utility) {
            conversations.map { $0.scrubbingGroupMemberTotals() }
        }.value
    }
}
// JHT_MOD_END CACHED_CONVERSATION_RESTORE_ASYNC_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN PROFILE_CONTACT_PROJECTION_ASYNC_PERF_20260912 - 修改开始：联系人/资料持久化投影从 AppState/MainActor 抽到后台 builder
enum ProfileContactProjectionBuilder {
    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_BEGIN
    static func projectionOffMain(
        revision: UInt64,
        contacts: [IMUser],
        remarks: [String: String],
        blacklist: [BlacklistItem],
        originalNames: [String: String]
    ) async -> LocalProfileContactProjection {
        await Task.detached(priority: .utility) {
            return LocalProfileContactProjection(
                revision: revision,
                contacts: contacts.map(PersistedContactUser.init),
                remarks: remarks,
                blacklist: blacklist.map(PersistedBlacklistItem.init),
                originalNames: originalNames
            )
        }.value
    }
    // WDT_IOS1_STORES_CONTACT_IDENTITY_PROJECTION_20261112_END
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
// JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束 // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
