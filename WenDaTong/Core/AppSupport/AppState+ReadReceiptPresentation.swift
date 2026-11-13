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

// WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110_BEGIN
@MainActor
final class ReadReceiptDetailAuthorityStore {
    @Published private var authorities: [String: AppState.ReadReceiptDetailAuthority] = [:]
    private(set) var generation: UInt64 = 0

    subscript(conversationID: String) -> AppState.ReadReceiptDetailAuthority? {
        get { authorities[conversationID] }
        set { authorities[conversationID] = newValue }
    }

    func updates(for conversationID: String) -> AnyPublisher<AppState.ReadReceiptDetailAuthority?, Never> {
        $authorities.map { $0[conversationID] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func invalidate() {
        generation &+= 1
        authorities.removeAll()
    }
}
// WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110_END

extension AppState {
    struct ReadReceiptDetailScope: Equatable {
        let scope: String
        let sessionEpoch: String
        let sessionGeneration: UInt64
        let authorityGeneration: UInt64
        let enterpriseID: String
        let role: String
    }

    struct ReadReceiptDetailAuthority: Equatable {
        let scope: ReadReceiptDetailScope
        let allowed: Bool
        let revision = UUID()
    }

    var readReceiptDetailScope: ReadReceiptDetailScope {
        ReadReceiptDetailScope(
            scope: remoteDataScopeKey(for: apiContext), sessionEpoch: apiContext.sessionEpoch,
            sessionGeneration: localMessageSessionGeneration,
            authorityGeneration: readReceiptAuthorityStore.generation, // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
            enterpriseID: currentEnterprise.id,
            role: currentEnterprise.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    var hasReadReceiptDetailTenantRole: Bool {
        // WDT_IOS1_RECEIPT_ROLE_20261023: group owner/admin is not a tenant capability.
        ["admin", "internal", "internal_user", "staff", "employee", "member_internal", "管理员", "内部用户"]
            .contains(readReceiptDetailScope.role)
    }

    func invalidateReadReceiptDetailAuthorities() {
        readReceiptAuthorityStore.invalidate() // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        for id in conversationStore.conversationMessageSnapshots().map(\.id) {
            conversationStore.updateReadReceiptDetailsVisibility(false, conversationID: id)
        }
    }

    func clearReadReceiptDetailAuthority(conversationID: String) {
        // Keep a new denial revision so an in-flight sync with an unknown capability cannot grant after leaving.
        readReceiptAuthorityStore[conversationID] = ReadReceiptDetailAuthority(scope: readReceiptDetailScope, allowed: false) // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        conversationStore.updateReadReceiptDetailsVisibility(false, conversationID: conversationID)
    }

    @discardableResult
    func applyReadReceiptDetailAuthority(_ allowed: Bool, conversationID: String) -> Bool {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        let effectiveAllowed = allowed && conversation.kind == .group && hasReadReceiptDetailTenantRole
            && apiContext.hasIMSession && fileUploadConfig.readReceiptsEnabled
        let scope = readReceiptDetailScope
        let old = readReceiptAuthorityStore[conversationID] // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        if old?.scope != scope || old?.allowed != effectiveAllowed {
            readReceiptAuthorityStore[conversationID] = ReadReceiptDetailAuthority(scope: scope, allowed: effectiveAllowed) // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        }
        return conversationStore.updateReadReceiptDetailsVisibility(effectiveAllowed, conversationID: conversationID)
    }

    func canViewMessageReadDetails(_ message: ChatMessage, in conversation: ConversationMessageSnapshot) -> Bool {
        guard conversation.kind == .group, message.isOutgoing, !message.isDeletedLocally,
              message.canViewReadDetails, fileUploadConfig.readReceiptsEnabled,
              apiContext.hasIMSession, hasReadReceiptDetailTenantRole,
              let authority = readReceiptAuthorityStore[conversation.id] else { return false } // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
        return authority.allowed && authority.scope == readReceiptDetailScope
    }

    // The panel always hydrates reactions from extras; personnel permission is checked independently.
    @discardableResult
    func prepareReadReceiptPanel(messageID: String, in conversationID: String) -> Task<Void, Never> {
        let scope = readReceiptDetailScope
        let selectionEpoch = conversationSelectionEpochFence.epoch
        return Task {
            guard scope == readReceiptDetailScope,
                  selectionEpoch == conversationSelectionEpochFence.epoch,
                  let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
                  let message = conversation.messages.first(where: { $0.id == messageID }),
                  message.isOutgoing, !message.isDeletedLocally else { return }
            if !canViewMessageReadDetails(message, in: conversation) {
                conversationStore.updateReadReceiptDetailsVisibility(false, conversationID: conversationID)
            }
            let channelID = remoteChannelID(for: conversation)
            let channelType = apiChannelType(for: conversation.kind)
            await syncMessageExtrasForConversation(channelID: channelID, channelType: channelType)
            guard scope == readReceiptDetailScope,
                  selectionEpoch == conversationSelectionEpochFence.epoch else { return }
            if conversation.kind == .group, hasReadReceiptDetailTenantRole,
               fileUploadConfig.readReceiptsEnabled,
               readReceiptAuthorityStore[conversationID]?.scope != scope || readReceiptAuthorityStore[conversationID]?.allowed != true { // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
                await syncReadReceiptsForConversation(channelID: channelID, channelType: channelType)
            }
            guard scope == readReceiptDetailScope,
                  selectionEpoch == conversationSelectionEpochFence.epoch,
                  let current = conversationStore.conversationMessageSnapshot(id: conversationID),
                  let currentMessage = current.messages.first(where: { $0.id == messageID }) else { return }
            guard canViewMessageReadDetails(currentMessage, in: current) else {
                conversationStore.updateReadReceiptDetailsVisibility(false, conversationID: conversationID)
                return
            }
            await loadReadReceipts(messageID: messageID, in: conversationID).value
        }
    }

    static func isReadReceiptDetailPermissionDenied(_ error: Error) -> Bool {
        switch error {
        case IMAPIError.businessForbidden(let code, _, _), IMAPIError.conflict(let code, _):
            return ["permission_denied", "forbidden", "read_receipt_details_forbidden"]
                .contains(code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case IMAPIError.forbidden, IMAPIError.httpStatus(403, _):
            return true
        default:
            return false
        }
    }
    // WDT_RECEIPT_DETAIL_SCOPE_20261023_END

    @discardableResult
    func loadReadReceipts(messageID: String, in conversationID: String) -> Task<Void, Never> {
        let requestScope = readReceiptDetailScope
        let selectionEpoch = conversationSelectionEpochFence.epoch
        return Task {
            guard requestScope == readReceiptDetailScope,
                  selectionEpoch == conversationSelectionEpochFence.epoch else { return }
            guard let initialConversationIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
                  let initialMessageIndex = conversationStore.conversationMessageSnapshot(at: initialConversationIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
            guard conversationStore.conversationMessageSnapshot(at: initialConversationIndex).messages[initialMessageIndex].isOutgoing else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只能查看自己发送消息的已读状态")
                return
            }
            guard fileUploadConfig.readReceiptsEnabled else {
                return
            }
            // WDT_RECEIPT_DETAIL_SCOPE_20261023: direct/unknown/ordinary users never query personnel.
            guard canViewMessageReadDetails(conversationStore.conversationMessageSnapshot(at: initialConversationIndex).messages[initialMessageIndex],
                                            in: conversationStore.conversationMessageSnapshot(at: initialConversationIndex)) else {
                conversationStore.updateReadReceiptDetailsVisibility(false, conversationID: conversationID)
                return
            }
            let authority = readReceiptAuthorityStore[conversationID] // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
            let channelID = remoteChannelID(for: conversationStore.conversationMessageSnapshot(at: initialConversationIndex))
            @MainActor
            func isCurrentRequest() -> Bool {
                guard !Task.isCancelled, requestScope == readReceiptDetailScope,
                      selectionEpoch == conversationSelectionEpochFence.epoch,
                      authority == readReceiptAuthorityStore[conversationID], // WDT_IOS1_REFACTOR_RECEIPT_AUTHORITY_OBSERVATION_20261110
                      let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
                      remoteChannelID(for: conversation) == channelID,
                      let message = conversation.messages.first(where: { $0.id == messageID }) else { return false }
                return canViewMessageReadDetails(message, in: conversation)
            }
            let context = apiContext
            guard context.hasIMSession else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
                return
            }
            let scope = remoteDataScopeKey(for: context)
            let response: RemoteMessageReadReceiptResponse
            do {
                response = try await api.messageReadReceipts(context: context, messageID: messageID)
            } catch {
                guard isCurrentRequest() else { return }
                logSyncEndpointFailure("/api/im/messages/{message_id}/read-receipts", error: error)
                if isCapabilityError(error, code: "read_receipts_not_enabled") {
                    setReadReceiptsEnabled(false)
                    return
                }
                // WDT_RECEIPT_DETAIL_SCOPE_20261023: an expected privacy denial is not a group or session failure.
                if Self.isReadReceiptDetailPermissionDenied(error) {
                    if applyReadReceiptDetailAuthority(false, conversationID: conversationID) {
                        await persistConversationSnapshotImmediately(conversationID: conversationID, scope: scope, source: .localMutation)
                    }
                    return
                }
                switch error {
                case IMAPIError.httpStatus(404, _):
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息不存在或已不可见")
                case IMAPIError.businessForbidden(let code, _, _)
                    where ["message_not_found", "message_not_visible", "message_invisible", "message_already_deleted"].contains(code),
                     IMAPIError.conflict(let code, _)
                    where ["message_not_found", "message_not_visible", "message_invisible", "message_already_deleted"].contains(code):
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息不存在或已不可见")
                case IMAPIError.businessForbidden:
                    applyReadReceiptDetailAuthority(false, conversationID: conversationID)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("无法获取已读明细，当前请求未获授权")
                default:
                    handleRemoteError(error, fallback: "已读状态获取失败")
                }
                return
            }
            guard isCurrentRequest() else { return }
            if response.readReceiptsEnabled == false || response.featureStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "disabled" {
                setReadReceiptsEnabled(false)
                return
            }
            // A restricted response is not evidence that an unknown message is unread.
            guard response.canViewDetails else {
                if applyReadReceiptDetailAuthority(false, conversationID: conversationID) {
                    await persistConversationSnapshotImmediately(conversationID: conversationID, scope: scope, source: .localMutation)
                }
                return
            }
            let didChange = conversationStore.applyRemoteReadReceiptDetails(
                response: response,
                messageID: messageID,
                conversationID: conversationID,
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
                },
                makeUnreadReceipt: { participant, conversation in
                    ReadReceipt(
                        id: "unread_\(participant.imUID)",
                        user: readReceiptUser(
                            imUID: participant.imUID,
                            conversation: conversation,
                            nickname: participant.nickname,
                            displayName: participant.displayName,
                            remark: participant.remark
                        ),
                        device: participant.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未同步" : participant.deviceID,
                        time: participant.readAt.map(displayTime) ?? "未读"
                    )
                },
                makeReactionDetail: reactionDetail(from:),
                preserveSyncedReactions: true // WDT_RECEIPT_DETAIL_SCOPE_20261023: extras owns the current reaction snapshot.
            )
            if didChange, conversationStore.conversationMessageSnapshot(id: conversationID)?.kind == .group,
               !shouldShowGroupMemberCount {
                conversationStore.scrubGroupMemberTotals()
            }
            if didChange {
                await persistConversationSnapshotImmediately(
                    conversationID: conversationID, scope: scope, source: .localMutation
                )
            }
        }
    }

    func readReceiptUser(imUID: String, conversation: ConversationMessageSnapshot, nickname: String? = nil, displayName: String? = nil, remark: String? = nil) -> IMUser {
        let normalizedID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupMember = groups.lazy.flatMap(\.members).first { $0.id == normalizedID || $0.userID == normalizedID }
        let participant = conversation.participants.first { $0.id == normalizedID || $0.userID == normalizedID }
        let contact = contacts.first { $0.id == normalizedID || $0.userID == normalizedID }
        let fallback = groupMember ?? participant ?? contact
        let name = remarkPreferredDisplayName(
            identifiers: [normalizedID, fallback?.id ?? "", fallback?.userID ?? "", fallback?.username ?? ""],
            candidates: [remark, displayName, nickname, groupMember?.name, participant?.name, contact?.name, contact?.username, contact?.userID],
            fallback: normalizedID
        )
        return IMUser(
            id: fallback?.id ?? normalizedID,
            name: name,
            title: fallback?.title ?? "",
            department: fallback?.department ?? "",
            departmentPathNames: fallback?.departmentPathNames ?? [],
            phone: fallback?.phone ?? "",
            email: fallback?.email ?? "",
            status: fallback?.status ?? "在线",
            enterprise: fallback?.enterprise ?? currentEnterprise.name,
            avatarSeed: fallback?.avatarSeed ?? stableSeed(normalizedID),
            avatarURL: fallback?.avatarURL ?? "",
            badges: fallback?.badges ?? []
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
