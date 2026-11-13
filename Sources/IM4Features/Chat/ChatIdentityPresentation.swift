import IM4Domain
import IM4DesignSystem
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

public struct ChatHeaderTitleDecision: Equatable {
    static let safeDirectFallback = "单聊"

    static public func resolve(
        kind: ConversationKind,
        resolvedPeerDisplayName: String?,
        conversationTitle: String
    ) -> String {
        let peerName = resolvedPeerDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind == .direct {
            return peerName.isEmpty ? safeDirectFallback : peerName
        }
        let normalizedTitle = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTitle.isEmpty ? kind.rawValue : normalizedTitle
    }
}

public struct GroupMuteBannerDecision: Equatable {
    public let title: String
    public let detail: String
    let isRepairRequired: Bool

    static public func resolve(group: GroupInfo, canManage: Bool) -> GroupMuteBannerDecision? {
        guard group.allMuted else { return nil }

        if group.allMuteRepairRequired {
            return GroupMuteBannerDecision(
                title: "禁言状态需要管理员修复",
                detail: canManage
                    ? "禁言状态需要修复；修复前群主和管理员可继续发言。"
                    : "禁言状态需要管理员修复；修复前普通成员无法发送。",
                isRepairRequired: true
            )
        }

        let isAuthoritativelyActive: Bool
        if let active = group.allMuteActive {
            isAuthoritativelyActive = active
        } else {
            isAuthoritativelyActive = group.allMuteMode == .always
                || (group.allMuteMode == nil
                    && group.allMuteStart == nil
                    && group.allMuteEnd == nil)
        }
        guard isAuthoritativelyActive else { return nil }

        return GroupMuteBannerDecision(
            title: "当前全员禁言",
            detail: canManage
                ? "当前全员禁言，管理员可发言。"
                : "当前全员禁言，普通成员暂不可发言。",
            isRepairRequired: false
        )
    }
}

public struct ChatDisabledBannerDecision: Equatable {
    public let groupMuteBanner: GroupMuteBannerDecision?
    public let showsComposerDisabledNotice: Bool

    var visibleBannerCount: Int {
        (groupMuteBanner == nil ? 0 : 1) + (showsComposerDisabledNotice ? 1 : 0)
    }

    static public func resolve(
        groupMuteBanner: GroupMuteBannerDecision?,
        composerIsDisabled: Bool
    ) -> ChatDisabledBannerDecision {
        ChatDisabledBannerDecision(
            groupMuteBanner: groupMuteBanner,
            showsComposerDisabledNotice: composerIsDisabled && groupMuteBanner == nil
        )
    }
}

public struct MessageSenderResolver {
    public let currentUser: IMUser
    public let enterpriseName: String
    public let contactRemarks: [String: String]
    private let usersByKey: [String: IMUser]
    private let groupNamesByKey: [String: String]

    public init(
        currentUser: IMUser,
        enterpriseName: String,
        conversation: ConversationMessageSnapshot,
        contacts: [IMUser],
        group: GroupInfo?,
        exactGroupSelf: IMUser? = nil,
        contactRemarks: [String: String] = [:]
    ) {
        self.currentUser = currentUser
        self.enterpriseName = enterpriseName
        self.contactRemarks = contactRemarks

        var keyed: [String: IMUser] = [:]
        var groupNames: [String: String] = [:]
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：构建发送人索引时避免为每个用户创建 map/filter 临时数组
        func registerKey(_ rawKey: String, user: IMUser) {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            keyed[key] = Self.preferredRegisteredUser(existing: keyed[key], candidate: user)
        }

        func registerExactGroupKey(_ rawKey: String, user: IMUser, projectedName: String) {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            keyed[key] = user
            groupNames[key] = projectedName
        }

        func register(_ user: IMUser) {
            registerKey(user.id, user: user)
            registerKey(user.userID, user: user)
            registerKey(user.username, user: user)
        }
        func registerExactGroupUser(_ user: IMUser) {
            let projectedName = chatProjectedMemberName(user)
            registerExactGroupKey(user.id, user: user, projectedName: projectedName)
            registerExactGroupKey(user.userID, user: user, projectedName: projectedName)
            registerExactGroupKey(user.username, user: user, projectedName: projectedName)
        }
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

        register(currentUser)
        conversation.participants.forEach(register)
        contacts.forEach(register)
        // Group members already carry the exact viewer/group projection. They
        // must replace global/contact identity rows with the same stable ID.
        if conversation.kind == .group {
            group?.members.forEach(registerExactGroupUser)
            group?.admins.forEach(registerExactGroupUser)
            if let exactGroupSelf {
                registerExactGroupUser(exactGroupSelf)
            }
        }
        usersByKey = keyed
        groupNamesByKey = groupNames
    }

