import IM4Domain
import IM4DesignSystem
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

func chatTimelineMessagesForRendering(_ messages: [ChatMessage], showsProcessingNotices: Bool = true) -> [ChatMessage] {
    // WDT_APP_CONTRACT_20261021_08: presentation only; retain tombstones in the store.
    if !showsProcessingNotices {
        return messages.filter { !$0.isPinnedContextOnly && !$0.isDeletedLocally && $0.status != .recalled }
    }
    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_FILTER - 修改开始：普通输入重绘时避免无 pinned-context 消息的数组重分配
    guard messages.contains(where: { $0.isPinnedContextOnly }) else { return messages }
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_FILTER - 修改结束
    return messages.filter { !$0.isPinnedContextOnly }
}

public func chatMessagesShareStorage(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    // Both arrays own their buffers for the duration of the comparison.
    // Mutating either value while the snapshot is retained uses copy-on-write.
    return lhs.withUnsafeBufferPointer { left in
        rhs.withUnsafeBufferPointer { right in
            left.baseAddress == right.baseAddress
        }
    }
}

// WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
public func chatPinnedMessagesForRendering(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { $0.isPinned && !$0.isDeletedLocally && $0.status != .recalled }
}
// WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
@MainActor
final public class ChatReplySourceLookup {
    private var source: [ChatMessage] = []
    private var indexByID: [String: Int] = [:]
    private var indexBySequence: [Int64: Int] = [:]

    public func message(in messages: [ChatMessage], id: String, sequence: Int64) -> ChatMessage? {
        if !chatMessagesShareStorage(source, messages) {
            source = messages
            indexByID.removeAll(keepingCapacity: true)
            indexBySequence.removeAll(keepingCapacity: true)
            for (index, message) in messages.enumerated() {
                if !message.id.isEmpty, indexByID[message.id] == nil {
                    indexByID[message.id] = index
                }
                if message.channelSeq > 0, indexBySequence[message.channelSeq] == nil {
                    indexBySequence[message.channelSeq] = index
                }
            }
        }

        // The original lookup took the first row matching either identifier.
        let index = min(indexByID[id] ?? messages.count, indexBySequence[sequence] ?? messages.count)
        return index < messages.count ? messages[index] : nil
    }
}

public struct ChatReplySourceSnapshot: Equatable, Sendable {
    public let messages: [ChatMessage]
    public let lookup: ChatReplySourceLookup

    static public func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lookup === rhs.lookup && chatMessagesShareStorage(lhs.messages, rhs.messages)
    }
}

private struct ChatReplySourceKey: EnvironmentKey {
    static let defaultValue: ChatReplySourceSnapshot? = nil
}

private struct ChatConversationParticipantsKey: EnvironmentKey {
    static let defaultValue: [IMUser]? = nil
}

private struct ChatCallRecordConversationKey: EnvironmentKey {
    static let defaultValue: ConversationMessageSnapshot? = nil
}

extension EnvironmentValues {
    public var chatReplySource: ChatReplySourceSnapshot? {
        get { self[ChatReplySourceKey.self] }
        set { self[ChatReplySourceKey.self] = newValue }
    }

    public var chatConversationParticipants: [IMUser]? {
        get { self[ChatConversationParticipantsKey.self] }
        set { self[ChatConversationParticipantsKey.self] = newValue }
    }

    public var chatCallRecordConversation: ConversationMessageSnapshot? {
        get { self[ChatCallRecordConversationKey.self] }
        set { self[ChatCallRecordConversationKey.self] = newValue }
    }
}

extension View {
    public func chatTranscriptConversation(_ conversation: ConversationMessageSnapshot, replyLookup: ChatReplySourceLookup) -> some View {
        environment(\.chatReplySource, ChatReplySourceSnapshot(messages: conversation.messages, lookup: replyLookup))
            .environment(\.chatConversationParticipants, conversation.participants)
            .environment(\.chatCallRecordConversation, conversation)
    }
}
// WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END

@MainActor
final public class ChatTranscriptProjectionCache: ObservableObject {
    @MainActor lazy public var replySourceLookup = ChatReplySourceLookup() // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110
    private var source: [ChatMessage] = []
    private var showsProcessingNotices = true
    private var timeline: [ChatMessage] = []
    private var pinned: [ChatMessage] = []

