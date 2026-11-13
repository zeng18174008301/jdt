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

extension AppState {
    func applyCachedRemoteSnapshotIfAvailable(context: IMAPIContext) async -> Bool {
        guard context.hasIMSession else { return false }
        let scope = remoteDataScopeKey(for: context)
        profileContactRevisionFence.rebind(scopeHash: scope)
        let profileContactReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        let generation = localMessageSessionGeneration
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
        var policySnapshot = tenantClientPolicyStore.snapshot
        policySnapshot.groupCountResolution = .unresolved(
            scope: scope,
            minimumGeneration: minimumGroupMemberCountPolicyGenerationByScope[scope] ?? 0
        )
        if let stored = GroupMemberCountVisibilityStore.load(scope: scope),
           !stored.showGroupMemberCount {
            policySnapshot.policyScope = scope
            policySnapshot.policy = RemoteTenantClientPolicy(
                showGroupMemberCount: false,
                groupMemberCountPolicyGeneration: stored.generation,
                groupMemberCountContractVersion: stored.contractVersion
            )
        }
        tenantClientPolicyStore.snapshot = policySnapshot
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        var confirmedReads: [String: Int64] = [:]
        do {
            let loaded = try await messagePersistence.activateAndLoad(
                context: context,
                sessionGeneration: generation,
                conversationLimit: 1_200,
                messagesPerConversation: 50
            )
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteScope(scope) else {
                return false
            }
            localMessageTicket = loaded.ticket
            let readStates = (try? await messagePersistence.ackStates(ticket: loaded.ticket, type: "read")) ?? []
            guard generation == localMessageSessionGeneration,
                  isCurrentRemoteScope(scope), localMessageTicket == loaded.ticket else {
                return false
            }
            for state in readStates where state.confirmedSeq > 0 {
                confirmedReads[state.channelID] = max(confirmedReads[state.channelID] ?? 0, state.confirmedSeq)
            }
            applyCachedProfileContactProjection(
                loaded.profileContactProjection,
                scope: scope,
                readStamp: profileContactReadStamp
            )
            if !loaded.conversations.isEmpty {
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: keep cached restore mapping off MainActor; publish/store mutations stay below.
                let safeCachedConversations = await CachedConversationRestoreBuilder.scrubbedModelsPreparedForLocalHistoryProjectionOffMain(
                    from: loaded.conversations
                )
                guard generation == localMessageSessionGeneration,
                      isCurrentRemoteScope(scope) else {
                    return false
                }
                // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END
                let visibleCachedConversations = visibleConversationsAfterLocalHiding(
                    safeCachedConversations,
                    scope: scope
                )
                let readReconciledConversations = cachedConversationsApplyingConfirmedReads(
                    visibleCachedConversations, confirmedReads: confirmedReads
                )
                _ = conversationStore.hydrateCachedConversations(readReconciledConversations)
                refreshDirectConversationDisplayNames()
                pruneNonFriendDirectConversations()
                syncAttachmentFilesFromConversations(visibleCachedConversations)
                bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                await recoverDurableOutbox(ticket: loaded.ticket, scope: scope)
                scheduleDurableReadAckRecovery(ticket: loaded.ticket, runImmediately: true)
                if loaded.pendingOutbox.isEmpty {
                    scheduleDurableOutboxRecovery(ticket: loaded.ticket)
                }
                return true
            }
        } catch {
            localMessageTicket = nil
        }

        guard let loaded = await messageStore.load(scope: scope) else { return false }
        guard isCurrentRemoteScope(scope) else {
            print("[JHT Perf] cached_snapshot_drop reason=stale_scope scope=\(Self.sessionScopeLogToken(scope))")
            return false
        }
        // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_BEGIN: keep legacy cached restore mapping off MainActor; publish/store mutations stay below.
        let safeCachedConversations = await CachedConversationRestoreBuilder.scrubbedConversationsPreparedForLocalHistoryProjectionOffMain(
            loaded.conversations
        )
        guard isCurrentRemoteScope(scope) else {
            print("[JHT Perf] cached_snapshot_drop reason=stale_scope_after_restore scope=\(Self.sessionScopeLogToken(scope))")
            return false
        }
        // WDT_LOGIN_WORKSPACE_MAINACTOR_PERF_20260924_END
        let visibleCachedConversations = cachedConversationsApplyingConfirmedReads(
            visibleConversationsAfterLocalHiding(safeCachedConversations, scope: scope),
            confirmedReads: confirmedReads
        )
        let cachedConversationCount = conversationStore.hydrateCachedConversations(visibleCachedConversations)
        syncAttachmentFilesFromConversations(visibleCachedConversations)
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        if let ticket = localMessageTicket,
           generation == localMessageSessionGeneration {
            let snapshots = LegacySnapshotImporter.snapshots(
                from: visibleCachedConversations,
                channelResolver: { conversation in
                    (
                        self.remoteChannelID(for: conversation),
                        self.apiChannelType(for: conversation.kind)
                    )
                },
                currentActorID: context.imUID ?? ""
            )
            let revision = nextLocalMessageProjectionRevision()
            do {
                let imported = try await messagePersistence.importLegacy(
                    ticket: ticket,
                    snapshots: snapshots,
                    revision: revision
                )
                guard imported,
                      generation == localMessageSessionGeneration,
                      isCurrentRemoteScope(scope) else { return true }
                messageStore.remove(scope: scope)
            } catch {
                // Keep the legacy snapshot intact. Online authority will rebuild the database.
            }
        }
        print("[JHT Perf] cached_snapshot_applied count=\(cachedConversationCount) scope=\(Self.sessionScopeLogToken(scope)) read_ms=\(loaded.readMs) decode_ms=\(loaded.decodeMs) map_sort_ms=\(loaded.mapSortMs)")
        return true
    }

