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
// AppState 仍是 @MainActor: 它拥有 SwiftUI @Published 状态、子 Store 和路由状态。
// 本文件只做边界收口,不改业务规则:
// - 需要读取 currentUser / contacts / groups / store / apiContext 的函数继续由
//   AppState 类型继承 MainActor 隔离。
// - 纯字符串、时间、ID、MessageKind 映射桥接标为 nonisolated,允许后续后台
//   消息映射复用,避免无意义地切回主线程。
// - 具体算法仍委托给非 AppState support 类型,保持行为一致,也方便后续把
//   批量消息映射继续拆到后台快照 mapper。

// MARK: - Identity, Conversation Presentation, and Pure Bridges

extension AppState {
    nonisolated func isIdentifierLikeDisplayName(_ name: String, matching id: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty { return true }
        if normalizedName.caseInsensitiveCompare(normalizedID) == .orderedSame { return true }
        return false
    }

    private func blacklistDisplayName(for id: String) -> String? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let item = blacklist.first(where: { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedID }) else {
            return nil
        }
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !isIdentifierLikeDisplayName(name, matching: normalizedID) else {
            return nil
        }
        return name
    }

    private func blockedConversationParticipant(for peerID: String) -> IMUser? {
        let normalizedID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayName = blacklistDisplayName(for: normalizedID) else { return nil }
        return IMUser(
            id: normalizedID,
            userID: normalizedID,
            name: displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "已拉黑",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(normalizedID),
            badges: []
        )
    }

    func directConversationSnapshotDisplayName(forBlockedUID blockedUID: String) -> String? {
        let normalizedID = blockedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        for conversation in conversations where conversation.kind == .direct {
            let peerID = directPeerID(for: conversation)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard peerID == normalizedID else { continue }

            if let participantName = conversation.participants
                .first(where: { user($0, matchesIdentifier: normalizedID) })?
                .name
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !participantName.isEmpty,
               !isIdentifierLikeDisplayName(participantName, matching: normalizedID) {
                return participantName
            }

            let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !isIdentifierLikeDisplayName(title, matching: normalizedID) {
                return title
            }

            if let senderName = conversation.messages.reversed().lazy
                .first(where: { $0.senderId.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedID })?
                .senderName
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !senderName.isEmpty,
               !isIdentifierLikeDisplayName(senderName, matching: normalizedID) {
                return senderName
            }
        }
        return nil
    }

    nonisolated func contactCardName(from message: RemoteMessage) -> String? {
        if let name = message.payload["contact_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let text = message.payload["text"]?.stringValue
            ?? message.payload["content"]?.stringValue
            ?? message.payload["body"]?.stringValue
        else { return nil }
        let stripped = text
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    func contactCardPreviewDisplayName(from message: RemoteMessage) -> String? {
        let fallbackName = contactCardName(from: message)
        guard let contactID = contactCardUID(from: message) else { return fallbackName }
        let displayName = remarkPreferredDisplayName(
            identifiers: [contactID],
            candidates: [fallbackName],
            fallback: fallbackName ?? contactID
        )
        return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : displayName
    }

    nonisolated func contactCardUID(from message: RemoteMessage) -> String? {
        [
            message.payload["contact_uid"]?.stringValue,
            message.payload["contact_user_id"]?.stringValue,
            message.payload["user_id"]?.stringValue,
            message.payload["im_uid"]?.stringValue,
            message.payload["target_uid"]?.stringValue,
            message.payload["contact_id"]?.stringValue
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    func titleForRemoteConversation(channelID: String, kind: ConversationKind, lookup: ConversationUserLookup? = nil) -> String {
        switch kind {
        case .direct:
            let peerID = directConversationPeerID(channelID)
            return user(for: peerID, lookup: lookup)?.name
                ?? blacklistDisplayName(for: peerID)
                ?? peerID
        case .group:
            return groups.first(where: { $0.id == channelID })?.name ?? channelID
        case .system:
            return "系统通知"
        }
    }

    private func systemNotificationTitle(
        for _: Conversation,
        latestIncomingMessage _: ChatMessage?
    ) -> String {
        IOSNotificationPrivacyCopy.appTitle
    }

    private func systemNotificationBody(for _: ChatMessage?) -> String {
        IOSNotificationPrivacyCopy.generic
    }

#if DEBUG
    func systemNotificationTitleForTesting(
        conversation: Conversation,
        latestIncomingMessage: ChatMessage?
    ) -> String {
        systemNotificationTitle(for: conversation, latestIncomingMessage: latestIncomingMessage)
    }

    func systemNotificationBodyForTesting(message: ChatMessage?) -> String {
        systemNotificationBody(for: message)
    }
#endif

    func conversationTitle(channelID: String, kind: ConversationKind, previous: Conversation?, remoteDisplayName: String = "", lookup: ConversationUserLookup? = nil) -> String {
        let resolvedTitle = titleForRemoteConversation(channelID: channelID, kind: kind, lookup: lookup)
        let serverTitle = remoteDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .direct {
            let previousTitle = previous?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !previousTitle.isEmpty, !isIdentifierLikeDisplayName(previousTitle, matching: channelID) {
                return previousTitle
            }
            if isIdentifierLikeDisplayName(resolvedTitle, matching: channelID),
               !serverTitle.isEmpty,
               !isIdentifierLikeDisplayName(serverTitle, matching: channelID) {
                return serverTitle
            }
            return resolvedTitle
        }
        let previousTitle = previous?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let peerID = directConversationPeerID(channelID)
        if previousTitle.isEmpty || isIdentifierLikeDisplayName(previousTitle, matching: peerID) {
            if isIdentifierLikeDisplayName(resolvedTitle, matching: peerID),
               !serverTitle.isEmpty,
               !isIdentifierLikeDisplayName(serverTitle, matching: peerID) {
                return serverTitle
            }
            return resolvedTitle
        }
        return previousTitle
    }

    func conversationParticipants(channelID: String, kind: ConversationKind, previous: Conversation?, lookup: ConversationUserLookup? = nil) -> [IMUser] {
        let resolved = participantsForRemoteConversation(channelID: channelID, kind: kind, lookup: lookup)
        guard kind == .direct else {
            return resolved.isEmpty ? previous?.participants ?? [] : resolved
        }
        if !resolved.isEmpty {
            return resolved
        }
        if let previousParticipants = previous?.participants, !previousParticipants.isEmpty {
            return previousParticipants
        }
        return blockedConversationParticipant(for: directConversationPeerID(channelID)).map { [$0] } ?? []
    }

    func participantsForRemoteConversation(channelID: String, kind: ConversationKind, lookup: ConversationUserLookup? = nil) -> [IMUser] {
        switch kind {
        case .direct:
            let peerID = directConversationPeerID(channelID)
            return user(for: peerID, lookup: lookup).map { [$0] } ?? []
        case .group:
            return groups.first(where: { $0.id == channelID })?.members ?? []
        case .system:
            return []
        }
    }

    func senderAvatarSnapshot(
        for message: RemoteMessage,
        senderID: String,
        isOutgoing: Bool,
        participants: [IMUser]
    ) -> (avatarURL: String, avatarVersion: String, avatarUpdatedAt: String, avatarSeed: UInt) {
        if isOutgoing {
            return (
                currentUser.avatarURL,
                currentUser.avatarVersion,
                currentUser.avatarUpdatedAt,
                currentUser.avatarSeed
            )
        }

        let knownUsers = knownSenderUsers(for: senderID, participants: participants)
        let avatarUser = knownUsers.first {
            !$0.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rawRemoteAvatar = message.senderAvatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAvatarURL = rawRemoteAvatar.isEmpty ? "" : resolveTenantAssetURL(rawRemoteAvatar)
        let remoteAvatarVersion = message.senderAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAvatarUpdatedAt = message.senderAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSeed = avatarUser?.avatarSeed ?? knownUsers.first?.avatarSeed ?? stableSeed(senderID)
        guard remoteAvatarURL.isEmpty else {
            let matchesKnownAvatar = avatarUser?.avatarURL == remoteAvatarURL
            return (
                remoteAvatarURL,
                remoteAvatarVersion.isEmpty ? (matchesKnownAvatar ? avatarUser?.avatarVersion ?? "" : "") : remoteAvatarVersion,
                remoteAvatarUpdatedAt.isEmpty ? (matchesKnownAvatar ? avatarUser?.avatarUpdatedAt ?? "" : "") : remoteAvatarUpdatedAt,
                fallbackSeed
            )
        }
        return (
            avatarUser?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            remoteAvatarVersion.isEmpty ? avatarUser?.avatarVersion ?? "" : remoteAvatarVersion,
            remoteAvatarUpdatedAt.isEmpty ? avatarUser?.avatarUpdatedAt ?? "" : remoteAvatarUpdatedAt,
            fallbackSeed
        )
    }

    func knownSenderUser(for senderID: String, participants: [IMUser]) -> IMUser? {
        let candidates = knownSenderUsers(for: senderID, participants: participants)
        return candidates.first {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && !isIdentifierLikeDisplayName(name, matching: senderID)
        } ?? candidates.first
    }

    func knownSenderUsers(for senderID: String, participants: [IMUser]) -> [IMUser] {
        let normalizedID = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return [] }
        var candidates: [IMUser] = []
        if let participant = participants.first(where: { user($0, matchesIdentifier: normalizedID) }) {
            candidates.append(participant)
        }
        if let cachedUser = user(for: normalizedID),
           !candidates.contains(where: { user($0, matchesIdentifier: cachedUser.id) || user($0, matchesIdentifier: cachedUser.userID) || user($0, matchesIdentifier: cachedUser.username) }) {
            candidates.append(cachedUser)
        }
        return candidates
    }

    // JHT_MOD_BEGIN APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改开始：AppState 保留频道/身份原入口，具体规则委托给独立 mapper
    nonisolated func user(_ user: IMUser, matchesIdentifier identifier: String) -> Bool {
        ConversationChannelIdentityMapper.user(user, matchesIdentifier: identifier)
    }

    private func directConversationPeerID(_ channelID: String) -> String {
        channelID.split(separator: ":").map(String.init).first { $0 != apiContext.imUID && $0 != currentUser.id } ?? channelID
    }

    func user(for id: String, lookup: ConversationUserLookup? = nil) -> IMUser? {
        if let lookup { return lookup.user(for: id) }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        if currentUserIdentitySet().contains(normalizedID) { return currentUser }
        if let contact = contacts.first(where: { user($0, matchesIdentifier: normalizedID) }) {
            return contact
        }
        return groups.lazy.flatMap(\.members).first { user($0, matchesIdentifier: normalizedID) }
    }

    func remoteChannelID(for conversation: Conversation, lookup: ConversationUserLookup? = nil) -> String {
        if conversation.kind == .group {
            return groups.first(where: { $0.id == conversation.id || $0.name == conversation.title })?.id ?? conversation.id
        }
        return ConversationChannelIdentityMapper.remoteChannelID(
            for: conversation,
            currentUser: currentUser,
            apiIMUID: apiContext.imUID,
            groups: [],
            lookup: lookup,
            fallbackCanonicalParticipantID: { [self] rawID in
                canonicalDirectParticipantID(rawID, lookup: lookup)
            }
        )
    }

    func normalizedRemoteChannelID(_ channelID: String, channelType: String, lookup: ConversationUserLookup? = nil) -> String {
        let currentID = (apiContext.imUID?.isEmpty == false ? apiContext.imUID : currentUser.id) ?? currentUser.id
        let currentIDs = currentUserIdentitySet()
        return ConversationChannelIdentityMapper.normalizedRemoteChannelID(
            channelID,
            channelType: channelType,
            currentID: currentID,
            currentIDs: currentIDs,
            lookup: lookup,
            fallbackCanonicalParticipantID: { [self] rawID in
                canonicalDirectParticipantID(rawID, lookup: lookup)
            }
        )
    }

    private func canonicalDirectChannelID(_ channelID: String, lookup: ConversationUserLookup? = nil) -> String {
        let currentID = (apiContext.imUID?.isEmpty == false ? apiContext.imUID : currentUser.id) ?? currentUser.id
        return ConversationChannelIdentityMapper.normalizedRemoteChannelID(
            channelID,
            channelType: "direct",
            currentID: currentID,
            currentIDs: currentUserIdentitySet(),
            lookup: lookup,
            fallbackCanonicalParticipantID: { [self] rawID in
                canonicalDirectParticipantID(rawID, lookup: lookup)
            }
        )
    }

    func canonicalDirectParticipantID(_ rawID: String, lookup: ConversationUserLookup? = nil) -> String {
        let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        guard let user = user(for: normalized, lookup: lookup) else { return normalized }
        if !user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.id
        }
        if !user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return user.userID
        }
        return normalized
    }

    nonisolated func directChannelParts(_ channelID: String) -> [String] {
        ConversationChannelIdentityMapper.directChannelParts(channelID)
    }

    nonisolated func apiChannelType(for kind: ConversationKind) -> String {
        ConversationChannelIdentityMapper.apiChannelType(for: kind)
    }

    nonisolated func conversationKind(from channelType: String, channelID: String = "") -> ConversationKind {
        ConversationChannelIdentityMapper.conversationKind(from: channelType, channelID: channelID)
    }
    // JHT_MOD_END APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改结束

    var rtcCallRecordRedialVideoCameraAvailable: Bool {
        videoMediaClient.isAvailable && videoMediaClient.cameraAvailable
    }

    // JHT_MOD_BEGIN APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改开始：AppState 保留纯展示工具入口，具体算法委托给 helper
    nonisolated func messageKind(from contentType: String) -> MessageKind {
        AppStatePresentationHelper.messageKind(from: contentType)
    }

    nonisolated func stableSeed(_ value: String) -> UInt {
        AppStatePresentationHelper.stableSeed(value)
    }
    // JHT_MOD_END APPSTATE_PRESENTATION_HELPER_SPLIT_20260913 - 修改结束

    nonisolated func effectiveCreatedAt(for message: ChatMessage) -> Date? {
        // 排序只认绝对发送时间;绝不从显示串("HH:mm"/"6月x日")反推:
        // 同一显示串在不同日期会被错误解析,正/反两种排序错乱都源于此。
        message.createdAt
    }

    // JHT_MOD_BEGIN APPSTATE_TIME_FORMATTER_DECOUPLE_PERF_20260913 - 修改开始：AppState 保留原入口，时间解析/格式化委托给独立 helper
    nonisolated func parseRemoteDate(_ raw: String?) -> Date? {
        AppStateTimeFormatter.parseRemoteDate(raw)
    }

    nonisolated func parseRemoteAbsoluteDate(_ raw: String?) -> Date? {
        AppStateTimeFormatter.parseRemoteAbsoluteDate(raw)
    }

    nonisolated func isTimeOnlyRemoteValue(_ raw: String?) -> Bool {
        AppStateTimeFormatter.isTimeOnlyRemoteValue(raw)
    }

    nonisolated func displayTime(_ raw: String?) -> String {
        AppStateTimeFormatter.displayTime(raw)
    }

    nonisolated func displayTime(_ date: Date) -> String {
        AppStateTimeFormatter.displayTime(date)
    }

    nonisolated func byteSize(_ bytes: Int64) -> String {
        AppStateTimeFormatter.byteSize(bytes)
    }
    // JHT_MOD_END APPSTATE_TIME_FORMATTER_DECOUPLE_PERF_20260913 - 修改结束
}
