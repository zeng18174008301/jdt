import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

public enum ChatInitialScrollAnchorPlacement: Equatable {
    case top
    case center
    case bottom

    public var unitPoint: UnitPoint {
        switch self {
        case .top:
            return .top
        case .center:
            return .center
        case .bottom:
            return .bottom
        }
    }
}

public struct ChatInitialScrollAnchor: Equatable {
    public let id: String
    public let placement: ChatInitialScrollAnchorPlacement
    public let anchorsLastReadMessage: Bool
    let lastReadMessageID: String?

    public init(
        id: String,
        placement: ChatInitialScrollAnchorPlacement,
        anchorsLastReadMessage: Bool,
        lastReadMessageID: String? = nil
    ) {
        self.id = id
        self.placement = placement
        self.anchorsLastReadMessage = anchorsLastReadMessage
        self.lastReadMessageID = lastReadMessageID
    }
}

public struct ChatInitialEntrySyncPolicy: Equatable {
    public let forceRemoteHistory: Bool
    public let silent: Bool
    public let showLoadingIndicator: Bool
    public let shouldWarmRefreshAfterInitialRender: Bool
}

public enum ConversationScrollRequestSource: Equatable {
    case initialAnchor
    case followBottom
    case incomingFollowBottom
    case viewportBottomRealignment
    case sendEcho
    case historyPrependCompensation
    case autofill
    case searchJump
    case pinnedJump
    case jumpToLatest
    case readAck
    case userGesture
}

public struct ConversationScrollRequest: Equatable {
    public let source: ConversationScrollRequestSource
    public let targetID: String?
    public let anchor: UnitPoint?
    public let userInitiated: Bool
    public let generation: Int

    public init(source: ConversationScrollRequestSource,
        targetID: String? = nil,
        anchor: UnitPoint? = nil,
        userInitiated: Bool,
        generation: Int) {
        self.source = source
        self.targetID = targetID
        self.anchor = anchor
        self.userInitiated = userInitiated
        self.generation = generation
    }
}

public enum ConversationScrollVerdict: Equatable {
    case allow
    case deny
    case allowAndEndWindow
}

public struct ConversationScrollArbiter: Equatable {
    public enum Mode: Equatable {
        case normalOpen
        case jump
    }

    private(set) public var mode: Mode = .normalOpen
    private(set) public var generation: Int = 0
    private(set) var stableUntil: Date = .distantPast

    public var isJumpMode: Bool { mode == .jump }

    mutating public func beginNormalOpen(now: Date, duration: TimeInterval) {
        mode = .normalOpen
        generation += 1
        stableUntil = now.addingTimeInterval(max(0, duration))
    }

    mutating func endWindow(mode nextMode: Mode, now: Date) {
        mode = nextMode
        stableUntil = now
    }

    mutating public func evaluate(_ request: ConversationScrollRequest, now: Date) -> ConversationScrollVerdict {
        guard request.generation == generation else { return .deny }
        if request.userInitiated {
            let nextMode: Mode = request.source == .jumpToLatest ? .normalOpen : .jump
            endWindow(mode: nextMode, now: now)
            return .allowAndEndWindow
        }
        if mode == .jump {
            switch request.source {
            case .jumpToLatest:
                endWindow(mode: .normalOpen, now: now)
                return .allowAndEndWindow
            case .searchJump, .pinnedJump, .userGesture, .historyPrependCompensation, .incomingFollowBottom, .viewportBottomRealignment:
                return .allow
            case .initialAnchor, .followBottom, .sendEcho, .autofill, .readAck:
                return .deny
            }
        }
        if now >= stableUntil {
            return .allow
        }
        switch mode {
        case .normalOpen:
            switch request.source {
            case .initialAnchor, .followBottom, .incomingFollowBottom, .viewportBottomRealignment, .sendEcho, .historyPrependCompensation:
                return .allow
            case .searchJump, .pinnedJump, .jumpToLatest, .userGesture:
                let nextMode: Mode = request.source == .jumpToLatest ? .normalOpen : .jump
                endWindow(mode: nextMode, now: now)
                return .allowAndEndWindow
            case .autofill, .readAck:
                return .deny
            }
        case .jump:
            return .deny
        }
    }

    public init(mode: Mode = .normalOpen,
        generation: Int = 0,
        stableUntil: Date = .distantPast) {
        self.mode = mode
        self.generation = generation
        self.stableUntil = stableUntil
    }
}

// JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：聊天滚动定位复用轻量 seq 遍历，避免 map/filter 临时数组
private func chatLatestPositiveChannelSeq(in messages: [ChatMessage]) -> Int64? {
    var latestSeq: Int64?
    for message in messages where message.channelSeq > 0 {
        latestSeq = max(latestSeq ?? message.channelSeq, message.channelSeq)
    }
    return latestSeq
}