    public func projection(
        for messages: [ChatMessage], showsProcessingNotices: Bool
    ) -> (timeline: [ChatMessage], pinned: [ChatMessage]) {
        if self.showsProcessingNotices != showsProcessingNotices || !chatMessagesShareStorage(source, messages) {
            source = messages
            self.showsProcessingNotices = showsProcessingNotices
            timeline = chatTimelineMessagesForRendering(messages, showsProcessingNotices: showsProcessingNotices)
            pinned = chatPinnedMessagesForRendering(messages)
        }
        return (timeline, pinned)
    }

    public init() {}
}

// Validate terminal visibility across all rows without deep message comparisons.
func chatMessageDeletionStateMatches<Cached: Collection, Current: Collection>(
    cachedMessages: Cached,
    messages: Current
) -> Bool where Cached.Element == ChatMessage, Current.Element == ChatMessage {
    guard cachedMessages.count == messages.count else { return false }
    return zip(cachedMessages, messages).allSatisfy { cached, current in
        cached.id == current.id && cached.isDeletedLocally == current.isDeletedLocally
            && (cached.status == .recalled) == (current.status == .recalled)
    }
}
// WDT_CHAT_DELETE_REFRESH_20261021_END

// WDT_CHAT_FIX2_DELETE_REFRESH_20261023_BEGIN
public func chatNeedsImmediateRemovalRefresh(cachedMessages: [ChatMessage], messages: [ChatMessage]) -> Bool {
    guard !cachedMessages.isEmpty else { return false }
    let currentByID = Dictionary(messages.map { ($0.id, (deleted: $0.isDeletedLocally, recalled: $0.status == .recalled)) },
                                 uniquingKeysWith: { _, latest in latest })
    return cachedMessages.contains { previous in
        guard let current = currentByID[previous.id] else { return true }
        return previous.isDeletedLocally != current.deleted
            || (previous.status != .recalled && current.recalled)
    }
}
// WDT_CHAT_FIX2_DELETE_REFRESH_20261023_END

struct ChatMessageLazyLeaf<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}

public struct ChatMessageTimelineItem: Identifiable {
    public enum Kind {
        case timeSeparator(String)
        case unreadDivider(Int)
        case historyAnchor
        case message
    }

    public let id: String
    public let row: ChatMessageRenderRow
    public let kind: Kind
}

// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
public struct MessageRowModel: Identifiable, Equatable, Sendable {
    public var index: Int
    public let message: ChatMessage
    public let showsSenderHeader: Bool
    public let senderUser: IMUser?
    public let displaySenderName: String
    public let timeSeparatorText: String?
    var renderVersion: UInt64 = 0
    public var generation: UUID = UUID()

    public init(index: Int, message: ChatMessage, showsSenderHeader: Bool, senderUser: IMUser? = nil,
        displaySenderName: String, timeSeparatorText: String? = nil, renderVersion: UInt64 = 0, generation: UUID = UUID()) {
        self.index = index; self.message = message; self.showsSenderHeader = showsSenderHeader
        self.senderUser = senderUser; self.displaySenderName = displaySenderName; self.timeSeparatorText = timeSeparatorText
        self.renderVersion = renderVersion; self.generation = generation
    }

    public var id: String { message.id }

    static public func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.generation == rhs.generation && lhs.renderVersion == rhs.renderVersion
    }
}

// Preserve the layout owner's snapshot interface while the model owns row derivation.
public typealias ChatMessageRenderRow = MessageRowModel
// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END

// JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_MODEL - 修改开始：缓存已展开的消息时间线 item，降低输入/键盘重绘分配
public struct ChatMessageRenderRowsSnapshot {
    public let rows: [ChatMessageRenderRow]
    public let conversationID: String
    public let version: Int
    public let fingerprint: Int

    public var count: Int { rows.count }
    var firstID: String { rows.first?.id ?? "" }
    var lastID: String { rows.last?.id ?? "" }
}

// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110: item expansion now belongs to ChatTimelineViewModel.

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
// MessageBubble assembly/row initializer now lives in App/ChatMessageBubbleAssembly.swift.
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END

// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