    func recoverDurableOutbox(
        ticket: LocalMessageSessionTicket,
        scope: String
    ) async {
        guard isCurrentRemoteScope(scope), localMessageTicket == ticket else { return }
        let items: [LocalMessageRecoveredOutbox]
        do {
            items = try await messagePersistence.claimOutboxForReplay(
                ticket: ticket,
                authorizationGeneration: ticket.sessionGeneration,
                trigger: .automatic,
                clientMessageID: nil,
                limit: 20,
                holdLegacyUnconfirmedSends: usesProtectedMessageSends // WDT_IOS1_HTTP_ROUTE_V5_20261113
            )
        } catch {
            return
        }
        guard isCurrentRemoteScope(scope), localMessageTicket?.scopeHash == ticket.scopeHash else { return }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        if let pending = try? await messagePersistence.recoverableOutbox(ticket: ticket) {
            guard isCurrentRemoteScope(scope), localMessageTicket == ticket else { return }
            scheduleOutgoingConfirmations(ticket: ticket, pending: pending)
        }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        for item in items {
            guard isCurrentRemoteScope(scope) else { continue }
            let message = item.message.model
            if conversationStore.conversationMessageSnapshot(id: item.conversationID)?
                .messages.contains(where: { $0.id == item.clientMessageID }) != true {
                _ = conversationStore.appendLocalOutgoingMessage(
                    message,
                    to: item.conversationID
                )
            }
            if message.kind == .image || message.kind == .file || message.kind == .voice {
                do {
                    let data: Data?
                    let fileURL: URL?
                    if message.kind == .voice {
                        data = try await messagePersistence.loadStagedAttachment(
                            ticket: ticket,
                            item: item
                        )
                        fileURL = nil
                    } else {
                        data = nil
                        fileURL = try await messagePersistence.stagedAttachmentFileURL(
                            ticket: ticket,
                            item: item
                        )
                    }
                    guard data != nil || fileURL != nil else {
                        throw LocalMessageDatabaseError.missingStagedAttachment
                    }
                    let durationMS = VoiceMessagePayload.decodedDurationMS(message.attachmentDurationSeconds) // WDT_IOS1_SAFE_NUMERIC_20261023
                    fileStore.rememberPendingAttachmentUpload(
                        PendingAttachmentUpload(
                            kind: message.kind,
                            name: item.attachmentFileName ?? message.attachmentName ?? message.text,
                            mimeType: item.attachmentMimeType ?? attachmentMimeType(from: message),
                            sizeBytes: item.attachmentSizeBytes ?? data.map { Int64($0.count) } ?? 0,
                            data: data,
                            fileURL: fileURL,
                            conversationID: item.conversationID,
                            quote: message.quote,
                            replyContext: message.replyContext,
                            voiceDurationMS: durationMS,
                            voiceWaveform: message.voiceWaveform,
                            onPolicyRejected: nil
                        ),
                        messageID: item.clientMessageID
                    )
                    restoreRecoveredAttachmentCheckpoint(item, message: message)
                    _ = startAttachmentUploadTask(
                        messageID: item.clientMessageID,
                        in: item.conversationID
                    )
                } catch {
                    markMessageFailed(messageID: item.clientMessageID, in: item.conversationID)
                    await updateDurableOutbox(
                        ticket: ticket,
                        messageID: item.clientMessageID,
                        state: .retryWait
                    )
                }
            } else {
                markMessageFailed(messageID: item.clientMessageID, in: item.conversationID)
                resendClaimed(
                    messageID: item.clientMessageID,
                    in: item.conversationID,
                    durableTicket: ticket
                )
            }
        }
    }

    private func restoreRecoveredAttachmentCheckpoint(
        _ item: LocalMessageRecoveredOutbox,
        message: ChatMessage
    ) {
        let fileID = (item.attachmentFileID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return }
        let phase = (item.attachmentPhase ?? "").lowercased()
        switch phase {
        case "video_presigned":
            fileStore.recordAttachmentUploadPresign(messageID: item.clientMessageID, fileID: fileID)
        case "video_accelerated_uploaded", "video_accelerated_verifying":
            fileStore.recordAttachmentUploadPUTCompleted(messageID: item.clientMessageID, fileID: fileID, accelerated: true)
        case "video_standard_fallback", "video_fallback_verifying":
            fileStore.recordAttachmentUploadStandardFallback(messageID: item.clientMessageID, fileID: fileID)
        case "uploaded", "video_verifying":
            fileStore.recordAttachmentUploadPUTCompleted(
                messageID: item.clientMessageID,
                fileID: fileID
            )
        case "finalized", "message_send":
            if let file = uploadedFileMetadata(from: message, fileIDOverride: fileID) {
                fileStore.recordAttachmentUploadFinalized(
                    messageID: item.clientMessageID,
                    file: file
                )
            }
        default:
            break
        }
        if ["video_verifying", "video_accelerated_verifying", "video_fallback_verifying"].contains(phase) {
            fileStore.recordVideoUploadVerificationSelected(messageID: item.clientMessageID)
        }
    }

    func recoverCachedDurableOutboxForTesting() async -> Bool {
        await applyCachedRemoteSnapshotIfAvailable(context: apiContext)
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
