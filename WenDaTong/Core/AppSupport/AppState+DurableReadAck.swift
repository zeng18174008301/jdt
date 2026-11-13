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
    func prepareDurableReadAckTicket(
        conversation: ConversationMessageSnapshot,
        context: IMAPIContext,
        scope: String
    ) async throws -> LocalMessageSessionTicket {
        let generation = localMessageSessionGeneration
        guard isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let ticket: LocalMessageSessionTicket
        if let localMessageTicket {
            ticket = localMessageTicket
        } else {
            ticket = try await messagePersistence.ensureTicket(
                context: context,
                sessionGeneration: generation
            )
        }
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope),
              ticket.sessionGeneration == generation else {
            throw LocalMessageDatabaseError.staleSession
        }
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        let snapshot = localMessageSnapshot(
            from: cacheableConversation,
            actorID: (context.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            projectedMessages: cacheableConversation.messages
        )
        _ = try await messagePersistence.persist(
            ticket: ticket,
            snapshots: [snapshot],
            source: .localMutation,
            revision: nextLocalMessageProjectionRevision(),
            replaceMissingConversations: false
        )
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        return ticket
    }

    private func conversationForDurableReadAck(channelID: String) -> ConversationMessageSnapshot? {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return nil }
        return conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.kind != .system
                && remoteChannelID(for: conversation) == normalizedChannelID
        }
    }

    @discardableResult
    func scheduleDurableReadAckRecovery(
        ticket: LocalMessageSessionTicket,
        runImmediately: Bool = false,
        requiresActiveScene: Bool = true
    ) -> Task<Void, Never>? {
        guard (!requiresActiveScene || iosRiskTelemetrySceneIsActive),
              isAuthenticated,
              apiContext.hasIMSession,
              localMessageTicket?.scopeHash == ticket.scopeHash else { return nil }
        if let durableReadAckRecoveryTask {
            if durableReadAckRecoveryTask.isCancelled {
                durableReadAckRecoveryRestartRequested = true
            }
            return durableReadAckRecoveryTask
        }
        let scope = remoteDataScopeKey(for: apiContext)
        durableReadAckRecoveryGeneration &+= 1
        let generation = durableReadAckRecoveryGeneration
        durableReadAckRecoveryRestartRequested = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDurableReadAckRecoveryLoop(
                ticket: ticket,
                scope: scope,
                runImmediately: runImmediately,
                requiresActiveScene: requiresActiveScene
            )
            self.finishDurableReadAckRecovery(
                generation: generation,
                ticket: ticket,
                requiresActiveScene: requiresActiveScene
            )
        }
        durableReadAckRecoveryTask = task
        return task
    }

    private func durableReadAckRecoveryIsEligible(
        ticket: LocalMessageSessionTicket,
        scope: String,
        requiresActiveScene: Bool
    ) -> Bool {
        !Task.isCancelled
            && (!requiresActiveScene || iosRiskTelemetrySceneIsActive)
            && isAuthenticated
            && apiContext.hasIMSession
            && isCurrentRemoteScope(scope)
            && localMessageTicket?.scopeHash == ticket.scopeHash
    }

    private func runDurableReadAckRecoveryLoop(
        ticket: LocalMessageSessionTicket,
        scope: String,
        runImmediately: Bool,
        requiresActiveScene: Bool
    ) async {
        _ = runImmediately
        while durableReadAckRecoveryIsEligible(
            ticket: ticket,
            scope: scope,
            requiresActiveScene: requiresActiveScene
        ) {
            let recoverable: [LocalMessagePendingAck]
            do {
                recoverable = try await messagePersistence.recoverableAcks(
                    ticket: ticket,
                    type: "read"
                )
            } catch {
                return
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ), !recoverable.isEmpty else { return }
            let nextRetryAt = recoverable.compactMap(\.retryAt).min()
                ?? Date().timeIntervalSince1970
            let delay = max(0, nextRetryAt - Date().timeIntervalSince1970)
            if delay > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(min(delay, 60) * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ) else { return }
            let items: [LocalMessagePendingAck]
            do {
                items = try await messagePersistence.claimAcksForRetry(
                    ticket: ticket,
                    type: "read",
                    limit: 1
                )
            } catch {
                return
            }
            guard let item = items.first else {
                await Task.yield()
                continue
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ) else {
                try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    claimedSeq: item.desiredSeq,
                    claimedAttemptCount: item.attemptCount
                )
                return
            }
            guard let conversation = conversationForDurableReadAck(channelID: item.channelID) else {
                try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    claimedSeq: item.desiredSeq,
                    claimedAttemptCount: item.attemptCount
                )
                continue
            }
            _ = await sendDurableReadAck(
                item,
                ticket: ticket,
                conversation: conversation,
                context: apiContext,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            )
        }
    }

    private func finishDurableReadAckRecovery(
        generation: UInt64,
        ticket: LocalMessageSessionTicket,
        requiresActiveScene: Bool
    ) {
        guard durableReadAckRecoveryGeneration == generation else { return }
        durableReadAckRecoveryTask = nil
        let shouldRestart = durableReadAckRecoveryRestartRequested
        durableReadAckRecoveryRestartRequested = false
        if shouldRestart {
            scheduleDurableReadAckRecovery(
                ticket: ticket,
                runImmediately: true,
                requiresActiveScene: requiresActiveScene
            )
        }
    }

