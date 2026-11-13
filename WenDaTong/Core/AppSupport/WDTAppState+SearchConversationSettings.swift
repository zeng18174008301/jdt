// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
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

// MARK: - Search and ConversationMessageSnapshot Settings

// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
struct TenantSearchHTTPFailure: Error {
    let status: Int
    let code: String
}

enum TenantSearchFailure: Equatable {
    case shortMessageQuery, invalidQuery, busy, timeout, unavailable, network, access, cursorExpired
    case legacyPageLimit // WDT_IOS1_SEARCH_CURSOR_V2_20261113

    init(error: Error) {
        if let failure = error as? TenantSearchHTTPFailure {
            switch (failure.status, failure.code) {
            case (_, "query_too_short"): self = .shortMessageQuery
            case (_, "search_cursor_expired"): self = .cursorExpired
            case (_, "search_deep_pagination_not_allowed"): self = .legacyPageLimit // WDT_IOS1_SEARCH_CURSOR_V2_20261113
            case (401, _), (403, _): self = .access
            case (504, _): self = .timeout
            case (500...599, _): self = .unavailable
            case (400...499, _): self = .invalidQuery
            default: self = .unavailable
            }
        } else if let error = error as? IMAPIError {
            switch error {
            case .rateLimited: self = .busy
            case .unauthorized, .forbidden, .forcedAuthRequired, .securityBlocked, .businessForbidden:
                self = .access
            default: self = .unavailable
            }
        } else if let error = error as? URLError {
            self = error.code == .timedOut ? .timeout : .network
        } else {
            self = .unavailable
        }
    }

    var message: String {
        switch self {
        case .shortMessageQuery: return "请至少输入 2 个字"
        case .invalidQuery: return "请检查关键词或筛选条件"
        case .busy: return "搜索繁忙，请稍后再试"
        case .timeout: return "搜索超时，请重试"
        case .unavailable: return "搜索暂时不可用"
        case .network: return "网络连接异常，请重试"
        case .access: return "当前登录或会话无法搜索"
        case .cursorExpired: return "结果已过期，请刷新搜索"
        case .legacyPageLimit: return "当前搜索只覆盖部分较新的记录" // WDT_IOS1_SEARCH_CURSOR_V2_20261113
        }
    }

    var canRetry: Bool {
        switch self {
        case .shortMessageQuery, .invalidQuery, .access, .legacyPageLimit: return false // WDT_IOS1_SEARCH_CURSOR_V2_20261113
        default: return true
        }
    }
}

extension ChatMessage {
    var isHiddenFromConversationSearch: Bool { isDeletedLocally || status == .recalled }
}

enum TenantSearchOutcome {
    case response(RemoteTenantSearchResponse)
    case failure(TenantSearchFailure)
    case retired
}

@MainActor
final class TenantSearchRequests {
    private var generation: UInt64 = 0
    private var active: (generation: UInt64, task: Task<RemoteTenantSearchResponse, Error>)?

    func retire() {
        generation &+= 1
        active?.task.cancel()
    }

    func run(
        isCurrent: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor () async throws -> RemoteTenantSearchResponse
    ) async throws -> RemoteTenantSearchResponse {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        retire()
        let ticket = generation
        if let predecessor = active?.task {
            _ = await predecessor.result
        }
        try Task.checkCancellation()
        guard ticket == generation, isCurrent() else { throw CancellationError() }

        let task = Task {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            do {
                return try await request()
            } catch let IMAPIError.rateLimited(code, _, retryAfter, _)
                where code == "search_capacity_limited" || code == "rate_limited" {
                let seconds = UInt64(max(0, retryAfter ?? 1))
                let maxSeconds = UInt64.max / 1_000_000_000
                try await Task.sleep(nanoseconds: min(seconds, maxSeconds) * 1_000_000_000)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                return try await request()
            }
        }
        active = (ticket, task)
        defer {
            if active?.generation == ticket { active = nil }
        }
        do {
            let response = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            try Task.checkCancellation()
            guard ticket == generation, isCurrent() else { throw CancellationError() }
            return response
        } catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { throw CancellationError() }
            throw error
        }
    }
}
// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

// WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_BEGIN
@MainActor
final class SearchInvalidationStore {
    private struct Stamp {
        let version: Int64
        let updatedAt: String
    }

    private var applied: [String: Stamp] = [:]
    private let subject = PassthroughSubject<SearchInvalidationEvent, Never>()

    var updates: AnyPublisher<SearchInvalidationEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func accept(_ invalidation: SearchInvalidationEvent) -> Bool {
        if invalidation.isTenantScopeReset { return true }
        let dedupeKey = invalidation.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dedupeKey.isEmpty else { return true }
        let newUpdatedAt = invalidation.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let previous = applied[dedupeKey] {
            if invalidation.version > 0 || previous.version > 0 {
                guard invalidation.version > previous.version else { return false }
            } else if !newUpdatedAt.isEmpty || !previous.updatedAt.isEmpty {
                guard newUpdatedAt > previous.updatedAt else { return false }
            } else {
                return false
            }
        }
        applied[dedupeKey] = Stamp(
            version: invalidation.version,
            updatedAt: newUpdatedAt
        )
        return true
    }

    func publish(_ event: SearchInvalidationEvent) {
        subject.send(event)
    }

    func reset(_ event: SearchInvalidationEvent) {
        applied.removeAll()
        publish(event)
    }
}
// WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_END

extension AppState {
    func applySearchInvalidations(_ invalidations: [SearchInvalidationEvent]) {
        for invalidation in invalidations {
            applySearchInvalidation(invalidation)
        }
    }

    // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_BEGIN
    func applySearchInvalidation(_ invalidation: SearchInvalidationEvent) {
        guard searchInvalidationBelongsToCurrentTenant(invalidation) else { return }
        let scopedInvalidation = searchInvalidationScopedToCurrentTenant(invalidation)
        guard searchInvalidationStore.accept(scopedInvalidation) else { return }
        // WDT_IOS1_SEARCH_HISTORY_20261113_BEGIN
        if scopedInvalidation.isConversationRemoval, let channel = scopedInvalidation.normalizedChannelID,
           let type = scopedInvalidation.normalizedChannelType, let tenant = apiContext.tenantID,
           let account = searchHistoryAccount(context: apiContext) {
            let key = "\(type):\(normalizedRemoteChannelID(channel, channelType: type))"
            tenantSearchHistory.clearConversation(key, tenant: tenant, account: account)
        }
        // WDT_IOS1_SEARCH_HISTORY_20261113_END
        applySearchInvalidationToLocalCaches(scopedInvalidation)
        searchInvalidationStore.publish(scopedInvalidation)
    }

    func clearTenantScopedSearchState(reason: String) {
        tenantSearchRequests.retire() // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        // WDT_IOS1_SEARCH_HISTORY_20261113_BEGIN
        if let account = searchHistoryAccount(context: apiContext) {
            if reason == "account_cancelled" || reason == "device_revoked" {
                tenantSearchHistory.clearAccount(account)
            } else if reason == "tenant_session_revoked", let tenant = apiContext.tenantID {
                tenantSearchHistory.clearTenant(tenant, account: account)
            }
        }
        // WDT_IOS1_SEARCH_HISTORY_20261113_END
        searchInvalidationStore.reset(.tenantScopeReset(tenantID: apiContext.tenantID ?? "", reason: reason))
    }
    // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_END

    // WDT_IOS1_SEARCH_HISTORY_20261113_BEGIN
    func recentTenantSearches(conversationID: String?, owner: ChatBubbleSessionIdentity) -> [String] {
        guard let scope = searchHistoryScope(conversationID: conversationID, owner: owner) else { return [] }
        return tenantSearchHistory.list(scope: scope)
    }

