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

// MARK: - Message Sending and Attachment Uploads

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
struct OutgoingConfirmationRead: Hashable {
    let ticket: LocalMessageSessionTicket
    let channelID: String
    let channelType: String

    var rotationPosition: String { cursorScope(authority: "").preferenceKey }

    static func rotationScope(_ ticket: LocalMessageSessionTicket) -> IMRouteV5Scope {
        .init(appID: ticket.scopeHash, environment: "", tenantID: nil, service: "outbox_confirmation_rotation")
    }

    func cursorScope(authority: String) -> IMRouteV5Scope {
        IMRouteV5Scope(appID: ticket.scopeHash, environment: channelType, tenantID: channelID,
                       service: "outbox_confirmation|" + authority)
    }

    static func cursorKey(_ clientMessageID: String) -> String {
        SHA256.hash(data: Data(clientMessageID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

extension AppState {
    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_APPSTATE_HELPERS - 修改开始：统一发送/上传链路诊断日志
    func chatBackSendDiagnostic(
        _ event: String,
        conversationID: String,
        messageID: String? = nil,
        extra: String = ""
    ) {
#if DEBUG
        let messagePart = messageID.map { " message=\(Self.shortDebugID($0))" } ?? ""
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortDebugID(conversationID))\(messagePart)\(suffix)")
#endif
    }

    static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_APPSTATE_HELPERS - 修改结束：统一发送/上传链路诊断日志

    func enqueueDurableOutgoing(
        messageID: String,
        conversationID: String,
        operationKind: String,
        context: IMAPIContext,
        scope: String,
        attachmentData: Data? = nil,
        attachmentFileURL: URL? = nil,
        attachmentSizeBytes: Int64? = nil,
        attachmentName: String = "",
        attachmentMimeType: String = ""
    ) async throws -> LocalMessageSessionTicket {
        let generation = localMessageSessionGeneration
        guard isCurrentRemoteScope(scope),
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }) else {
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
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let attachment: LocalMessageAttachmentIntent?
        if let data = attachmentData {
            attachment = LocalMessageAttachmentIntent(
                data: data,
                fileName: attachmentName,
                mimeType: attachmentMimeType,
                sizeBytes: Int64(data.count),
                checksum: AttachmentTransferRepository.sha256Hex(data)
            )
        } else if let attachmentFileURL,
                  let attachmentSizeBytes {
            attachment = LocalMessageAttachmentIntent(
                fileURL: attachmentFileURL,
                fileName: attachmentName,
                mimeType: attachmentMimeType,
                sizeBytes: attachmentSizeBytes
            )
        } else {
            attachment = nil
        }
        let snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: remoteChannelID(for: conversation),
            channelType: apiChannelType(for: conversation.kind),
            currentActorID: context.imUID ?? ""
        )
        _ = try await messagePersistence.enqueueOutgoing(
            ticket: ticket,
            intent: LocalMessageOutgoingIntent(
                conversation: snapshot,
                message: CachedMessage(message: message),
                operationKind: operationKind,
                attachment: attachment
            ),
            revision: nextLocalMessageProjectionRevision()
        )
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        try await messagePersistence.updateOutboxState(
            ticket: ticket,
            clientMessageID: messageID,
            state: .sending
        )
        return ticket
    }

    func confirmDurableOutgoing(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        remote: RemoteMessage,
        conversationID: String,
        scope: String
    ) async {
        guard isCurrentRemoteScope(scope),
              remote.channelSeq > 0,
              !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let projection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: remote.channelID.isEmpty ? remoteChannelID(for: conversation) : remote.channelID,
            channelType: remote.channelType.isEmpty ? apiChannelType(for: conversation.kind) : remote.channelType,
            currentActorID: apiContext.imUID ?? ""
        )
        do {
            try await messagePersistence.confirmOutgoing(
                ticket: ticket,
                clientMessageID: clientMessageID,
                authoritativeMessageID: remote.messageID,
                authoritativeChannelSeq: remote.channelSeq,
                projection: projection,
                revision: nextLocalMessageProjectionRevision()
            )
            scheduleDurableOutboxRecovery(ticket: ticket)
        } catch {
            // Realtime/history readback can still close the same authority by
            // client_msg_no; never issue a second identity here.
        }
    }

    @discardableResult
    func updateDurableOutbox(
        ticket: LocalMessageSessionTicket?,
        messageID: String,
        state: LocalMessageOutboxState,
        uncertain: Bool = false,
        fileID: String? = nil,
        attachmentPhase: String? = nil
    ) async -> Bool {
        guard let ticket else { return false }
        do {
            try await messagePersistence.updateOutboxState(
                ticket: ticket,
                clientMessageID: messageID,
                state: state,
                uncertain: uncertain,
                fileID: fileID,
                attachmentPhase: attachmentPhase
            )
            if state == .retryWait || state == .uncertain {
                scheduleDurableOutboxRecovery(ticket: ticket)
            }
            return true
        } catch {
            // The outbox write remains authoritative. A scope transition or a
            // later foreground activation will reopen and recover it.
            return false
        }
    }

    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    var usesProtectedMessageSends: Bool {
        (api as? IMAPIClient)?.runtimeRouteStore.routeV5Enabled(IMRuntimeRouteService.imAPI.rawValue) == true
    }