    public func senderUser(for message: ChatMessage) -> IMUser? {
        let isCurrentUser = message.senderId == currentUser.id
            || message.senderId == currentUser.userID
            || message.senderId == currentUser.username
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：发送人查找只有 senderId 一个 key，直接 trim 后查表
        let senderKey = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !senderKey.isEmpty, let user = usersByKey[senderKey] {
            return userApplyingSenderSnapshot(user, from: message)
        }
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        return isCurrentUser ? currentUser : nil
    }

    public func displaySenderName(for message: ChatMessage, resolvedUser: IMUser?) -> String {
        guard message.kind != .system else { return "系统" }
        if isCancelledUserAvatarURL(message.senderAvatarURL) {
            return cancelledUserDisplayName
        }
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedUser {
            if resolvedUser.isCancelledUser {
                return cancelledUserDisplayName
            }
        }
        // Apply the exact current-group projection only to presentation. The
        // stored sender/reply snapshots remain unchanged for history/export.
        if let groupName = groupNamesByKey[message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)] {
            return groupName
        }
        if let resolvedUser {
            if let remark = remarkDisplayName(for: resolvedUser, senderID: message.senderId) {
                return remark
            }
        }
        if let remark = remarkDisplayName(for: nil, senderID: message.senderId) {
            return remark
        }
        // The server-owned message snapshot is immutable. Current group/profile
        // data is a compatibility fallback for older messages without a snapshot;
        // viewer-private remarks remain a presentation-only override.
        if !storedName.isEmpty, !isIdentifierLikeSenderName(storedName, senderID: message.senderId) {
            return storedName
        }
        if let resolvedUser {
            let name = preferredDisplayName(for: resolvedUser, senderID: message.senderId)
            if !name.isEmpty {
                return name
            }
        }
        return storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
    }

    private func remarkDisplayName(for user: IMUser?, senderID: String) -> String? {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：备注名查找保留原 key 顺序，去掉数组拼接和 map/filter 临时数组
        let normalized = normalizedRemarkIdentifiers(for: user, senderID: senderID)
        guard !normalized.isEmpty,
              !normalized.contains(where: isCurrentUserIdentifier) else { return nil }
        for key in normalized {
            if let remark = contactRemarks[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                return remark
            }
        }
        for key in normalized {
            guard let registeredUser = usersByKey[key] else { continue }
            for userKey in [registeredUser.id, registeredUser.userID, registeredUser.username] {
                let normalizedUserKey = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedUserKey.isEmpty else { continue }
                if let remark = contactRemarks[normalizedUserKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                    return remark
                }
            }
        }
        return nil
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func isCurrentUserIdentifier(_ identifier: String) -> Bool {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：当前用户 ID 比较逐项执行，避免每条消息备注判断创建数组
        return normalizedUserIdentifier(currentUser.id, equals: normalized)
            || normalizedUserIdentifier(currentUser.userID, equals: normalized)
            || normalizedUserIdentifier(currentUser.username, equals: normalized)
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：消息行发送人展示名解析的轻量 key 工具
    private func normalizedRemarkIdentifiers(for user: IMUser?, senderID: String) -> [String] {
        var identifiers: [String] = []
        identifiers.reserveCapacity(user == nil ? 1 : 4)
        func append(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            identifiers.append(value)
        }
        append(senderID)
        if let user {
            append(user.id)
            append(user.userID)
            append(user.username)
        }
        return identifiers
    }

    private func normalizedUserIdentifier(_ rawValue: String, equals target: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value == target
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

    static public func fallbackUser(for message: ChatMessage, displayName: String, enterpriseName: String) -> IMUser? {
        guard !displayName.isEmpty, displayName != "系统" else { return nil }
        let senderID = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderID.isEmpty else { return nil }
        let isCancelled = isCancelledUserAvatarURL(message.senderAvatarURL)
        let resolvedName = isCancelled ? cancelledUserDisplayName : displayName
        return IMUser(
            id: senderID,
            name: resolvedName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: isCancelled ? "cancelled" : "在线",
            enterprise: enterpriseName,
            avatarSeed: message.senderAvatarSeed == 0 ? UInt(bitPattern: resolvedName.hashValue) : message.senderAvatarSeed,
            avatarURL: message.senderAvatarURL,
            avatarVersion: message.senderAvatarVersion,
            avatarUpdatedAt: message.senderAvatarUpdatedAt,
            badges: []
        )
    }

    private static func preferredRegisteredUser(existing: IMUser?, candidate: IMUser) -> IMUser {
        guard let existing else { return candidate }
        if existing.isCancelledUser || candidate.isCancelledUser {
            return candidate.isCancelledUser ? candidate : existing
        }
        let existingAvatar = existing.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateAvatar = candidate.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingAvatar.isEmpty, !candidateAvatar.isEmpty {
            return candidate
        }
        let existingName = preferredDisplayName(for: existing, senderID: existing.id)
        let candidateName = preferredDisplayName(for: candidate, senderID: candidate.id)
        if existingName.isEmpty, !candidateName.isEmpty {
            return candidate
        }
        return existing
    }

    private func userApplyingSenderSnapshot(_ user: IMUser, from message: ChatMessage) -> IMUser {
        let currentAvatar = user.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotAvatar = message.senderAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCancelledUserAvatarURL(snapshotAvatar) {
            return IMUser(
                id: user.id,
                userID: user.userID,
                username: user.username,
                name: cancelledUserDisplayName,
                title: user.title,
                department: user.department,
                departmentPathNames: user.departmentPathNames,
                phone: user.phone,
                phoneVerified: user.phoneVerified,
                realNameVerified: user.realNameVerified,
                realNameStatus: user.realNameStatus,
                email: user.email,
                status: "cancelled",
                enterprise: user.enterprise,
                avatarSeed: user.avatarSeed,
                avatarURL: snapshotAvatar,
                avatarVersion: message.senderAvatarVersion,
                avatarUpdatedAt: message.senderAvatarUpdatedAt,
                badges: user.badges
            )
        }
        guard !user.isCancelledUser else { return user }
        guard currentAvatar.isEmpty, !snapshotAvatar.isEmpty else { return user }
        return IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: user.status,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: snapshotAvatar,
            avatarVersion: message.senderAvatarVersion,
            avatarUpdatedAt: message.senderAvatarUpdatedAt,
            badges: user.badges
        )
    }
}

public func isIdentifierLikeSenderName(_ name: String, senderID: String) -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedID = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedName.isEmpty { return true }
    if !normalizedID.isEmpty, normalizedName.caseInsensitiveCompare(normalizedID) == .orderedSame {
        return true
    }
    return false
}