    func recordTenantSearch(_ term: String, conversationID: String?, owner: ChatBubbleSessionIdentity) {
        guard let scope = searchHistoryScope(conversationID: conversationID, owner: owner) else { return }
        tenantSearchHistory.add(term, scope: scope)
    }

    func removeTenantSearch(_ term: String, conversationID: String?, owner: ChatBubbleSessionIdentity) {
        guard let scope = searchHistoryScope(conversationID: conversationID, owner: owner) else { return }
        tenantSearchHistory.remove(term, scope: scope)
    }

    func clearTenantSearchHistory(conversationID: String?, owner: ChatBubbleSessionIdentity) {
        guard let scope = searchHistoryScope(conversationID: conversationID, owner: owner) else { return }
        tenantSearchHistory.clear(scope: scope)
    }

    func purgeSearchHistoryForAccessBlock(_ code: String, context: IMAPIContext, tenant: String?) {
        guard let account = searchHistoryAccount(context: context) else { return }
        switch code {
        case "account_disabled", "account_blocked", "account_locked":
            tenantSearchHistory.clearAccount(account)
        case "tenant_member_disabled", "tenant_member_not_found", "workspace_identity_unlinked":
            if let tenant { tenantSearchHistory.clearTenant(tenant, account: account) }
        default:
            break
        }
    }

    private func searchHistoryAccount(context: IMAPIContext) -> TenantSearchHistoryStore.Account? {
        guard let account = context.accountID else { return nil }
        let client = api as? IMAPIClient
        guard let deployment = client?.configuredAppBootstrapPrimaryBase?.absoluteString
            ?? client?.platformBase.absoluteString ?? context.tenantAPIBaseURL else { return nil }
        return .init(deployment: "\(context.appID)|\(deployment)", account: account)
    }

    private func searchHistoryScope(conversationID: String?, owner: ChatBubbleSessionIdentity) -> TenantSearchHistoryStore.Scope? {
        let context = apiContext
        guard isAuthenticated, context.hasIMSession, owner == chatBubbleSessionIdentity,
              let account = searchHistoryAccount(context: context),
              let tenant = context.tenantID, let subject = context.imUID else { return nil }
        let key: String?
        if let conversationID {
            guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
            key = "\(apiChannelType(for: conversation.kind)):\(remoteChannelID(for: conversation))"
        } else {
            key = nil
        }
        return .init(account: account, tenant: tenant, imSubject: subject, conversation: key)
    }
    // WDT_IOS1_SEARCH_HISTORY_20261113_END

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

