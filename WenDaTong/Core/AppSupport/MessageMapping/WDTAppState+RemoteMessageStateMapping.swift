import IM4Features
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

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
    func remarkPreferredDisplayName(
        for user: IMUser,
        fallback: String? = nil,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
        directory: ContactStore.DirectoryPresentationSnapshot? = nil
    ) -> String {
        remarkPreferredDisplayName(
            identifiers: [user.id, user.userID, user.username],
            candidates: [user.name, user.username, user.userID],
            fallback: fallback ?? (user.id.isEmpty ? "未知用户" : user.id),
            contactLookup: contactLookup,
            directory: directory
        )
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

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

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
    func remarkPreferredDisplayName(
        identifiers: [String],
        candidates: [String?],
        fallback: String,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
        directory: ContactStore.DirectoryPresentationSnapshot? = nil
    ) -> String {
        // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END
        let normalizedIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let remark = contactRemarkValue(matching: normalizedIdentifiers, contactLookup: contactLookup, directory: directory) { // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110
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

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
    func contactRemarkValue(
        matching identifiers: [String],
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil,
        directory: ContactStore.DirectoryPresentationSnapshot? = nil
    ) -> String? {
        guard !identifiers.isEmpty,
              !identifiers.contains(where: { isCurrentUserIdentity($0) }) else { return nil }
        let remarks = directory?.remarks ?? contactRemarks
        for identifier in identifiers {
            if let remark = remarks[identifier]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
        }
        let matchedContact: IMUser?
        if let contactLookup {
            matchedContact = contactLookup.firstContact(matchingAny: identifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        } else {
            matchedContact = (directory?.contacts ?? contacts).first { contact in identifiers.contains { user(contact, matchesIdentifier: $0) } }
        }
        guard let contact = matchedContact else { return nil }
        for identifier in [contact.id, contact.userID, contact.username] {
            let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let remark = remarks[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
        }
        return nil
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

    func currentMessageSenderIdentitySet() -> Set<String> {
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
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
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

    func applyRemoteReadSummary(from remote: RemoteMessage, toMessagesIn conversation: inout ConversationMessageSnapshot) {
        conversationStore.applyRemoteReadSummary(
            from: remote,
            toMessagesIn: &conversation,
            readReceiptsEnabled: fileUploadConfig.readReceiptsEnabled
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
