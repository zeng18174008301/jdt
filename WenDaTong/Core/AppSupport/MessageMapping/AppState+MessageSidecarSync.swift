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
    struct MessageSidecarSyncSession {
        let context: IMAPIContext
        let scope: String
        let refreshSession: RemoteSnapshotRefreshSession
    }

    func currentMessageSidecarSyncSession() -> MessageSidecarSyncSession? {
        guard apiContext.hasIMSession else { return nil }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else { return nil }
        return MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
    }

    private func readReceiptSidecarSyncTarget(
        channelID: String,
        channelType: String
    ) -> ConversationStore.ReadReceiptSidecarSyncTarget? {
        conversationStore.readReceiptSidecarSyncTarget(
            channelID: channelID,
            channelType: channelType,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    func syncReadReceiptsForConversation(channelID: String, channelType: String) async {
        guard let session = currentMessageSidecarSyncSession() else { return }
        await syncReadReceiptsForConversation(channelID: channelID, channelType: channelType, session: session)
    }

    func syncReadReceiptsForConversation(
        channelID: String,
        channelType: String,
        session: MessageSidecarSyncSession
    ) async {
        let context = session.context
        guard context.hasIMSession,
              isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
        let syncContext = conversationStore.messageSidecarSyncKeyContext(
            tenantID: context.tenantID,
            imUID: context.imUID,
            channelID: channelID,
            channelType: channelType,
            suffix: "read",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType)
            }
        )
        let syncPlan = conversationStore.messageReceiptsSyncPlan(
            syncKey: syncContext.syncKey,
            channelID: channelID,
            channelType: channelType,
            afterSeq: 0,
            receiptType: "",
            limit: 100
        )
        let command: ConversationStore.MessageReceiptsSyncCommand
        switch syncPlan {
        case .sync(let syncCommand):
            command = syncCommand
        case .skip:
            return
        }
        guard let claim = conversationStore.beginMessageReceiptsSyncClaim(command) else { return }
        defer { conversationStore.finishMessageReceiptsSync(claim) }
        let generation = localMessageSessionGeneration
        // WDT_RECEIPT_DETAIL_SCOPE_20261023: a response from the previous tenant role cannot grant detail access.
        var detailScope = readReceiptDetailScope
        let senderIdentities = currentMessageSenderIdentitySet()
        let conversationID = conversationStore.conversationMessageSnapshots().first(where: {
            ($0.id == command.channelID || remoteChannelID(for: $0) == command.channelID)
                && apiChannelType(for: $0.kind) == command.channelType
        })?.id
        let pendingWindow = command.channelType == "direct"
            ? conversationStore.pendingDirectReadWindow(
                channelID: command.channelID,
                senderIdentities: senderIdentities,
                channelIDForConversation: { remoteChannelID(for: $0) }
            ) : nil
        var detailAuthority = conversationID.flatMap { readReceiptAuthorityStore[$0] } // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        func isCurrentRequest() -> Bool {
            guard generation == localMessageSessionGeneration,
                  detailScope == readReceiptDetailScope, // WDT_RECEIPT_DETAIL_SCOPE_20261023: discard pre-revocation receipts.
                  isCurrentRemoteRefresh(session.refreshSession, scope: session.scope),
                  context.appID == apiContext.appID,
                  context.sessionEpoch == apiContext.sessionEpoch,
                  context.imToken == apiContext.imToken,
                  senderIdentities == currentMessageSenderIdentitySet(),
                  conversationStore.isCurrentMessageReceiptsSync(claim),
                  let conversationID,
                  let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
            return remoteChannelID(for: conversation) == command.channelID
                && apiChannelType(for: conversation.kind) == command.channelType
        }
        guard isCurrentRequest() else { return }
        var didChange = false
        do {
            var afterSequence = command.afterSeq
            var confirmedWatermark: Int64 = 0
            // Keep the existing delivery/detail sync, then spend at most two requests
            // on this captured pending window. Hidden items do not imply end of data.
            for requestIndex in 0..<3 {
                if Task.isCancelled { break }
                let result = try await api.syncMessageReceipts(
                    context: context,
                    channelID: command.channelID,
                    channelType: command.channelType,
                    afterSeq: afterSequence,
                    receiptType: requestIndex == 0 ? command.receiptType : "read",
                    limit: command.limit
                )
                guard isCurrentRequest() else { return }
                if Task.isCancelled { break }
                if result.readReceiptsEnabled == false || result.featureStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "disabled" {
                    didChange = applyRemoteReadReceipts(
                        result.items.filter { $0.receiptType == "delivered" },
                        channelID: command.channelID, persistChanges: false
                    ) || didChange
                    let previous = conversationID.flatMap { conversationStore.conversationMessageSnapshot(id: $0) }
                    setReadReceiptsEnabled(false)
                    detailScope = readReceiptDetailScope // Keep this request's own privacy cleanup eligible for persistence.
                    didChange = previous != conversationID.flatMap { conversationStore.conversationMessageSnapshot(id: $0) } || didChange
                    break
                }
                // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023: honor visibility even when the response has no items.
                if detailScope == readReceiptDetailScope,
                   let allowed = result.canViewReadReceiptDetails, let conversationID,
                   detailAuthority == readReceiptAuthorityStore[conversationID] { // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
                    didChange = applyReadReceiptDetailAuthority(
                        allowed, conversationID: conversationID
                    ) || didChange
                    detailAuthority = readReceiptAuthorityStore[conversationID] // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
                }
                didChange = applyRemoteReadReceipts(
                    result.items, channelID: command.channelID, persistChanges: false
                ) || didChange
                guard fileUploadConfig.readReceiptsEnabled, let pendingWindow else { break }
                let watermark = result.readUpToSeq ?? 0
                didChange = conversationStore.applyDirectReadWatermark(
                    watermark, window: pendingWindow, readReceiptsEnabled: true
                ) || didChange
                // Baseline may be occupied by old receipts. The first extra request
                // jumps straight to the oldest pending confirmed sequence, not page 2.
                if requestIndex > 0 && watermark <= max(confirmedWatermark, afterSequence) { break }
                confirmedWatermark = max(confirmedWatermark, watermark)
                guard let nextAfter = pendingWindow.afterSequence(through: confirmedWatermark) else { break }
                afterSequence = nextAfter
            }
        } catch {
            guard isCurrentRequest() else { return }
            if error is CancellationError || Task.isCancelled {
                // Preserve any earlier successful page in this still-current scope.
            } else if isCapabilityError(error, code: "read_receipts_not_enabled") {
                let previous = conversationID.flatMap { conversationStore.conversationMessageSnapshot(id: $0) }
                setReadReceiptsEnabled(false)
                detailScope = readReceiptDetailScope
                didChange = previous != conversationID.flatMap { conversationStore.conversationMessageSnapshot(id: $0) } || didChange
            } else if isNotFriendsError(error),
               let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == command.channelID || remoteChannelID(for: $0) == command.channelID }) {
                handleNotFriends(for: conversation, showToast: false)
            } else {
                handleRemoteError(error, fallback: "已读状态同步失败", silent: true)
            }
        }
        if didChange, isCurrentRequest(), let conversationID {
            await persistConversationSnapshotImmediately(
                conversationID: conversationID, scope: session.scope, source: .localMutation
            )
        }
    }

    func syncReadReceiptsIfNeeded(_ conversationID: String) {
        guard let session = currentMessageSidecarSyncSession(),
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        guard let readReceiptTarget = readReceiptSidecarSyncTarget(channelID: channelID, channelType: channelType) else {
            return
        }
        Task {
            await syncReadReceiptsForConversation(
                channelID: readReceiptTarget.channelID,
                channelType: readReceiptTarget.channelType,
                session: session
            )
        }
    }

    func syncMessageExtrasForConversation(channelID: String, channelType: String) async {
        guard let session = currentMessageSidecarSyncSession() else { return }
        await syncMessageExtrasForConversation(channelID: channelID, channelType: channelType, session: session)
    }

    func syncMessageExtrasForConversation(
        channelID: String,
        channelType: String,
        session: MessageSidecarSyncSession
    ) async {
        let context = session.context
        guard context.hasIMSession,
              isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
        let syncContext = conversationStore.messageSidecarSyncKeyContext(
            tenantID: context.tenantID,
            imUID: context.imUID,
            channelID: channelID,
            channelType: channelType,
            suffix: "extras",
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType)
            }
        )
        let syncPlan = conversationStore.messageExtrasSyncPlan(
            syncKey: syncContext.syncKey,
            channelID: channelID,
            channelType: channelType,
            afterVersion: 0,
            limit: 100
        )
        let command: ConversationStore.MessageExtrasSyncCommand
        switch syncPlan {
        case .sync(let syncCommand):
            command = syncCommand
        case .skip:
            return
        }
        guard conversationStore.beginMessageExtrasSync(command) else { return }
        defer {
            conversationStore.finishMessageExtrasSync(syncKey: command.syncKey)
        }
        do {
			var afterVersion = command.afterVersion
			let pageLimit = min(100, max(1, command.limit))
			for _ in 0..<200 {
				let extras = try await api.syncMessageExtras(
					context: context,
					channelID: command.channelID,
					channelType: command.channelType,
					afterVersion: afterVersion,
					limit: pageLimit
					)
					guard isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
					// JHT_MOD_BEGIN CHAT_MESSAGE_SIDECAR_APPLY_SLICE_PERF_20260912 - 修改开始：分页返回后分批应用 extras，避免消息页主线程连续卡顿
					#if DEBUG
					let extrasApplyStartedAt = CFAbsoluteTimeGetCurrent()
					if !extras.isEmpty {
						print("[JHT Perf] message_extras_apply_start channel=\(command.channelID) count=\(extras.count)")
					}
					#endif
						// JHT_MOD_BEGIN MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改开始：同步 extras 批量应用，避免逐条触发会话消息全量扫描
						applySyncedRemoteMessageExtras(extras)
						guard await pauseMessageSidecarApplySliceIfNeeded(
							processedCount: extras.count,
							totalCount: extras.count + 1,
							session: session
						) else { return }
						// JHT_MOD_END MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改结束
					#if DEBUG
					if !extras.isEmpty {
						let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - extrasApplyStartedAt) * 1000)
						print("[JHT Perf] message_extras_apply_done channel=\(command.channelID) count=\(extras.count) elapsed_ms=\(elapsedMs)")
					}
					#endif
					// JHT_MOD_END CHAT_MESSAGE_SIDECAR_APPLY_SLICE_PERF_20260912 - 修改结束
					guard extras.count >= pageLimit,
					      let nextVersion = extras.map(\.version).max(),
					      nextVersion > afterVersion else { break }
					afterVersion = nextVersion
				}
        } catch {
            guard isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
            handleRemoteError(error, fallback: "消息互动同步失败", silent: true)
	        }
	    }

    // JHT_MOD_BEGIN CHAT_MESSAGE_SIDECAR_APPLY_SLICE_PERF_20260912 - 修改开始：sidecar 主线程应用分片工具，保持顺序但给 UI 让帧
    private func pauseMessageSidecarApplySliceIfNeeded(
        processedCount: Int,
        totalCount: Int,
        session: MessageSidecarSyncSession
    ) async -> Bool {
        guard processedCount < totalCount, processedCount % 12 == 0 else { return true }
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 4_000_000)
        } catch {
            return false
        }
        return !Task.isCancelled && isCurrentRemoteRefresh(session.refreshSession, scope: session.scope)
    }
    // JHT_MOD_END CHAT_MESSAGE_SIDECAR_APPLY_SLICE_PERF_20260912 - 修改结束

	    func syncConversationSidecars(
	        channelID: String,
	        channelType: String,
        session: MessageSidecarSyncSession
    ) async {
        guard isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
        await syncMessageExtrasForConversation(channelID: channelID, channelType: channelType, session: session)
        guard isCurrentRemoteRefresh(session.refreshSession, scope: session.scope) else { return }
        if let readReceiptTarget = readReceiptSidecarSyncTarget(channelID: channelID, channelType: channelType) {
            await syncReadReceiptsForConversation(
                channelID: readReceiptTarget.channelID,
                channelType: readReceiptTarget.channelType,
                session: session
            )
        }
    }

    func applyRealtimeMessageReceipt(_ receipt: RemoteMessageReceipt) {
        guard receipt.receiptType == "delivered" || (receipt.receiptType == "read" && fileUploadConfig.readReceiptsEnabled),
              !receipt.messageID.isEmpty || receipt.channelSeq > 0 else { return }
        let fromUID = receipt.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromUID.isEmpty, currentMessageSenderIdentitySet().contains(fromUID) else { return }
        let channelID = receipt.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channelID.isEmpty {
            guard let conversation = conversationStore.conversationMessageSnapshots().first(where: {
                $0.id == channelID || remoteChannelID(for: $0) == channelID
            }), receipt.channelType.isEmpty || receipt.channelType == apiChannelType(for: conversation.kind) else {
                refreshReceiptFallback(receipt)
                return
            }
            let hasTarget = conversation.messages.contains { message in
                guard message.isOutgoing else { return false }
                return !receipt.messageID.isEmpty ? message.id == receipt.messageID
                    : message.channelSeq > 0 && message.channelSeq <= receipt.channelSeq
            }
            if hasTarget {
                // A duplicate is a no-op, not a missing-message recovery signal.
                applyRemoteReadReceipts([receipt], channelID: channelID)
            } else {
                refreshReceiptFallback(receipt)
            }
        } else {
            // Sequence numbers are channel-local. Without a channel only an exact,
            // unambiguous message identity can route a legacy receipt safely.
            let matches = receipt.messageID.isEmpty ? [] : conversationStore.conversationMessageSnapshots().filter { conversation in
                conversation.messages.contains { $0.isOutgoing && $0.id == receipt.messageID }
            }
            if matches.count == 1, let conversation = matches.first {
                applyRemoteReadReceipts([receipt], channelID: remoteChannelID(for: conversation))
            } else {
                refreshReceiptFallback(receipt)
            }
        }
    }

    private func refreshReceiptFallback(_ receipt: RemoteMessageReceipt) {
        guard receipt.receiptType == "delivered" || fileUploadConfig.readReceiptsEnabled else { return }
        let channelID = receipt.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelType = receipt.channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty, !channelType.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "receipt_missing_channel")
            return
        }
        guard let conversation = conversationStore.conversationMessageSnapshots().first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else {
            scheduleRealtimeRecoveryRefresh(reason: "receipt_unknown_channel")
            return
        }
        Task {
            syncConversationMessagesIfNeeded(conversation.id, force: true, silent: true)
            if let session = currentMessageSidecarSyncSession() {
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: session)
            }
        }
    }

    @discardableResult
    func applyRemoteReadReceipts(
        _ receipts: [RemoteMessageReceipt], channelID: String, persistChanges: Bool = true
    ) -> Bool {
        let senderIdentities = currentMessageSenderIdentitySet()
        guard let conversation = conversationStore.conversationMessageSnapshots().first(where: {
            $0.id == channelID || remoteChannelID(for: $0) == channelID
        }) else { return false }
        let safeReceipts = receipts.filter { receipt in
            let fromUID = receipt.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let receiptChannel = receipt.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let receiptChannelType = receipt.channelType.trimmingCharacters(in: .whitespacesAndNewlines)
            return !fromUID.isEmpty && senderIdentities.contains(fromUID)
                && (receiptChannel.isEmpty || receiptChannel == channelID || receiptChannel == remoteChannelID(for: conversation))
                && (receiptChannelType.isEmpty || receiptChannelType == apiChannelType(for: conversation.kind))
        }
        let didApply = conversationStore.applyRemoteReadReceipts(
            safeReceipts,
            channelID: channelID,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            },
            makeReadReceipt: { receipt, conversation in
                ReadReceipt(
                    id: "\(receipt.imUID)_\(receipt.deviceID)_\(receipt.channelSeq)",
                        user: readReceiptUser(
                            imUID: receipt.imUID,
                            conversation: conversation,
                            nickname: receipt.nickname,
                            displayName: receipt.displayName,
                            remark: receipt.remark
                        ),
                    device: receipt.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "设备未同步" : receipt.deviceID,
                    time: displayTime(receipt.createdAt)
                )
            }
        )
        if didApply,
           conversationStore.conversationMessageSnapshots().first(where: {
               $0.id == channelID || remoteChannelID(for: $0) == channelID
           })?.kind == .group,
           !shouldShowGroupMemberCount {
            conversationStore.scrubGroupMemberTotals()
        }
        if didApply && persistChanges {
            scheduleConversationSnapshotCacheWrite(
                conversationID: conversation.id, scope: remoteDataScopeKey(for: apiContext)
            )
        }
        return didApply
    }

    func setReadReceiptsEnabled(_ enabled: Bool) {
        guard fileUploadConfig.readReceiptsEnabled != enabled else { return }
        fileStore.replaceUploadConfig(FileUploadConfig(
            maxBytes: fileUploadConfig.maxBytes,
            maxMB: fileUploadConfig.maxMB,
            source: fileUploadConfig.source,
            messageRecallMaxMinutes: fileUploadConfig.messageRecallMaxMinutes,
            voiceCallEnabled: fileUploadConfig.voiceCallEnabled,
            videoCallEnabled: fileUploadConfig.videoCallEnabled,
            readReceiptsEnabled: enabled,
            groupAdminDeleteMessageEnabled: fileUploadConfig.groupAdminDeleteMessageEnabled,
            voiceCallLicenseKnown: fileUploadConfig.voiceCallLicenseKnown,
            videoCallLicenseKnown: fileUploadConfig.videoCallLicenseKnown
        ))
        if !enabled {
            // WDT_RECEIPT_DETAIL_SCOPE_20261023: re-enabling requires a fresh explicit capability.
            invalidateReadReceiptDetailAuthorities()
            conversationStore.stripReadReceiptDetailsFromAllMessages()
        }
    }

    func applyFileUploadConfig(_ config: FileUploadConfig) {
        fileUploadConfig = config
        if config.videoCallEnabled {
            scheduleRTCDeviceCapabilitiesReportIfNeeded()
        } else {
            resetRTCDeviceCapabilityReportState()
        }
        if !config.readReceiptsEnabled {
            invalidateReadReceiptDetailAuthorities() // WDT_RECEIPT_DETAIL_SCOPE_20261023
            conversationStore.stripReadReceiptDetailsFromAllMessages()
        }
    }

    private func stripReadReceiptDetails(from message: inout ChatMessage) {
        conversationStore.stripReadReceiptDetails(from: &message)
    }

    func reactionDetail(from remote: RemoteMessageReactionReceipt) -> ReactionDetail {
        let fallbackName = remote.operatorName.isEmpty ? remote.operatorUID : remote.operatorName
        let resolvedUser = user(for: remote.operatorUID)
        let user = resolvedUser
            ?? IMUser(
                id: remote.operatorUID,
                name: remarkPreferredDisplayName(
                    identifiers: [remote.operatorUID],
                    candidates: [fallbackName],
                    fallback: remote.operatorUID
                ),
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "在线",
                enterprise: currentEnterprise.name,
                avatarSeed: stableSeed(remote.operatorUID),
                badges: []
            )
        let idParts = [remote.messageID, remote.operatorUID, remote.emoji, remote.createdAt ?? UUID().uuidString]
            .filter { !$0.isEmpty }
        return ReactionDetail(
            id: idParts.joined(separator: "_"),
            emoji: remote.emoji,
            user: user,
            time: displayTime(remote.createdAt)
        )
    }

    func reactionDetail(from extra: RemoteMessageExtra, id: String) -> ReactionDetail {
        let fallbackName = extra.operatorName.isEmpty ? extra.operatorUID : extra.operatorName
        let resolvedUser = user(for: extra.operatorUID)
        let user = resolvedUser
            ?? IMUser(
                id: extra.operatorUID,
                name: remarkPreferredDisplayName(
                    identifiers: [extra.operatorUID],
                    candidates: [fallbackName],
                    fallback: extra.operatorUID
                ),
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "在线",
                enterprise: currentEnterprise.name,
                avatarSeed: stableSeed(extra.operatorUID),
                badges: []
            )
        return ReactionDetail(
            id: id,
            emoji: extra.emoji,
            user: user,
            time: displayTime(extra.createdAt)
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