    private func applySearchInvalidationToLocalCaches(_ invalidation: SearchInvalidationEvent) {
        if let fileID = invalidation.normalizedFileID {
            files = files.filter { $0.id != fileID }
        }
        if invalidation.isConversationRemoval,
           let channelID = invalidation.normalizedChannelID,
           let conversationID = conversationStore.conversationMessageSnapshots().first(where: { conversation in
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
        cursorV2: String? = nil, // WDT_IOS1_SEARCH_CURSOR_V2_20261113
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
        hasLink: Bool = false, // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        messageContent: String? = nil, // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        date: String? = nil
    ) async -> TenantSearchOutcome { // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDate = date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty || !trimmedDate.isEmpty else { return .failure(.invalidQuery) } // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        let context = apiContext
        guard context.hasIMSession else {
            return .failure(.access) // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        }
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
        let channelID: String?
        let channelType: String?
        if normalizedScope == "conversation" {
            guard let conversationID,
                  let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else {
                return .failure(.access) // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
            }
            channelID = remoteChannelID(for: conversation)
            channelType = apiChannelType(for: conversation.kind)
        } else {
            channelID = nil
            channelType = nil
        }
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        let identity = chatBubbleSessionIdentity
        let isCurrent: @MainActor () -> Bool = {
            self.apiContext.hasIMSession && self.chatBubbleSessionIdentity == identity
                && self.apiContext.tenantAPIBaseURL == context.tenantAPIBaseURL
        }
        do {
            let response = try await tenantSearchRequests.run(isCurrent: isCurrent) { [self] in
                // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
                func fetch(cursorV2: String?) async throws -> RemoteTenantSearchResponse {
                    try await api.tenantSearch(
                        context: context,
                        scope: normalizedScope.isEmpty ? "global" : normalizedScope,
                        query: trimmed,
                        types: types,
                        limit: limit,
                        cursor: cursor,
                        cursorV2: cursorV2,
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
                        hasLink: hasLink, // WDT_IOS1_SEARCH_LINK_FILTER_20261113
                        messageContent: messageContent, // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
                        date: trimmedDate.isEmpty ? nil : trimmedDate
                    )
                }
                do {
                    return try await fetch(cursorV2: cursorV2)
                } catch let failure as TenantSearchHTTPFailure
                    where cursorV2 == "" && failure.code == "search_cursor_unavailable" {
                    try Task.checkCancellation()
                    guard isCurrent() else { throw CancellationError() }
                    return try await fetch(cursorV2: nil)
                }
                // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END
            }
            return .response(response)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled, isCurrent() else { return .retired }
            handleRemoteError(error, fallback: "搜索失败", silent: true)
            return .failure(TenantSearchFailure(error: error))
        }
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
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

    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    func conversationSearchDateMessages(_ conversationID: String, days: [DateInterval], excludedIDs: Set<String>,
                                        excludedSequences: Set<Int64>) async -> [ChatMessage] {
        let owner = chatBubbleSessionIdentity
        let ticket = localMessageTicket
        guard apiContext.hasIMSession,
              let initial = conversationStore.conversationMessageSnapshot(id: conversationID) else { return [] }
        let minimumSequence = conversationStore.historyBoundary(for: initial)?.fromSeq ?? 1
        let initiallyRevoked = initial.messages.filter(\.isHiddenFromConversationSearch)
        let initialHiddenIDs = excludedIDs.union(initiallyRevoked.map(\.id))
        let initialHiddenSequences = excludedSequences.union(initiallyRevoked.map(\.channelSeq))
        let cached: [ChatMessage]
        if let ticket {
            cached = (try? await messagePersistence.loadSearchDateMessages(ticket: ticket,
                conversationID: conversationID, days: days, minimumSequence: minimumSequence,
                excludedIDs: initialHiddenIDs, excludedSequences: initialHiddenSequences)) ?? []
        } else {
            cached = []
        }
        guard !Task.isCancelled, owner == chatBubbleSessionIdentity, ticket == localMessageTicket,
              let current = conversationStore.conversationMessageSnapshot(id: conversationID) else { return [] }
        let boundary = conversationStore.historyBoundary(for: current)?.fromSeq ?? 1
        let revoked = current.messages.filter(\.isHiddenFromConversationSearch)
        let hiddenIDs = initialHiddenIDs.union(revoked.map(\.id))
        let hiddenSequences = initialHiddenSequences.union(revoked.map(\.channelSeq))
        return (current.messages + cached).filter { message in
            guard let date = message.createdAt, message.isHistorySearchDateContent,
                  message.channelSeq >= boundary, !hiddenIDs.contains(message.id),
                  !hiddenSequences.contains(message.channelSeq) else { return false }
            return days.contains { date >= $0.start && date < $0.end }
        }
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    func visibleConversationSearchHits(_ items: [RemoteTenantSearchResult], _ conversationID: String) -> [RemoteTenantSearchResult] {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return [] }
        let channel = remoteChannelID(for: conversation)
        let historyBoundary = conversationStore.historyBoundary(for: conversation)
        let hidden = conversation.messages.filter(\.isHiddenFromConversationSearch)
        let hiddenIDs = Set(hidden.map(\.id))
        let hiddenSequences = Set(hidden.map(\.channelSeq).filter { $0 > 0 })
        return items.filter { item in
            guard !item.isBlockedFromChatSearchDisplay else { return false }
            guard let target = item.jumpTarget else { return true }
            if let targetChannel = target.channelID, targetChannel != channel && targetChannel != conversation.id { return false }
            if let sequence = target.channelSeq, sequence > 0 {
                if hiddenSequences.contains(sequence) { return false }
                if let historyBoundary, historyBoundary.isRestrictive, sequence < historyBoundary.fromSeq { return false }
            }
            return target.messageID.map { !hiddenIDs.contains($0) } ?? true
        }
    }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END

    func conversationID(for searchTarget: RemoteTenantSearchJumpTarget?) -> String? {
        guard let channelID = searchTarget?.channelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelID.isEmpty else {
            return nil
        }
        return conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.id == channelID || remoteChannelID(for: conversation) == channelID
        }?.id
    }

    func prepareSearchJumpTarget(_ target: RemoteTenantSearchJumpTarget, conversationID: String) async -> String? {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        guard !Task.isCancelled else { return nil }
        let type = apiChannelType(for: conversation.kind)
        let expectedChannel = remoteChannelID(for: conversation)
        if let claimedType = nonEmptySearchString(target.channelType), claimedType != type { return nil }
        if let claimedChannel = nonEmptySearchString(target.channelID),
           claimedChannel != conversation.id,
           normalizedRemoteChannelID(claimedChannel, channelType: type) != expectedChannel { return nil }
        if let sequence = target.channelSeq, sequence > 0,
           let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive, sequence < boundary.fromSeq {
            setToast(groupHistoryLimitedMessage)
            return nil
        }
        guard !hasHiddenSearchMessage(in: conversation, target: target) else { return nil }
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        if let messageID = searchMessageID(in: conversation, target: target) {
            return messageID
        }
        guard let channelSeq = target.channelSeq, channelSeq > 0 else {
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        let owner = chatBubbleSessionIdentity
        let channelID = expectedChannel
        let channelType = type
        let isCurrent: @MainActor () -> Bool = { [self] in
            !Task.isCancelled && isCurrentRemoteScope(scope) && chatBubbleSessionIdentity == owner
                && apiContext.tenantAPIBaseURL == context.tenantAPIBaseURL
        }
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        do {
            let tracedPage = try await traceMessageHTTPRequest {
                try await api.syncMessages(
                    context: context,
                    channelID: channelID,
                    channelType: channelType,
                    afterSeq: 0,
                    beforeSeq: channelSeq + 1,
                    limit: 50
                )
            }
            let page = tracedPage.value
            guard isCurrent(), // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                  isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return nil }
            let syncBoundary = historyBoundary(from: page, channelType: channelType)
            if let syncBoundary,
               syncBoundary.isRestrictive,
               channelSeq < syncBoundary.fromSeq {
                applyHistoryVisibilityBoundaryForGroup(
                    channelID: channelID,
                    boundary: syncBoundary
                )
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                return nil
            }
            if !page.items.isEmpty {
                guard await applyRemoteMessagesFromAsyncEntry(page.items, channelID: channelID, channelType: channelType,
                    historyBoundary: syncBoundary, sourceCorrelations: [tracedPage.sourceCorrelation], isCurrent: {
                        isCurrent() // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                            && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration)
                    }) else { return nil }
            }
            guard isCurrent() else { return nil } // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            conversationStore.normalizePinnedContextMessagesWithinLoadedWindow(conversationID: conversationID)
            guard let refreshed = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
            guard !hasHiddenSearchMessage(in: refreshed, target: target) else { return nil }
            return searchMessageID(in: refreshed, target: target)
        } catch {
            guard isCurrent() else { return nil } // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
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
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
        if let existing = jumpableMessageID(in: conversation, messageID: messageID, channelSeq: channelSeq) {
            return existing
        }
        guard channelSeq > 0 else { return nil }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        if let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive,
           channelSeq < boundary.fromSeq {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
            return nil
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        do {
            let tracedPage = try await traceMessageHTTPRequest {
                try await api.syncMessages(
                    context: context,
                    channelID: channelID,
                    channelType: channelType,
                    afterSeq: 0,
                    beforeSeq: channelSeq + 1,
                    limit: 50
                )
            }
            let page = tracedPage.value
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                return nil
            }
            if !page.items.isEmpty {
                guard await applyRemoteMessagesFromAsyncEntry(page.items, channelID: channelID, channelType: channelType,
                    historyBoundary: syncBoundary, sourceCorrelations: [tracedPage.sourceCorrelation], isCurrent: {
                        self.isCurrentRemoteScope(scope) && context.sessionEpoch == self.apiContext.sessionEpoch
                            && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration)
                    }) else { return nil }
            }
            conversationStore.normalizePinnedContextMessagesWithinLoadedWindow(conversationID: conversationID)
            guard let refreshed = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
            return jumpableMessageID(in: refreshed, messageID: messageID, channelSeq: channelSeq)
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                return nil
            }
            handleRemoteError(error, fallback: "定位置顶消息失败")
            return nil
        }
    }

    private func jumpableMessageID(in conversation: ConversationMessageSnapshot, messageID: String, channelSeq: Int64) -> String? {
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

    private func searchMessageID(in conversation: ConversationMessageSnapshot, target: RemoteTenantSearchJumpTarget) -> String? {
        jumpableMessageID(
            in: conversation,
            messageID: nonEmptySearchString(target.messageID) ?? "",
            channelSeq: target.channelSeq ?? 0
        )
    }

    private func hasHiddenSearchMessage(in conversation: ConversationMessageSnapshot, target: RemoteTenantSearchJumpTarget) -> Bool {
        let id = nonEmptySearchString(target.messageID)
        let sequence = target.channelSeq ?? 0
        return conversation.messages.contains { message in
            message.isHiddenFromConversationSearch &&
                (message.id == id || (sequence > 0 && message.channelSeq == sequence))
        }
    }

    private func nonEmptySearchString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111_BEGIN
    func searchMessages(in conversationID: String, keyword: String) async -> [MessageSearchHit] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return [] }

        let scope = remoteDataScopeKey(for: apiContext)
        let epoch = apiContext.sessionEpoch
        let generation = localMessageSessionGeneration
        let ticket = localMessageTicket
        let isCurrentSearchAuthority: @MainActor () -> Bool = {
            self.remoteDataScopeKey(for: self.apiContext) == scope && self.apiContext.sessionEpoch == epoch
                && self.localMessageSessionGeneration == generation && (ticket == nil || self.localMessageTicket == ticket)
        }
        // Cached history remains available under the same authority without an IM token.
        let persisted: [LocalMessageSearchResult] = if let ticket {
            (try? await messagePersistence.search(ticket: ticket, query: trimmed, limit: 100)) ?? []
        } else { [] }
        guard isCurrentSearchAuthority() else { return [] }
        let localHits = persisted.filter { $0.conversationID == conversationID }.map { result in
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

        let context = apiContext
        guard context.hasIMSession else {
            return localHits
        }
        do {
            let tracedPage = try await traceMessageHTTPRequest {
                try await api.searchMessages(
                    context: context,
                    conversation: conversation,
                    channelID: remoteChannelID(for: conversation),
                    query: trimmed,
                    limit: 50
                )
            }
            let results = tracedPage.value
            // WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_BEGIN
            guard isCurrentSearchAuthority() else { return [] }
            let remoteMessages = results.map(\.message)
            let applied = await applyRemoteMessagesFromAsyncEntry(remoteMessages,
                channelID: remoteChannelID(for: conversation), channelType: apiChannelType(for: conversation.kind),
                sourceCorrelations: [tracedPage.sourceCorrelation], isCurrent: isCurrentSearchAuthority)
            guard isCurrentSearchAuthority() else { return [] }
            guard applied else { return localHits }
            // WDT_IOS1_PHASE6_REVIEW_SEARCH_AND_TRACE_20261111_END
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
            guard isCurrentSearchAuthority() else { return [] }
            guard apiContext.hasIMSession else { return localHits }
            if isNotFriendsError(error) {
                handleNotFriends(for: conversation)
            } else {
                handleRemoteError(error, fallback: "聊天记录搜索失败")
            }
            return isCurrentSearchAuthority() ? localHits : []
        }
    }
    // WDT_IOS1_PHASE6_SEARCH_READ_AUTHORITY_20261111_END

    func searchTenantUsers(keyword: String) async -> [UserSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入用户 ID")
            return []
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        guard !result.isCancelledUser else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该用户已注销，无法添加好友")
            return result
        }
        guard canCurrentUserInitiateFriendRequest else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭好友申请")
            return result
        }
        guard Self.canInitiateFriendRequestFromSearch(pairCanApply: result.canApplyFriend) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(userSearchBlockedMessage(result))
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.establishedMessage)
            case .pending:
                updated.relationStatus = "pending_out"
                updated.canApplyFriend = false
                updated.reason = "pending_out"
                updated.friendAction = "none"
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.sentMessage)
            case .terminal:
                updated.relationStatus = applyResult.relationStatus.isEmpty ? "history" : applyResult.relationStatus
                updated.canApplyFriend = false
                updated.reason = applyResult.outcome
                updated.friendAction = applyResult.friendAction
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            return updated
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            handleRemoteError(error, fallback: "好友申请失败")
            return nil
        }
    }

    @discardableResult
    func applyFriend(to user: IMUser, message: String = "你好，我想添加你为好友", source: String = "profile", sourceGroupID: String? = nil) async -> Bool {
        let targetID = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard !targetID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户信息不完整，无法添加好友")
            return false
        }
        guard targetID != currentUser.id && targetID != context.imUID else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("不能添加自己为好友")
            return false
        }
        guard !isCancelledProfile(user) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该用户已注销，无法添加好友")
            return false
        }
        guard !isFriendID(targetID) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已是好友")
            return true
        }
        guard canCurrentUserInitiateFriendRequest else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭好友申请")
            return false
        }
        if let sourceGroupID, group(id: sourceGroupID)?.memberFriendApplyEnabled != true {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前群暂不允许从群内添加好友")
            return false
        }
        do {
            let applyResult: RemoteFriendApplyResult
            if let sourceGroupID {
                guard let client = api as? IMAPIClient else { return false }
                applyResult = try await client.applyFriend(context: context, targetUID: targetID,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines), source: "group", sourceGroupID: sourceGroupID)
            } else {
                applyResult = try await api.applyFriend(context: context, targetUID: targetID,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
            }
            guard isCurrentRemoteScope(scope) else { return false }
            let resolution = Self.friendApplyResolution(applyResult)
            switch resolution {
            case .established:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.establishedMessage)
            case .pending:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.sentMessage)
            case .terminal:
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            }
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            guard isCurrentRemoteScope(scope) else { return false }
            return resolution != .terminal
        } catch IMAPIError.conflict(let code, _) {
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            guard isCurrentRemoteScope(scope) else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "好友申请失败")
            return false
        }
    }

    func togglePinned(_ conversationID: String) {
        guard let targetConversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversationListSupportsMutableActions(targetConversation.conversation) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let change = conversationStore.toggleConversationPinned(conversationID: conversationID) else { return }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(change.conversation.isPinned ? "已置顶会话" : "已取消置顶")
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
        guard let targetConversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversationListSupportsMutableActions(targetConversation.conversation) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let change = conversationStore.toggleConversationMuted(conversationID: conversationID) else { return }
        let conversation = change.conversation
        mirrorGroupNotificationMutedIfNeeded(for: conversation, muted: conversation.isMuted)
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(conversation.isMuted ? "已开启免打扰" : "已关闭免打扰")
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

    private func mirrorGroupNotificationMutedIfNeeded(for conversation: ConversationMessageSnapshot, muted: Bool) {
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
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return nil }
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