private func chatPositiveChannelSeqRange(in messages: [ChatMessage]) -> (oldest: Int64, latest: Int64)? {
    var oldestSeq: Int64?
    var latestSeq: Int64?
    for message in messages where message.channelSeq > 0 {
        oldestSeq = min(oldestSeq ?? message.channelSeq, message.channelSeq)
        latestSeq = max(latestSeq ?? message.channelSeq, message.channelSeq)
    }
    guard let oldestSeq, let latestSeq else { return nil }
    return (oldestSeq, latestSeq)
}
// JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

public func chatShouldWaitForInitialLatestWindowRefresh(
    needsUnreadWindowRefresh: Bool,
    needsLatestWindowRefresh: Bool,
    canReuseConfirmedBottom: Bool
) -> Bool {
    needsLatestWindowRefresh && !canReuseConfirmedBottom
}

public func chatInitialEntrySyncPolicy(
    hasCachedMessages: Bool,
    needsUnreadWindowRefresh: Bool,
    needsLatestWindowRefresh: Bool,
    canReuseConfirmedBottom: Bool
) -> ChatInitialEntrySyncPolicy {
    let shouldRefreshLatestWindow = chatShouldWaitForInitialLatestWindowRefresh(
        needsUnreadWindowRefresh: needsUnreadWindowRefresh,
        needsLatestWindowRefresh: needsLatestWindowRefresh,
        canReuseConfirmedBottom: canReuseConfirmedBottom
    )
    let forceRemoteHistory = !hasCachedMessages || shouldRefreshLatestWindow
    return ChatInitialEntrySyncPolicy(
        forceRemoteHistory: forceRemoteHistory,
        silent: hasCachedMessages && !forceRemoteHistory,
        showLoadingIndicator: forceRemoteHistory,
        shouldWarmRefreshAfterInitialRender: hasCachedMessages && !forceRemoteHistory
    )
}

public func chatCanReuseConfirmedBottom(
    unreadCount: Int,
    latestBottomTargetSeq: Int64,
    isLatestMessageWindowLoaded: Bool,
    rememberedConfirmedSeq: Int64
) -> Bool {
    unreadCount == 0
        && latestBottomTargetSeq > 0
        && isLatestMessageWindowLoaded
        && rememberedConfirmedSeq >= latestBottomTargetSeq
}

public func chatCanApplyAutomaticBottomScroll(
    isUserBrowsingHistory: Bool,
    isLoadingConversationHistory: Bool,
    isAutomaticBottomScrollSuppressed: Bool,
    didUserInteractWithMessageScroll: Bool,
    isAtBottom: Bool
) -> Bool {
    !isUserBrowsingHistory
        && !isLoadingConversationHistory
        && !isAutomaticBottomScrollSuppressed
        && (!didUserInteractWithMessageScroll || isAtBottom)
}

public func chatCanLoadOlderFromScrollMetrics(
    didUserInteractWithMessageScroll: Bool,
    isUserBrowsingHistory: Bool,
    visibility: ChatScrollVisibility
) -> Bool {
    guard visibility.isNearHistoryBoundary else { return false }
    if didUserInteractWithMessageScroll && isUserBrowsingHistory {
        return true
    }
    return !visibility.isAtBottom || visibility.isContentUnderfilled
}

public func chatShouldShowReturnToBottom(
    didInitialScroll: Bool,
    isApplyingInitialScroll: Bool,
    messageCount: Int,
    isAtBottom: Bool,
    isSearchVisible: Bool,
    isReadOnlySystemConversation: Bool
) -> Bool {
    didInitialScroll
        && !isApplyingInitialScroll
        && messageCount > 0
        && !isAtBottom
        && !isSearchVisible
        && !isReadOnlySystemConversation
}

public struct ChatReturnToBottomActionPlan: Equatable {
    public let targetID: String
    public let source: ConversationScrollRequestSource
    public let anchor: UnitPoint
    let acknowledgesReadImmediately: Bool
    let loadsHistoryPage: Bool
    let rebuildsTimeline: Bool
}

public func chatReturnToBottomActionPlan(bottomAnchorID: String) -> ChatReturnToBottomActionPlan {
    ChatReturnToBottomActionPlan(
        targetID: bottomAnchorID,
        source: .jumpToLatest,
        anchor: .bottom,
        acknowledgesReadImmediately: false,
        loadsHistoryPage: false,
        rebuildsTimeline: false
    )
}

public func chatLatestBottomConfirmationDelays(force: Bool) -> [TimeInterval] {
    [0]
}

public func chatMessageDisplaysReadStatusForInitialAnchor(_ message: ChatMessage) -> Bool {
    guard message.isOutgoing,
          message.status != .recalled,
          !message.isDeletedLocally else {
        return false
    }
    return message.status == .read
        || !message.readBy.isEmpty
        || (message.readCount ?? 0) > 0
}