private func preferredDisplayName(for user: IMUser, senderID: String) -> String {
    for candidate in [user.name, user.username, user.userID] {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isIdentifierLikeSenderName(trimmed, senderID: senderID) {
            return trimmed
        }
    }
    return user.name.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ChatBackButtonBadge: View {
    let count: Int
    let text: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(IMColor.ink)
                .frame(width: 34, height: 34)

            if count > 0 {
                Text(text)
                    .font(.system(size: 8, weight: .black))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, count > 9 ? 4 : 0)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(IMColor.danger))
                    .offset(x: 3, y: 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 42, height: 34, alignment: .leading)
        .contentShape(Rectangle())
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

func chatProjectedMemberName(_ user: IMUser) -> String {
    [user.name, user.username, user.userID, user.id]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "未命名成员"
}

public func chatShouldShowSenderHeader(for message: ChatMessage, at index: Int, in messages: [ChatMessage]) -> Bool {
        guard message.kind != .system else { return true }
        guard index > 0, messages.indices.contains(index - 1) else { return true }
        let previous = messages[index - 1]
        guard previous.kind != .system else { return true }
        guard previous.senderId == message.senderId,
              previous.senderName == message.senderName,
              previous.isOutgoing == message.isOutgoing else {
            return true
        }
        return false
    }


public func chatTimeSeparatorText(before message: ChatMessage, previous: ChatMessage?, threshold: TimeInterval) -> String? {
        guard let createdAt = message.createdAt else { return nil }
        guard let previousCreatedAt = previous?.createdAt else {
            return chatTimeSeparatorText(for: createdAt)
        }
        guard createdAt.timeIntervalSince(previousCreatedAt) > threshold else {
            return nil
        }
        return chatTimeSeparatorText(for: createdAt)
    }


private func chatTimeSeparatorText(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return ChatMessageDateFormatterPool.string(from: date, format: "HH:mm")
        }
        if calendar.isDateInYesterday(date) {
            return ChatMessageDateFormatterPool.string(from: date, format: "'昨天' HH:mm")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear),
           calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return ChatMessageDateFormatterPool.string(from: date, format: "E HH:mm")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return ChatMessageDateFormatterPool.string(from: date, format: "M月d日 HH:mm")
        }
        return ChatMessageDateFormatterPool.string(from: date, format: "yyyy年M月d日 HH:mm")
    }