    func withDurableOutgoingSend<T>(
        ticket: LocalMessageSessionTicket?, messageID: String, operation: () async throws -> T
    ) async rethrows -> T {
        guard let ticket else { return try await operation() }
        let persistence = messagePersistence
        let send = IMDurableOutgoingSend(clientMessageID: messageID, checkScope: { [weak self] authority in
            guard let self, self.localMessageTicket == ticket,
                  self.apiContext.authSessionFence == authority else { throw CancellationError() }
        }, prepare: { selected, protect in
            try await persistence.prepareOutgoingSend(ticket: ticket, clientMessageID: messageID,
                selectedV5: selected, protect: protect)
        }, deferKnownUnsent: {
            try await persistence.deferKnownUnsentOutgoingSend(ticket: ticket, clientMessageID: messageID)
        }, releaseUnsent: {
            await persistence.releaseUnsentOutgoing(ticket: ticket, clientMessageID: messageID)
        })
        return try await IMDurableOutgoingSend.$current.withValue(send, operation: operation)
    }

    func requestOutgoingMessageConfirmation(_ conversationID: String) {
        setToast("消息发送状态待确认")
        guard let ticket = localMessageTicket else { return }
        Task { @MainActor [weak self] in
            guard let self, let pending = try? await self.messagePersistence.recoverableOutbox(ticket: ticket),
                  let target = pending.first(where: { $0.conversationID == conversationID
                    && $0.state == LocalMessageOutboxState.confirmationRequired.rawValue }) else { return }
            self.scheduleOutgoingConfirmations(ticket: ticket, pending: pending.filter {
                $0.channelID == target.channelID && $0.channelType == target.channelType
            }, rotate: false)
        }
    }

