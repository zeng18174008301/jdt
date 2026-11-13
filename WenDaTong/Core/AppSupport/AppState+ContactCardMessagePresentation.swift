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

extension AppState {
    private func normalizedContactCardUID(_ value: String?, rejecting displayName: String = "") -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty || normalized != normalizedName else { return nil }
        return normalized
    }

    func contactCardLocalDisplayName(for user: IMUser) -> String {
        remarkPreferredDisplayName(for: user, fallback: contactCardUID(for: user) ?? "未知用户")
    }

    func contactCardExportDisplayName(for user: IMUser) -> String {
        let identifiers = userIdentityCandidates(for: user)
        if let originalName = contactCardOriginalName(matching: identifiers) {
            return originalName
        }
        let remark = contactRemarkValue(matching: identifiers)
        let candidates = [user.name, user.username, user.userID, user.id].filter { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value != remark
        }
        return preferredDisplayName(
            candidates: candidates.map(Optional.some),
            identifiers: identifiers,
            fallback: contactCardUID(for: user) ?? "未知用户"
        )
    }

    private func contactCardDisplayName(from message: ChatMessage) -> String {
        let name = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未知用户" : name
    }

    func contactCardExportDisplayName(from message: ChatMessage) -> String {
        let fallbackName = contactCardDisplayName(from: message)
        if let contactID = contactCardUID(for: message),
           let originalName = contactCardOriginalName(matching: [contactID]) {
            return originalName
        }
        return fallbackName
    }

    func contactCardUID(for user: IMUser) -> String? {
        let displayName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [user.id, user.userID]
            .compactMap { normalizedContactCardUID($0, rejecting: displayName) }
            .first
    }

    func contactCardUID(for message: ChatMessage) -> String? {
        let displayName = contactCardDisplayName(from: message)
        if let directID = normalizedContactCardUID(message.attachmentMeta, rejecting: displayName) {
            return directID
        }
        let normalizedMeta = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = (contacts + groups.flatMap(\.members)).filter { user in
            user.name == displayName
                || (!normalizedMeta.isEmpty && (user.id == normalizedMeta || user.userID == normalizedMeta))
        }
        let uniqueIDs = Set(candidates.compactMap { contactCardUID(for: $0) })
        return uniqueIDs.count == 1 ? uniqueIDs.first : nil
    }

    func contactCardAvatarURL(for contactID: String) -> String? {
        guard let avatar = user(for: contactID)?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !avatar.isEmpty else { return nil }
        return avatar
    }

    func isSystemReadOnlyConversation(_ conversation: ConversationMessageSnapshot) -> Bool {
        if conversation.kind == .system || conversation.title.contains("系统") {
            return true
        }
        guard conversation.kind != .group else {
            return false
        }
        let hasSystemParticipant = conversation.participants.contains { user in
            let normalizedID = user.id.lowercased()
            return normalizedID.contains("system")
                || normalizedID.contains("bot")
                || user.name.contains("系统")
                || user.title.contains("系统")
        }
        return hasSystemParticipant
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
