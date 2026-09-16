import Combine
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

// MARK: - AppState MainActor Partition
//
// This file contains stateful message projection, receipt, sidecar, delivery ack,
// and sender presentation bridges. It stays on AppState/MainActor because it
// reads and mutates conversationStore, message sidecar state, file upload config,
// read watermarks, delivery ack queues, and SwiftUI-observed conversation state.
// Pure payload decoding remains in AppState+RemoteMessagePayloadMapping.swift as
// nonisolated helpers so future bulk mapping can keep heavy parsing off MainActor.

// MARK: - Identity, Receipts, and Message Mapping

extension AppState {
    func isCurrentUserIdentity(_ rawValue: String) -> Bool {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return currentUserIdentitySet().contains(normalized)
    }

    func isCurrentMessageSender(_ rawValue: String) -> Bool {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return currentMessageSenderIdentitySet().contains(normalized)
    }

    func remarkPreferredDisplayName(for user: IMUser, fallback: String? = nil) -> String {
        remarkPreferredDisplayName(
            identifiers: [user.id, user.userID, user.username],
            candidates: [user.name, user.username, user.userID],
            fallback: fallback ?? (user.id.isEmpty ? "未知用户" : user.id)
        )
    }

    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_DISPLAY_NAME_FAST_PATH - 修改开始：通讯录列表使用当前联系人自身标识快速解析备注名，避免大列表滚动/重建时反查全量联系人
    func contactDirectoryDisplayName(for user: IMUser, fallback: String? = nil) -> String {
        let normalizedIdentifiers = [user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !normalizedIdentifiers.contains(where: { isCurrentUserIdentity($0) }) {
            for identifier in normalizedIdentifiers {
                if let remark = contactRemarks[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !remark.isEmpty {
                    return remark
                }
            }
        }
        return preferredDisplayName(
            candidates: [user.name, user.username, user.userID],
            identifiers: normalizedIdentifiers,
            fallback: fallback ?? (user.id.isEmpty ? "未知用户" : user.id)
        )
    }
    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_DISPLAY_NAME_FAST_PATH - 修改结束：通讯录列表使用当前联系人自身标识快速解析备注名，避免大列表滚动/重建时反查全量联系人

    func liveProfileUser(for seed: IMUser) -> IMUser {
        if isCurrentUserProfile(seed) {
            return presentationOverlaidUser(currentUser)
        }
        for identifier in userIdentityCandidates(for: seed) {
            if let live = user(for: identifier) {
                return presentationOverlaidUser(live)
            }
        }
        return presentationOverlaidUser(seed)
    }

    func userProfileDisplayName(for seed: IMUser) -> String {
        let live = liveProfileUser(for: seed)
        if isCurrentUserProfile(live) {
            return preferredDisplayName(
                candidates: [live.name, live.username, live.userID],
                identifiers: userIdentityCandidates(for: live),
                fallback: live.id.isEmpty ? "未知用户" : live.id
            )
        }
        return remarkPreferredDisplayName(for: live)
    }

    func remarkPreferredDisplayName(identifiers: [String], candidates: [String?], fallback: String) -> String {
        let normalizedIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let remark = contactRemarkValue(matching: normalizedIdentifiers) {
            return remark
        }
        return preferredDisplayName(candidates: candidates, identifiers: normalizedIdentifiers, fallback: fallback)
    }

    func currentUserIdentitySet() -> Set<String> {
        Set([
            currentUser.id,
            currentUser.userID,
            currentUser.username,
            apiContext.imUID ?? "",
            apiContext.accountID ?? ""
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func contactRemarkValue(matching identifiers: [String]) -> String? {
        guard !identifiers.isEmpty,
              !identifiers.contains(where: { isCurrentUserIdentity($0) }) else { return nil }
        for identifier in identifiers {
            if let remark = contactRemarks[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
        }
        guard let contact = contacts.first(where: { contact in
            identifiers.contains { user(contact, matchesIdentifier: $0) }
        }) else { return nil }
        for identifier in [contact.id, contact.userID, contact.username] {
            let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let remark = contactRemarks[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
        }
        return nil
    }

    private func currentMessageSenderIdentitySet() -> Set<String> {
        Set([
            apiContext.imUID ?? "",
            currentUser.id
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func localOutgoingMessageSenderID() -> String {
        let imUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !imUID.isEmpty {
            return imUID
        }
        return currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func localOutgoingMessageSenderName(conversationID: String) -> String {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .group else {
            return currentUser.name
        }
        if let projectedSelf = myGroupMemberProjection(groupID: remoteChannelID(for: conversation)) {
            let name = projectedSelf.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        return currentUser.name
    }

    func isRemoteMessageFromCurrentUser(_ message: RemoteMessage) -> Bool {
        currentMessageSenderIdentitySet().contains(message.fromUID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func applyRemoteReadSummary(from remote: RemoteMessage, to message: inout ChatMessage) {
        conversationStore.applyRemoteReadSummary(
            from: remote,
            to: &message,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled
        )
    }

    func applyRemoteReadSummary(from remote: RemoteMessage, toMessagesIn conversation: inout Conversation) {
        conversationStore.applyRemoteReadSummary(
            from: remote,
            toMessagesIn: &conversation,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled
        )
    }

    func startConversationHistoryPrefetch(_ remoteConversations: [RemoteConversation], context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession, performanceStart: CFAbsoluteTime) {
        let generation = refreshSession.generation
        guard !remoteConversations.isEmpty else {
            print("[JHT Perf] history_prefetch_complete_ms=\(Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)) success=0 failed=0 skipped=empty generation=\(generation)")
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.mainShellHistoryPrefetchDelayNs)
            } catch {
                return
            }
            guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            print("[JHT Perf] history_prefetch_start_delay_ms=\(Int(Double(self.mainShellHistoryPrefetchDelayNs) / 1_000_000)) generation=\(generation)")
            await self.refreshConversationHistories(
                remoteConversations,
                context: context,
                scope: scope,
                refreshSession: refreshSession,
                performanceStart: performanceStart
            )
        }
    }

    private struct HistoryPrefetchResult: @unchecked Sendable {
        let remote: RemoteConversation
        let messages: [RemoteMessage]
        let historyBoundary: ConversationStore.HistoryVisibilityBoundary?
        let boundaryGeneration: Int?
        let readReceiptTarget: ConversationStore.HistoryPrefetchReadReceiptBackfillTarget?
        let error: Error?
    }

    private func historyPrefetchLogID(for remote: RemoteConversation) -> String {
        let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType)
        if conversationKind(from: remote.channelType, channelID: channelID) != .direct {
            return channelID
        }
        let sum = channelID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return "direct#\(abs(sum % 100_000))"
    }

    private func refreshConversationHistories(_ remoteConversations: [RemoteConversation], context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession, performanceStart: CFAbsoluteTime) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope),
              context.hasIMSession else { return }
        let canonicalRemotes = canonicalRemoteConversations(remoteConversations)
        let localByChannelID = conversationStore.conversationsByChannelID(channelIDForConversation: { remoteChannelID(for: $0) })
        let activeID = activeRealtimeConversationID ?? ""
        let candidates = canonicalRemotes.map { remote -> ConversationStore.HistoryPrefetchCandidate in
            let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType)
            let local = localByChannelID[channelID]
            let isActive = !activeID.isEmpty && (activeID == channelID || activeID == local?.id)
            return ConversationStore.HistoryPrefetchCandidate(
                remote: remote,
                channelID: channelID,
                local: local,
                isActive: isActive,
                latestSeq: remoteConversationLatestSeq(remote),
                sortTimestamp: remoteConversationSortTimestamp(remote, previous: local),
                logID: historyPrefetchLogID(for: remote)
            )
        }
        let targets = conversationStore.historyPrefetchTargets(candidates: candidates, limit: 6)
        guard !targets.isEmpty else {
            print("[JHT Perf] history_prefetch_complete_ms=\(Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)) success=0 failed=0 skipped=no_candidates generation=\(generation)")
            return
        }
        let prefetchPlan = conversationStore.historyPrefetchExecutionPlan(
            targets: targets,
            messageLimit: latestConversationMessageWindowLimit,
            maxConcurrent: 2
        )
        print("[JHT Perf] history_prefetch_targets generation=\(generation) targets=\(prefetchPlan.targetSummary)")
        var successCount = 0
        var failureCount = 0
        var readReceiptTargets: [(channelID: String, channelType: String)] = []

        for batch in prefetchPlan.batches {
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            let tasks = batch.map { command in
                let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: command.apiChannelID, channelType: command.channelType)
                return Task(priority: .utility) { [weak self] in
                    guard let self else {
                        return HistoryPrefetchResult(remote: command.remote, messages: [], historyBoundary: nil, boundaryGeneration: boundaryGeneration, readReceiptTarget: nil, error: nil)
                    }
                    do {
                        let page = try await self.api.syncMessages(
                            context: context,
                            channelID: command.apiChannelID,
                            channelType: command.channelType,
                            afterSeq: command.afterSeq,
                            limit: command.limit
                        )
                        let normalizedChannelType = command.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let historyBoundary = normalizedChannelType == "group"
                            ? ConversationStore.HistoryVisibilityBoundary(
                                fromSeq: page.historyVisibleFromSeq,
                                limited: page.historyLimited,
                                confirmed: true
                            )
                            : nil
                        let readReceiptTarget: ConversationStore.HistoryPrefetchReadReceiptBackfillTarget? = await MainActor.run {
                            guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return nil }
                            return self.conversationStore.historyPrefetchReadReceiptBackfillTarget(
                                for: command,
                                readReceiptsEnabled: self.fileUploadConfig.readReceiptsEnabled,
                                channelIDForConversation: { self.remoteChannelID(for: $0) }
                            )
                        }
                        return HistoryPrefetchResult(remote: command.remote, messages: page.items, historyBoundary: historyBoundary, boundaryGeneration: boundaryGeneration, readReceiptTarget: readReceiptTarget, error: nil)
                    } catch {
                        return HistoryPrefetchResult(remote: command.remote, messages: [], historyBoundary: nil, boundaryGeneration: boundaryGeneration, readReceiptTarget: nil, error: error)
                    }
                }
            }

            for task in tasks {
                let result = await task.value
                guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                guard isCurrentGroupHistoryBoundaryResponse(context: context, channelID: result.remote.channelID, channelType: result.remote.channelType, generation: result.boundaryGeneration) else { continue }
                if let error = result.error {
                    failureCount += 1
                    logSyncEndpointFailure("/api/im/sync", error: error, channelID: result.remote.channelID, channelType: result.remote.channelType)
                    if isUnauthorizedError(error) {
                        handleRemoteError(error, fallback: "聊天记录同步失败", silent: true)
                        return
                    }
                    continue
                }
                applyRemoteMessages(
                    result.messages.filter { isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: result.historyBoundary) },
                    channelID: result.remote.channelID,
                    channelType: result.remote.channelType,
                    windowRetention: .latestTail(limit: latestConversationMessageWindowLimit),
                    historyBoundary: result.historyBoundary
                )
                successCount += 1
                if let readReceiptTarget = result.readReceiptTarget {
                    readReceiptTargets.append((readReceiptTarget.channelID, readReceiptTarget.channelType))
                }
            }
        }

        if failureCount > 0 {
            print("[JHT Sync] history_partial_failed success=\(successCount) failed=\(failureCount)")
        }
        let finishedMs = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
        print("[JHT Perf] history_prefetch_complete_ms=\(finishedMs) success=\(successCount) failed=\(failureCount) targets=\(prefetchPlan.commands.count) generation=\(generation)")
        scheduleRemoteSnapshotCacheWrite(scope: scope, source: .history)

        guard !readReceiptTargets.isEmpty else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            for target in readReceiptTargets {
                guard await MainActor.run(body: {
                    self.isCurrentRemoteRefresh(refreshSession, scope: scope)
                }) else { return }
                await self.syncReadReceiptsForConversation(
                    channelID: target.channelID,
                    channelType: target.channelType,
                    session: sidecarSession
                )
            }
        }
    }

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
        let senderIdentities = currentMessageSenderIdentitySet()
        let conversationID = conversations.first(where: {
            ($0.id == command.channelID || remoteChannelID(for: $0) == command.channelID)
                && apiChannelType(for: $0.kind) == command.channelType
        })?.id
        let pendingWindow = command.channelType == "direct"
            ? conversationStore.pendingDirectReadWindow(
                channelID: command.channelID,
                senderIdentities: senderIdentities,
                channelIDForConversation: { remoteChannelID(for: $0) }
            ) : nil
        func isCurrentRequest() -> Bool {
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteRefresh(session.refreshSession, scope: session.scope),
                  context.appID == apiContext.appID,
                  context.sessionEpoch == apiContext.sessionEpoch,
                  context.imToken == apiContext.imToken,
                  senderIdentities == currentMessageSenderIdentitySet(),
                  conversationStore.isCurrentMessageReceiptsSync(claim),
                  let conversationID,
                  let conversation = conversationStore.conversation(id: conversationID) else { return false }
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
                    let previous = conversationID.flatMap { conversationStore.conversation(id: $0) }
                    setReadReceiptsEnabled(false)
                    didChange = previous != conversationID.flatMap { conversationStore.conversation(id: $0) } || didChange
                    break
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
                let previous = conversationID.flatMap { conversationStore.conversation(id: $0) }
                setReadReceiptsEnabled(false)
                didChange = previous != conversationID.flatMap { conversationStore.conversation(id: $0) } || didChange
            } else if isNotFriendsError(error),
               let conversation = conversations.first(where: { $0.id == command.channelID || remoteChannelID(for: $0) == command.channelID }) {
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
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
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
            guard let conversation = conversations.first(where: {
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
            let matches = receipt.messageID.isEmpty ? [] : conversations.filter { conversation in
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
        guard let conversation = conversations.first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else {
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
        guard let conversation = conversations.first(where: {
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
           conversations.first(where: {
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

    func applyRemoteMessages(
        _ remoteMessages: [RemoteMessage],
        channelID: String,
        channelType: String,
        fromRealtime: Bool = false,
        windowRetention: ConversationStore.MessageWindowRetention = .preserveLoadedHistory,
        historyBoundary explicitHistoryBoundary: ConversationStore.HistoryVisibilityBoundary? = nil,
        sequenceCoverageAfterSeq: Int64? = nil,
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_APPLY_OLDER_PREPEND_PARAM - 修改开始：标识更早消息分页，减少合并前本地消息全量扫描
        olderHistoryBeforeSeq: Int64? = nil,
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_APPLY_OLDER_PREPEND_PARAM - 修改结束：标识更早消息分页，减少合并前本地消息全量扫描
        scheduleSequenceRecovery: Bool = true
    ) {
        let kind = conversationKind(from: channelType, channelID: channelID)
        let existingIndex = conversations.firstIndex { conversation in
            conversation.id == channelID || remoteChannelID(for: conversation) == channelID
        }
        let previousRaw = existingIndex.map { conversations[$0] }
        let resolvedHistoryBoundary = kind == .group
            ? (explicitHistoryBoundary ?? conversationStore.historyBoundary(for: previousRaw))
            : nil
        if let resolvedHistoryBoundary {
            pruneDerivedCachesForHistoryBoundary(channelID: channelID, boundary: resolvedHistoryBoundary)
        }
        let visibleRemoteMessages = remoteMessages
            .filter { !isAnnouncementSystemMessage($0) }
            .filter { isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: resolvedHistoryBoundary) }
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
                applyHistoryVisibilityBoundaryForGroup(
                    channelID: channelID,
                    boundary: resolvedHistoryBoundary
                )
            }
            return
        }
        let previous = conversationStore.applyingHistoryVisibilityBoundary(
            resolvedHistoryBoundary,
            to: previousRaw
        )
        let normalizedChannelID = normalizedRemoteChannelID(channelID, channelType: channelType)
        let normalizedChannelType = normalizedReadWatermarkChannelType(channelID: normalizedChannelID, channelType: channelType)
        let readStateKey = conversationReadStateKey(channelID: normalizedChannelID, channelType: normalizedChannelType)
        let readWatermarkScope = currentReadWatermarkScope(channelID: normalizedChannelID, channelType: normalizedChannelType)
        let effectiveReadSeq = max(
            previous?.lastReadSeq ?? 0,
            conversationStore.effectiveReadSeq(readStateKey: readStateKey, scope: readWatermarkScope)
        )
        let previousMessages = previous?.messages ?? []
        let participants = conversationParticipants(channelID: channelID, kind: kind, previous: previous)
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
        let mergeResult = conversationStore.mergeMappedRemoteMessages(
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
            historyBoundary: resolvedHistoryBoundary
        )
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
        } else if mergeResult.sequenceRecoveryAfterSeq == nil {
            clearCompletedMessageSequenceRecovery(
                conversationID: applyResult.conversation.id,
                coveredThroughSeq: mergeResult.messageCoveredThroughSeq
            )
        }
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
    }

    func scheduleDeliveryAcksForPersistedMessages() {
        // JHT_MOD_BEGIN DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改开始：批量 ack 扫描分片执行，保留原有调度与高水位判断
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        deliveryAckSweepGeneration &+= 1
        let generation = deliveryAckSweepGeneration
        deliveryAckSweepTask?.cancel()
        deliveryAckSweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let snapshot = self.conversations
            var scannedCount = 0
            var scheduledCount = 0
            for conversation in snapshot where conversation.kind != .system {
                guard !Task.isCancelled,
                      self.deliveryAckSweepGeneration == generation,
                      self.isCurrentRemoteScope(scope) else {
                    return
                }
                scannedCount += 1
                if scannedCount > 1,
                   scannedCount % 8 == 1 {
                    guard await self.pauseDeliveryAckSweepSlice(generation: generation, scope: scope) else {
                        return
                    }
                }
                if let targetSeq = self.deliveryAckTargetSequence(for: conversation), targetSeq > 0 {
                    scheduledCount += 1
                    self.scheduleDeliveryAck(
                        conversation: conversation,
                        channelID: self.remoteChannelID(for: conversation),
                        channelSeq: targetSeq
                    )
                }
            }
            if self.deliveryAckSweepGeneration == generation {
                self.deliveryAckSweepTask = nil
            }
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMs >= 8 || scannedCount > 8 {
                print("[JHT Perf] delivery_ack_sweep_done scanned=\(scannedCount) scheduled=\(scheduledCount) elapsed_ms=\(elapsedMs)")
            }
            #endif
        }
        // JHT_MOD_END DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改开始：ack 目标 seq 单次循环计算，避免 filter/map/max 临时数组
    private func deliveryAckTargetSequence(for conversation: Conversation) -> Int64? {
        var latestIncomingSeq: Int64 = 0
        for message in conversation.messages {
            guard !message.isOutgoing,
                  message.kind != .system,
                  message.channelSeq > 0 else { continue }
            latestIncomingSeq = max(latestIncomingSeq, message.channelSeq)
        }
        guard latestIncomingSeq > 0 else { return nil }
        let coveredThrough = conversationStore.messageSequenceCoveredThrough(in: conversation)
        let targetSeq = min(latestIncomingSeq, coveredThrough)
        return targetSeq > 0 ? targetSeq : nil
    }

    private func pauseDeliveryAckSweepSlice(generation: UInt64, scope: String) async -> Bool {
        await Task.yield()
        do {
            try await Task.sleep(nanoseconds: 4_000_000)
        } catch {
            return false
        }
        return !Task.isCancelled
            && deliveryAckSweepGeneration == generation
            && isCurrentRemoteScope(scope)
    }
    // JHT_MOD_END DELIVERY_ACK_SWEEP_SLICE_PERF_20260912 - 修改结束

    private func scheduleDeliveryAck(conversation: Conversation, channelID: String, channelSeq: Int64) {
        let context = apiContext
        guard context.hasIMSession, conversation.kind != .system, channelSeq > 0 else { return }
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        guard let ticket = localMessageTicket else { return }
        let key = "\(scope)|\(channelID)"
        guard channelSeq > (deliveryAckHighWaterByScope[key] ?? 0), deliveryAckTasksByScope[key] == nil else { return }
        deliveryAckTasksByScope[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let durableSeq = try? await self.messagePersistence.recordAckDesired(
                ticket: ticket,
                channelKey: channelID,
                type: "delivery",
                desiredSeq: channelSeq
            ), durableSeq > 0 else {
                self.deliveryAckTasksByScope[key] = nil
                return
            }
            var acknowledged = false
            for delayMS in [0, 500, 1_500] {
                if delayMS > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                }
                guard !Task.isCancelled,
                      self.remoteDataScopeKey(for: self.apiContext) == scope,
                      self.isCurrentRemoteScope(scope) else { break }
                do {
                    try await self.api.deliveryAck(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        channelSeq: durableSeq
                    )
                    try? await self.messagePersistence.confirmAck(
                        ticket: ticket,
                        channelKey: channelID,
                        type: "delivery",
                        confirmedSeq: durableSeq
                    )
                    self.deliveryAckHighWaterByScope[key] = max(self.deliveryAckHighWaterByScope[key] ?? 0, durableSeq)
                    acknowledged = true
                    break
                } catch {
                    // Delivery acknowledgement is best-effort and never blocks rendering.
                }
            }
            self.deliveryAckTasksByScope[key] = nil
            if acknowledged {
                self.scheduleDeliveryAcksForPersistedMessages()
            }
        }
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
        guard let conversation = conversationStore.conversation(id: conversationID) else { return }
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
        if let updatedConversation = conversationStore.conversation(id: conversationID) {
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
        toast = "消息接口发送失败，可点击重发"
    }

    func removeMessage(messageID: String, in conversationID: String) {
        conversationStore.removeMessage(messageID: messageID, conversationID: conversationID)
    }

    private func remoteReplyQuote(from message: RemoteMessage, participants: [IMUser]) -> String? {
        if let context = remoteReplyContext(from: message, participants: participants) {
            return context.quoteText
        }
        if let topLevelQuote = sanitizedReplyComponent(message.quote) {
            return topLevelQuote
        }
        if let payloadQuote = sanitizedReplyComponent(payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"])) {
            return payloadQuote
        }

        for key in ["reply_message", "replyMessage", "quoted_message", "quoted", "reply"] {
            guard let value = message.payload[key] else { continue }
            if let quote = remoteReplyQuote(from: value, participants: participants) {
                return quote
            }
        }
        for key in ["reply_to", "replyTo"] {
            guard let replyTo = message.payload[key] else { continue }
            if case .object = replyTo, let quote = remoteReplyQuote(from: replyTo, participants: participants) {
                return quote
            }
            if let messageID = sanitizedReplyComponent(replyTo.stringValue) {
                return unavailableReplyContext(messageID: messageID).quoteText
            }
        }

        if let extra = message.payload["message_extra"]?.objectValue,
           let reply = extra["reply"],
           let quote = remoteReplyQuote(from: reply, participants: participants) {
            return quote
        }

        return nil
    }

    private func remoteReplyContext(from message: RemoteMessage, participants: [IMUser]) -> MessageReplyContext? {
        for key in ["reply_to", "replyTo"] {
            guard let replyTo = message.payload[key] else { continue }
            if replyTo.objectValue != nil,
               let context = remoteReplyContext(from: replyTo, participants: participants) {
                return context
            }
            if let messageID = sanitizedReplyComponent(replyTo.stringValue) {
                return replyContextFromQuote(message.quote ?? payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"]), messageID: messageID)
                    ?? unavailableReplyContext(messageID: messageID)
            }
        }
        for key in ["reply_message", "replyMessage", "reply", "quoted_message", "quoted"] {
            guard let value = message.payload[key],
                  let context = remoteReplyContext(from: value, participants: participants) else { continue }
            return context
        }
        if let replyID = sanitizedReplyComponent(payloadString(message.payload, ["reply_to_message_id", "reply_message_id", "quoted_message_id"])) {
            return replyContextFromQuote(message.quote ?? payloadString(message.payload, ["quote", "quote_text", "quoted_text", "reply_quote"]), messageID: replyID)
                ?? unavailableReplyContext(messageID: replyID)
        }
        if let extra = message.payload["message_extra"]?.objectValue,
           let reply = extra["reply"],
           let context = remoteReplyContext(from: reply, participants: participants) {
            return context
        }
        return nil
    }

    private func remoteReplyQuote(from value: JSONValue, participants: [IMUser]) -> String? {
        if let context = remoteReplyContext(from: value, participants: participants) {
            return context.quoteText
        }
        if let stringValue = value.stringValue {
            return sanitizedReplyComponent(stringValue)
        }
        guard let object = value.objectValue else { return nil }
        if let directQuote = sanitizedReplyComponent(payloadString(object, ["quote", "quote_text", "quoted_text"])) {
            return directQuote
        }
        if let nested = object["message"], let quote = remoteReplyQuote(from: nested, participants: participants) {
            return quote
        }

        let senderName = replySenderDisplayName(from: object, participants: participants)
        let summary = remoteReplySummary(from: object) ?? "回复了一条消息"
        guard let cleanSummary = sanitizedReplyComponent(summary) else { return nil }
        guard let cleanSender = sanitizedReplyComponent(senderName), !cleanSender.isEmpty else {
            return cleanSummary
        }
        if cleanSummary.hasPrefix("\(cleanSender)：") || cleanSummary.hasPrefix("\(cleanSender):") {
            return cleanSummary
        }
        return "\(cleanSender)：\(cleanSummary)"
    }

    private func remoteReplyContext(from value: JSONValue, participants: [IMUser]) -> MessageReplyContext? {
        if let stringValue = value.stringValue {
            return replyContextFromQuote(stringValue)
        }
        guard let object = value.objectValue else { return nil }
        if let nested = object["message"],
           let context = remoteReplyContext(from: nested, participants: participants) {
            return context
        }
        let messageID = payloadString(object, ["message_id", "id", "msg_id", "reply_to_message_id", "reply_message_id", "quoted_message_id"])
        let senderID = payloadString(object, ["from_uid", "sender_uid", "sender_user_id", "from_user_id", "im_uid", "user_id"])
        let senderName = replySenderDisplayName(from: object, participants: participants)
        let status = payloadString(object, ["status", "message_status"]).lowercased()
        let isUnavailable = ["deleted", "recalled", "removed", "invisible"].contains(status)
        let summary = remoteReplySummary(from: object)
            ?? sanitizedReplyComponent(payloadString(object, ["quote", "quote_text", "quoted_text", "reply_quote"]))
            ?? (isUnavailable ? "原消息不可查看/已撤回" : "回复了一条消息")
        let contentType = payloadString(object, ["content_type", "type", "kind", "media_category", "category", "preview_kind"])
        let channelSeq = payloadInt64(object, ["channel_seq", "seq"]) ?? 0
        return MessageReplyContext(
            messageID: messageID,
            senderID: senderID,
            senderName: senderName,
            summary: summary,
            contentType: contentType,
            channelSeq: channelSeq,
            isUnavailable: isUnavailable,
            thumbnailURL: payloadString(object, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"])
        )
    }

    private func replyContextFromQuote(_ quote: String?, messageID: String = "") -> MessageReplyContext? {
        guard let cleanQuote = sanitizedReplyComponent(quote) else { return nil }
        for separator in ["：", ":"] {
            if let range = cleanQuote.range(of: separator) {
                let sender = String(cleanQuote[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = String(cleanQuote[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    return MessageReplyContext(messageID: messageID, senderName: sender, summary: summary)
                }
            }
        }
        return MessageReplyContext(messageID: messageID, summary: cleanQuote)
    }

    private func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

    private func remoteReplySummary(from object: [String: JSONValue]) -> String? {
        if isStickerPayload(object, contentType: payloadString(object, ["content_type", "type"])) {
            return stickerFallbackText(from: object)
        }
        if let text = sanitizedReplyComponent(payloadString(object, ["text", "content", "body", "message_text", "original_text", "display_text", "summary", "preview", "quote", "quote_text", "quoted_text", "reply_quote"])) {
            return text
        }

        let contentType = payloadString(object, ["content_type", "type", "mime_type"])
        let kind = payloadString(object, ["kind", "media_category", "category", "preview_kind"])
        let normalizedType = "\(contentType) \(kind)".lowercased()
        let fileName = sanitizedReplyComponent(payloadString(object, ["file_name", "name", "filename", "attachment_name"]))
        if normalizedType.contains("image") || normalizedType.contains("photo") {
            return "[图片]"
        }
        if normalizedType.contains("video") || normalizedType.contains("movie") {
            return "[视频]"
        }
        if normalizedType.contains("voice") || normalizedType.contains("audio") {
            return "[语音]"
        }
        if normalizedType.contains("contact") || normalizedType.contains("card") {
            return "[名片] \(fileName ?? "联系人")"
        }
        if normalizedType.contains("file") || normalizedType.contains("pdf") || normalizedType.contains("download") || fileName != nil {
            if let fileName {
                return "[文件] \(fileName)"
            }
            return "[文件]"
        }
        return nil
    }

    private func replySenderDisplayName(from object: [String: JSONValue], participants: [IMUser]) -> String {
        let payloadName = payloadString(
            object,
            ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "display_name", "nickname", "user_name"]
        )
        if !payloadName.isEmpty {
            return payloadName
        }
        let senderID = payloadString(object, ["from_uid", "sender_uid", "sender_user_id", "from_user_id", "im_uid", "user_id"])
        guard !senderID.isEmpty else { return "" }
        let knownUser = user(for: senderID) ?? participants.first { user in
            user.id == senderID || user.userID == senderID || user.username == senderID
        }
        if let knownUser {
            let name = knownUser.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !isIdentifierLikeDisplayName(name, matching: senderID) {
                return name
            }
        }
        return senderID
    }

    private func sanitizedReplyComponent(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 180 {
            return collapsed
        }
        let index = collapsed.index(collapsed.startIndex, offsetBy: 180)
        return "\(collapsed[..<index])…"
    }

    private func rtcMessageDisplayTime(_ remote: RemoteMessage) -> String {
        let record = remote.channelSeq > 0 && !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RTCCallRecordPayload.parse(contentType: remote.contentType, channelType: remote.channelType, fromUID: remote.fromUID, payload: remote.payload)
            : nil
        let date = RTCCallRecordTimeProjection.messageDate(
            outerDate: parseRemoteDate(remote.createdAt),
            record: record,
            contentType: remote.contentType,
            channelType: remote.channelType,
            fromUID: remote.fromUID
        )
        return date.map { displayTime($0) } ?? "时间未知"
    }

    func chatMessage(from remote: RemoteMessage, participants: [IMUser] = [], forceOutgoing: Bool = false) -> ChatMessage {
        let isOutgoing = forceOutgoing || isRemoteMessageFromCurrentUser(remote)
        let kind = remoteMessageKind(from: remote)
        let rtcCallRecord: RTCCallRecordPayload? = {
            guard remote.channelSeq > 0,
                  !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return RTCCallRecordPayload.parse(
                contentType: remote.contentType,
                channelType: remote.channelType,
                fromUID: remote.fromUID,
                payload: remote.payload
            )
        }()
        let isAdminDeleted = isAdminDeletedRemoteMessage(remote)
        let isContactCard = kind == .contactCard
        let isAttachment = kind == .image || kind == .video || kind == .file || kind == .voice
        let stickerSnapshot = stickerSnapshot(from: remote)
        let attachmentFileName = attachmentPayloadString(remote.payload, ["file_name", "name", "filename"])
        let attachmentMimeType = attachmentPayloadString(remote.payload, ["mime_type", "content_type"])
        let attachmentSizeBytes = attachmentPayloadInt64(remote.payload, ["size_bytes", "size"])
        let attachmentObjectKey = attachmentPayloadString(remote.payload, ["thumb_object_key", "thumbnail_object_key", "object_key"])
        let attachmentCacheKey = attachmentPayloadString(remote.payload, ["cache_key", "cacheKey"], fallback: attachmentObjectKey)
        let attachmentVersion = attachmentPayloadString(remote.payload, ["version", "file_version", "cache_version"])
        let attachmentChecksum = attachmentPayloadString(remote.payload, ["checksum"])
        let attachmentMediaCategory = attachmentPayloadString(remote.payload, ["media_category", "category", "kind"])
        let attachmentExtension = attachmentPayloadString(remote.payload, ["extension", "ext", "file_extension"])
        let attachmentThumbnailURL = attachmentPayloadString(remote.payload, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"])
        let attachmentPosterURL = attachmentPayloadString(remote.payload, ["poster_url", "video_poster_url"])
        let attachmentCoverURL = attachmentPayloadString(remote.payload, ["cover_url", "video_cover_url"])
        let attachmentPreviewKind = attachmentPayloadString(remote.payload, ["preview_kind"])
        let attachmentContentDisposition = attachmentPayloadString(remote.payload, ["content_disposition", "disposition"])
        let attachmentWidth = attachmentPayloadInt64(remote.payload, ["width"]).map(Int.init)
        let attachmentHeight = attachmentPayloadInt64(remote.payload, ["height"]).map(Int.init)
        let attachmentDurationSeconds = attachmentDuration(from: remote.payload)
        let attachmentWaveform = kind == .voice ? attachmentWaveform(from: remote.payload) : []
        let attachmentUploadStatus = attachmentPayloadString(remote.payload, ["attachment_status", "upload_status", "status"])
        let attachmentPreviewURL = attachmentPayloadString(remote.payload, ["preview_url", "preview_public"])
        let attachmentDownloadURL = attachmentPayloadString(remote.payload, ["download_url", "download_public"])
        let replyContext = remoteReplyContext(from: remote, participants: participants)
        let replyQuote = replyContext?.quoteText ?? remoteReplyQuote(from: remote, participants: participants)
        let attachmentPreviewAvailable = attachmentPreviewAllowed(
            previewURL: attachmentPreviewURL,
            previewKind: attachmentPreviewKind,
            contentDisposition: attachmentContentDisposition,
            backendAvailable: attachmentPayloadBool(remote.payload, ["preview_available"])
        )
        let attachmentMeta = isContactCard
            ? contactCardUID(from: remote)
            : (isAttachment ? attachmentMeta(kind: kind, mimeType: attachmentMimeType, sizeBytes: attachmentSizeBytes) : nil)
        let senderID = forceOutgoing && remote.fromUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localOutgoingMessageSenderID()
            : remote.fromUID
        let senderName = senderDisplayName(for: remote, isOutgoing: isOutgoing, kind: kind, participants: participants)
        let senderAvatarSnapshot = senderAvatarSnapshot(
            for: remote,
            senderID: senderID,
            isOutgoing: isOutgoing,
            participants: participants
        )
        var message = ChatMessage(
            id: remote.messageID,
            senderId: senderID,
            senderProvenance: remote.senderProvenance,
            senderName: senderName,
            senderAvatarURL: senderAvatarSnapshot.avatarURL,
            senderAvatarVersion: senderAvatarSnapshot.avatarVersion,
            senderAvatarUpdatedAt: senderAvatarSnapshot.avatarUpdatedAt,
            senderAvatarSeed: senderAvatarSnapshot.avatarSeed,
            text: messagePreview(remote, participants: participants),
            time: kind == .rtcCallRecord ? rtcMessageDisplayTime(remote) : displayTime(remote.createdAt),
            createdAt: parseRemoteDate(remote.createdAt),
            channelSeq: remote.channelSeq,
            isOutgoing: isOutgoing,
            status: isOutgoing ? .sent : .read,
            kind: kind,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: replyQuote,
            attachmentName: isContactCard ? contactCardName(from: remote) : (isAttachment ? attachmentFileName : nil),
            attachmentMeta: attachmentMeta,
            attachmentFileID: isAttachment ? encodedAttachmentResourceID(from: remote.payload) : nil,
            attachmentSizeBytes: isAttachment ? attachmentSizeBytes : nil,
            attachmentPreviewURL: isAttachment ? attachmentPreviewURL : "",
            attachmentDownloadURL: isAttachment ? attachmentDownloadURL : "",
            attachmentPreviewAvailable: isAttachment && attachmentPreviewAvailable,
            attachmentDownloadAvailable: isAttachment && (attachmentPayloadBool(remote.payload, ["download_available"]) ?? (!attachmentDownloadURL.isEmpty || !(attachmentPayloadString(remote.payload, ["file_id", "attachment_id", "media_id", "id"]).isEmpty))),
            mentionExcluded: kind == .system || remote.payload["mention_excluded"]?.boolValue == true,
            mentionAll: remoteMessageMentionsAll(remote),
            systemEventType: remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue,
            systemDisplayStyle: remote.payload["display_style"]?.stringValue,
            systemColorToken: remote.payload["color_token"]?.stringValue,
            systemTextColorHex: remote.payload["text_color"]?.stringValue,
            systemBackgroundColorHex: remote.payload["background_color"]?.stringValue,
            systemAccentColorHex: remote.payload["accent_color"]?.stringValue,
            groupInviteApproval: groupInviteApproval(from: remote.payload, kind: remote.payload["kind"]?.stringValue ?? remote.payload["event_type"]?.stringValue ?? remote.payload["event"]?.stringValue ?? "", fallbackTitle: messagePreview(remote, participants: participants))
        )
        message.replyContext = replyContext ?? replyContextFromQuote(replyQuote)
        message.contentType = remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.contentType.isEmpty, stickerSnapshot != nil {
            message.contentType = "sticker"
        }
        message.stickerSnapshot = stickerSnapshot
        message.rtcCallRecord = rtcCallRecord
        if isAdminDeleted {
            conversationStore.markMessageAsAdminDeleted(&message)
        } else if ["recalled", "revoked"].contains(remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            // 服务端撤回只改消息本体 status,payload 仍保留原文。冷读(历史分页/
            // 重进会话)不能依赖 message-extras 补丁——extras 只按 after_version=0
            // 拉前 100 条,活跃频道(反应/置顶也是 extra)很容易越界。必须在映射
            // 阶段就按撤回墓碑处理,否则其他用户回看会看到已撤回消息的原文。
            conversationStore.markMessageAsRecalledFromRemoteStatus(&message)
        }
        message.isEdited = remote.isEdited
		message.editRevision = remote.editRevision
        if isAttachment && !isAdminDeleted {
            message.attachmentMimeType = attachmentMimeType
            message.attachmentCacheKey = attachmentCacheKey
            message.attachmentVersion = attachmentVersion
            message.attachmentChecksum = attachmentChecksum
            message.attachmentMediaCategory = attachmentMediaCategory
            message.attachmentExtension = attachmentExtension
            message.attachmentThumbnailURL = attachmentThumbnailURL
            message.attachmentPosterURL = attachmentPosterURL
            message.attachmentCoverURL = attachmentCoverURL
            message.attachmentPreviewKind = attachmentPreviewKind
            message.attachmentContentDisposition = attachmentContentDisposition
            message.attachmentWidth = attachmentWidth
            message.attachmentHeight = attachmentHeight
            message.attachmentDurationSeconds = attachmentDurationSeconds
            message.voiceWaveform = attachmentWaveform
            message.attachmentUploadStatus = attachmentUploadStatus
        }
        message.mentionedUsers = remoteMentionIdentities(from: remote)
        applyRemoteReadSummary(from: remote, to: &message)
        return message
    }

    func messagePreview(_ message: RemoteMessage, participants: [IMUser] = []) -> String {
        if isAdminDeletedRemoteMessage(message) {
            return "原消息已删除"
        }
        if message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
            if let record = RTCCallRecordPayload.parse(
                contentType: message.contentType,
                channelType: message.channelType,
                fromUID: message.fromUID,
                payload: message.payload
            ) {
                return record.presentation(
                    viewerIsCaller: isRemoteMessageFromCurrentUser(message)
                ).conversationPreview
            }
            return RTCCallRecordPayload.safeFallbackText(payload: message.payload)
        }
        if isSystemRemoteMessage(message) {
            if let groupEventText = groupMembershipSystemPreview(message, participants: participants) {
                return groupEventText
            }
            let text = payloadString(message.payload, ["text", "content", "body"])
            if !text.isEmpty { return text }
            let event = payloadString(message.payload, ["event_type", "event"])
            return event.isEmpty ? "群成员变更" : "群成员变更：\(event)"
        }
        if isContactCardRemoteMessage(message) {
            return contactCardPreviewDisplayName(from: message).map { "个人名片：\($0)" }
                ?? message.payload["text"]?.stringValue
                ?? message.payload["content"]?.stringValue
                ?? "个人名片"
        }
        if message.contentType == "contact_card" {
            return contactCardPreviewDisplayName(from: message).map { "个人名片：\($0)" }
                ?? message.payload["text"]?.stringValue
                ?? "个人名片"
        }
        if remoteMessageKind(from: message) == .voice {
            if let durationSeconds = attachmentDuration(from: message.payload), durationSeconds > 0 {
                return VoiceMessagePayload.durationLabel(durationMS: Int((durationSeconds * 1_000).rounded()))
            }
            return ""
        }
        if isStickerPayload(message.payload, contentType: message.contentType) {
            return stickerFallbackText(from: message.payload)
        }
        return message.payload["text"]?.stringValue
        ?? message.payload["content"]?.stringValue
        ?? message.payload["body"]?.stringValue
        ?? message.payload["file_name"]?.stringValue
        ?? "[\(message.contentType)]"
    }

    #if DEBUG
    func debugConfigureRegistrationResolutionScreenshotScenarioForTesting(_ rawValue: String) -> Bool {
        configureRegistrationResolutionScreenshotScenarioIfRequested([
            "--registration-resolution-screenshot=\(rawValue)"
        ])
    }

    func debugConfigureLicenseQuotaScreenshotScenarioForTesting(_ rawValue: String) -> Bool {
        configureLicenseQuotaScreenshotScenarioIfRequested([
            "--license-quota-screenshot=\(rawValue)"
        ])
    }

    func debugMessagePreviewForTesting(_ message: RemoteMessage, participants: [IMUser] = []) -> String {
        messagePreview(message, participants: participants)
    }

    func debugChatMessageForTesting(_ message: RemoteMessage, participants: [IMUser] = []) -> ChatMessage {
        chatMessage(from: message, participants: participants)
    }

    func debugHandleRealtimeEnvelopeForTesting(_ envelope: RealtimeEnvelope) {
        handleRealtimeEnvelope(envelope)
    }

    func debugApplyRemoteGroupsForTesting(_ remoteGroups: [RemoteUserGroup]) {
        applyRemoteGroups(remoteGroups)
    }

    func debugApplyRemoteConversationsForTesting(
        _ remoteConversations: [RemoteConversation],
        replacing: Bool = true
    ) {
        applyRemoteConversations(remoteConversations, replacing: replacing)
    }

    func debugResetAvatarRealtimeAssetResolutionCountForTesting() {
        avatarRealtimeAssetResolutionCountForTesting = 0
    }

    func debugAvatarRealtimeAssetResolutionCountForTesting() -> Int {
        avatarRealtimeAssetResolutionCountForTesting
    }

    func debugReapplyAllAvatarRealtimeProjectionsForTesting() {
        reapplyAllAvatarRealtimeProjections()
    }

    func debugApplyAvatarRealtimeProjectionsForTesting(_ projections: [AvatarRealtimeProjectionValue]) {
        applyAvatarRealtimeProjections(projections)
    }

    func debugHandleRemoteErrorForTesting(_ error: Error, fallback: String = "操作失败") {
        handleRemoteError(error, fallback: fallback)
    }

    func debugHasIMSessionForTesting() -> Bool {
        apiContext.hasIMSession
    }

    func debugMinimumGroupMemberProfileGenerationForTesting(groupID: String) -> Int64 {
        minimumGroupMemberProfileGenerationByScopedGroupKey[
            groupMemberProfileCacheKey(groupID: groupID)
        ] ?? 0
    }

    func debugApplyGroupMembersResultForTesting(
        _ result: RemoteGroupMembersResult,
        groupID: String,
        profileGenerationAtRequestStart: Int64? = nil
    ) {
        applyGroupMembers(
            result.items,
            selfMember: result.selfMember,
            total: result.total,
            groupID: groupID,
            partial: result.hasMore == true,
            nextOffset: result.nextOffset,
            nextCursor: result.nextCursor,
            profileGenerationAtRequestStart: profileGenerationAtRequestStart
        )
    }

    func debugApplyMyGroupMemberProfileForTesting(
        _ profile: RemoteGroupMemberProfile,
        fallbackGroupID: String
    ) {
        applyMyGroupMemberProfile(profile, fallbackGroupID: fallbackGroupID)
    }
    #endif

    // Group membership system preview helpers are split to Core/AppSupport/MessageMapping/AppState+GroupSystemMessagePresentation.swift.

    private func senderDisplayName(for message: RemoteMessage, isOutgoing: Bool, kind: MessageKind, participants: [IMUser]) -> String {
        if kind == .system { return "系统" }

        let senderID = message.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotName = payloadString(message.payload, ["sender_snapshot_name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !snapshotName.isEmpty, !isIdentifierLikeDisplayName(snapshotName, matching: senderID) {
            return snapshotName
        }
        if isOutgoing { return currentUser.name }
        let payloadName = payloadString(
            message.payload,
            ["sender_display_name", "sender_name", "sender_nickname", "from_name", "from_nickname", "nickname", "display_name", "user_name"]
        )
        let topLevelName = message.senderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteName = !topLevelName.isEmpty ? topLevelName : payloadName
        if !remoteName.isEmpty, !isIdentifierLikeDisplayName(remoteName, matching: senderID) {
            return remoteName
        }
        let knownUser = knownSenderUser(for: senderID, participants: participants)
        if let knownUser {
            let knownName = knownUser.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifiers = [senderID, knownUser.id, knownUser.userID, knownUser.username]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if contactRemarkValue(matching: identifiers) == nil, !knownName.isEmpty {
                return knownName
            }
        }
        return senderID.isEmpty ? "未知用户" : senderID
    }

    // Identity, conversation title, and pure formatting bridges are split to Core/AppSupport/MessageMapping/AppState+IdentityPresentation.swift.
}