    func scheduleOutgoingConfirmations(ticket: LocalMessageSessionTicket, pending: [LocalMessageRecoveredOutbox], rotate: Bool = true) {
        let context = apiContext
        let slots = 4 - outgoingConfirmationReads.count
        guard slots > 0, localMessageTicket == ticket, context.hasIMSession, let client = api as? IMAPIClient,
              let route = client.outgoingConfirmationRoute(context: context) else { return }
        let groups = Dictionary(grouping: pending.filter { $0.state == LocalMessageOutboxState.confirmationRequired.rawValue }) {
            OutgoingConfirmationRead(ticket: ticket, channelID: $0.channelID, channelType: $0.channelType)
        }
        let rotationScope = OutgoingConfirmationRead.rotationScope(ticket)
        let lastPosition = rotate ? client.runtimeRouteStore.outgoingConfirmationRotation(scope: rotationScope) : ""
        let eligible = groups.filter { !outgoingConfirmationReads.contains($0.key) }
            .map { (position: $0.key.rotationPosition, read: $0.key, items: $0.value) }
            .sorted { ($0.position <= lastPosition ? 1 : 0, $0.position) < ($1.position <= lastPosition ? 1 : 0, $1.position) }
            .prefix(slots)
        if rotate, let last = eligible.last {
            client.runtimeRouteStore.saveOutgoingConfirmationRotation(last.position, scope: rotationScope)
        }
        for (_, read, items) in eligible where outgoingConfirmationReads.insert(read).inserted {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.outgoingConfirmationReads.remove(read) }
                await self.readOutgoingConfirmations(read, items: items, context: context, client: client, route: route)
            }
        }
    }

    private func readOutgoingConfirmations(
        _ read: OutgoingConfirmationRead, items: [LocalMessageRecoveredOutbox], context: IMAPIContext,
        client: IMAPIClient, route: IMOutgoingConfirmationRoute
    ) async {
        let authority = context.authSessionFence
        let scope = remoteDataScopeKey(for: context)
        let store = client.runtimeRouteStore
        func isCurrent() -> Bool {
            !Task.isCancelled && localMessageTicket == read.ticket && apiContext.authSessionFence == authority
                && isCurrentRemoteScope(scope) && (try? route.permit.withCurrent { true }) == true
        }
        guard isCurrent(), let sender = context.imUID, !sender.isEmpty, !read.channelID.isEmpty else { return }
        let keys = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.clientMessageID, OutgoingConfirmationRead.cursorKey(item.clientMessageID))
        })
        let pendingKeys = Set(keys.values)
        var pending = Dictionary(uniqueKeysWithValues: items.map { ($0.clientMessageID, $0) })
        let cursorScope = read.cursorScope(authority: route.cursorAuthority)
        var cursors = store.outgoingConfirmationCursors(scope: cursorScope)
            .filter { pendingKeys.contains($0.key) }
        for _ in 0..<3 {
            guard isCurrent() else { return }
            let before = pending.keys.compactMap { keys[$0].map { cursors[$0] ?? Int64.max } }.max() ?? 0
            guard before > 0 else { return }
            let page = try? await client.syncOutgoingConfirmationPage(context: context,
                channelID: read.channelID, channelType: read.channelType, beforeSeq: before, route: route)
            guard isCurrent(), let page, page.hasExplicitItems, page.items.count <= 50,
                  page.items.allSatisfy({ $0.channelID == read.channelID && $0.channelType == read.channelType
                    && $0.channelSeq >= max(1, page.historyVisibleFromSeq) && $0.channelSeq < before }) else { return }
            let matches = Dictionary(grouping: page.items.filter {
                $0.fromUID == sender && $0.clientMsgNo.flatMap { pending[$0] } != nil
            }, by: { $0.clientMsgNo })
            guard matches.values.allSatisfy({ messages in
                messages.count == 1 && AuthoritativeMessageSendPolicy.accepts(remoteMessageID: messages[0].messageID)
            }) else { return }
            for (id, messages) in matches {
                guard isCurrent(), let id, let remote = messages.first, let item = pending[id], let key = keys[id] else { return }
                guard (try? await messagePersistence.acknowledgeOutgoingAuthority(
                    ticket: read.ticket, clientMessageID: id, authoritativeMessageID: remote.messageID,
                    authoritativeChannelSeq: remote.channelSeq, channelKey: read.channelID,
                    historyRoutePermit: route.permit
                )) == true else { return }
                guard isCurrent() else { return }
                pending.removeValue(forKey: id)
                cursors.removeValue(forKey: key)
                replaceMessageID(localID: id, remote: remote, in: item.conversationID)
            }
            let hasMore = page.hasMoreBefore ?? page.hasMore
            let next: Int64?
            if hasMore == false {
                next = 0
            } else if hasMore == true, let cursor = page.nextBeforeSeq, cursor > 0, cursor < before,
                      cursor == page.items.map(\.channelSeq).min() {
                next = cursor
            } else {
                next = nil
            }
            if next == 0 {
                // A later confirmation pass can see messages committed after this scan.
                cursors.removeAll()
            } else if let next {
                for id in pending.keys {
                    if let key = keys[id], (cursors[key] ?? Int64.max) == before { cursors[key] = next }
                }
            }
            guard isCurrent() else { return }
            try? route.permit.withCurrent {
                if !Task.isCancelled {
                    store.saveOutgoingConfirmationCursors(cursors, scope: cursorScope)
                }
            }
            guard let next, next > 0 else { return }
        }
    }

    func retainUnconfirmedOutgoing(
        _ error: Error, ticket: LocalMessageSessionTicket?, messageID: String,
        conversationID: String, scope: String
    ) async -> Bool {
        if (error as? MessageSendOutcomeUncertainError)?.requiresReadback != true {
            guard let ticket,
                  let authority = try? await messagePersistence.outgoingAuthority(ticket: ticket, clientMessageID: messageID),
                  authority.state == LocalMessageOutboxState.confirmationRequired.rawValue else { return false }
        }
        guard isCurrentRemoteScope(scope) else { return true }
        markMessageFailed(messageID: messageID, in: conversationID)
        requestOutgoingMessageConfirmation(conversationID)
        return true
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END

    func scheduleDurableOutboxRecovery(ticket: LocalMessageSessionTicket) {
        guard iosRiskTelemetrySceneIsActive,
              isAuthenticated,
              apiContext.hasIMSession,
              localMessageTicket?.scopeHash == ticket.scopeHash else { return }
        let scope = remoteDataScopeKey(for: apiContext)
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recoverable: [LocalMessageRecoveredOutbox]
            do {
                recoverable = try await self.messagePersistence.recoverableOutbox(ticket: ticket)
            } catch {
                self.durableOutboxRecoveryTask = nil
                return
            }
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope),
                  self.localMessageTicket?.scopeHash == ticket.scopeHash else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            let automatic = recoverable.filter {
                !$0.requiresUserInitiatedReplay && $0.state != LocalMessageOutboxState.confirmationRequired.rawValue
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
            guard !automatic.isEmpty else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            let nextAttemptAt = automatic.compactMap(\.nextAttemptAt).min()
                ?? Date().timeIntervalSince1970
            let delay = max(0, nextAttemptAt - Date().timeIntervalSince1970)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(delay, 5 * 60) * 1_000_000_000))
                } catch {
                    self.durableOutboxRecoveryTask = nil
                    return
                }
            }
            guard !Task.isCancelled,
                  self.iosRiskTelemetrySceneIsActive,
                  self.isAuthenticated,
                  self.apiContext.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  self.localMessageTicket?.scopeHash == ticket.scopeHash else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            self.durableOutboxRecoveryTask = nil
            await self.recoverDurableOutbox(ticket: ticket, scope: scope)
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
