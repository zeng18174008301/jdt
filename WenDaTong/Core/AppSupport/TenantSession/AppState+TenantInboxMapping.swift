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
    nonisolated static func friendRequestProjection(
        _ item: RemoteFriendApplication,
        currentID: String
    ) -> FriendRequest? {
        let status = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let applicantID = item.applicantUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = item.targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverDirection = item.direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCurrentID = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedDirection: String
        if !normalizedCurrentID.isEmpty, applicantID == normalizedCurrentID {
            derivedDirection = "outgoing"
        } else if !normalizedCurrentID.isEmpty, targetID == normalizedCurrentID {
            derivedDirection = "incoming"
        } else {
            derivedDirection = ""
        }
        // A valid viewer-specific server direction is authoritative.  Identity
        // derivation is retained only for legacy payloads that omitted it.
        let direction = ["incoming", "outgoing"].contains(serverDirection)
            ? serverDirection
            : derivedDirection
        guard direction == "incoming" || direction == "outgoing" else { return nil }
        let isOutgoing = direction == "outgoing"
        let isIncoming = direction == "incoming"
        let suppressed = Self.isSuppressedFriendApplication(status: status, outcome: item.outcome)
        if suppressed && isIncoming {
            return nil
        }
        let reviewStatus = item.tenantReviewStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let legacyCanRespond = isIncoming
            && item.requiresTargetApproval != false
            && status == "pending"
            && (reviewStatus.isEmpty || reviewStatus == "not_required" || reviewStatus == "approved")
        // `actionable_by_current_user` is computed for this exact viewer and is
        // therefore stronger than generic flow hints such as
        // `requires_target_approval`.  Do not hide valid accept/reject controls
        // when those compatibility fields disagree.
        let canRespond = !suppressed
            && isIncoming
            && status == "pending"
            && (item.actionableByCurrentUser ?? legacyCanRespond)
        let displayName = isOutgoing
            ? (item.targetName.isEmpty ? targetID : item.targetName)
            : (item.applicantName.isEmpty ? applicantID : item.applicantName)
        let peerID = isOutgoing ? targetID : applicantID
        let avatar = isOutgoing ? item.targetAvatar : item.applicantAvatar
        let source: String
        if isOutgoing {
            source = "我发出的申请"
        } else {
            switch item.source {
            case "direct_chat_not_friends": source = "来自私聊"
            case "profile": source = "来自个人资料"
            case "search_user": source = "来自用户搜索"
            default: source = item.source.isEmpty ? (item.sourceGroupName ?? "好友申请") : item.source
            }
        }
        let message: String
        if status == "accepted" {
            message = "申请已通过"
        } else if status == "rejected" {
            message = "申请已拒绝"
        } else if status == "cancelled" || status == "canceled" || item.outcome.lowercased() == "application_cancelled" {
            message = "申请已取消"
        } else if suppressed {
            message = FriendAddPresentation.suppressedMessage
        } else if status == "expired" || item.outcome.lowercased() == "application_expired" {
            message = "申请已过期"
        } else if isOutgoing {
            message = reviewStatus == "pending" ? "等待企业审核" : "等待对方通过"
        } else if !canRespond {
            message = "当前暂不可处理"
        } else {
            message = item.message ?? "申请添加你为好友"
        }
        return FriendRequest(
            id: item.id,
            name: displayName,
            userID: peerID,
            avatarURL: avatar,
            source: source,
            message: message,
            status: status,
            direction: direction,
            tenantReviewStatus: reviewStatus,
            peerReviewStatus: item.peerReviewStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            canRespond: canRespond,
            outcome: item.outcome,
            relationStatus: item.relationStatus,
            friendAction: item.friendAction,
            friendFlow: item.friendFlow,
            directlyEstablished: item.directlyEstablished,
            requiresTenantReview: item.requiresTenantReview,
            requiresTargetApproval: item.requiresTargetApproval,
            resolutionMode: item.resolutionMode,
            accepted: status == "accepted" || item.relationStatus.lowercased() == "friend"
        )
    }

    func applyFriendApplications(_ applications: [RemoteFriendApplication]) {
        let currentID = (apiContext.imUID ?? currentUser.id).trimmingCharacters(in: .whitespacesAndNewlines)
        friendRequests = applications.compactMap {
            Self.friendRequestProjection($0, currentID: currentID)
        }
    }

    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_BEGIN
    struct ContactRequestOwner {
        let scope: String
        let localGeneration: UInt64
        let authority: IMAuthSessionFence
    }

    func contactRequestOwner(context: IMAPIContext, scope: String? = nil) -> ContactRequestOwner {
        ContactRequestOwner(
            scope: scope ?? remoteDataScopeKey(for: context),
            localGeneration: localMessageSessionGeneration,
            authority: context.authSessionFence
        )
    }

    func contactRequestContext(for owner: ContactRequestOwner) -> IMAPIContext? {
        let context = apiContext
        guard !Task.isCancelled, context.hasIMSession,
              localMessageSessionGeneration == owner.localGeneration, isCurrentRemoteScope(owner.scope),
              context.isSameAuthAuthority(as: owner.authority) || context.credentialsAdvanced(since: owner.authority)
        else { return nil }
        return context
    }

    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
    func withContactHTTPRequest<Value>(
        owner: ContactRequestOwner,
        context: IMAPIContext,
        operation: @MainActor () async throws -> Value
    ) async rethrows -> Value {
        let authority = context.authSessionFence
        let requestOwner = ContactHTTPRequestOwner(
            ownsOperation: { [weak self] in self?.contactRequestContext(for: owner) != nil },
            ownsAuthority: { [weak self] in
                self?.contactRequestContext(for: owner)?.isSameAuthAuthority(as: authority) == true
            }
        )
        return try await ContactHTTPRequestOwner.$current.withValue(requestOwner, operation: operation)
    }
    // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END

    func isContactRequestCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func isContactSessionFailure(_ error: Error) -> Bool {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case .forcedAuthRequired, .loginSecurity:
                return true
            default:
                break
            }
        }
        return DeviceRevocationDetector.matches(error: error)
            || securityBlockedInfo(from: error) != nil
            || workspaceAccessCode(from: error) != nil
            || isUnauthorizedError(error)
    }

    func refreshFriendApplicationsAndRelations() async {
        await refreshFriendApplicationsAndRelations(owner: contactRequestOwner(context: apiContext))
    }

    func refreshFriendApplicationsAndRelations(context: IMAPIContext, scope: String) async {
        guard context.hasIMSession else { return }
        await refreshFriendApplicationsAndRelations(owner: contactRequestOwner(context: context, scope: scope))
    }

    func refreshFriendApplicationsAndRelations(owner: ContactRequestOwner) async {
        guard let applicationsContext = contactRequestContext(for: owner) else { return }
        let scope = owner.scope
        profileContactRevisionFence.rebind(scopeHash: scope)
        do {
            let requests = try await withContactHTTPRequest(owner: owner, context: applicationsContext) { // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
                try await api.listFriendApplications(context: applicationsContext)
            }
            guard contactRequestContext(for: owner) != nil else { return }
            applyFriendApplications(requests)
        } catch {
            guard !isContactRequestCancellation(error), !isContactSessionFailure(error) else { return }
        }

        guard let blacklistContext = contactRequestContext(for: owner) else { return }
        let blacklistReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        do {
            let blocked = try await withContactHTTPRequest(owner: owner, context: blacklistContext) { // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112
                try await api.listBlacklist(context: blacklistContext)
            }
            guard contactRequestContext(for: owner) != nil else { return }
            applyBlacklist(blocked, readStamp: blacklistReadStamp)
        } catch {
            guard !isContactRequestCancellation(error), !isContactSessionFailure(error) else { return }
        }

        guard let friendsContext = contactRequestContext(for: owner) else { return }
        let friendsReadStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_BEGIN
        let relations = try? await withContactHTTPRequest(owner: owner, context: friendsContext) {
            try await api.listFriends(context: friendsContext)
        }
        // WDT_IOS1_CONTACT_HTTP_REQUEST_OWNERSHIP_20261112_END
        if let relations, contactRequestContext(for: owner) != nil {
            applyFriendRelations(relations, readStamp: friendsReadStamp)
        }
    }
    // WDT_IOS1_CONTACT_REQUEST_OWNERSHIP_20261112_END

    func applyDevices(_ remoteDevices: [RemoteUserDevice]) {
        guard !remoteDevices.isEmpty else { return }
        deviceSessions = remoteDevices.map { device in
            DeviceSession(
                id: device.deviceID,
                name: device.deviceType.isEmpty ? device.deviceID : device.deviceType,
                platform: device.appID,
                lastSeen: displayTime(device.lastSeenAt),
                status: device.banned ? "已封禁" : device.status,
                isBound: true,
                isBlocked: device.banned
            )
        }
    }

    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_BEGIN
    func refreshLoginLogs() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession, isCurrentRemoteScope(scope), !loginLogStore.isLoading else { return }
        loginLogStore.isLoading = true
        defer { loginLogStore.isLoading = false }
        do {
            let remoteLogs = try await api.listMyLoginLogs(context: context)
            guard isCurrentRemoteScope(scope) else { return }
            loginLogStore.logs = remoteLogs.map { remote in
                LoginLog(
                    id: remote.id,
                    device: Self.loginLogDeviceLabel(remote.deviceType),
                    location: "当前账号",
                    time: displayTime(remote.createdAt),
                    result: Self.loginLogResultLabel(remote.result)
                )
            }
            loginLogStore.loadFailed = false
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            loginLogStore.loadFailed = true
            logSyncEndpointFailure("/api/tenant/me/login-logs", error: error)
            if isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "登录日志同步失败", silent: true)
            }
        }
    }
    // WDT_IOS1_REFACTOR_LOGIN_LOG_OBSERVATION_20261110_END

    private static func loginLogDeviceLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios": return "iOS"
        case "android": return "Android"
        case "web": return "Web"
        case "desktop": return "桌面端"
        default: return "未知设备"
        }
    }

    private static func loginLogResultLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "success": return "成功"
        case "blocked": return "已拦截"
        case "locked": return "已锁定"
        case "limited": return "已限制"
        case "warning": return "风险提示"
        default: return "失败"
        }
    }

    func applyInbox(_ remoteInbox: [RemoteInboxEntry]) {
        let previousKnownIDs = contactStore.knownInboxIDs()
        let sortedInbox = remoteInbox.filter(shouldKeepFriendInboxEntry).sorted { lhs, rhs in
            let lhsDate = parseRemoteDate(lhs.createdAt) ?? Date.distantPast
            let rhsDate = parseRemoteDate(rhs.createdAt) ?? Date.distantPast
            return lhsDate > rhsDate
        }
        let nextItems = sortedInbox.map(inboxItem)
        inboxItems = nextItems
        contactStore.replaceKnownInboxIDs(Set(nextItems.map(\.id)))
        syncSystemConversationFromInbox(nextItems)

        let newUnreadAnnouncements = nextItems.filter { item in
            item.isAnnouncement && !item.isRead && !previousKnownIDs.contains(item.id)
        }
        guard isAuthenticated, !previousKnownIDs.isEmpty, let firstAnnouncement = newUnreadAnnouncements.first else { return }
        SystemNotificationSound.playMessage()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(newUnreadAnnouncements.count > 1
            ? "收到 \(newUnreadAnnouncements.count) 条新公告"
            : "收到新公告：\(firstAnnouncement.title)") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
    }

    static func mergedInboxEntries(_ primary: [RemoteInboxEntry], _ announcements: [RemoteInboxEntry]) -> [RemoteInboxEntry] {
        guard !announcements.isEmpty else { return primary }
        var ids: [String: Int] = [:]
        var merged = primary
        for index in merged.indices {
            let id = merged[index].id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty {
                ids[id] = index
            }
        }
        for item in announcements {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = ids[id] {
                merged[index] = item
            } else {
                ids[id] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    func mergeInboxNotifications(_ remoteInbox: [RemoteInboxEntry]) {
        guard !remoteInbox.isEmpty else { return }
        let mappedNotifications = remoteInbox
            .filter(shouldKeepFriendInboxEntry)
            .sorted {
                let lhsDate = parseRemoteDate($0.createdAt) ?? Date.distantPast
                let rhsDate = parseRemoteDate($1.createdAt) ?? Date.distantPast
                return lhsDate > rhsDate
            }
            .map(inboxItem)
            .filter { !$0.id.isEmpty }
        let notificationIDs = Set(mappedNotifications.map(\.id))
        let preservedItems = inboxItems.filter { !notificationIDs.contains($0.id) }
        inboxItems = mappedNotifications + preservedItems
        contactStore.mergeKnownInboxIDs(Set(inboxItems.map(\.id)))
        syncSystemConversationFromInbox(inboxItems)
    }

    private func shouldKeepFriendInboxEntry(_ item: RemoteInboxEntry) -> Bool {
        let event = payloadString(
            item.payload,
            ["event", "event_type", "notification_type", "notice_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isFriendRelationRealtimeEvent(event: event, kind: kind) else {
            return true
        }
        let status = payloadString(item.payload, ["status", "application_status"])
        let outcome = payloadString(item.payload, ["outcome"])
        return !Self.isSuppressedFriendApplication(status: status, outcome: outcome)
    }

    private func inboxItem(from item: RemoteInboxEntry) -> InboxItem {
        let category = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "system" : item.kind
        let isAnnouncement = InboxItem(id: item.id, title: item.title, subtitle: item.summary, time: "", category: category, isRead: false, accentHex: 0).isAnnouncement
        let approval = groupInviteApproval(from: item.payload, kind: item.kind, fallbackTitle: item.title)
        let isRead = item.readAt != nil || (!isAnnouncement && contactStore.isSystemInboxReadLocally(id: item.id))
        return InboxItem(
            id: item.id,
            title: item.title,
            subtitle: item.summary,
            time: displayTime(item.createdAt),
            category: category,
            isRead: isRead,
            accentHex: approval != nil ? 0x7C6BFF : (isAnnouncement ? 0x5D6BFF : 0x18B6D7),
            avatarURL: resolveTenantAssetURL(item.senderAvatarURL),
            groupInviteApproval: approval,
            sortTimestamp: parseRemoteDate(item.createdAt)?.timeIntervalSince1970 ?? 0
        )
    }

    func syncSystemConversationFromInbox(_ items: [InboxItem]) {
        let systemItems = items.filter { !$0.isAnnouncement }
        let unread = systemItems.filter { !$0.isRead }.count
        let messagePairs: [(item: InboxItem, message: ChatMessage)] = systemItems
            .reversed()
            .enumerated()
            .map { offset, item in
                var message = systemInboxMessage(from: item)
                message.channelSeq = Int64(offset + 1)
                return (item, message)
            }
        let messages = messagePairs.map { $0.message }
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：系统会话同步避免生成序号临时数组
        let lastMsgSeq = ConversationSequenceInspector.maximumChannelSeq(in: messages) ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        let firstUnread = messagePairs.first { !$0.item.isRead }
        conversationStore.replaceSystemConversation { previousSystem in
            guard let latest = systemItems.first else {
                return nil
            }
            let latestItemTimestamp = latest.sortTimestamp
            if let previousSystem,
               shouldPreserveNewerSystemConversationSnapshot(
                   previousSortTimestamp: previousSystem.sortTimestamp,
                   latestInboxSortTimestamp: latestItemTimestamp
               ) {
                return previousSystem
            }
            let lastMessage = systemConversationPreview(from: latest)
            let previousReadSeq = min(previousSystem?.lastReadSeq ?? 0, lastMsgSeq)
            let firstUnreadSeq = firstUnread?.message.channelSeq ?? 0
            let firstUnreadMessageID = firstUnread?.message.id ?? ""
            let lastReadSeq = unread == 0
                ? lastMsgSeq
                : min(max(previousReadSeq, max(firstUnreadSeq - 1, 0)), lastMsgSeq)
            return ConversationMessageSnapshot(
                id: "system_notification",
                title: "系统通知",
                subtitle: "系统",
                kind: .system,
                lastMessage: lastMessage,
                time: latest.time,
                unread: unread,
                isPinned: previousSystem?.isPinned ?? false,
                isMuted: previousSystem?.isMuted ?? false,
                memberCount: 1,
                accentHex: 0x18B6D7,
                participants: [],
                messages: messages,
                avatarURL: systemNoticeAvatarURL,
                hasUnreadReaction: false,
                unreadReactionCount: 0,
                lastMsgSeq: lastMsgSeq,
                lastReadSeq: lastReadSeq,
                firstUnreadSeq: firstUnreadSeq,
                firstUnreadMessageID: firstUnreadMessageID,
                unreadAnchorSeq: firstUnreadSeq,
                unreadAnchorState: unread > 0 ? "unread" : "none",
                sortTimestamp: latestItemTimestamp
            )
        }
    }

    private func systemConversationPreview(from item: InboxItem) -> String {
        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subtitle.isEmpty { return subtitle }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "系统通知" : title
    }

    private func systemInboxMessage(from item: InboxItem) -> ChatMessage {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if title.isEmpty {
            text = subtitle.isEmpty ? "系统通知" : subtitle
        } else if subtitle.isEmpty {
            text = title
        } else {
            text = "\(title)\n\(subtitle)"
        }
        return ChatMessage(
            id: "inbox_\(item.id)",
            senderId: "system",
            senderName: "系统",
            text: text,
            time: item.time,
            isOutgoing: false,
            status: item.isRead ? .read : .sent,
            kind: .system,
            reactions: [],
            readBy: [],
            unreadBy: [],
            quote: nil,
            attachmentName: nil,
            attachmentMeta: nil,
            groupInviteApproval: item.groupInviteApproval
        )
    }

    func attachmentResourceComponents(
        for message: ChatMessage
    ) -> (fileID: String, attachmentID: String, mediaID: String) {
        let encoded = message.attachmentFileID ?? ""
        if encoded.hasPrefix("attachment_id:") {
            return ("", String(encoded.dropFirst("attachment_id:".count)), "")
        }
        if encoded.hasPrefix("media_id:") {
            return ("", "", String(encoded.dropFirst("media_id:".count)))
        }
        return (encoded, "", "")
    }

    func tenantFileID(for message: ChatMessage) -> String {
        attachmentResourceComponents(for: message).fileID
    }

    // Remote message payload, sticker, mention, and attachment parsing helpers are split to Core/AppSupport/MessageMapping/AppState+RemoteMessagePayloadMapping.swift.

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
