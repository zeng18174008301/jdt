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
    func decodeRealtimeMessage(_ envelope: RealtimeEnvelope) -> RemoteMessage? {
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
        if let decoded = envelope.decodedMessage { return decoded.value }
        return RealtimeMessagePayloadDecoder.decode(envelope, using: realtimeDecoder)
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
    }

    func decodeRealtimePayload<T: Decodable>(_ type: T.Type, key: String, envelope: RealtimeEnvelope) -> T? {
        guard let value = envelope.payload[key],
              let data = try? JSONSerialization.data(withJSONObject: value.anyValue) else { return nil }
        return try? realtimeDecoder.decode(T.self, from: data)
    }

    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_BEGIN
    private func decodeRealtimeExtra(_ envelope: RealtimeEnvelope) -> RemoteMessageExtra? {
        if case let .extra(value)? = envelope.decodedSidecar?.value { return value }
        return RealtimeMessagePayloadDecoder.decodeSidecar(RemoteMessageExtra.self, key: "extra", envelope: envelope,
            using: realtimeDecoder)
    }

    func decodeRealtimeReceipt(_ envelope: RealtimeEnvelope) -> RemoteMessageReceipt? {
        if case let .receipt(value)? = envelope.decodedSidecar?.value { return value }
        return RealtimeMessagePayloadDecoder.decodeSidecar(RemoteMessageReceipt.self, key: "receipt", envelope: envelope,
            using: realtimeDecoder)
    }

    func handleRealtimeMessageExtra(_ envelope: RealtimeEnvelope) {
        guard let extra = decodeRealtimeExtra(envelope) else {
    // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111_END
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_decode_fallback")
            return
        }
        if extra.isReaction || extra.normalizedExtraType == "recall" || extra.normalizedExtraType == "edit" || extra.normalizedExtraType == "pin" || isMessageDeleteExtra(extra) || searchInvalidationEvent(from: extra) != nil {
            applyRemoteMessageExtra(extra, fromRealtime: true)
            return
        }
        scheduleRealtimeRecoveryRefresh(reason: "message_extra_unknown")
        if let activeRealtimeConversationID {
            syncConversationMessagesIfNeeded(activeRealtimeConversationID, force: true)
        }
    }

    @discardableResult
    private func applyRealtimeRecall(_ extra: RemoteMessageExtra) -> Bool {
        if let context = mediaCacheScopeContext {
            invalidateIndexedMediaCache(
                messageID: extra.messageID,
                state: .recalled,
                authorityVersion: String(max(extra.version, 0)),
                context: context
            )
        }
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        if !channelID.isEmpty {
            return conversationStore.applyRecall(
                messageID: extra.messageID,
                conversationID: channelID,
                channelIDForConversation: { conversation in
                    self.remoteChannelID(for: conversation)
                }
            )
        }
        return conversationStore.applyRecall(messageID: extra.messageID)
    }

    func applyRemoteMessageExtra(_ extra: RemoteMessageExtra, fromRealtime: Bool) {
        return conversationStore.performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let extraTenantID = extra.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTenantID = (apiContext.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard extraTenantID.isEmpty || (!currentTenantID.isEmpty && extraTenantID == currentTenantID) else { return }
            if let invalidation = searchInvalidationEvent(from: extra) {
                applySearchInvalidation(invalidation)
            }
            if extra.isReaction {
                guard conversationStore.shouldApplyReactionExtra(extra) else {
                    conversationStore.applyDedupedReactionExtraIfMissing(
                        extra,
                        currentUserIDs: currentUserIdentitySet(),
                        makeReactionDetail: reactionDetail(from:id:)
                    )
                    return
                }
                // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN
                let didApply = conversationStore.applyReactionExtra(
                    extra,
                    currentUserIDs: currentUserIdentitySet(),
                    activeConversationID: activeRealtimeConversationID,
                    includeReminder: fromRealtime && !isMessageExtraAtOrBelowEffectiveRead(extra),
                    channelIDForConversation: { remoteChannelID(for: $0) },
                    makeReactionDetail: reactionDetail(from:id:)
                )
                if fromRealtime {
                    if didApply {
                        scheduleRealtimeRecoveryRefresh(reason: "reaction_extra_applied")
                    } else {
                        refreshMessageExtraFallback(extra)
                    }
                }
                // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END
                return
            }
            if extra.normalizedExtraType == "recall" {
                let didApply = applyRealtimeRecall(extra)
                if fromRealtime, !didApply {
                    refreshMessageExtraFallback(extra)
                }
                return
            }
            if extra.normalizedExtraType == "edit" {
                let didApply = applyRemoteEditExtra(extra)
                if didApply {
                    let scope = contentCacheScopeKey
                    if !scope.isEmpty { scheduleRemoteSnapshotCacheWrite(scope: scope) }
                }
                if fromRealtime {
                    if didApply {
                        scheduleRealtimeRecoveryRefresh(reason: "edit_extra_applied")
                    } else {
                        refreshMessageExtraFallback(extra)
                    }
                }
                return
            }
            if isMessageDeleteExtra(extra) {
                if applyAdminDeletedMessage(
                    messageID: extra.messageID,
                    authorityVersion: String(max(extra.version, 0))
                ) {
                    let scope = contentCacheScopeKey
                    if !scope.isEmpty {
                        scheduleRemoteSnapshotCacheWrite(scope: scope)
                    }
                }
                return
            }
            if extra.normalizedExtraType == "pin" {
                let didApply = applyRemotePinExtra(extra)
                if fromRealtime {
                    if didApply {
                        scheduleRealtimeRecoveryRefresh(reason: "pin_extra_applied")
                    } else {
                        refreshMessageExtraFallback(extra)
                    }
                }
            }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // JHT_MOD_BEGIN MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改开始：同步分页 extras 批量处理 reaction，减少主线程反复扫描和发布
    func applySyncedRemoteMessageExtras(_ extras: [RemoteMessageExtra]) {
        guard !extras.isEmpty else { return }
        var pendingReactionExtras: [RemoteMessageExtra] = []
        pendingReactionExtras.reserveCapacity(extras.count)

        func flushPendingReactionExtras() {
            guard !pendingReactionExtras.isEmpty else { return }
            #if DEBUG
            let startedAt = CFAbsoluteTimeGetCurrent()
            #endif
            let result = conversationStore.applySyncedReactionExtras(
                pendingReactionExtras,
                currentUserIDs: currentUserIdentitySet(),
                makeReactionDetail: reactionDetail(from:id:)
            )
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMs >= 8 || result.processed > 4 {
                DebugConsoleDiagnostics.trace("[JHT Perf] message_extras_reaction_batch_apply processed=\(result.processed) changed=\(result.changed) conversations=\(result.conversationsChanged) messages=\(result.messagesChanged) skipped=\(result.skipped.count) elapsed_ms=\(elapsedMs)")
            }
            #endif
            pendingReactionExtras.removeAll(keepingCapacity: true)
        }

        for extra in extras {
            let extraTenantID = extra.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTenantID = (apiContext.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard extraTenantID.isEmpty || (!currentTenantID.isEmpty && extraTenantID == currentTenantID) else { continue }
            guard extra.isReaction else {
                flushPendingReactionExtras()
                applyRemoteMessageExtra(extra, fromRealtime: false)
                continue
            }
            if let invalidation = searchInvalidationEvent(from: extra) {
                applySearchInvalidation(invalidation)
            }
            pendingReactionExtras.append(extra)
        }
        flushPendingReactionExtras()
    }
    // JHT_MOD_END MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改结束

    private func isMessageDeleteExtra(_ extra: RemoteMessageExtra) -> Bool {
        let type = extra.normalizedExtraType
        let action = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let event = (extra.payload["event"]?.stringValue ?? extra.payload["event_type"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "delete",
            "admin_delete",
            "admin_deleted",
            "admin_delete_message",
            "message_admin_delete",
            "group_admin_delete",
            "group_admin_delete_message",
            "message_deleted",
            "tombstone"
        ].contains(type)
            || ["admin_delete", "admin_deleted", "admin_delete_message", "group_admin_delete_message", "delete_for_all", "deleted", "tombstone"].contains(action)
            || ["admin_delete", "admin_delete_message", "message_admin_delete", "group_admin_delete_message", "message_deleted"].contains(event)
    }

    @discardableResult
    private func applyRemoteEditExtra(_ extra: RemoteMessageExtra) -> Bool {
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        return conversationStore.applyRemoteEditExtra(
            extra,
            normalizedChannelID: channelID,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    @discardableResult
    private func applyRemotePinExtra(_ extra: RemoteMessageExtra) -> Bool {
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        return conversationStore.applyRemotePinExtra(
            extra,
            normalizedChannelID: channelID,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110: remote detail/read/reminder wrappers are replaced by the single event commit above; optimistic reactions keep this entry.
    @discardableResult
    func applyMessageReaction(messageID: String, emoji: String, operatorUID: String, action: String) -> Bool {
        conversationStore.applyMessageReaction(
            messageID: messageID,
            emoji: emoji,
            operatorUID: operatorUID,
            action: action,
            currentUserIDs: currentUserIdentitySet()
        )
    }

    private func refreshMessageExtraFallback(_ extra: RemoteMessageExtra) {
        let channelID = extra.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelType = extra.channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty, !channelType.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_missing_channel")
            return
        }
        guard let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else {
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_unknown_channel")
            return
        }
        Task {
            syncConversationMessagesIfNeeded(conversation.id, force: true, silent: true)
            if let session = currentMessageSidecarSyncSession() {
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: session)
            }
        }
    }

    private func isMessageExtraAtOrBelowEffectiveRead(_ extra: RemoteMessageExtra) -> Bool {
        guard extra.channelSeq > 0 else { return false }
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        let channelType = normalizedReadWatermarkChannelType(channelID: channelID, channelType: extra.channelType)
        let readStateKey = conversationReadStateKey(channelID: channelID, channelType: channelType)
        let readWatermarkScope = currentReadWatermarkScope(channelID: channelID, channelType: channelType)
        return conversationStore.isReadByEffectiveWatermark(
            channelSeq: extra.channelSeq,
            readStateKey: readStateKey,
            scope: readWatermarkScope
        )
    }

    func decodeRealtimeEnvelopePayload<T: Decodable>(_ type: T.Type, envelope: RealtimeEnvelope) -> T? {
        let object = envelope.payload.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? realtimeDecoder.decode(T.self, from: data)
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
