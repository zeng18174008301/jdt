import Foundation
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话分页结果标记为可跨任务传递的值快照
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteConversationPage = IM4Data.RemoteConversationPage
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

struct ConversationPageFailure: Error, LocalizedError {
    let statusCode: Int
    let code: String
    var errorDescription: String? { "会话加载未完成，请重试同步" }
}

@MainActor
enum ConversationPageLoader {
    static func load(
        request: (String) async throws -> RemoteConversationPage,
        validate: () throws -> Void,
        onPage: (RemoteConversationPage) throws -> Void,
        onRestart: () throws -> Void,
        delay: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> Int64 {
        var retries = 0
        var restarted = false
        while true {
            var cursor = ""
            var seenCursors = Set<String>()
            var snapshotID: String?
            var version: Int64?
            do {
                while true {
                    try Task.checkCancellation()
                    try validate()
                    let page: RemoteConversationPage
                    do {
                        page = try await request(cursor)
                    } catch {
                        try validate()
                        let transient: Bool
                        if let failure = error as? ConversationPageFailure {
                            transient = (500...599).contains(failure.statusCode)
                        } else if let urlError = error as? URLError {
                            transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code)
                        } else {
                            transient = false
                        }
                        guard transient, retries < 2 else { throw error }
                        retries += 1
                        try await delay(retries == 1 ? 400_000_000 : 1_000_000_000)
                        continue
                    }
                    try Task.checkCancellation()
                    try validate()
                    let id = page.snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pageVersion = page.snapshotVersion ?? 0
                    guard !id.isEmpty, pageVersion >= 0,
                          snapshotID == nil || snapshotID == id,
                          version == nil || version == pageVersion else {
                        throw ConversationPageFailure(statusCode: 0, code: "invalid_snapshot")
                    }
                    snapshotID = id
                    version = pageVersion
                    if page.hasMore {
                        let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !next.isEmpty, next != cursor, seenCursors.insert(next).inserted else {
                            throw ConversationPageFailure(statusCode: 0, code: "invalid_cursor")
                        }
                        cursor = next
                    }
                    try onPage(page)
                    if !page.hasMore { return pageVersion }
                    await Task.yield()
                }
            } catch let failure as ConversationPageFailure where !restarted && (
                failure.code == "conversation_page_cursor_expired"
                    || failure.code == "conversation_page_credentials_advanced"
            ) {
                try Task.checkCancellation()
                try validate()
                restarted = true
                try onRestart()
            }
        }
    }
}

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话同步结果标记为可跨任务传递的值快照
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteConversationSyncData = IM4Data.RemoteConversationSyncData
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteRemovedConversation = IM4Data.RemoteRemovedConversation
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：置顶消息响应标记为可跨任务传递的值快照
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemotePinnedMessagesResponse = IM4Data.RemotePinnedMessagesResponse
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端会话模型标记为可跨任务传递的值快照
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteConversation = IM4Data.RemoteConversation
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// JHT_MOD_BEGIN APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改开始：远端 mention 摘要标记为可跨任务传递的值快照
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMentionSummary = IM4Data.RemoteMentionSummary
// JHT_MOD_END APPSTATE_REMOTE_MODEL_SENDABLE_PERF_20260913 - 修改结束
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END
