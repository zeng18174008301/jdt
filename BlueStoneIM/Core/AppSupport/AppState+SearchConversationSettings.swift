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

// MARK: - Search and Conversation Settings

struct SearchInvalidationStamp {
    let version: Int64
    let updatedAt: String
}

extension AppState {
    func applySearchInvalidations(_ invalidations: [SearchInvalidationEvent]) {
        for invalidation in invalidations {
            applySearchInvalidation(invalidation)
        }
    }

    func applySearchInvalidation(_ invalidation: SearchInvalidationEvent) {
        guard searchInvalidationBelongsToCurrentTenant(invalidation) else { return }
        let scopedInvalidation = searchInvalidationScopedToCurrentTenant(invalidation)
        guard shouldApplySearchInvalidation(scopedInvalidation) else { return }
        applySearchInvalidationToLocalCaches(scopedInvalidation)
        latestSearchInvalidation = scopedInvalidation
        searchInvalidationRevision = searchInvalidationRevision &+ 1
    }

    func clearTenantScopedSearchState(reason: String) {
        appliedSearchInvalidations.removeAll()
        latestSearchInvalidation = .tenantScopeReset(tenantID: apiContext.tenantID ?? "", reason: reason)
        searchInvalidationRevision = searchInvalidationRevision &+ 1
    }

    private func searchInvalidationBelongsToCurrentTenant(_ invalidation: SearchInvalidationEvent) -> Bool {
        guard let eventTenantID = invalidation.normalizedTenantID else { return true }
        guard let currentTenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentTenantID.isEmpty else {
            return true
        }
        return eventTenantID == currentTenantID
    }

    private func searchInvalidationScopedToCurrentTenant(_ invalidation: SearchInvalidationEvent) -> SearchInvalidationEvent {
        guard invalidation.normalizedTenantID == nil,
              let tenantID = apiContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty else {
            return invalidation
        }
        return SearchInvalidationEvent(
            tenantID: tenantID,
            invalidationKey: invalidation.invalidationKey,
            eventType: invalidation.eventType,
            reason: invalidation.reason,
            channelID: invalidation.channelID,
            channelType: invalidation.channelType,
            channelSeq: invalidation.channelSeq,
            messageID: invalidation.messageID,
            fileID: invalidation.fileID,
            version: invalidation.version,
            updatedAt: invalidation.updatedAt,
            clientAction: invalidation.clientAction,
            isTenantScopeReset: invalidation.isTenantScopeReset
        )
    }

    private func shouldApplySearchInvalidation(_ invalidation: SearchInvalidationEvent) -> Bool {
        if invalidation.isTenantScopeReset { return true }
        let dedupeKey = invalidation.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dedupeKey.isEmpty else { return true }
        let newUpdatedAt = invalidation.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let previous = appliedSearchInvalidations[dedupeKey] {
            if invalidation.version > 0 || previous.version > 0 {
                guard invalidation.version > previous.version else { return false }
            } else if !newUpdatedAt.isEmpty || !previous.updatedAt.isEmpty {
                guard newUpdatedAt > previous.updatedAt else { return false }
            } else {
                return false
            }
        }
        appliedSearchInvalidations[dedupeKey] = SearchInvalidationStamp(
            version: invalidation.version,
            updatedAt: newUpdatedAt
        )
        return true
    }

    private func applySearchInvalidationToLocalCaches(_ invalidation: SearchInvalidationEvent) {
        if let fileID = invalidation.normalizedFileID {
            files = files.filter { $0.id != fileID }
        }
        if invalidation.isConversationRemoval,
           let channelID = invalidation.normalizedChannelID,
           let conversationID = conversations.first(where: { conversation in
               conversation.id == channelID || remoteChannelID(for: conversation) == channelID
           })?.id {
            _ = conversationStore.deleteConversation(conversationID: conversationID)
        }
    }

    func searchInvalidationEvent(from extra: RemoteMessageExtra) -> SearchInvalidationEvent? {
        SearchInvalidationEvent(
            payload: extra.payload,
            fallbackTenantID: extra.tenantID.isEmpty ? apiContext.tenantID ?? "" : extra.tenantID,
            fallbackChannelID: extra.channelID.isEmpty ? nil : extra.channelID,
            fallbackChannelType: extra.channelType.isEmpty ? nil : extra.channelType,
            fallbackChannelSeq: extra.channelSeq > 0 ? extra.channelSeq : nil,
            fallbackMessageID: extra.messageID.isEmpty ? nil : extra.messageID,
            fallbackUpdatedAt: extra.createdAt
        )
    }