func chatLastReadMessageIDForInitialAnchor(
    messages: [ChatMessage],
    lastReadSeq: Int64,
    firstUnreadMessageID: String,
    firstUnreadSeq: Int64,
    unreadCount: Int
) -> String? {
    guard !messages.isEmpty else { return nil }

    func isAnchorCandidate(_ message: ChatMessage) -> Bool {
        message.status != .recalled && !message.isDeletedLocally
    }

    if unreadCount == 0 {
        guard let latestMessage = messages.last(where: isAnchorCandidate),
              chatMessageDisplaysReadStatusForInitialAnchor(latestMessage) else {
            return nil
        }
        return latestMessage.id
    }

    let normalizedFirstUnreadID = firstUnreadMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
    if unreadCount > 0,
       firstUnreadSeq > 0,
       // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：初始锚点判断直接遍历 seq，避免主线程临时数组
       let latestLoadedSeq = chatLatestPositiveChannelSeq(in: messages),
       // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
       latestLoadedSeq < firstUnreadSeq {
        if latestLoadedSeq + 1 == firstUnreadSeq {
            return messages.last(where: isAnchorCandidate)?.id
        }
        return nil
    }
    var firstUnreadIndex: Int?
    if !normalizedFirstUnreadID.isEmpty {
        firstUnreadIndex = messages.firstIndex { $0.id == normalizedFirstUnreadID }
    }
    if firstUnreadIndex == nil, firstUnreadSeq > 0 {
        firstUnreadIndex = messages.firstIndex { $0.channelSeq == firstUnreadSeq }
    }
    if firstUnreadIndex == nil, messages.count >= unreadCount {
        firstUnreadIndex = messages.count - unreadCount
    }

    if let firstUnreadIndex {
        guard firstUnreadIndex > 0 else { return nil }
        if let message = messages[..<firstUnreadIndex].last(where: isAnchorCandidate) {
            return message.id
        }
    }

    if lastReadSeq > 0,
       let message = messages.last(where: { message in
           message.channelSeq > 0 && message.channelSeq <= lastReadSeq && isAnchorCandidate(message)
       }) {
        return message.id
    }

    if let message = messages.last(where: { message in
        guard chatMessageDisplaysReadStatusForInitialAnchor(message) else { return false }
        return lastReadSeq <= 0 || message.channelSeq <= 0 || message.channelSeq <= lastReadSeq
    }) {
        return message.id
    }

    return nil
}

public func chatFirstUnreadMessageIDForDivider(
    messages: [ChatMessage],
    firstUnreadMessageID: String,
    firstUnreadSeq: Int64,
    lastReadSeq: Int64,
    unreadCount: Int
) -> String? {
    guard unreadCount > 0, !messages.isEmpty else { return nil }

    func isDividerCandidate(_ message: ChatMessage) -> Bool {
        message.status != .recalled && !message.isDeletedLocally
    }

    func loadedSequenceRange() -> (oldest: Int64, latest: Int64)? {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：未读分隔线范围判断直接遍历 seq，避免主线程临时数组
        return chatPositiveChannelSeqRange(in: messages)
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    let normalizedFirstUnreadID = firstUnreadMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedFirstUnreadID.isEmpty,
       let message = messages.first(where: { $0.id == normalizedFirstUnreadID && isDividerCandidate($0) }) {
        return message.id
    }

    if firstUnreadSeq > 0 {
        if let range = loadedSequenceRange(),
           firstUnreadSeq < range.oldest || firstUnreadSeq > range.latest {
            return nil
        }
        if let message = messages.first(where: { $0.channelSeq == firstUnreadSeq && isDividerCandidate($0) }) {
            return message.id
        }
        if let message = messages.first(where: { $0.channelSeq > firstUnreadSeq && isDividerCandidate($0) }) {
            return message.id
        }
        return nil
    }

    if lastReadSeq > 0 {
        if let range = loadedSequenceRange() {
            guard lastReadSeq >= range.oldest - 1, lastReadSeq < range.latest else { return nil }
        }
        return messages.first { message in
            message.channelSeq > lastReadSeq && isDividerCandidate(message)
        }?.id
    }

    guard unreadCount <= messages.count else { return nil }
    return messages[messages.count - unreadCount].id
}

public func chatInitialScrollAnchor(
    messages: [ChatMessage],
    unreadCount: Int,
    lastReadSeq: Int64,
    firstUnreadMessageID: String?,
    firstUnreadSeq: Int64,
    firstUnreadMarkerID: String,
    bottomAnchorID: String
) -> ChatInitialScrollAnchor? {
    guard !messages.isEmpty else { return nil }
    return ChatInitialScrollAnchor(id: bottomAnchorID, placement: .bottom, anchorsLastReadMessage: false)
}

public func chatCanClearUnreadReminderFromVisibleProgress(
    isUserBrowsingHistory: Bool,
    isAtBottom: Bool,
    didScrollTowardUnreadMessages: Bool
) -> Bool {
    isAtBottom || (!isUserBrowsingHistory && didScrollTowardUnreadMessages)
}

public func chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: Bool) -> String? {
    isAutomaticRecoveryPath ? nil : "已读状态同步失败，请稍后重试"
}

