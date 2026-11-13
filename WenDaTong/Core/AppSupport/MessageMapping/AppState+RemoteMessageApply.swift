// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import IM4Stores
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
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
    func applyRemoteMessages(
        _ remoteMessages: [RemoteMessage],
        channelID: String,
        channelType: String,
        fromRealtime: Bool = false,
        realtimeSignposts: [RealtimeMessageFlowSignpost] = [],
        preparedRealtime: RealtimeComputeApplication? = nil, // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        derivationTrace: MessageDerivationTraceContext? = nil,
        derivationInputRevision: UInt64? = nil,
        windowRetention: ConversationStore.MessageWindowRetention = .preserveLoadedHistory,
        historyBoundary explicitHistoryBoundary: ConversationStore.HistoryVisibilityBoundary? = nil,
        sequenceCoverageAfterSeq: Int64? = nil,
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_APPLY_OLDER_PREPEND_PARAM - 修改开始：标识更早消息分页，减少合并前本地消息全量扫描
        olderHistoryBeforeSeq: Int64? = nil,
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_APPLY_OLDER_PREPEND_PARAM - 修改结束：标识更早消息分页，减少合并前本地消息全量扫描
        scheduleSequenceRecovery: Bool = true
    ) {
        let inputRevision = derivationInputRevision ?? conversationStore.memorySnapshot.revision
        var diagnostics = realtimeSignposts.map { $0.memoryDiagnostic() }
        // WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111: Resolve the diagnostic key within this memory command.
        var installedConversationID: String?
        if let derivationTrace {
            diagnostics.append(derivationMemoryDiagnostic(derivationTrace,
                conversationID: { installedConversationID }, inputRevision: inputRevision))
        }
        return conversationStore.performMemoryCommand(memoryDiagnostics: diagnostics) { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let kind = conversationKind(from: channelType, channelID: channelID)
            let existingIndex = conversationStore.conversations.firstIndex { $0.id == channelID } ?? {
                let lookup = makeConversationUserLookup()
                return conversationStore.conversationMessageSnapshots().firstIndex { remoteChannelID(for: $0, lookup: lookup) == channelID }
            }()
            let previousRaw = existingIndex.map { conversationStore.conversationMessageSnapshot(at: $0) }
            let resolvedHistoryBoundary = kind == .group
                ? (explicitHistoryBoundary ?? conversationStore.historyBoundary(for: previousRaw))
                : nil
            if let resolvedHistoryBoundary {
                pruneDerivedCachesForHistoryBoundary(channelID: channelID, boundary: resolvedHistoryBoundary)
            }
            // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
            let prepared = preparedRealtime.flatMap { value -> RealtimeComputeApplication? in
                guard value.group.options == RemoteMessageDerivationOptions(fromRealtime: fromRealtime,
                    windowRetention: windowRetention, historyBoundary: explicitHistoryBoundary,
                    sequenceCoverageAfterSeq: sequenceCoverageAfterSeq, olderHistoryBeforeSeq: olderHistoryBeforeSeq,
                    scheduleSequenceRecovery: scheduleSequenceRecovery) else { return nil } // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
                return realtimePreparedApplicationIsCurrent(value, rawPrevious: previousRaw) ? value : nil
            }
            #if DEBUG
            if preparedRealtime != nil && prepared == nil { realtimeComputeRuntime.fallbackDuringApply = true }
            #endif
            let visibleRemoteMessages: [RemoteMessage]
            if let prepared { visibleRemoteMessages = prepared.visibleMessages }
            else {
                visibleRemoteMessages = remoteMessages
                .filter { !isAnnouncementSystemMessage($0) }
                .filter { isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: resolvedHistoryBoundary) }
            }
            // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
            if apiContext.hasIMSession {
                let scope = remoteDataScopeKey(for: apiContext)
                var hiddenRecords = LocalHiddenConversationStore.load(scope: scope)
                if let record = locallyHiddenRecord(
                    channelID: channelID,
                    channelType: channelType,
                    records: hiddenRecords
                ) {
                    let latestSeq = latestKnownSequence(for: visibleRemoteMessages)
                    if latestSeq > record.hiddenThroughSeq, latestSeq > 0 {
                        removeLocalHiddenRecord(record, from: &hiddenRecords)
                        LocalHiddenConversationStore.save(hiddenRecords, scope: scope)
                    } else {
                        return
                    }
                }
            }
            guard !visibleRemoteMessages.isEmpty else {
                if let resolvedHistoryBoundary {
                    installedConversationID = previousRaw?.id
                    applyHistoryVisibilityBoundaryForGroup(
                        channelID: channelID,
                        boundary: resolvedHistoryBoundary
                    )
                }
                return
            }
            let previous: ConversationMessageSnapshot?
            if let prepared { previous = prepared.expectedPrevious }
            else { previous = conversationStore.applyingHistoryVisibilityBoundary(resolvedHistoryBoundary, to: previousRaw) }
            let participants = conversationParticipants(channelID: channelID, kind: kind, previous: previous)
            let normalizedChannelID = normalizedRemoteChannelID(channelID, channelType: channelType)
            let normalizedChannelType = normalizedReadWatermarkChannelType(channelID: normalizedChannelID, channelType: channelType)
            let readStateKey = conversationReadStateKey(channelID: normalizedChannelID, channelType: normalizedChannelType)
            let readWatermarkScope = currentReadWatermarkScope(channelID: normalizedChannelID, channelType: normalizedChannelType)
            let effectiveReadSeq = max(
                previous?.lastReadSeq ?? 0,
                conversationStore.effectiveReadSeq(readStateKey: readStateKey, scope: readWatermarkScope)
            )
            // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
            let mergeResult: ConversationStore.MergedRemoteMessagesResult
            if let prepared {
                prepared.mappingSideEffects.forEach(invalidateIndexedMediaCacheIfRemoteTombstone)
                mergeResult = prepared.merge
            } else {
            let mappingStarted = DispatchTime.now().uptimeNanoseconds
            let previousMessages = previous?.messages ?? []
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_MAPPING_LOCAL_ECHO_SKIP - 修改开始：更早分页不会命中刚发送的本地回显，避免扫描全量已加载消息
            let canUseOlderHistoryMappingFastPath = olderHistoryBeforeSeq.map { beforeSeq in
                beforeSeq > 1 && visibleRemoteMessages.allSatisfy { remote in
                    remote.channelSeq > 0 && remote.channelSeq < beforeSeq
                }
            } ?? false
            let previousLocalClientIDs: Set<String> = canUseOlderHistoryMappingFastPath
                ? []
                : Set(previousMessages.compactMap { message -> String? in
                    guard message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed else { return nil }
                    return message.id
                })
            let previousPendingLocalMessages = canUseOlderHistoryMappingFastPath
                ? []
                : previousMessages.filter(isPendingLocalMessage)
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_MAPPING_LOCAL_ECHO_SKIP - 修改结束：更早分页不会命中刚发送的本地回显，避免扫描全量已加载消息
            var mappedLocalEchoIDs = Set<String>()
            var mappedRemoteMessages: [ConversationStore.MappedRemoteMessage] = []
            var remoteMessageIDs = Set<String>()
            // Let the Store inspect RTC conflicts, including malformed replacements
            // of a typed record received earlier or within this same batch.
            let rtcMessageIDs = Set(visibleRemoteMessages.filter {
                $0.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
            }.map { $0.messageID.trimmingCharacters(in: .whitespacesAndNewlines) })
                .union(previousMessages.filter { $0.rtcCallRecord != nil }.map(\.id))
            for remote in visibleRemoteMessages {
                let remoteMessageID = remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !remoteMessageID.isEmpty, remoteMessageIDs.contains(remoteMessageID), !rtcMessageIDs.contains(remoteMessageID) {
                    continue
                }
                invalidateIndexedMediaCacheIfRemoteTombstone(remote)
                // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_REMOTE_CLIENT_SKIP - 修改开始：更早分页跳过本地 client id 匹配开销
                let remoteClientIDs = canUseOlderHistoryMappingFastPath
                    ? []
                    : self.remoteClientMessageIdentifiers(remote)
                let isLocalEchoByClientMessageID = remoteClientIDs.contains { previousLocalClientIDs.contains($0) }
                let matchedLocalEchoID = canUseOlderHistoryMappingFastPath
                    ? nil
                    : matchedPendingLocalMessageID(
                        for: remote,
                        pendingLocals: previousPendingLocalMessages,
                        usedLocalIDs: mappedLocalEchoIDs
                    )
                // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_REMOTE_CLIENT_SKIP - 修改结束：更早分页跳过本地 client id 匹配开销
                if let matchedLocalEchoID {
                    mappedLocalEchoIDs.insert(matchedLocalEchoID)
                }
                var mapped = chatMessage(from: remote, participants: participants, forceOutgoing: isLocalEchoByClientMessageID || matchedLocalEchoID != nil)
                if kind == .group, !shouldShowGroupMemberCount {
                    mapped.readCount = nil
                    mapped.unreadCount = nil
                    if mapped.kind == .system {
                        mapped.text = textRemovingGroupMemberTotals(mapped.text)
                    }
                }
                mappedRemoteMessages.append(
                    ConversationStore.MappedRemoteMessage(
                        remote: remote,
                        message: mapped,
                        clientMessageIDs: Set(remoteClientIDs),
                        isRemoteFromCurrentUser: isRemoteMessageFromCurrentUser(remote),
                        matchedLocalID: matchedLocalEchoID
                    )
                )
                if !remoteMessageID.isEmpty {
                    remoteMessageIDs.insert(remoteMessageID)
                }
            }
            if let derivationTrace {
                recordMessageDerivation(.mapping, trace: derivationTrace, inputRevision: inputRevision, started: mappingStarted)
            }
            let mergingStarted = DispatchTime.now().uptimeNanoseconds
            mergeResult = conversationStore.mergeMappedRemoteMessages(
                previous: previous,
                mappedRemoteMessages: mappedRemoteMessages,
                readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled,
                fromRealtime: fromRealtime,
                windowRetention: windowRetention,
                sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
                // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PASS_OLDER_PREPEND_TO_STORE - 修改开始：把旧分页 beforeSeq 传给 store 进行线性合并
                olderHistoryBeforeSeq: canUseOlderHistoryMappingFastPath ? olderHistoryBeforeSeq : nil,
                // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PASS_OLDER_PREPEND_TO_STORE - 修改结束：把旧分页 beforeSeq 传给 store 进行线性合并
                coveredChannelSeqs: remoteMessages
                    .filter { isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: resolvedHistoryBoundary) }
                    .map(\.channelSeq),
                effectiveReadSeq: effectiveReadSeq
            )
            if let derivationTrace {
                recordMessageDerivation(.merging, trace: derivationTrace, inputRevision: inputRevision, started: mergingStarted)
            }
            }
            // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
            for finalization in mergeResult.pendingLocalFinalizations {
                finalizePendingAttachmentIfNeeded(localID: finalization.localID, remoteMessage: finalization.remoteMessage)
            }
            if let ticket = localMessageTicket {
                let durableAcknowledgements = mergeResult.pendingLocalFinalizations.compactMap { finalization -> (String, String, Int64)? in
                    let authoritativeMessageID = finalization.remoteMessage.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !authoritativeMessageID.isEmpty,
                          finalization.remoteMessage.channelSeq > 0 else { return nil }
                    return (finalization.localID, authoritativeMessageID, finalization.remoteMessage.channelSeq)
                }
                if !durableAcknowledgements.isEmpty {
                    Task {
                        guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                        for acknowledgement in durableAcknowledgements {
                            _ = try? await messagePersistence.acknowledgeOutgoingAuthority(
                                ticket: ticket,
                                clientMessageID: acknowledgement.0,
                                authoritativeMessageID: acknowledgement.1,
                                authoritativeChannelSeq: acknowledgement.2,
                                channelKey: channelID
                            )
                        }
                        scheduleDurableOutboxRecovery(ticket: ticket)
                    }
                }
            }
            let messages = mergeResult.messages
            let incomingRealtimeMessages = mergeResult.incomingRealtimeMessages
            guard let last = mergeResult.latestMessage else { return }
            let matchedGroup = kind == .group ? groups.first(where: { $0.id == channelID }) : nil
            let groupAvatarURL = matchedGroup?.avatarURL ?? ""
            let isActiveRealtimeConversation = activeRealtimeConversationID == (previous?.id ?? channelID) || activeRealtimeConversationID == channelID
            let latestKnownSeq = mergeResult.latestKnownSeq
            let memberCount = resolvedConversationMemberCount(
                kind: kind,
                channelID: channelID,
                previous: previous,
                participants: participants
            )
            let canAutoReadActiveRealtimeConversation = conversationStore.canAutoReadActiveRealtimeConversation(
                previousConversationID: previous?.id,
                channelID: channelID
            )
            realtimeSignposts.forEach { $0.bind(conversationID: kind == .system ? "system_notification" : (previous?.id ?? channelID)) }
            let applyResult = conversationStore.applyMergedRemoteMessagesConversation(
                channelID: channelID,
                kind: kind,
                previous: previous,
                title: conversationTitle(channelID: channelID, kind: kind, previous: previous),
                subtitle: previous?.subtitle ?? kind.rawValue,
                participants: participants,
                messages: messages,
                latestMessage: last,
                incomingRealtimeMessages: incomingRealtimeMessages,
                latestKnownSeq: latestKnownSeq,
                messageCoveredThroughSeq: mergeResult.messageCoveredThroughSeq,
                messageCoverageRequiresRecovery: mergeResult.messageCoverageRequiresRecovery,
                fromRealtime: fromRealtime,
                isActiveRealtimeConversation: isActiveRealtimeConversation,
                canAutoReadActiveRealtimeConversation: canAutoReadActiveRealtimeConversation,
                memberCount: memberCount,
                accentHex: stableSeed(channelID),
                avatarURL: groupAvatarURL,
                avatarVersion: matchedGroup?.avatarVersion ?? "",
                avatarUpdatedAt: matchedGroup?.avatarUpdatedAt ?? "",
                effectiveReadSeq: effectiveReadSeq,
                historyBoundary: resolvedHistoryBoundary,
                preparedRealtime: prepared?.applied,
                preparedChangesState: prepared?.changesState ?? true
            )
            installedConversationID = applyResult.conversation.id
            if applyResult.shouldPlayIncomingSound {
                let message = applyResult.incomingRealtimeMessages.last
                let localMetadata = message.flatMap { message -> IOSNotificationLocalMetadata? in
                    IOSNotificationLocalMetadata(
                        notificationID: message.id,
                        aggregateID: channelID,
                        tenantID: apiContext.tenantID ?? "",
                        imUID: apiContext.imUID ?? "",
                        appID: apiContext.appID,
                        channelID: normalizedChannelID,
                        channelType: normalizedChannelType,
                        channelSeq: message.channelSeq
                    )
                }
                IOSNotificationRuntime.shared.presentRealtimeMessage(
                    eventID: message?.id ?? "",
                    backgrounded: isApplicationBackgroundedForRTC,
                    localMetadata: localMetadata
                )
            }
            syncAttachmentFilesFromConversation(applyResult.conversation)
            if applyResult.shouldAutoRead {
                markConversationRead(applyResult.conversation.id, showToast: false)
            }
            if scheduleSequenceRecovery,
               let recoveryAfterSeq = mergeResult.sequenceRecoveryAfterSeq,
               let recoveryThroughSeq = mergeResult.sequenceRecoveryThroughSeq {
                scheduleMessageSequenceRecovery(
                    conversationID: applyResult.conversation.id,
                    target: ConversationStore.MessageSequenceRecoveryTarget(
                        afterSeq: recoveryAfterSeq,
                        throughSeq: recoveryThroughSeq
                    ),
                    reason: fromRealtime ? "realtime_gap" : "history_gap"
                )
            } // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111: only confirmed recovery persistence retires a scheduled gap.
            if kind == .group, !shouldShowGroupMemberCount {
                conversationStore.scrubGroupMemberTotals()
            }
            let deliveredSeq = visibleRemoteMessages
                .filter { !$0.fromUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { !isRemoteMessageFromCurrentUser($0) }
                .map(\.channelSeq)
                .filter { $0 > 0 }
                .max()
            if let deliveredSeq = deliveredSeq.map({ min($0, mergeResult.messageCoveredThroughSeq) }),
               deliveredSeq > 0 {
                scheduleDeliveryAck(conversation: applyResult.conversation, channelID: channelID, channelSeq: deliveredSeq)
            }
            if fromRealtime || visibleRemoteMessages.contains(where: {
                $0.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record"
            }) {
                scheduleRemoteSnapshotCacheWrite(
                    scope: remoteDataScopeKey(for: apiContext),
                    source: fromRealtime ? .realtime : .history
                )
            }
            reapplyAllAvatarRealtimeProjections()
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }

    private func matchedPendingLocalMessageID(for remote: RemoteMessage, pendingLocals: [ChatMessage], usedLocalIDs: Set<String>) -> String? {
        // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：remote 带 client 身份时只允许精确确认，不再落到同名/文本兜底误认领附件 pending
        let remoteClientIDs = remoteClientMessageIdentifiers(remote)
        for clientID in remoteClientIDs
            where pendingLocals.contains(where: { $0.id == clientID }) && !usedLocalIDs.contains(clientID) {
            return clientID
        }
        guard remoteClientIDs.isEmpty else { return nil }
        // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束

        let remoteSender = remote.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSenderIsCurrentUser = isRemoteMessageFromCurrentUser(remote)
        guard remoteSenderIsCurrentUser || remoteSender.isEmpty else { return nil }

        let maxTimeDrift: TimeInterval = remoteSenderIsCurrentUser ? 10 * 60 : 2 * 60
        // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：缺 client 的旧协议附件只允许唯一稳定文件身份匹配，模糊同名候选继续保留 pending
        if isAttachmentMessageKind(remoteMessageKind(from: remote)) {
            let candidates = pendingLocals.compactMap { local -> String? in
                guard !usedLocalIDs.contains(local.id),
                      pendingLocalMessage(local, matches: remote, maxTimeDrift: maxTimeDrift) else { return nil }
                return local.id
            }
            return candidates.count == 1 ? candidates[0] : nil
        }
        // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
        return pendingLocals.first { local in
            !usedLocalIDs.contains(local.id) && pendingLocalMessage(local, matches: remote, maxTimeDrift: maxTimeDrift)
        }?.id
    }

    private func pendingLocalMessage(_ local: ChatMessage, matches remote: RemoteMessage, maxTimeDrift: TimeInterval = 10 * 60) -> Bool {
        guard local.isOutgoing else { return false }
        let remoteKind = remoteMessageKind(from: remote)
        if isAttachmentMessageKind(local.kind) || isAttachmentMessageKind(remoteKind) {
            guard attachmentKindsCompatible(local: local, remoteKind: remoteKind, remote: remote) else { return false }
            // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：附件不再失败后落入通用文本匹配，避免 same.jpg 误确认
            return pendingLocalAttachment(local, matches: remote, maxTimeDrift: maxTimeDrift)
            // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
        } else {
            guard local.kind == remoteKind else { return false }
        }
        let localText = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteText = messagePreview(remote).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localText.isEmpty, localText == remoteText else { return false }
        if let localDate = local.createdAt,
           let remoteDate = parseRemoteDate(remote.createdAt),
           abs(localDate.timeIntervalSince(remoteDate)) > maxTimeDrift {
            return false
        }
        return true
    }

    private func remoteClientMessageIdentifiers(_ remote: RemoteMessage) -> [String] {
        var identifiers: [String] = []
        if let clientMsgNo = remote.clientMsgNo?.trimmingCharacters(in: .whitespacesAndNewlines), !clientMsgNo.isEmpty {
            identifiers.append(clientMsgNo)
        }
        for key in ["client_msg_no", "client_msg_id", "client_message_id", "client_id", "local_id", "localId"] {
            let value = payloadString(remote.payload, [key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                identifiers.append(value)
            }
        }
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    func isAttachmentMessageKind(_ kind: MessageKind) -> Bool {
        kind == .image || kind == .file || kind == .video || kind == .voice
    }

    private func attachmentKindsCompatible(local: ChatMessage, remoteKind: MessageKind, remote: RemoteMessage) -> Bool {
        if local.kind == remoteKind { return true }
        let localCategory = attachmentMediaCategory(for: local)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let remoteCategory = remoteAttachmentMediaCategory(remote, remoteKind: remoteKind)
        if !localCategory.isEmpty, !remoteCategory.isEmpty, localCategory == remoteCategory {
            return true
        }
        if local.kind == .voice, ["voice", "audio"].contains(remoteCategory) {
            return true
        }
        if remoteKind == .voice, ["voice", "audio"].contains(localCategory) {
            return true
        }
        return local.kind == .file && remoteKind == .video && localCategory == "video"
    }

    private func remoteAttachmentMediaCategory(_ remote: RemoteMessage, remoteKind: MessageKind) -> String {
        let explicit = attachmentPayloadString(remote.payload, ["media_category", "category", "kind", "preview_kind"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !explicit.isEmpty { return explicit }
        switch remoteKind {
        case .image:
            return "image"
        case .video:
            return "video"
        case .voice:
            return "voice"
        case .file:
            return "file"
        default:
            return ""
        }
    }

    private func pendingLocalAttachment(_ local: ChatMessage, matches remote: RemoteMessage, maxTimeDrift: TimeInterval) -> Bool {
        guard attachmentTimeMatches(local, remote: remote, maxTimeDrift: maxTimeDrift) else { return false }
        // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：附件 pending 只按稳定文件身份匹配；file/cache/size 冲突时禁止同名兜底
        let localSize = local.attachmentSizeBytes ?? 0
        let remoteSize = attachmentPayloadInt64(remote.payload, ["size_bytes", "size"]) ?? 0
        if localSize > 0, remoteSize > 0, localSize != remoteSize {
            return false
        }

        let localFileID = (local.attachmentFileID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFileIDs = remoteAttachmentIdentifiers(remote)
        if !localFileID.isEmpty, !remoteFileIDs.isEmpty {
            return remoteFileIDs.contains(localFileID)
        }

        let localCacheKey = local.attachmentCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteCacheKey = attachmentPayloadString(remote.payload, ["cache_key", "cacheKey", "thumb_object_key", "thumbnail_object_key", "object_key"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !localCacheKey.isEmpty, localCacheKey == remoteCacheKey {
            let localVersion = local.attachmentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteVersion = attachmentPayloadString(remote.payload, ["version", "file_version", "cache_version"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let localChecksum = local.attachmentChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteChecksum = attachmentPayloadString(remote.payload, ["checksum"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localVersion.isEmpty, !remoteVersion.isEmpty, localVersion != remoteVersion {
                return !localChecksum.isEmpty && localChecksum == remoteChecksum
            }
            if !localChecksum.isEmpty, !remoteChecksum.isEmpty, localChecksum != remoteChecksum {
                return false
            }
            return true
        } else if !localCacheKey.isEmpty || !remoteCacheKey.isEmpty {
            return false
        }

        return false
        // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
    }

    private func remoteAttachmentIdentifiers(_ remote: RemoteMessage) -> Set<String> {
        Set(["file_id", "attachment_id", "media_id", "id"]
            .map { attachmentPayloadString(remote.payload, [$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func attachmentTimeMatches(_ local: ChatMessage, remote: RemoteMessage, maxTimeDrift: TimeInterval) -> Bool {
        guard let localDate = local.createdAt,
              let remoteDate = parseRemoteDate(remote.createdAt) else {
            return true
        }
        return abs(localDate.timeIntervalSince(remoteDate)) <= maxTimeDrift
    }

    private func isAnnouncementSystemMessage(_ remote: RemoteMessage) -> Bool {
        guard remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" else {
            return false
        }
        let event = (remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue ?? "").lowercased()
        let kind = (remote.payload["kind"]?.stringValue ?? remote.payload["category"]?.stringValue ?? "").lowercased()
        if event.contains("announcement") || kind == "announcement" || kind == "notice" {
            return true
        }
        // 群成员事件(入群/邀请/移出/退群)绝不能按公告过滤。之前用
        // messagePreview 文本包含“公告”做兜底,导致群名带“公告”的群
        // (如「全员公告群」)所有入群系统消息在 applyRemoteMessages 里
        // 被整批丢弃,历史消息永远补不齐。
        if isGroupMembershipSystemEvent(event) {
            return false
        }
        let displayStyle = (remote.payload["display_style"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if displayStyle == "group_event_notice" {
            return false
        }
        // 其余未带明确事件类型的旧格式系统消息才允许文本兜底判断。
        guard event.isEmpty else { return false }
        let text = messagePreview(remote)
        return text.contains("公告")
    }

    func applyImmediateSystemMessages(_ messages: [RemoteMessage]) {
        let grouped = Dictionary(grouping: messages) { message in
            "\(message.channelType)|\(message.channelID)"
        }
        for (_, items) in grouped {
            guard let first = items.first else { continue }
            applyRemoteMessages(items, channelID: first.channelID, channelType: first.channelType)
        }
    }

    func replaceMessageID(localID: String, remote: RemoteMessage, in conversationID: String) {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let remoteMapped = chatMessage(from: remote, participants: conversation.participants, forceOutgoing: true)
        guard let replacement = conversationStore.replaceLocalMessageWithRemoteConfirmation(
            localID: localID,
            remoteMessageID: remote.messageID,
            remoteMapped: remoteMapped,
            remoteDisplayTime: displayTime(remote.createdAt),
            remoteCreatedAt: parseRemoteDate(remote.createdAt),
            remoteChannelSeq: remote.channelSeq,
            in: conversationID,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled
        ) else { return }
        if let resources = cachedLocalAttachmentResources(for: replacement.previousMessage) {
            let resourcesToCache = resources
            cacheLocalAttachmentResources(resourcesToCache, messageID: remote.messageID, fileID: replacement.confirmedMessage.attachmentFileID)
            let mediaCategory = attachmentMediaCategory(for: replacement.confirmedMessage)
            let fallbackExtension = attachmentFileExtension(for: replacement.confirmedMessage, remoteURL: nil, mediaCategory: mediaCategory)
            if let cacheIdentity = attachmentStableCacheIdentity(for: replacement.confirmedMessage, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
                cacheLocalAttachmentResources(
                    resourcesToCache,
                    messageID: remote.messageID,
                    fileID: replacement.confirmedMessage.attachmentFileID,
                    cacheIdentity: cacheIdentity
                )
            }
        }
        finalizePendingAttachmentIfNeeded(localID: localID, remoteMessage: replacement.confirmedMessage)
        if let updatedConversation = conversationStore.conversationMessageSnapshot(id: conversationID) {
            syncAttachmentFilesFromConversation(updatedConversation)
        }
        if conversation.kind == .group, !shouldShowGroupMemberCount {
            conversationStore.scrubGroupMemberTotals()
        }
    }

    private func finalizePendingAttachmentIfNeeded(localID: String, remoteMessage: ChatMessage) {
        guard fileStore.hasAttachmentUploadRuntimeState(messageID: localID) else { return }
        if let key = scopedContentCacheKey(localID),
           let resources = fileStore.localAttachmentResources(cacheKey: key) {
            let resourcesToCache = resources
            cacheLocalAttachmentResources(resourcesToCache, messageID: remoteMessage.id, fileID: remoteMessage.attachmentFileID)
        }
        fileStore.cancelAttachmentUpload(messageID: localID)
        clearCompletedAttachmentProgress(localID: localID, remoteMessage: remoteMessage)
    }

    private func clearCompletedAttachmentProgress(localID: String, remoteMessage: ChatMessage) {
        clearAttachmentProgressKeys([
            localID,
            remoteMessage.id,
            attachmentProgressKey(for: remoteMessage),
            remoteMessage.attachmentFileID
        ])
    }

    func clearAttachmentProgressKeys(_ rawKeys: [String?]) {
        let keys = Set(rawKeys.compactMap { rawKey -> String? in
            guard let rawKey else { return nil }
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        })
        fileStore.clearAttachmentDownloadProgress(attachmentIDs: keys)
    }

    func retainedRemoteAttachmentURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.isFileURL {
            return ""
        }
        if isTenantFileAPIEndpoint(trimmed) {
            return ""
        }
        return rawValue
    }

    func resolvedTenantFileAssetURL(_ rawValue: String) -> String {
        let retained = retainedRemoteAttachmentURL(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retained.isEmpty else { return "" }
        let resolved = resolveTenantAssetURL(retained)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty, !isTenantFileAPIEndpoint(resolved) else { return "" }
        return resolved
    }

    func setAttachmentFileID(_ fileID: String, messageID: String, in conversationID: String) {
        guard let updatedMessage = conversationStore.setAttachmentFileID(fileID, messageID: messageID, conversationID: conversationID) else { return }
        if let resources = cachedLocalAttachmentResources(for: updatedMessage) {
            cacheLocalAttachmentResources(resources, messageID: updatedMessage.id, fileID: updatedMessage.attachmentFileID)
        }
    }

    func updateAttachmentProgress(_ progress: Double?, messageID: String, in conversationID: String) {
        guard let updatedMessage = conversationStore.updateAttachmentProgress(progress, messageID: messageID, conversationID: conversationID) else {
            if progress == nil {
                clearAttachmentProgressKeys([messageID])
            }
            return
        }
        let key = attachmentProgressKey(for: updatedMessage)
        if let progress {
            fileStore.setAttachmentDownloadProgress(progress, attachmentID: key)
            if key != messageID {
                fileStore.clearAttachmentDownloadProgress(attachmentID: messageID)
            }
        } else {
            clearAttachmentProgressKeys([messageID, key])
        }
    }

    func updateMessageAttachment(_ message: ChatMessage, in conversationID: String) {
        conversationStore.updateMessageAttachment(message, conversationID: conversationID)
    }

    func markMessageFailed(messageID: String, in conversationID: String) {
        guard conversationStore.markMessageFailed(messageID: messageID, conversationID: conversationID) else { return }
        if apiContext.hasIMSession {
            scheduleConversationSnapshotCacheWrite(
                conversationID: conversationID,
                scope: remoteDataScopeKey(for: apiContext)
            )
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息接口发送失败，可点击重发")
    }

    func removeMessage(messageID: String, in conversationID: String) {
        conversationStore.removeMessage(messageID: messageID, conversationID: conversationID)
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