    func tenantSearch(
        query: String,
        scope: String,
        types: [String],
        limit: Int,
        cursor: String? = nil,
        typeCursors: [String: String] = [:],
        conversationID: String? = nil,
        fromUID: String? = nil,
        senderID: String? = nil,
        startAt: String? = nil,
        after: String? = nil,
        endAt: String? = nil,
        before: String? = nil,
        fileType: String? = nil,
        mimeType: String? = nil,
        date: String? = nil
    ) async -> RemoteTenantSearchResponse? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDate = date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty || !trimmedDate.isEmpty else { return nil }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var channelID: String?
        var channelType: String?
        if normalizedScope == "conversation" {
            guard let conversationID,
                  let conversation = conversations.first(where: { $0.id == conversationID }) else {
                toast = "当前会话不可用"
                return nil
            }
            channelID = remoteChannelID(for: conversation)
            channelType = apiChannelType(for: conversation.kind)
        }
        let scopeKey = remoteDataScopeKey(for: context)
        do {
            let response = try await api.tenantSearch(
                context: context,
                scope: normalizedScope.isEmpty ? "global" : normalizedScope,
                query: trimmed,
                types: types,
                limit: limit,
                cursor: cursor,
                typeCursors: typeCursors,
                channelID: channelID,
                channelType: channelType,
                fromUID: fromUID,
                senderID: senderID,
                startAt: startAt,
                after: after,
                endAt: endAt,
                before: before,
                fileType: fileType,
                mimeType: mimeType,
                date: trimmedDate.isEmpty ? nil : trimmedDate
            )
            guard isCurrentRemoteScope(scopeKey) else { return nil }
            return response
        } catch {
            guard isCurrentRemoteScope(scopeKey) else { return nil }
            handleRemoteError(error, fallback: "搜索失败")
            return nil
        }
    }

    func postTenantSearchEvent(_ event: TenantSearchAnalyticsEvent) {
        let context = apiContext
        guard context.hasIMSession else { return }
        Task {
            do {
                try await api.postTenantSearchEvent(context: context, event: event)
            } catch {
                // Analytics must never block the visible search flow.
            }
        }
    }

    func conversationID(for searchTarget: RemoteTenantSearchJumpTarget?) -> String? {
        guard let channelID = searchTarget?.channelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelID.isEmpty else {
            return nil
        }
        return conversations.first { conversation in
            conversation.id == channelID || remoteChannelID(for: conversation) == channelID
        }?.id
    }

    func prepareSearchJumpTarget(_ target: RemoteTenantSearchJumpTarget, conversationID: String) async -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        if let messageID = searchMessageID(in: conversation, target: target) {
            return messageID
        }
        guard let channelSeq = target.channelSeq, channelSeq > 0 else {
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        let channelID = nonEmptySearchString(target.channelID) ?? remoteChannelID(for: conversation)
        let channelType = nonEmptySearchString(target.channelType) ?? apiChannelType(for: conversation.kind)
        if let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive,
           channelSeq < boundary.fromSeq {
            toast = groupHistoryLimitedMessage
            return nil
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        do {
            let page = try await api.syncMessages(
                context: context,
                channelID: channelID,
                channelType: channelType,
                afterSeq: 0,
                beforeSeq: channelSeq + 1,
                limit: 50
            )
            guard isCurrentRemoteScope(scope),
                  isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return nil }
            let syncBoundary = historyBoundary(from: page, channelType: channelType)
            if let syncBoundary,
               syncBoundary.isRestrictive,
               channelSeq < syncBoundary.fromSeq {
                applyHistoryVisibilityBoundaryForGroup(
                    channelID: channelID,
                    boundary: syncBoundary
                )
                toast = groupHistoryLimitedMessage
                return nil
            }
            if !page.items.isEmpty {
                applyRemoteMessages(page.items, channelID: channelID, channelType: channelType, historyBoundary: syncBoundary)
            }
            conversationStore.normalizePinnedContextMessagesWithinLoadedWindow(conversationID: conversationID)
            guard let refreshed = conversations.first(where: { $0.id == conversationID }) else { return nil }
            return searchMessageID(in: refreshed, target: target)
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                toast = groupHistoryLimitedMessage
                return nil
            }
            handleRemoteError(error, fallback: "定位搜索结果失败")
            return nil
        }
    }

    /// 置顶消息(或其他已知 messageID/seq 的消息)跳转:目标不在已加载时间线
    /// 窗口时,先按 before_seq 拉取目标附近的历史窗口,再返回可定位的消息 id。
    /// 与搜索跳转共用同一水合策略。
    func prepareMessageJump(messageID: String, channelSeq: Int64, conversationID: String) async -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        if let existing = jumpableMessageID(in: conversation, messageID: messageID, channelSeq: channelSeq) {
            return existing
        }
        guard channelSeq > 0 else { return nil }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        if let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive,
           channelSeq < boundary.fromSeq {
            toast = groupHistoryLimitedMessage
            return nil
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        do {
            let page = try await api.syncMessages(
                context: context,
                channelID: channelID,
                channelType: channelType,
                afterSeq: 0,
                beforeSeq: channelSeq + 1,
                limit: 50
            )
            guard isCurrentRemoteScope(scope),
                  isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return nil }
            let syncBoundary = historyBoundary(from: page, channelType: channelType)
            if let syncBoundary,
               syncBoundary.isRestrictive,
               channelSeq < syncBoundary.fromSeq {
                applyHistoryVisibilityBoundaryForGroup(
                    channelID: channelID,
                    boundary: syncBoundary
                )
                toast = groupHistoryLimitedMessage
                return nil
            }
            if !page.items.isEmpty {
                applyRemoteMessages(page.items, channelID: channelID, channelType: channelType, historyBoundary: syncBoundary)
            }
            conversationStore.normalizePinnedContextMessagesWithinLoadedWindow(conversationID: conversationID)
            guard let refreshed = conversations.first(where: { $0.id == conversationID }) else { return nil }
            return jumpableMessageID(in: refreshed, messageID: messageID, channelSeq: channelSeq)
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                toast = groupHistoryLimitedMessage
                return nil
            }
            handleRemoteError(error, fallback: "定位置顶消息失败")
            return nil
        }
    }

    private func jumpableMessageID(in conversation: Conversation, messageID: String, channelSeq: Int64) -> String? {
        let normalizedID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedID.isEmpty,
           let message = conversation.messages.first(where: { $0.id == normalizedID && !$0.isPinnedContextOnly }) {
            return message.id
        }
        if channelSeq > 0,
           let message = conversation.messages.first(where: { $0.channelSeq == channelSeq && !$0.isPinnedContextOnly }) {
            return message.id
        }
        return nil
    }

    private func searchMessageID(in conversation: Conversation, target: RemoteTenantSearchJumpTarget) -> String? {
        jumpableMessageID(
            in: conversation,
            messageID: nonEmptySearchString(target.messageID) ?? "",
            channelSeq: target.channelSeq ?? 0
        )
    }

    private func nonEmptySearchString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func searchMessages(in conversationID: String, keyword: String) async -> [MessageSearchHit] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return [] }

        // SQLite is the first authority for already-downloaded history. Access
        // expiry or a temporarily unavailable refresh service must never turn
        // local search into an authentication gate.
        let localHits: [MessageSearchHit]
        if let ticket = localMessageTicket,
           let persisted = try? await messagePersistence.search(
                ticket: ticket,
                query: trimmed,
                limit: 100
           ) {
            localHits = persisted
                .filter { $0.conversationID == conversationID }
                .map { result in
                    let message = result.message.model
                    return MessageSearchHit(
                        id: message.id,
                        messageID: message.id,
                        conversationID: conversationID,
                        senderName: message.senderName,
                        snippet: message.text,
                        time: message.time
                    )
                }
        } else {
            localHits = []
        }

        let context = apiContext
        guard context.hasIMSession else {
            return localHits
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let results = try await api.searchMessages(
                context: context,
                conversation: conversation,
                channelID: remoteChannelID(for: conversation),
                query: trimmed,
                limit: 50
            )
            guard isCurrentRemoteScope(scope) else { return [] }
            let remoteMessages = results.map(\.message)
            applyRemoteMessages(remoteMessages, channelID: remoteChannelID(for: conversation), channelType: apiChannelType(for: conversation.kind))
            let hidesGroupMemberTotals = conversation.kind == .group && !shouldShowGroupMemberCount
            let remoteHits = results.map { result in
                let remote = result.message
                let sender = user(for: remote.fromUID)
                let snippet = isAdminDeletedRemoteMessage(remote)
                    ? "原消息已删除"
                    : (isStickerPayload(remote.payload, contentType: remote.contentType)
                        ? stickerFallbackText(from: remote.payload)
                        : ((result.matchText ?? "").isEmpty ? messagePreview(remote) : (result.matchText ?? "")))
                return MessageSearchHit(
                    id: remote.messageID,
                    messageID: remote.messageID,
                    conversationID: conversationID,
                    senderName: sender?.name ?? remote.fromUID,
                    snippet: hidesGroupMemberTotals
                        ? textRemovingGroupMemberTotals(snippet)
                        : snippet,
                    time: displayTime(remote.createdAt)
                )
            }
            let remoteIDs = Set(remoteHits.map(\.messageID))
            return remoteHits + localHits.filter { !remoteIDs.contains($0.messageID) }
        } catch {
            guard isCurrentRemoteScope(scope) else { return localHits }
            if isNotFriendsError(error) {
                handleNotFriends(for: conversation)
            } else {
                handleRemoteError(error, fallback: "聊天记录搜索失败")
            }
            return localHits
        }
    }

    func searchTenantUsers(keyword: String) async -> [UserSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "请输入用户 ID"
            return []
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return []
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let items = try await api.searchTenantUsers(context: context, userID: trimmed)
            guard isCurrentRemoteScope(scope) else { return [] }
            return projectAvatarRealtime(items.map(userSearchResult))
        } catch {
            guard isCurrentRemoteScope(scope) else { return [] }
            handleRemoteError(error, fallback: "查找用户失败")
            return []
        }
    }

    func applyFriendFromSearch(_ result: UserSearchResult, message: String) async -> UserSearchResult? {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        guard !result.isCancelledUser else {
            toast = "该用户已注销，无法添加好友"
            return result
        }
        guard canCurrentUserInitiateFriendRequest else {
            toast = "管理员已关闭好友申请"
            return result
        }
        guard Self.canInitiateFriendRequestFromSearch(pairCanApply: result.canApplyFriend) else {
            toast = userSearchBlockedMessage(result)
            return result
        }
        do {
            let applyResult = try await api.applyFriend(
                context: context,
                targetUID: result.id,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "search_user"
            )
            guard isCurrentRemoteScope(scope) else { return nil }
            var updated = result
            let resolution = Self.friendApplyResolution(applyResult)
            switch resolution {
            case .established:
                updated.relationStatus = "friend"
                updated.canApplyFriend = false
                updated.reason = ""
                updated.friendAction = "none"
                toast = FriendAddPresentation.establishedMessage
            case .pending:
                updated.relationStatus = "pending_out"
                updated.canApplyFriend = false
                updated.reason = "pending_out"
                updated.friendAction = "none"
                toast = FriendAddPresentation.sentMessage
            case .terminal:
                updated.relationStatus = applyResult.relationStatus.isEmpty ? "history" : applyResult.relationStatus
                updated.canApplyFriend = false
                updated.reason = applyResult.outcome
                updated.friendAction = applyResult.friendAction
                toast = Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage
            }
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            guard isCurrentRemoteScope(scope) else { return nil }
            return updated
        } catch IMAPIError.conflict(let code, _) {
            guard isCurrentRemoteScope(scope) else { return nil }
            await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            guard isCurrentRemoteScope(scope) else { return nil }
            var updated = result
            if isFriendID(result.id) {
                updated.relationStatus = "friend"
                updated.reason = ""
            } else {
                updated.relationStatus = "pending_out"
                updated.reason = "pending_out"
            }
            updated.canApplyFriend = false
            updated.friendAction = "none"
            toast = Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage
            return updated
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            handleRemoteError(error, fallback: "好友申请失败")
            return nil
        }
    }

    @discardableResult
    func applyFriend(to user: IMUser, message: String = "你好，我想添加你为好友", source: String = "profile") async -> Bool {
        let targetID = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard !targetID.isEmpty else {
            toast = "用户信息不完整，无法添加好友"
            return false
        }
        guard targetID != currentUser.id && targetID != context.imUID else {
            toast = "不能添加自己为好友"
            return false
        }
        guard !isCancelledProfile(user) else {
            toast = "该用户已注销，无法添加好友"
            return false
        }
        guard !isFriendID(targetID) else {
            toast = "已是好友"
            return true
        }
        guard canCurrentUserInitiateFriendRequest else {
            toast = "管理员已关闭好友申请"
            return false
        }
        do {
            let applyResult = try await api.applyFriend(
                context: context,
                targetUID: targetID,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                source: source
            )
            guard isCurrentRemoteScope(scope) else { return false }
            let resolution = Self.friendApplyResolution(applyResult)
            switch resolution {
            case .established:
                toast = FriendAddPresentation.establishedMessage
            case .pending:
                toast = FriendAddPresentation.sentMessage
            case .terminal:
                toast = Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage
            }
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            guard isCurrentRemoteScope(scope) else { return false }
            return resolution != .terminal
        } catch IMAPIError.conflict(let code, _) {
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            guard isCurrentRemoteScope(scope) else { return false }
            toast = Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "好友申请失败")
            return false
        }
    }

    func togglePinned(_ conversationID: String) {
        guard let targetConversation = conversations.first(where: { $0.id == conversationID }),
              conversationListSupportsMutableActions(targetConversation) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let change = conversationStore.toggleConversationPinned(conversationID: conversationID) else { return }
        toast = change.conversation.isPinned ? "已置顶会话" : "已取消置顶"
        let conversation = change.conversation
        Task {
            do {
                try await api.updateConversationSettings(context: context, conversation: conversation, channelID: remoteChannelID(for: conversation))
                guard isCurrentRemoteScope(scope) else { return }
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                conversationStore.restoreConversationPinned(conversationID: conversationID, to: change.previousValue)
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation)
                } else {
                    handleRemoteError(error, fallback: "会话设置失败")
                }
            }
        }
    }

    func toggleMuted(_ conversationID: String) {
        guard let targetConversation = conversations.first(where: { $0.id == conversationID }),
              conversationListSupportsMutableActions(targetConversation) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let change = conversationStore.toggleConversationMuted(conversationID: conversationID) else { return }
        let conversation = change.conversation
        mirrorGroupNotificationMutedIfNeeded(for: conversation, muted: conversation.isMuted)
        toast = conversation.isMuted ? "已开启免打扰" : "已关闭免打扰"
        Task {
            do {
                try await api.updateConversationSettings(context: context, conversation: conversation, channelID: remoteChannelID(for: conversation))
                guard isCurrentRemoteScope(scope) else { return }
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                conversationStore.restoreConversationMuted(conversationID: conversationID, to: change.previousValue)
                mirrorGroupNotificationMutedIfNeeded(for: conversation, muted: change.previousValue)
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation)
                } else {
                    handleRemoteError(error, fallback: "会话设置失败")
                }
            }
        }
    }

    private func mirrorGroupNotificationMutedIfNeeded(for conversation: Conversation, muted: Bool) {
        guard conversation.kind == .group else { return }
        let channelID = remoteChannelID(for: conversation).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = groups.firstIndex(where: { group in
            group.id == conversation.id
                || (!channelID.isEmpty && group.id == channelID)
                || (!title.isEmpty && group.name == title)
        }) else { return }
        groups[index].muted = muted
    }

    func group(id: String) -> GroupInfo? {
        groups.first { $0.id == id }
    }

    func group(forConversationID conversationID: String) -> GroupInfo? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        return group(for: conversation)
    }

    #if DEBUG
    func overrideAPIContextForTesting(_ context: IMAPIContext) {
        apiContext = context
    }

    func sessionReauthenticationMatchesContextForTesting(_ context: IMAPIContext) -> Bool {
        apiContext.authSessionFence == context.authSessionFence
            && apiContext.platformToken == context.platformToken
            && apiContext.imToken == context.imToken
            && apiContext.platformAuthSession == context.platformAuthSession
            && apiContext.tenantAuthSession == context.tenantAuthSession
            && apiContext.tenantAPIBaseURL == context.tenantAPIBaseURL
            && apiContext.imAPIBaseURL == context.imAPIBaseURL
            && apiContext.accessExpiresAt == context.accessExpiresAt
            && apiContext.pendingRefreshRequestID == context.pendingRefreshRequestID
    }

    func persistConversationSnapshotForReauthenticationTesting(conversationID: String) async {
        await persistConversationSnapshotImmediately(
            conversationID: conversationID, scope: remoteDataScopeKey(for: apiContext), source: .localMutation
        )
    }

    func attachmentUploadTaskForReauthenticationTesting(messageID: String) -> Task<Void, Never>? {
        attachmentUploadOperations[messageID]?.task
    }
    #endif

}