public func chatScrollVisibility(
    metrics: ChatScrollMetricsSnapshot,
    bottomTolerance: CGFloat = 56,
    historyPrefetchDistance: CGFloat = 160
) -> ChatScrollVisibility {
    guard metrics.isValid else { return .initial }
    let bottomSlack = max(0, bottomTolerance)
    let historySlack = max(0, historyPrefetchDistance)
    return ChatScrollVisibility(
        isAtBottom: metrics.contentHeight <= metrics.viewportHeight + bottomSlack
            || metrics.bottomDistance <= bottomSlack,
        isNearHistoryBoundary: metrics.contentMinY >= -historySlack,
        isContentUnderfilled: metrics.contentHeight <= metrics.viewportHeight + 1
    )
}

// Offset-only movement between the edges does not affect any transcript action.
// Keep the exact read boundary separate from the looser follow-bottom threshold.
public func chatNeedsTranscriptLayoutUpdate(
    from previous: ChatScrollMetricsSnapshot,
    to current: ChatScrollMetricsSnapshot
) -> Bool {
    guard current.isValid else { return false }
    return !previous.isValid
        || chatScrollVisibility(metrics: previous) != chatScrollVisibility(metrics: current)
        || (previous.bottomDistance <= 1) != (current.bottomDistance <= 1)
        || !chatCGFloatApproximatelyEqual(previous.viewportHeight, current.viewportHeight)
        || !chatCGFloatApproximatelyEqual(previous.contentHeight, current.contentHeight)
        || previous.renderedReadToken != current.renderedReadToken
        || previous.renderedReadSeq != current.renderedReadSeq
        || previous.readVisibilityEpoch != current.readVisibilityEpoch
}

/// UIKit may preserve the keyboard-sized content offset when the viewport grows.
/// Visibility alone intentionally treats that negative bottom distance as visible;
/// only a previously bottom-aligned, scrollable transcript needs realignment.
public func chatNeedsBottomRealignmentAfterViewportExpansion(
    from previous: ChatScrollMetricsSnapshot,
    to metrics: ChatScrollMetricsSnapshot
) -> Bool {
    previous.isValid && metrics.isValid
        && previous.viewportHeight.isFinite && metrics.viewportHeight.isFinite
        && metrics.viewportHeight > previous.viewportHeight
        && metrics.contentHeight > metrics.viewportHeight + 1
        && chatScrollVisibility(metrics: previous).isAtBottom
        && metrics.bottomDistance < -56
}

func chatCanConsumePendingScrollTarget(
    targetID: String,
    renderedMessageIDs: Set<String>,
    bottomAnchorID: String
) -> Bool {
    targetID == bottomAnchorID || renderedMessageIDs.contains(targetID)
}

// WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_BEGIN
public struct ScrollIntent: Equatable {
    public enum Position: Equatable { case followBottom, preserveReadingPosition, jump, historyAnchor }
    public enum Motion: Equatable { case immediate, spring, incoming }
    public let position: Position
    public let targetID: String
    public let anchor: UnitPoint?
    public let motion: Motion

    public init(position: Position, targetID: String, anchor: UnitPoint? = nil, motion: Motion) {
        self.position = position; self.targetID = targetID; self.anchor = anchor; self.motion = motion
    }

    static public func position(for source: ConversationScrollRequestSource) -> Position {
        switch source {
        case .followBottom, .incomingFollowBottom, .sendEcho, .jumpToLatest: .followBottom
        case .historyPrependCompensation: .historyAnchor
        case .viewportBottomRealignment, .autofill, .userGesture, .readAck: .preserveReadingPosition
        case .initialAnchor, .searchJump, .pinnedJump: .jump
        }
    }
}

// Execution receives only intents already accepted by the existing arbiter.
@MainActor
public final class ChatScrollIntentStateMachine {
    enum State: Equatable { case idle, applying(ScrollIntent), applied(ScrollIntent) }
    private(set) var state: State = .idle
    public func apply(_ intent: ScrollIntent, execute: (ScrollIntent) -> Void) {
        state = .applying(intent)
        execute(intent)
        state = .applied(intent)
    }
    public func reset() { state = .idle }
}
// WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110_END