#if DEBUG
    func recoverDurableReadAcksForTesting(requiresActiveScene: Bool = false) async {
        guard let ticket = localMessageTicket else { return }
        let task = scheduleDurableReadAckRecovery(
            ticket: ticket,
            runImmediately: true,
            requiresActiveScene: requiresActiveScene
        )
        await task?.value
    }
#endif

    @discardableResult
    func sendDurableReadAck(
        _ item: LocalMessagePendingAck,
        ticket: LocalMessageSessionTicket,
        conversation: ConversationMessageSnapshot,
        context: IMAPIContext,
        scope: String,
        requiresActiveScene: Bool = false
    ) async -> Bool {
        guard durableReadAckRecoveryIsEligible(
            ticket: ticket,
            scope: scope,
            requiresActiveScene: requiresActiveScene
        ) else {
            try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                ticket: ticket,
                channelKey: item.channelID,
                type: item.type,
                claimedSeq: item.desiredSeq,
                claimedAttemptCount: item.attemptCount
            )
            return false
        }
        do {
            let response = try await api.readAck(
                context: context,
                conversation: conversation,
                channelID: item.channelID,
                throughSeq: item.desiredSeq
            )
            guard isCurrentRemoteScope(scope),
                  localMessageTicket?.scopeHash == ticket.scopeHash else { return false }
            applyRemoteReadReceipts(
                response.readReceipts,
                channelID: response.channelID.isEmpty ? item.channelID : response.channelID
            )
            let confirmedSeq = max(0, response.lastReadSeq ?? 0)
            if confirmedSeq > 0 {
                try await messagePersistence.confirmAck(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    confirmedSeq: confirmedSeq
                )
                guard isCurrentRemoteScope(scope), localMessageTicket == ticket else { return false }
                conversationStore.advanceRead(
                    conversationID: conversation.id,
                    through: confirmedSeq
                )
                let effectiveReadSeq = rememberConversationReadLocally(
                    conversation,
                    through: confirmedSeq
                )
                cancelLocalNotificationsForCurrentRead(
                    channelID: item.channelID,
                    channelType: apiChannelType(for: conversation.kind),
                    throughSeq: effectiveReadSeq
                )
                await persistConversationSnapshotImmediately(
                    conversationID: conversation.id, scope: scope, source: .localMutation
                )
                guard isCurrentRemoteScope(scope), localMessageTicket == ticket else { return false }
            }
            guard confirmedSeq >= item.desiredSeq else {
                try? await messagePersistence.releaseAckForRetry(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type
                )
                return false
            }
            return true
        } catch {
            try? await messagePersistence.releaseAckForRetry(
                ticket: ticket,
                channelKey: item.channelID,
                type: item.type
            )
            return false
        }
    }

    func cachedConversationsApplyingConfirmedReads(
        _ cachedConversations: [ConversationMessageSnapshot],
        confirmedReads: [String: Int64]
    ) -> [ConversationMessageSnapshot] {
        let lookup = confirmedReads.isEmpty ? nil : makeConversationUserLookup()
        return cachedConversations.map { cached in
            guard cached.kind != .system else { return cached }
            var conversation = cached
            let confirmedSeq = lookup.flatMap {
                confirmedReads[remoteChannelID(for: cached, lookup: $0)]
            } ?? 0
            if confirmedSeq > 0 {
                _ = rememberConversationReadLocally(cached, through: confirmedSeq)
                conversationStore.advanceRead(in: &conversation, through: confirmedSeq, restoringConfirmedRead: true)
            }
            let readSeq = max(conversation.lastReadSeq, confirmedSeq)
            let tailSeq = max(conversation.lastMsgSeq, ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0)
            let messageUnread = boundedConversationMessageUnreadCount(
                conversation.unread, lastMsgSeq: tailSeq, lastReadSeq: readSeq
            )
            let reactionUnread = max(conversation.unreadReactionCount, conversation.hasUnreadReaction ? 1 : 0)
            conversation.unread = max(messageUnread, reactionUnread)
            if tailSeq > 0, readSeq >= tailSeq {
                conversation.firstUnreadSeq = 0
                conversation.firstUnreadMessageID = ""
                conversation.unreadAnchorSeq = 0
                conversation.unreadAnchorState = "none"
            }
            return conversation
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
