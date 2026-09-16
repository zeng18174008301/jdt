import SwiftUI
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import QuickLook

enum ChatTranscriptKeyboardDismissalTrigger: CaseIterable {
    case tap
    case verticalScroll
    case longPress
}

struct ChatTranscriptKeyboardDismissalPlan: Equatable {
    let dismissesKeyboard: Bool
    let preservesDraft: Bool
    let sendsMessage: Bool
    let acknowledgesRead: Bool
    let loadsHistoryPage: Bool
    let rebuildsTimeline: Bool
    let requestsScrollTarget: Bool
}

func chatTranscriptKeyboardDismissalPlan(
    trigger: ChatTranscriptKeyboardDismissalTrigger
) -> ChatTranscriptKeyboardDismissalPlan {
    ChatTranscriptKeyboardDismissalPlan(
        dismissesKeyboard: true,
        preservesDraft: true,
        sendsMessage: false,
        acknowledgesRead: false,
        loadsHistoryPage: false,
        rebuildsTimeline: false,
        requestsScrollTarget: false
    )
}

@MainActor
private func dismissActiveChatKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

private extension View {
    @ViewBuilder
    func chatScrollDismissesKeyboardInteractively() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

func groupAnnouncementDisplayContent(content: String?, summary: String?, groupNotice: String) -> String {
    for candidate in [content, summary, groupNotice] {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
              value != "暂无群公告" else {
            continue
        }
        return value
    }
    return ""
}

func groupAnnouncementHasVisibleContent(content: String?, summary: String?, groupNotice: String) -> Bool {
    !groupAnnouncementDisplayContent(content: content, summary: summary, groupNotice: groupNotice).isEmpty
}

enum ChatInitialScrollAnchorPlacement: Equatable {
    case top
    case center
    case bottom

    var unitPoint: UnitPoint {
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

struct ChatInitialScrollAnchor: Equatable {
    let id: String
    let placement: ChatInitialScrollAnchorPlacement
    let anchorsLastReadMessage: Bool
    let lastReadMessageID: String?

    init(
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

struct ChatInitialEntrySyncPolicy: Equatable {
    let forceRemoteHistory: Bool
    let silent: Bool
    let showLoadingIndicator: Bool
    let shouldWarmRefreshAfterInitialRender: Bool
}

enum ConversationScrollRequestSource: Equatable {
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

struct ConversationScrollRequest: Equatable {
    let source: ConversationScrollRequestSource
    let targetID: String?
    let anchor: UnitPoint?
    let userInitiated: Bool
    let generation: Int
}

enum ConversationScrollVerdict: Equatable {
    case allow
    case deny
    case allowAndEndWindow
}

struct ConversationScrollArbiter: Equatable {
    enum Mode: Equatable {
        case normalOpen
        case jump
    }

    private(set) var mode: Mode = .normalOpen
    private(set) var generation: Int = 0
    private(set) var stableUntil: Date = .distantPast

    var isJumpMode: Bool { mode == .jump }

    mutating func beginNormalOpen(now: Date, duration: TimeInterval) {
        mode = .normalOpen
        generation += 1
        stableUntil = now.addingTimeInterval(max(0, duration))
    }

    mutating func endWindow(mode nextMode: Mode, now: Date) {
        mode = nextMode
        stableUntil = now
    }

    mutating func evaluate(_ request: ConversationScrollRequest, now: Date) -> ConversationScrollVerdict {
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
}

func chatTimelineMessagesForRendering(_ messages: [ChatMessage]) -> [ChatMessage] {
    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_FILTER - 修改开始：普通输入重绘时避免无 pinned-context 消息的数组重分配
    guard messages.contains(where: { $0.isPinnedContextOnly }) else { return messages }
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_FILTER - 修改结束
    return messages.filter { !$0.isPinnedContextOnly }
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

func chatShouldWaitForInitialLatestWindowRefresh(
    needsUnreadWindowRefresh: Bool,
    needsLatestWindowRefresh: Bool,
    canReuseConfirmedBottom: Bool
) -> Bool {
    needsLatestWindowRefresh && !canReuseConfirmedBottom
}

func chatInitialEntrySyncPolicy(
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

func chatCanReuseConfirmedBottom(
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

func chatCanApplyAutomaticBottomScroll(
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

func chatCanLoadOlderFromScrollMetrics(
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

func chatShouldShowReturnToBottom(
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

struct ChatReturnToBottomActionPlan: Equatable {
    let targetID: String
    let source: ConversationScrollRequestSource
    let anchor: UnitPoint
    let acknowledgesReadImmediately: Bool
    let loadsHistoryPage: Bool
    let rebuildsTimeline: Bool
}

func chatReturnToBottomActionPlan(bottomAnchorID: String) -> ChatReturnToBottomActionPlan {
    ChatReturnToBottomActionPlan(
        targetID: bottomAnchorID,
        source: .jumpToLatest,
        anchor: .bottom,
        acknowledgesReadImmediately: false,
        loadsHistoryPage: false,
        rebuildsTimeline: false
    )
}

func chatLatestBottomConfirmationDelays(force: Bool) -> [TimeInterval] {
    [0]
}

func chatMessageDisplaysReadStatusForInitialAnchor(_ message: ChatMessage) -> Bool {
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

func chatFirstUnreadMessageIDForDivider(
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

func chatInitialScrollAnchor(
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

func chatCanClearUnreadReminderFromVisibleProgress(
    isUserBrowsingHistory: Bool,
    isAtBottom: Bool,
    didScrollTowardUnreadMessages: Bool
) -> Bool {
    isAtBottom || (!isUserBrowsingHistory && didScrollTowardUnreadMessages)
}

func chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: Bool) -> String? {
    isAutomaticRecoveryPath ? nil : "已读状态同步失败，请稍后重试"
}

struct ChatScrollMetricsSnapshot: Equatable {
    let viewportHeight: CGFloat
    let contentMinY: CGFloat
    let contentMaxY: CGFloat
    var renderedReadToken: String = ""
    var renderedReadSeq: Int64 = 0
    var readVisibilityEpoch: Int = 0

    static let zero = ChatScrollMetricsSnapshot(viewportHeight: 0, contentMinY: 0, contentMaxY: 0)

    var isValid: Bool {
        viewportHeight > 0
            && contentMinY.isFinite
            && contentMaxY.isFinite
            && contentMaxY >= contentMinY
    }

    var contentHeight: CGFloat {
        max(0, contentMaxY - contentMinY)
    }

    var bottomDistance: CGFloat {
        contentMaxY - viewportHeight
    }
}

struct ChatIncomingRowGeometry: Equatable {
    let token: String
    let frame: CGRect
    let epoch: Int
    static let empty = ChatIncomingRowGeometry(token: "", frame: .null, epoch: -1)
}

/// A scroll request and lazy onAppear are not evidence of visibility. Only a
/// layout carrying the current rendered token/scene epoch may advance read state.
func chatVisibleIncomingReadSequence(
    metrics: ChatScrollMetricsSnapshot,
    row: ChatIncomingRowGeometry,
    expectedToken: String,
    epoch: Int,
    isActive: Bool,
    scopeMatches: Bool
) -> Int64? {
    guard isActive, scopeMatches, metrics.isValid,
          metrics.readVisibilityEpoch == epoch,
          metrics.contentMaxY <= metrics.viewportHeight + 1,
          metrics.renderedReadSeq > 0, !expectedToken.isEmpty,
          metrics.renderedReadToken == expectedToken,
          row.token == expectedToken, row.epoch == epoch,
          row.frame.minY.isFinite, row.frame.maxY.isFinite,
          row.frame.height > 0, row.frame.minY < metrics.viewportHeight,
          row.frame.maxY > 0, row.frame.maxY <= metrics.viewportHeight + 1 else { return nil }
    return metrics.renderedReadSeq
}

struct ChatScrollVisibility: Equatable {
    let isAtBottom: Bool
    let isNearHistoryBoundary: Bool
    let isContentUnderfilled: Bool

    init(isAtBottom: Bool, isNearHistoryBoundary: Bool, isContentUnderfilled: Bool = false) {
        self.isAtBottom = isAtBottom
        self.isNearHistoryBoundary = isNearHistoryBoundary
        self.isContentUnderfilled = isContentUnderfilled
    }

    static let initial = ChatScrollVisibility(isAtBottom: false, isNearHistoryBoundary: false)
}

// JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_COMPARE - 修改开始：键盘/输入导致的重复布局回调用近似比较去噪
private func chatCGFloatApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
    if lhs == rhs { return true }
    guard lhs.isFinite, rhs.isFinite else { return false }
    return abs(lhs - rhs) <= tolerance
}

private func chatScrollMetricsApproximatelyEqual(
    _ lhs: ChatScrollMetricsSnapshot,
    _ rhs: ChatScrollMetricsSnapshot
) -> Bool {
    chatCGFloatApproximatelyEqual(lhs.viewportHeight, rhs.viewportHeight)
        && chatCGFloatApproximatelyEqual(lhs.contentMinY, rhs.contentMinY)
        && chatCGFloatApproximatelyEqual(lhs.contentMaxY, rhs.contentMaxY)
        && lhs.renderedReadToken == rhs.renderedReadToken
        && lhs.renderedReadSeq == rhs.renderedReadSeq
        && lhs.readVisibilityEpoch == rhs.readVisibilityEpoch
}

private func chatIncomingRowGeometryApproximatelyEqual(
    _ lhs: ChatIncomingRowGeometry,
    _ rhs: ChatIncomingRowGeometry
) -> Bool {
    lhs.token == rhs.token
        && lhs.epoch == rhs.epoch
        && chatCGFloatApproximatelyEqual(lhs.frame.minX, rhs.frame.minX)
        && chatCGFloatApproximatelyEqual(lhs.frame.minY, rhs.frame.minY)
        && chatCGFloatApproximatelyEqual(lhs.frame.width, rhs.frame.width)
        && chatCGFloatApproximatelyEqual(lhs.frame.height, rhs.frame.height)
}

private func chatGeometryValuesApproximatelyEqual(
    _ lhs: [String: CGFloat],
    _ rhs: [String: CGFloat]
) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (key, lhsValue) in lhs {
        guard let rhsValue = rhs[key],
              chatCGFloatApproximatelyEqual(lhsValue, rhsValue) else {
            return false
        }
    }
    return true
}
// JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_COMPARE - 修改结束

/// Geometry preferences are produced during SwiftUI layout. Keeping their latest
/// values in an observed `@State` dictionary feeds every layout pass back into a
/// new view update and can trap a large message list in AttributeGraph forever.
/// This store deliberately does not publish writes: scroll/history handlers can
/// still read the latest anchors without invalidating the view that measured them.
final class ChatMessageTopMeasurementStore: ObservableObject {
    private(set) var values: [String: CGFloat] = [:]

    // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_DEDUPE - 修改开始：几何测量无变化时不调度聊天页滚动处理
    @discardableResult
    func replace(with values: [String: CGFloat], isEnabled: Bool) -> Bool {
        let nextValues = isEnabled ? values : [:]
        guard !chatGeometryValuesApproximatelyEqual(self.values, nextValues) else { return false }
        self.values = nextValues
        return true
    }
    // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_DEDUPE - 修改结束

    func removeAll() {
        values.removeAll(keepingCapacity: true)
    }

    subscript(messageID: String) -> CGFloat? {
        values[messageID]
    }
}

/// Gesture bookkeeping is deliberately not published. Only a start or direction
/// change asks ChatView to update semantic state, read gates and diagnostics.
final class ChatTranscriptScrollControl: ObservableObject {
    enum Direction: Equatable {
        case history
        case latest
    }

    struct Transition: Equatable {
        let isStart: Bool
        let direction: Direction
    }

    private(set) var direction: Direction?
    private(set) var generation = 0
    private(set) var suppressedUntil = Date.distantPast
    private var previousVerticalTranslation: CGFloat = 0
    private var heldHistorySuppression = false

    func updateDrag(translation: CGSize, now: Date, suppressionInterval: TimeInterval) -> Transition? {
        guard translation.width.isFinite, translation.height.isFinite,
              abs(translation.height) >= abs(translation.width) else { return nil }
        let delta = translation.height - previousVerticalTranslation
        previousVerticalTranslation = translation.height
        guard delta != 0 else { return nil }
        let nextDirection: Direction = delta > 0 ? .history : .latest
        guard direction != nextDirection else { return nil }
        let transition = Transition(isStart: direction == nil, direction: nextDirection)
        direction = nextDirection
        // Invalidate queued automatic work once per transition, not per frame.
        _ = nextGeneration()
        if nextDirection == .history {
            heldHistorySuppression = true
            suppressedUntil = now.addingTimeInterval(suppressionInterval)
        }
        return transition
    }

    /// Normal end, gesture cancellation and view/scene departure share one
    /// idempotent finish. Duplicate lifecycle callbacks cannot extend the deadline.
    @discardableResult
    func finishDrag(now: Date, suppressionInterval: TimeInterval) -> Direction? {
        guard let endedDirection = direction else { return nil }
        if heldHistorySuppression {
            // A stationary or very long drag must not outlive its protection.
            suppressedUntil = now.addingTimeInterval(suppressionInterval)
        }
        direction = nil
        previousVerticalTranslation = 0
        heldHistorySuppression = false
        _ = nextGeneration()
        return endedDirection
    }

    func isSuppressed(now: Date) -> Bool {
        heldHistorySuppression || now < suppressedUntil
    }

    func suppress(now: Date, interval: TimeInterval) {
        suppressedUntil = now.addingTimeInterval(interval)
        _ = nextGeneration()
    }

    func clearSuppression() {
        suppressedUntil = .distantPast
        // Bottom visibility may change during a drag; it cannot release the
        // active gesture's latch. Explicit jump requests still use the arbiter.
    }

    func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    func reset() {
        direction = nil
        previousVerticalTranslation = 0
        heldHistorySuppression = false
        suppressedUntil = .distantPast
        // Never reuse a generation captured by work from the previous scope.
        _ = nextGeneration()
    }
}

/// Captures the viewport before @Published replaces the message array. A burst
/// retains its first bottom decision while layout catches up; any newer scroll
/// intent invalidates it, including work queued for late media layout.
struct ChatIncomingBottomFollowState {
    private var generation: Int?
    private var follows = false

    func decision(generation current: Int) -> Bool? {
        generation == current ? follows : nil
    }

    func needsLayoutCorrection(from previous: ChatScrollMetricsSnapshot,
                               to metrics: ChatScrollMetricsSnapshot, generation current: Int) -> Bool {
        decision(generation: current) == true && metrics.isValid
            && !chatScrollVisibility(metrics: metrics).isAtBottom
            && (metrics.contentHeight != previous.contentHeight
                || metrics.viewportHeight != previous.viewportHeight)
    }

    mutating func recordAppend(metrics: ChatScrollMetricsSnapshot, generation current: Int, eligible: Bool) {
        let wasFollowing = decision(generation: current) == true
        follows = eligible && (wasFollowing || chatScrollVisibility(metrics: metrics).isAtBottom)
        generation = current
    }

    mutating func reset() {
        generation = nil
        follows = false
    }
}

/// Geometry callbacks run inside SwiftUI's layout transaction. Coalesce them
/// into one next-run-loop update, and invalidate scheduled work on departure.
struct ChatLayoutCallbackCoalescer {
    private(set) var generation = 0
    private var scheduled = false

    mutating func schedule() -> Int? {
        guard !scheduled else { return nil }
        scheduled = true
        return generation
    }

    mutating func consume(_ expectedGeneration: Int) -> Bool {
        guard scheduled, generation == expectedGeneration else { return false }
        scheduled = false
        return true
    }

    mutating func cancel() {
        generation &+= 1
        scheduled = false
    }
}

/// Retain geometry outside published state so a measurement cannot invalidate
/// the same view hierarchy that just produced it.
final class ChatScrollMetricsMeasurementStore: ObservableObject {
    private(set) var metrics = ChatScrollMetricsSnapshot.zero
    var lastHandledMetrics = ChatScrollMetricsSnapshot.zero
    var layoutCallbacks = ChatLayoutCallbackCoalescer()
    var incomingRow = ChatIncomingRowGeometry.empty
    var incomingBottomFollow = ChatIncomingBottomFollowState()
    // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_STORE - 修改开始：记录滚动边界重复检查节流时间
    private var lastRepeatedBoundaryCheckAt = Date.distantPast
    // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_STORE - 修改结束：记录滚动边界重复检查节流时间

    // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_METRICS_DEDUPE - 修改开始：滚动指标无有效变化时跳过后续主线程处理
    @discardableResult
    func replace(with metrics: ChatScrollMetricsSnapshot) -> Bool {
        guard metrics.isValid else { return false }
        guard !chatScrollMetricsApproximatelyEqual(self.metrics, metrics) else { return false }
        self.metrics = metrics
        return true
    }
    // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_METRICS_DEDUPE - 修改结束

    // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_API - 修改开始：普通滚动中节流重复边界处理
    func consumeRepeatedBoundaryCheckIfNeeded(
        now: Date = Date(),
        minimumInterval: TimeInterval = 0.12
    ) -> Bool {
        guard now.timeIntervalSince(lastRepeatedBoundaryCheckAt) >= minimumInterval else {
            return false
        }
        lastRepeatedBoundaryCheckAt = now
        return true
    }

    func resetRepeatedBoundaryCheckThrottle() {
        lastRepeatedBoundaryCheckAt = .distantPast
    }
    // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_API - 修改结束：普通滚动中节流重复边界处理

    func removeAll() {
        metrics = .zero
        lastHandledMetrics = .zero
        layoutCallbacks.cancel()
        incomingRow = .empty
        incomingBottomFollow.reset()
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_RESET - 修改开始：重置滚动边界节流状态
        resetRepeatedBoundaryCheckThrottle()
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_RESET - 修改结束：重置滚动边界节流状态
    }
}

func chatScrollVisibility(
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

/// UIKit may preserve the keyboard-sized content offset when the viewport grows.
/// Visibility alone intentionally treats that negative bottom distance as visible;
/// only a previously bottom-aligned, scrollable transcript needs realignment.
func chatNeedsBottomRealignmentAfterViewportExpansion(
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

private struct ChatLinkedConversationRoute: Identifiable, Hashable {
    let id: String
}

struct ChatHeaderTitleDecision: Equatable {
    static let safeDirectFallback = "单聊"

    static func resolve(
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

struct GroupMuteBannerDecision: Equatable {
    let title: String
    let detail: String
    let isRepairRequired: Bool

    static func resolve(group: GroupInfo, canManage: Bool) -> GroupMuteBannerDecision? {
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

struct ChatDisabledBannerDecision: Equatable {
    let groupMuteBanner: GroupMuteBannerDecision?
    let showsComposerDisabledNotice: Bool

    var visibleBannerCount: Int {
        (groupMuteBanner == nil ? 0 : 1) + (showsComposerDisabledNotice ? 1 : 0)
    }

    static func resolve(
        groupMuteBanner: GroupMuteBannerDecision?,
        composerIsDisabled: Bool
    ) -> ChatDisabledBannerDecision {
        ChatDisabledBannerDecision(
            groupMuteBanner: groupMuteBanner,
            showsComposerDisabledNotice: composerIsDisabled && groupMuteBanner == nil
        )
    }
}

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var readVisibilityEpoch = 0
    let conversationID: String
    var initialSearchJumpTarget: RemoteTenantSearchJumpTarget? = nil
    private static let messageTimeSeparatorThreshold: TimeInterval = 5 * 60
    private static let searchSelectionJumpDelayNanoseconds: UInt64 = 320_000_000
    @State private var input = ""
    @State private var showTools = false
    @State private var showEmoji = false
    @State private var actionMessage: ChatMessage?
    @State private var reactionMessage: ChatMessage?
    @State private var receiptMessage: ChatMessage?
    @State private var editMessage: ChatMessage?
    @State private var reportMessage: ChatMessage?
    @State private var showBatchForwardTargets = false
    @State private var adminDeleteCandidate: ChatMessage?
    @State private var replyQuote: String?
    @State private var replyContext: MessageReplyContext?
    @State private var showDetail = false
    @State private var showGroupAnnouncement = true
    @State private var showGroupAnnouncementDetail = false
    @State private var openedGroupAnnouncementID: String?
    @State private var isOpeningGroupAnnouncementDetail = false
    @State private var isMarkingGroupAnnouncementRead = false
    @State private var showPinnedMessages = false
    @State private var pendingPinnedJumpMessage: ChatMessage?
    @State private var pinnedCarouselIndex = 0
    @State private var scrollTargetID: String?
    @State private var focusedTimelineMessageID: String?
    @State private var focusedTimelineMessageGeneration = 0
    @State private var pendingUnreadCount = 0
    @State private var previousMessageCount = 0
    @State private var didInitialScroll = false
    @State private var capturedUnreadCount = 0
    @State private var didAutoScrollToUnreadAnchor = false
    @State private var initialUnreadSnapshot: Int?
    @State private var initialUnreadAnchorLoadAttempts = 0
    @State private var unreadDividerVisible = false
    @State private var didInitialLatestWindowCatchupScroll = false
    @State private var didScheduleInitialProvisionalBottom = false
    @State private var didResolveReadStatusAnchorAfterSideData = false
    @State private var latestBottomConfirmedSeq: Int64 = 0
    @State private var chatEntryStabilizationUntil = Date.distantPast
    @State private var didUserInteractWithMessageScroll = false
    @State private var selectedUserProfile: IMUser?
    @State private var selectedSenderActionUser: IMUser?
    @State private var selectedAttachmentMessage: ChatMessage?
    @State private var previewImageAttachment: AttachmentMediaPreviewItem?
    @State private var previewVideoAttachment: AttachmentMediaPreviewItem?
    @State private var attachmentShareItem: AttachmentShareItem?
    @State private var attachmentPreviewDocument: AttachmentLocalPreviewDocument?
    @State private var showSearch = false
    @FocusState private var isHistorySearchFocused: Bool
    @State private var searchDismissalCoordinator = ChatSearchDismissalCoordinator()
    @State private var pendingSearchResultSelection: RemoteTenantSearchResult?
    @State private var searchKeyword = ""
    @State private var searchResults: [RemoteTenantSearchResult] = []
    @State private var conversationSearchResponse: RemoteTenantSearchResponse?
    @State private var conversationSearchDate = ""
    @State private var conversationSearchTotal = 0
    @State private var conversationSearchHitSeqs: [Int64] = []
    @State private var conversationSearchTypeCursors: [String: String] = [:]
    @State private var focusedSearchResultID: String?
    @State private var conversationSearchInvalidations: [SearchInvalidationEvent] = []
    @State private var isSearchingMessages = false
    @State private var isLoadingMoreSearchResults = false
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var didApplyInitialSearchJumpTarget = false
    @State private var isPreparingInitialSearchJumpTarget = false
    @State private var linkedConversationRoute: ChatLinkedConversationRoute?
    @State private var pendingProfileConversationID: String?
    @State private var oldestHistoryLoadAnchorID: String?
    @State private var oldestHistoryLoadAnchorMinY: CGFloat?
    @State private var newestHistoryLoadAnchorSeq: Int64 = 0
    @State private var didTriggerOlderHistoryLoadForScrollIntent = false
    @StateObject private var transcriptScrollControl = ChatTranscriptScrollControl()
    @GestureState private var isTranscriptDragRecognized = false
    @State private var scrollStateConversationID: String?
    @State private var scrollStateSessionKey = ""
    @State private var scrollArbiter = ConversationScrollArbiter()
    @State private var pendingScrollTargetSource: ConversationScrollRequestSource = .searchJump
    @State private var pendingScrollTargetAnchor: UnitPoint = .center
    @StateObject private var messageTopMeasurements = ChatMessageTopMeasurementStore()
    @StateObject private var scrollMetricsMeasurements = ChatScrollMetricsMeasurementStore()
    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_STATE - 修改开始：输入/键盘重绘时复用消息时间线 item
    @StateObject private var messageTimelineItemCache = ChatMessageTimelineItemCache()
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_STATE - 修改结束
    @State private var isApplyingInitialScroll = false
    @State private var isUserBrowsingHistory = false
    @State private var isAtBottom = false
    @State private var pendingOwnSendScrollBaselineCount: Int?
    @State private var didScrollTowardUnreadMessages = false
    @State private var isClearingUnreadReminder = false
    @State private var lastScrollVisibility = ChatScrollVisibility.initial
    @State private var underfilledOlderAutofillAttempts = 0
    @State private var pendingMentionAll = false
    @State private var pendingMentionUsers: [MentionIdentity] = []
    @State private var cachedMessageRows: [ChatMessageRenderRow] = []
    @State private var cachedMessageRowsConversationID = ""
    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：用结构化签名替代拼接字符串，降低消息列表重绘时的主线程分配
    @State private var cachedMessageRowSignatures: [ChatMessageRowCacheSignature] = []
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_ROW_CACHE_VERSION_STATE - 修改开始：给消息行缓存稳定版本，避免输入时全量比较 item
    @State private var cachedMessageRowsVersion = 0
    @State private var cachedMessageRowSignatureFingerprint = 0
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_ROW_CACHE_VERSION_STATE - 修改结束
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_RENDER_CACHE_STATE - 修改开始：旧消息同步后合并刷新消息行缓存
    @State private var cachedMessageRowsRenderToken = ChatMessageRenderChangeToken.empty
    @State private var messageRenderCacheRefreshTask: Task<Void, Never>?
    @State private var lastOlderHistoryLoadAttemptAt = Date.distantPast
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_RENDER_CACHE_STATE - 修改结束：旧消息同步后合并刷新消息行缓存
    @State private var lastVisibleReadAckToken = ""
    @State private var chatOpenStartedAt = CFAbsoluteTimeGetCurrent()
    @State private var chatOpenPerfConversationID: String?
    @State private var didLogChatFirstFrame = false
    @State private var didLogChatHistoryReady = false
    @State private var didLogChatSideDataReady = false
    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_STATE - 修改开始：定位图片发送后返回偶发卡住的 UI 链路日志状态
    @State private var chatBackDismissAttemptID = 0
    @State private var chatBackDisappearedAttemptID = 0
    @State private var chatBackDismissAttemptStartedAt = CFAbsoluteTimeGetCurrent()
    @State private var messageRenderCacheRefreshDiagnosticID = 0
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_STATE - 修改结束：定位图片发送后返回偶发卡住的 UI 链路日志状态
    private let bottomAnchorID = "chat-bottom-anchor"
    private let messageListBottomAnchorHeight: CGFloat = 24
    private let firstUnreadMarkerID = "first-unread-marker"
    private let initialUnreadAnchorMaxHistoryLoads = 1
    private let maxUnderfilledOlderAutofillAttempts = 3
    private let automaticBottomScrollSuppressionInterval: TimeInterval = 1.6
    private let chatEntryStabilizationDuration: TimeInterval = 3.0

    private var chatScrollCoordinateSpaceName: String {
        "chat-scroll-\(conversationID)"
    }

    private var conversation: Conversation {
        state.conversation(id: conversationID)
    }

    private var isBatchForwardSelectionActive: Bool {
        state.batchForwardSourceConversationID == conversationID
            && !(state.batchForwardState?.selectedSourceIDSet.isEmpty ?? true)
    }

    private var batchForwardSelectedSourceCount: Int {
        guard state.batchForwardSourceConversationID == conversationID else { return 0 }
        return state.batchForwardState?.selectedSourceIDSet.count ?? 0
    }

    private func batchForwardDisabledReason(for message: ChatMessage) -> String? {
        switch state.batchForwardEligibility(for: message, in: conversationID) {
        case .selectable:
            return nil
        case .disabled(let reason):
            return reason
        }
    }

    private func beginBatchForward(with message: ChatMessage) {
        state.beginBatchForward(
            conversationID: conversationID,
            initialMessageID: message.id
        )
    }

    private var pinnedMessages: [ChatMessage] {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：无置顶消息时避免每次键盘/输入重绘都分配空数组
        let messages = conversation.messages
        let hasPinnedMessage = messages.contains { $0.isPinned && !$0.isDeletedLocally && $0.status != .recalled }
        guard hasPinnedMessage else { return [] }
        return messages.filter { $0.isPinned && !$0.isDeletedLocally && $0.status != .recalled }
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private var timelineMessages: [ChatMessage] {
        chatTimelineMessagesForRendering(conversation.messages)
    }

    private var backUnreadCount: Int {
        ConversationUnreadBadgeProjection.total(
            state.conversations,
            excludingConversationID: conversationID
        )
    }

    private var backUnreadBadgeText: String {
        UnreadBadgeFormatter.text(backUnreadCount) ?? ""
    }

    private var directCallPeer: IMUser? {
        state.directConversationCallPeer(for: conversation)
    }

    private var directProfilePeer: IMUser? {
        state.directConversationProfilePeer(for: conversation)
    }

    private var conversationDisplayTitle: String {
        let resolvedPeerDisplayName = directProfilePeer.map {
            state.remarkPreferredDisplayName(for: $0)
        }
        return ChatHeaderTitleDecision.resolve(
            kind: conversation.kind,
            resolvedPeerDisplayName: resolvedPeerDisplayName,
            conversationTitle: conversation.title
        )
    }

    private var conversationHeader: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(
                    isBatchForwardSelectionActive
                        ? "已选 \(batchForwardSelectedSourceCount) 条"
                        : conversationDisplayTitle
                )
                    .font(.headline.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat_centered_conversation_title")
                    .accessibilityAddTraits(.isHeader)
                if !isBatchForwardSelectionActive,
                   conversation.kind == .group,
                   let groupMemberSubtitleText {
                    Text(groupMemberSubtitleText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // The symmetric fixed-width center lane is independent of the
            // asymmetric action lanes, so a narrow device cannot shift or
            // collapse the title while the text itself still truncates.
            .frame(width: 136)
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                Button {
                    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_BACK_TAP - 修改开始：记录返回点击是否进入 action，以及 dismiss 后页面是否消失
                    chatBackDismissAttemptID &+= 1
                    let attemptID = chatBackDismissAttemptID
                    chatBackDismissAttemptStartedAt = CFAbsoluteTimeGetCurrent()
                    chatBackStuckDiagnostic(
                        "back_tap",
                        force: true,
                        extra: "attempt=\(attemptID) batch=\(isBatchForwardSelectionActive)"
                    )
                    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_BACK_TAP - 修改结束：记录返回点击是否进入 action，以及 dismiss 后页面是否消失
                    if isBatchForwardSelectionActive {
                        state.cancelBatchForward()
                        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_BATCH_CANCEL - 修改开始：区分多选取消与真实页面返回
                        chatBackStuckDiagnostic(
                            "back_batch_cancel_done",
                            force: true,
                            extra: "attempt=\(attemptID)"
                        )
                        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_BATCH_CANCEL - 修改结束：区分多选取消与真实页面返回
                    } else {
                        dismiss()
                        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_DISMISS_CALLED - 修改开始：记录 dismiss 调用与延迟未消失检查
                        chatBackStuckDiagnostic(
                            "back_dismiss_called",
                            force: true,
                            extra: "attempt=\(attemptID)"
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            guard chatBackDismissAttemptID == attemptID,
                                  chatBackDisappearedAttemptID != attemptID else { return }
                            chatBackStuckDiagnostic(
                                "back_dismiss_pending_after_350ms",
                                force: true,
                                extra: "attempt=\(attemptID) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: chatBackDismissAttemptStartedAt))"
                            )
                        }
                        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_DISMISS_CALLED - 修改结束：记录 dismiss 调用与延迟未消失检查
                    }
                } label: {
                    if isBatchForwardSelectionActive {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .frame(width: 44, height: 44)
                    } else {
                        ChatBackButtonBadge(count: backUnreadCount, text: backUnreadBadgeText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("chat_back_button")
                .accessibilityLabel(
                    isBatchForwardSelectionActive
                        ? "取消多选"
                        : (backUnreadCount > 0
                            ? "返回，会话列表还有\(backUnreadBadgeText)条未读消息"
                            : "返回")
                )

                Spacer(minLength: 0)

                if !isReadOnlySystemConversation && !isBatchForwardSelectionActive {
                    Button {
                        if showSearch {
                            requestSearchDismissal(.close)
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                showSearch = true
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat_search_button")
                    .accessibilityLabel("搜索聊天记录")

                    Button {
                        if conversation.kind == .group {
                            showDetail = true
                        } else if let user = directProfilePeer {
                            selectedUserProfile = user
                        } else {
                            state.toast = DirectConversationProfilePeerResolver.unavailableMessage
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat_more_button")
                    .accessibilityLabel("会话详情")
                }
            }
            // Product contract keeps back physically left and actions right;
            // the centered title still inherits the surrounding text direction.
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: 56)
        .padding(.horizontal, 8)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var canStartVoiceCall: Bool {
        guard conversation.kind == .direct, let directCallPeer else { return false }
        return state.canStartVoiceCall(with: directCallPeer)
    }

    private var canStartVideoCall: Bool {
        guard conversation.kind == .direct, let directCallPeer else { return false }
        return state.canStartVideoCall(with: directCallPeer)
    }

    private var isVideoCallEntryVisible: Bool {
        conversation.kind == .direct
    }

    private var voiceCallAccessibilityHint: String {
        state.callLicenseUnavailableMessage(for: .voice)
            ?? directCallPeer.flatMap(state.voiceCallUnavailableReason(for:)) ?? ""
    }

    private var videoCallAccessibilityHint: String {
        directCallPeer.flatMap(state.videoCallUnavailableReason(for:)) ?? ""
    }

    private var currentGroup: GroupInfo {
        if let group = state.group(forConversationID: conversationID) {
            return group
        }
        let fallbackMemberCount = state.visibleGroupMemberCount(
            conversation.memberCount,
            conversation.participants.count
        ) ?? 0
        return GroupInfo(
            id: conversation.id,
            name: conversation.title,
            avatarURL: conversation.avatarURL,
            notice: "群资料同步中",
            owner: "",
            members: conversation.participants,
            admins: [],
            muted: conversation.isMuted,
            allMuted: false,
            allMuteStart: nil,
            allMuteEnd: nil,
            memberCount: fallbackMemberCount
        )
    }

    private var groupMemberSubtitleText: String? {
        state.visibleGroupMemberCount(
            currentGroup.memberCount,
            currentGroup.members.count,
            conversation.memberCount,
            conversation.participants.count
        ).map { "\($0) 人" }
    }

    private func startVoiceCallFromConversation() {
        guard let directCallPeer else {
            state.toast = conversation.kind == .direct
                ? DirectConversationCallPeerResolver.unavailableMessage
                : "暂不支持群语音通话"
            return
        }
        guard state.guardCallLicenseForAction(.voice) else { return }
        guard canStartVoiceCall else {
            if conversation.kind != .direct {
                state.toast = "暂不支持群语音通话"
            } else {
                state.toast = state.voiceCallUnavailableReason(for: directCallPeer) ?? "暂无法发起语音通话"
            }
            return
        }
        state.startOutgoingVoiceCall(to: directCallPeer, channelID: conversation.id)
    }

    private func startVideoCallFromConversation() {
        guard let directCallPeer else {
            state.toast = conversation.kind == .direct
                ? DirectConversationCallPeerResolver.unavailableMessage
                : "暂不支持群视频通话"
            return
        }
        guard state.guardCallLicenseForAction(.video) else { return }
        guard canStartVideoCall else {
            state.toast = state.videoCallUnavailableReason(for: directCallPeer) ?? "暂无法发起视频通话"
            return
        }
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：聊天页直发视频先拉起轻量通话页，网络/权限准备继续异步执行
        state.startOutgoingVideoCall(to: directCallPeer, channelID: conversation.id, presentImmediately: true)
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
    }

    private var boundedPendingUnreadCount: Int {
        let sourceCount = scrollArbiter.isJumpMode
            ? max(pendingUnreadCount, conversation.unread)
            : pendingUnreadCount
        return min(max(sourceCount, 0), max(timelineMessages.count, sourceCount))
    }

    private var hasUnreadReminder: Bool {
        pendingUnreadCount > 0 || capturedUnreadCount > 0 || unreadDividerVisible
    }

    private var firstUnreadSourceCount: Int {
        let anchorCount = capturedUnreadCount > 0 ? capturedUnreadCount : pendingUnreadCount
        return max(anchorCount, 0)
    }

    private var firstUnreadAnchorCount: Int {
        min(firstUnreadSourceCount, timelineMessages.count)
    }

    private var latestLoadedMessageSeq: Int64 {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：避免消息多时 map/max 在主线程生成临时数组
        var latestSeq: Int64 = 0
        for message in timelineMessages where message.channelSeq > latestSeq {
            latestSeq = message.channelSeq
        }
        return latestSeq
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private var latestBottomScrollTargetID: String {
        bottomAnchorID
    }

    private var shouldMeasureMessageTopAnchors: Bool {
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_ANCHOR_MEASURE_GATE - 修改开始：只在需要历史锚点时测量消息位置
        isWithinChatEntryStabilizationWindow
            || oldestHistoryLoadAnchorID != nil
            || isLoadingConversationHistory
            || isUserBrowsingHistory
            // Late initial pages can need autofill after entry stabilization.
            || lastScrollVisibility.isContentUnderfilled
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_ANCHOR_MEASURE_GATE - 修改结束：只在需要历史锚点时测量消息位置
    }

    private func shouldMeasureMessageTopAnchor(for row: ChatMessageRenderRow) -> Bool {
        // The lazy list mounts only nearby leaves. A visible history row can be
        // anywhere in the window, so its index is not a visibility boundary.
        shouldMeasureMessageTopAnchors
    }

    private func historyAnchorID(for messageID: String) -> String {
        "history-anchor-\(messageID)"
    }

    private var isLatestMessageWindowLoaded: Bool {
        conversation.lastMsgSeq <= 0 || latestLoadedMessageSeq >= conversation.lastMsgSeq
    }

    private var latestBottomTargetSeq: Int64 {
        max(conversation.lastMsgSeq, latestLoadedMessageSeq)
    }

    private var hasConfirmedLatestBottomForCurrentWindow: Bool {
        let targetSeq = latestBottomTargetSeq
        guard targetSeq > 0 else { return didInitialLatestWindowCatchupScroll }
        guard isLatestMessageWindowLoaded else { return false }
        return latestBottomConfirmedSeq >= targetSeq
            || state.rememberedConversationBottomSeq(for: conversationID) >= targetSeq
    }

    private var canReuseConfirmedBottomForCurrentWindow: Bool {
        chatCanReuseConfirmedBottom(
            unreadCount: rawInitialUnreadCount(),
            latestBottomTargetSeq: latestBottomTargetSeq,
            isLatestMessageWindowLoaded: isLatestMessageWindowLoaded,
            rememberedConfirmedSeq: state.rememberedConversationBottomSeq(for: conversationID)
        )
    }

    private var needsInitialLatestMetadataRefresh: Bool {
        rawInitialUnreadCount() == 0
            && conversation.lastMsgSeq <= 0
            && !timelineMessages.isEmpty
            && initialUnreadAnchorLoadAttempts == 0
    }

    private var needsInitialLatestWindowRefresh: Bool {
        !timelineMessages.isEmpty
            && (
                needsInitialLatestMetadataRefresh
                    || (conversation.lastMsgSeq > 0 && latestLoadedMessageSeq < conversation.lastMsgSeq)
            )
    }

    private var hasLastReadInitialAnchorForCurrentWindow: Bool {
        initialScrollAnchor(unreadCount: initialUnreadCountForCurrentMessageWindow())?.anchorsLastReadMessage == true
    }

    private var needsInitialUnreadWindowRefresh: Bool {
        rawInitialUnreadCount() > 0
            && !timelineMessages.isEmpty
            && initialUnreadAnchorLoadAttempts == 0
            && !hasConfirmedLatestBottomForCurrentWindow
    }

    private var isLoadingConversationHistory: Bool {
        state.conversationHistoryLoadingIDs.contains(conversationID)
            || state.isConversationMessageSyncInFlight(conversationID)
    }

    private var isOlderConversationHistoryLoading: Bool {
        state.conversationHistoryLoadingIDs.contains(conversationID)
    }

    private var shouldShowConversationHistoryLoadingPill: Bool {
        isOlderConversationHistoryLoading && didUserInteractWithMessageScroll && isUserBrowsingHistory
    }

    private var conversationHistoryMessage: String? {
        state.conversationHistoryMessages[conversationID]
    }

    private var shouldShowDirectEmptyHistoryState: Bool {
        conversation.kind == .direct
            && conversation.messages.isEmpty
            && !isLoadingConversationHistory
            && !isReadOnlySystemConversation
    }

    private var directEmptyHistoryTitle: String {
        if !conversationSendDisabledReason.isEmpty {
            return "当前无法发送消息"
        }
        if let message = conversationHistoryMessage, message.contains("失败") {
            return "聊天记录同步失败"
        }
        return "暂无历史消息"
    }

    private var directEmptyHistorySubtitle: String {
        if !conversationSendDisabledReason.isEmpty {
            return conversationSendDisabledReason
        }
        if let message = conversationHistoryMessage, message.contains("失败") {
            return "网络或服务暂时不可用，请稍后重试。"
        }
        return "可以发送第一条消息，后续历史同步完成后会自动显示。"
    }

    private var canRetryDirectHistorySync: Bool {
        conversationHistoryMessage?.contains("失败") == true
    }

    private var conversationSendDisabledReason: String {
        state.conversationSendDisabledReason(conversationID)
    }

    private var composerDisabledReason: String {
        conversationSendDisabledReason.isEmpty ? groupMuteDisabledReason : conversationSendDisabledReason
    }

    private var composerDisabledTitle: String {
        if conversationSendDisabledReason == AppState.globalMutedMessage {
            return AppState.globalMutedMessage
        }
        if conversationSendDisabledReason.isEmpty, isGroupAllMuted {
            return currentGroup.allMuteStatusText()
        }
        return conversationSendDisabledReason.isEmpty ? AppState.globalMutedMessage : "当前无法发送消息"
    }

    private var firstUnreadMessageID: String? {
        chatFirstUnreadMessageIDForDivider(
            messages: timelineMessages,
            firstUnreadMessageID: conversation.firstUnreadMessageID,
            firstUnreadSeq: conversation.firstUnreadSeq,
            lastReadSeq: conversation.lastReadSeq,
            unreadCount: firstUnreadSourceCount
        )
    }

    private var latestReadableIncomingMessageReadToken: String {
        guard let message = latestReadableIncomingMessage() else { return "" }
        let sequenceToken = message.channelSeq > 0 ? String(message.channelSeq) : message.id
        return "\(conversationID):\(sequenceToken)"
    }

    private var isReadOnlySystemConversation: Bool {
        conversation.kind == .system || (conversation.kind != .group && isSystemAccountConversation)
    }

    private func isMessageAuthoredByCurrentUser(_ message: ChatMessage) -> Bool {
        guard message.kind != .system else { return false }
        return state.isCurrentMessageSender(message.senderId)
    }

    private func currentMessageSnapshot(for message: ChatMessage) -> ChatMessage {
        conversation.messages.first(where: { $0.id == message.id }) ?? message
    }

    private func handleAttachmentTap(_ message: ChatMessage) {
        if message.status == .sending || (message.status == .failed && state.canRetryAttachmentUpload(message)) {
            selectedAttachmentMessage = message
            return
        }

        let mediaCategory = state.attachmentMediaCategory(for: message)
        switch mediaCategory {
        case "image":
            prepareMediaPreview(message, mediaCategory: "image")
        case "video":
            prepareMediaPreview(message, mediaCategory: "video")
        case "pdf":
            prepareDocumentPreview(message)
        default:
            prepareFileShare(message)
        }
    }

    private func prepareMediaPreview(_ message: ChatMessage, mediaCategory: String) {
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else { return }
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(
                    message, conversationID: conversationID,
                    preferPreview: !AttachmentGIFPresentation.isGIF(message)
                )
                let item = AttachmentMediaPreviewItem(message: currentMessageSnapshot(for: message), localURL: localURL)
                await MainActor.run {
                    switch mediaCategory {
                    case "video":
                        previewVideoAttachment = item
                    default:
                        previewImageAttachment = item
                    }
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    state.toast = "下载失败，请重试"
                }
            }
        }
    }

    private func prepareDocumentPreview(_ message: ChatMessage) {
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else { return }
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
                await MainActor.run {
                    attachmentPreviewDocument = AttachmentLocalPreviewDocument(url: localURL)
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    state.toast = "下载失败，请重试"
                }
            }
        }
    }

    private func prepareFileShare(_ message: ChatMessage) {
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else { return }
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                await MainActor.run {
                    attachmentShareItem = AttachmentShareItem(url: localURL)
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    state.toast = "下载失败，请重试"
                }
            }
        }
    }

    private func canSaveAttachmentFromActionMenu(_ message: ChatMessage) -> Bool {
        AttachmentSaveCapabilityPolicy.canSave(
            kind: message.kind,
            mediaCategory: state.attachmentMediaCategory(for: message),
            status: message.status,
            isDeletedLocally: message.isDeletedLocally,
            hasResolvableAsset: state.resolvedAttachmentDownloadURL(for: message) != nil
            || state.resolvedAttachmentBestPreviewURL(for: message) != nil
                || state.attachmentCanRefreshRemoteFile(message)
        )
    }

    private func canFavoriteAssetFromActionMenu(_ message: ChatMessage) -> Bool {
        guard !message.isRTCCallRecordMessage,
              message.status != .sending,
              message.status != .failed,
              message.status != .recalled,
              !message.isDeletedLocally,
              !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.id.hasPrefix("local_") else {
            return false
        }
        if message.kind == .image || message.kind == .video || message.kind == .voice {
            return true
        }
        guard message.kind == .file else { return false }
        let mediaCategory = state.attachmentMediaCategory(for: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["image", "video", "audio", "voice", "pdf", "document", "spreadsheet", "archive"].contains(mediaCategory) {
            return true
        }
        return !(message.attachmentFileID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAttachmentFromActionMenu(_ message: ChatMessage) {
        let mediaCategory = state.attachmentMediaCategory(for: message)
        Task {
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(
                    message,
                    conversationID: conversationID,
                    preferPreview: !AttachmentGIFPresentation.isGIF(message) && (mediaCategory == "image" || mediaCategory == "video")
                )
                switch mediaCategory {
                case "image":
                    await saveImageAttachment(localURL, originalGIF: AttachmentGIFPresentation.isGIF(message))
                case "video":
                    await saveVideoAttachment(localURL)
                default:
                    await MainActor.run {
                        attachmentShareItem = AttachmentShareItem(url: localURL)
                    }
                }
            } catch is CancellationError {
                // User cancelled; no toast needed.
            } catch {
                await MainActor.run {
                    state.toast = "文件下载失败，无法保存，请重试"
                }
            }
        }
    }

    private func saveImageAttachment(_ localURL: URL, originalGIF: Bool = false) async {
        if originalGIF {
            let result = await AttachmentPhotoLibrarySaver.saveOriginalImage(at: localURL)
            switch result {
            case .success: state.toast = "图片已保存到相册"
            case .denied: state.toast = "没有相册保存权限，请在系统设置中开启"
            case .failed, .unknownFailure: state.toast = "图片保存失败，请重试"
            }
            return
        }
        guard let image = UIImage(contentsOfFile: localURL.path) else {
            await MainActor.run {
                state.toast = "图片文件不存在，请重新下载后保存"
            }
            return
        }
        let result = await AttachmentPhotoLibrarySaver.saveImage(image)
        await MainActor.run {
            switch result {
            case .success:
                state.toast = "图片已保存到相册"
            case .denied:
                state.toast = "没有相册保存权限，请在系统设置中开启"
            case .failed(let message):
                state.toast = "图片保存失败：\(message)"
            case .unknownFailure:
                state.toast = "图片保存失败，请重试"
            }
        }
    }

    private func saveVideoAttachment(_ localURL: URL) async {
        guard localURL.isFileURL, FileManager.default.fileExists(atPath: localURL.path) else {
            await MainActor.run {
                state.toast = "视频文件不存在，请重新下载后保存"
            }
            return
        }
        let result = await AttachmentPhotoLibrarySaver.saveVideo(at: localURL)
        await MainActor.run {
            switch result {
            case .success:
                state.toast = "视频已保存到相册"
            case .denied:
                state.toast = "没有相册保存权限，请在系统设置中开启"
            case .failed(let message):
                state.toast = "视频保存失败：\(message)"
            case .unknownFailure:
                state.toast = "视频保存失败，请重试"
            }
        }
    }

    private var isSystemAccountConversation: Bool {
        let hasSystemParticipant = conversation.participants.contains { user in
            let normalizedID = user.id.lowercased()
            return normalizedID.contains("system")
                || normalizedID.contains("bot")
                || user.name.contains("系统")
                || user.title.contains("系统")
        }
        return hasSystemParticipant || conversation.title.contains("系统")
    }

    private var isGroupAllMuted: Bool {
        conversation.kind == .group && !state.canCurrentUserSend(in: currentGroup)
    }

    private var composerIsDisabled: Bool {
        !conversationSendDisabledReason.isEmpty || isGroupAllMuted
    }

    private var shouldShowGroupMuteStatus: Bool {
        disabledBannerDecision.groupMuteBanner != nil
    }

    private var groupMuteBannerDecision: GroupMuteBannerDecision? {
        guard conversation.kind == .group else { return nil }
        return GroupMuteBannerDecision.resolve(
            group: currentGroup,
            canManage: state.canManageGroup(currentGroup)
        )
    }

    private var disabledBannerDecision: ChatDisabledBannerDecision {
        ChatDisabledBannerDecision.resolve(
            groupMuteBanner: groupMuteBannerDecision,
            composerIsDisabled: composerIsDisabled
        )
    }

    private var currentGroupAnnouncement: GroupAnnouncement? {
        state.currentUnreadAnnouncement(for: currentGroup.id)
    }

    private var currentGroupAnnouncementTitle: String {
        let title = currentGroupAnnouncement?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "群公告" : title
    }

    private var currentGroupAnnouncementPreview: String {
        let summary = currentGroupAnnouncement?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        let content = currentGroupAnnouncement?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty { return content }
        return currentGroup.notice
    }

    private var shouldShowGroupAnnouncement: Bool {
        conversation.kind == .group && showGroupAnnouncement && state.hasUnreadAnnouncement(for: currentGroup.id)
    }

    private var groupMuteDisabledReason: String {
        if currentGroup.allMuteRepairRequired {
            return "禁言状态需要管理员修复；修复前普通成员无法发送，草稿会保留。"
        }
        if currentGroup.allMuteMode == .always
            || (currentGroup.allMuteMode == nil
                && currentGroup.allMuted
                && currentGroup.allMuteStart == nil
                && currentGroup.allMuteEnd == nil) {
            return "群主已开启一直禁言；群主和管理员可继续发言。"
        }
        return "\(currentGroup.allMuteStatusText())；群主和管理员可继续发言。"
    }

    private var groupMuteStatusDetail: String {
        groupMuteBannerDecision?.detail ?? ""
    }

    private func openCurrentGroupAnnouncement() {
        guard let announcement = currentGroupAnnouncement else { return }
        guard !isOpeningGroupAnnouncementDetail, !isMarkingGroupAnnouncementRead else { return }
        let groupID = currentGroup.id
        isOpeningGroupAnnouncementDetail = true
        state.loadGroupAnnouncementDetail(groupID: groupID, announcementID: announcement.id, silent: false) { success in
            isOpeningGroupAnnouncementDetail = false
            guard success, conversation.kind == .group, currentGroup.id == groupID else { return }
            openedGroupAnnouncementID = announcement.id
            showGroupAnnouncementDetail = true
            state.markGroupAnnouncementRead(groupID: groupID, announcementID: announcement.id)
        }
    }

    private func closeCurrentGroupAnnouncementBanner() {
        markCurrentGroupAnnouncementRead()
    }

    private func markCurrentGroupAnnouncementRead() {
        guard !isMarkingGroupAnnouncementRead else { return }
        guard let announcement = currentGroupAnnouncement else {
            return
        }
        isMarkingGroupAnnouncementRead = true
        state.markGroupAnnouncementRead(groupID: currentGroup.id, announcementID: announcement.id) { _ in
            isMarkingGroupAnnouncementRead = false
        }
    }

    private func beginChatOpenPerfTrace(reason: String, force: Bool = false) {
        guard force || chatOpenPerfConversationID != conversationID else { return }
        chatOpenStartedAt = CFAbsoluteTimeGetCurrent()
        chatOpenPerfConversationID = conversationID
        didLogChatFirstFrame = false
        didLogChatHistoryReady = false
        didLogChatSideDataReady = false
        print("[JHT Perf] chat_open_start reason=\(reason) kind=\(conversation.kind.rawValue) cached_messages=\(conversation.messages.count) unread=\(conversation.unread)")
    }

    private func logChatFirstFrameIfNeeded(stage: String) {
        guard chatOpenPerfConversationID == conversationID, !didLogChatFirstFrame else { return }
        didLogChatFirstFrame = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_first_frame_ms=\(elapsedMs) stage=\(stage) kind=\(conversation.kind.rawValue) rendered_messages=\(conversation.messages.count)")
    }

    private func logChatHistoryReadyIfNeeded(reason: String) {
        guard chatOpenPerfConversationID == conversationID, !didLogChatHistoryReady else { return }
        guard !state.conversationHistoryLoadingIDs.contains(conversationID) else { return }
        guard !conversation.messages.isEmpty || state.conversationHistoryMessages[conversationID] != nil else { return }
        didLogChatHistoryReady = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_visible_history_ready_ms=\(elapsedMs) reason=\(reason) messages=\(conversation.messages.count)")
    }

    private func logChatSideDataReadyIfNeeded(reason: String) {
        guard chatOpenPerfConversationID == conversationID,
              conversation.kind == .group,
              !didLogChatSideDataReady else { return }
        let hasGroupDetail = currentGroup.notice != "群资料同步中" || !currentGroup.members.isEmpty
        let hasSideData = hasGroupDetail || currentGroupAnnouncement != nil || !pinnedMessages.isEmpty
        guard hasSideData else { return }
        didLogChatSideDataReady = true
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - chatOpenStartedAt) * 1000)
        print("[JHT Perf] chat_side_data_ready_ms=\(elapsedMs) reason=\(reason) pinned=\(pinnedMessages.count) announcement=\(currentGroupAnnouncement != nil)")
    }

    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_HELPERS - 修改开始：统一聊天返回卡住定位日志，避免输出消息正文和敏感标识
    private func chatBackStuckDiagnostic(_ event: String, force: Bool = false, extra: String = "") {
#if DEBUG
        let uploadingCount = conversation.messages.filter {
            $0.attachmentTransferProgress != nil || !$0.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        guard force || uploadingCount > 0 || chatBackDismissAttemptID > 0 else { return }
        let scrollTarget = scrollTargetID.map(Self.shortChatBackDiagnosticID) ?? "none"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortChatBackDiagnosticID(conversationID)) kind=\(conversation.kind.rawValue) messages=\(conversation.messages.count) input_len=\(input.count) uploading=\(uploadingCount) browsing=\(isUserBrowsingHistory) at_bottom=\(isAtBottom) pending_scroll=\(scrollTarget)\(suffix)")
#endif
    }

    private static func shortChatBackDiagnosticID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    private static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_HELPERS - 修改结束：统一聊天返回卡住定位日志，避免输出消息正文和敏感标识

    private func requestSearchDismissal(_ intent: ChatSearchDismissalIntent) {
        applySearchDismissalEffect(
            searchDismissalCoordinator.request(
                intent,
                isFocused: isHistorySearchFocused
            )
        )
    }

    private func applySearchDismissalEffect(_ effect: ChatSearchDismissalEffect) {
        switch effect {
        case .none:
            break
        case .releaseFocus:
            isHistorySearchFocused = false
        case .dismissPanel:
            guard let intent = searchDismissalCoordinator.consumePendingIntent() else { return }
            completeSearchDismissal(intent)
        }
    }

    private func completeSearchDismissal(_ intent: ChatSearchDismissalIntent) {
        switch intent {
        case .close:
            pendingSearchResultSelection = nil
            if isSearchingMessages || isLoadingMoreSearchResults {
                postConversationSearchAnalytics(eventType: "cancel", response: conversationSearchResponse)
            }
            searchTask?.cancel()
            isSearchingMessages = false
            isLoadingMoreSearchResults = false
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                showSearch = false
            }
        case .selectResult:
            guard let hit = pendingSearchResultSelection else { return }
            pendingSearchResultSelection = nil
            focusedSearchResultID = hit.id
            postConversationSearchAnalytics(eventType: "click", response: conversationSearchResponse, item: hit)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                showSearch = false
            }
            let selectedResultID = hit.id
            Task {
                try? await Task.sleep(nanoseconds: Self.searchSelectionJumpDelayNanoseconds)
                guard !Task.isCancelled else { return }
                let shouldJump = await MainActor.run {
                    focusedSearchResultID == selectedResultID && !showSearch
                }
                guard shouldJump else { return }
                await jumpToSearchResult(hit)
            }
        }
    }

    var body: some View {
        Group {
            if !state.isProtectedAccessAuthorized(.chat) {
                BiometricProtectedContentGate(
                    symbol: "faceid",
                    title: "会话已受保护",
                    subtitle: "通过 Face ID 验证后才能查看聊天内容。"
                ) {
                    _ = await state.authorizeProtectedAccess(.chat)
                }
            } else {
                unlockedBody
            }
        }
    }

    @ViewBuilder
    private var unlockedBody: some View {
        let renderMessages = timelineMessages
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：同一轮 body 渲染复用置顶消息结果，避免重复扫描
        let renderPinnedMessages = pinnedMessages
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_RENDER_ROW_SNAPSHOT - 修改开始：渲染行携带缓存版本，减少输入重绘中的时间线 item 重建
        let renderMessageRowsSnapshot = cachedRowsForRendering(messages: renderMessages)
        let renderMessageRows = renderMessageRowsSnapshot.rows
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_RENDER_ROW_SNAPSHOT - 修改结束

        ZStack {
            AuroraBackground()
            AnyView(
                VStack(spacing: 0) {
                if shouldShowGroupAnnouncement {
                    groupContext
                }
                if !renderPinnedMessages.isEmpty {
                    pinnedContext(messages: renderPinnedMessages)
                }
                if showSearch {
                    ChatHistorySearchPanel(
                        keyword: $searchKeyword,
                        dateText: $conversationSearchDate,
                        results: searchResults,
                        total: conversationSearchTotal,
                        hitChannelSeqs: conversationSearchHitSeqs,
                        isSearching: isSearchingMessages,
                        isLoadingMore: isLoadingMoreSearchResults,
                        hasMore: conversationSearchHasMore,
                        searchFocus: $isHistorySearchFocused,
                        onSearch: {
                            performMessageSearch()
                        },
                        onDateSearch: {
                            performConversationDateSearch()
                        },
                        onPrevious: {
                            jumpToAdjacentSearchResult(direction: -1)
                        },
                        onNext: {
                            jumpToAdjacentSearchResult(direction: 1)
                        },
                        onLoadMore: {
                            loadMoreConversationSearchResults()
                        },
                        onClose: {
                            requestSearchDismissal(.close)
                        },
                        onSelect: { hit in
                            pendingSearchResultSelection = hit
                            requestSearchDismissal(.selectResult)
                        },
                        onQueryChange: {
                            scheduleConversationSearch()
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                ZStack(alignment: .top) {
                    ScrollViewReader { reader in
                        messageTimeline(
                            reader: reader,
                            renderMessages: renderMessages,
                            renderMessageRows: renderMessageRows,
                            // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SNAPSHOT_PASS - 修改开始：传递消息行缓存快照
                            renderMessageRowsSnapshot: renderMessageRowsSnapshot
                            // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SNAPSHOT_PASS - 修改结束
                        )
                    }
                    if chatShouldShowReturnToBottom(
                        didInitialScroll: didInitialScroll,
                        isApplyingInitialScroll: isApplyingInitialScroll,
                        messageCount: renderMessages.count,
                        isAtBottom: isAtBottom,
                        isSearchVisible: showSearch,
                        isReadOnlySystemConversation: isReadOnlySystemConversation
                    ) {
                        ReturnToBottomBar(count: boundedPendingUnreadCount) {
                            let plan = chatReturnToBottomActionPlan(bottomAnchorID: bottomAnchorID)
                            suppressAutomaticBottomScroll(reason: "return_to_bottom")
                            setScrollTarget(plan.targetID, source: plan.source, anchor: plan.anchor)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                if shouldShowGroupMuteStatus, let muteBanner = disabledBannerDecision.groupMuteBanner {
                    HStack(spacing: 10) {
                        Image(systemName: muteBanner.isRepairRequired ? "exclamationmark.triangle.fill" : "speaker.slash.fill")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(muteBanner.isRepairRequired ? IMColor.danger : IMColor.warning)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(
                                    (muteBanner.isRepairRequired ? IMColor.danger : IMColor.warning)
                                        .opacity(0.12)
                                )
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(muteBanner.title)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text(groupMuteStatusDetail)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(IMColor.warning.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(IMColor.warning.opacity(0.16), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat_group_mute_active_banner")
                    .accessibilityLabel("\(muteBanner.title)。\(groupMuteStatusDetail)")
                }
                if !isReadOnlySystemConversation {
                    if isBatchForwardSelectionActive {
                        BatchForwardSelectionBar(
                            selectedCount: batchForwardSelectedSourceCount,
                            onCancel: {
                                state.cancelBatchForward()
                            },
                            onForward: {
                                state.refreshBatchForwardContext(
                                    conversationID: conversationID
                                )
                                showBatchForwardTargets = true
                            }
                        )
                    } else {
                        ChatComposer(
                        conversationID: conversationID,
                        input: $input,
                        replyQuote: $replyQuote,
                        replyContext: $replyContext,
                        showTools: $showTools,
                        showEmoji: $showEmoji,
                        mentionAllSelected: $pendingMentionAll,
                        mentionGroupID: conversation.kind == .group ? currentGroup.id : "",
                        mentionMembers: conversation.kind == .group ? (currentGroup.members.isEmpty ? conversation.participants : currentGroup.members) : [],
                        mentionMembersLoading: conversation.kind == .group && currentGroup.members.isEmpty,
                        canMentionAll: conversation.kind == .group && currentGroup.canCurrentUserManage,
                        isDisabled: composerIsDisabled,
                        showsDisabledNotice: disabledBannerDecision.showsComposerDisabledNotice,
                        disabledTitle: composerDisabledTitle,
                        disabledReason: composerDisabledReason,
                        friendActionTitle: state.conversationFriendRequestActionTitle(conversationID),
                        isApplyingFriend: state.applyingFriendFromConversationIDs.contains(conversationID),
                        allowsVoiceCall: conversation.kind == .direct,
                        allowsVideoCall: isVideoCallEntryVisible,
                        voiceCallAccessibilityHint: voiceCallAccessibilityHint,
                        videoCallAccessibilityHint: videoCallAccessibilityHint,
                        startVoiceCall: startVoiceCallFromConversation,
                        startVideoCall: startVideoCallFromConversation,
                        applyFriend: {
                            Task {
                                await state.applyFriendFromDisabledConversation(conversationID)
                            }
                        },

                        // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_CALL - 修改开始：ChatView 传入输入框聚焦滚动回调
                        onBeginEditing: {
                            scrollToLatestMessageForComposerFocus()
                        },
                        // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_CALL - 修改结束：ChatView 传入输入框聚焦滚动回调
                        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CALL - 修改开始：ChatView 传入 composer 操作滚动回调
                        onRequestLatestScroll: {
                            scrollToLatestMessageForComposerFocus()
                        },
                        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CALL - 修改结束：ChatView 传入 composer 操作滚动回调
                        send: { draft, mentionAll, mentionedUsers in
                            let allowsMention = conversation.kind == .group
                            let activeMentionUsers = allowsMention
                                ? mergedMentionUsers(from: mentionedUsers, externalMentions: pendingMentionUsers, in: draft)
                                : []
                            let activeMentionAll = allowsMention ? mentionAll : false
                            let sentReplyQuote = replyQuote
                            let activeReplyContext = replyQuote == nil ? nil : replyContext
                            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_TEXT_SEND_UI - 修改开始：定位发送文本时主线程同步耗时
                            let textSendDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
                            chatBackStuckDiagnostic(
                                "text_send_tap",
                                extra: "draft_len=\(draft.count) mention_all=\(activeMentionAll) mentions=\(activeMentionUsers.count)"
                            )
                            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_TEXT_SEND_UI - 修改结束：定位发送文本时主线程同步耗时
                            let didStart = state.sendText(
                                draft,
                                conversationID: conversationID,
                                quote: sentReplyQuote,
                                replyContext: activeReplyContext,
                                mentionAll: activeMentionAll,
                                mentionedUsers: activeMentionUsers
                            ) {
                                if input.isEmpty {
                                    input = draft
                                } else if input != draft && !input.contains(draft) {
                                    input = "\(draft)\n\(input)"
                                }
                                if replyQuote == nil {
                                    replyQuote = sentReplyQuote
                                    replyContext = activeReplyContext
                                }
                                pendingMentionAll = pendingMentionAll || activeMentionAll
                                pendingMentionUsers = mergedMentionUsers(
                                    from: pendingMentionUsers,
                                    externalMentions: activeMentionUsers,
                                    in: input
                                )
                            }
                            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_TEXT_SEND_UI_RETURN - 修改开始：记录 sendText 同步返回耗时
                            chatBackStuckDiagnostic(
                                "text_send_return",
                                force: didStart,
                                extra: "started=\(didStart) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: textSendDiagnosticStartedAt))"
                            )
                            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_TEXT_SEND_UI_RETURN - 修改结束：记录 sendText 同步返回耗时
                            guard didStart else { return }
                            // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：文本发送成功后主动收起系统键盘，不影响发送失败时的草稿回填
                            dismissActiveChatKeyboard()
                            // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
                            if pendingUnreadCount > 0 {
                                clearUnreadReminderAndAckIfNeeded(reason: "send_before_reply")
                            }
//                            withoutSendLayoutAnimation {
//                                pendingOwnSendScrollBaselineCount = conversation.messages.count
//                                isUserBrowsingHistory = false
//                                isAtBottom = true
//                                transcriptScrollControl.clearSuppression()
//                            }
//                            withoutSendLayoutAnimation {
//                                input = ""
//                                pendingMentionAll = false
//                                pendingMentionUsers.removeAll()
//                                replyQuote = nil
//                                replyContext = nil
//                                showEmoji = false
//                                showTools = false
//                            }
                            // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_STATE_BATCH - 修改开始：发送后输入栏状态合并更新
                            withoutSendLayoutAnimation {
                                pendingOwnSendScrollBaselineCount = conversation.messages.count
                                isUserBrowsingHistory = false
                                isAtBottom = true
                                transcriptScrollControl.clearSuppression()
                                input = ""
                                pendingMentionAll = false
                                pendingMentionUsers.removeAll()
                                replyQuote = nil
                                replyContext = nil
                                showEmoji = false
                                showTools = false
                            }
                            // JHT_MOD_END CHAT_SEND_UI_PERF_END_STATE_BATCH - 修改结束：发送后输入栏状态合并更新
                        }
                        )
                    }
                }
                }
            )

            AnyView(
                Group {
                    if !isReadOnlySystemConversation, let actionMessage {
                        MessageActionOverlay(
                            message: actionMessage,
                            conversationID: conversationID,
                            canShowReadActions: isMessageAuthoredByCurrentUser(actionMessage),
                            readActionTitle: state.fileUploadConfig.readReceiptsEnabled ? "已读列表" : "送达详情",
                            canForward: batchForwardDisabledReason(for: actionMessage) == nil,
                            forwardDisabledReason: batchForwardDisabledReason(for: actionMessage),
                            canSaveAttachment: canSaveAttachmentFromActionMenu(actionMessage),
                            canFavoriteAsset: canFavoriteAssetFromActionMenu(actionMessage),
                            canReportMessage: messageReportActionIsAvailable(
                                message: actionMessage,
                                isCurrentUserSender: isMessageAuthoredByCurrentUser(actionMessage)
                            ),
                            canAdminDeleteForAll: state.canAdminDeleteMessage(actionMessage, in: conversationID),
                            editDisabledReason: state.messageEditUnavailableReason(actionMessage),
                            recallDisabledReason: state.messageRecallUnavailableReason(actionMessage),
                            onDismiss: {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                                    self.actionMessage = nil
                                }
                            },
                            onReact: { emoji in
                                state.addReaction(emoji, to: actionMessage.id, in: conversationID)
                                self.actionMessage = nil
                            },
                            onMoreReactions: {
                                reactionMessage = actionMessage
                                self.actionMessage = nil
                            },
                            onReply: {
                                startReply(to: actionMessage)
                                self.actionMessage = nil
                            },
                            onCopy: {
                                state.copyMessage(actionMessage)
                                self.actionMessage = nil
                            },
                            onRead: {
                                guard isMessageAuthoredByCurrentUser(actionMessage) else {
                                    state.toast = "只能查看自己发送消息的已读状态"
                                    self.actionMessage = nil
                                    return
                                }
                                if state.fileUploadConfig.readReceiptsEnabled {
                                    state.loadReadReceipts(messageID: actionMessage.id, in: conversationID)
                                }
                                receiptMessage = actionMessage
                                self.actionMessage = nil
                            },
                            onEdit: {
                                editMessage = actionMessage
                                self.actionMessage = nil
                            },
                            onPin: {
                                state.toggleMessagePinned(messageID: actionMessage.id, in: conversationID)
                                self.actionMessage = nil
                            },
                            onFavorite: {
                                state.toggleMessageFavorite(messageID: actionMessage.id, in: conversationID)
                                self.actionMessage = nil
                            },
                            onForward: {
                                beginBatchForward(with: actionMessage)
                                self.actionMessage = nil
                            },
                            onSaveAttachment: {
                                saveAttachmentFromActionMenu(actionMessage)
                                self.actionMessage = nil
                            },
                            onReport: {
                                reportMessage = actionMessage
                                self.actionMessage = nil
                            },
                            onAdminDeleteForAll: {
                                adminDeleteCandidate = actionMessage
                                self.actionMessage = nil
                            },
                            onRecall: {
                                state.recallMessage(messageID: actionMessage.id, in: conversationID)
                                self.actionMessage = nil
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(20)
                    }
                }
            )

            AnyView(
                Group {
                    if !isReadOnlySystemConversation, let user = selectedSenderActionUser {
                        UserQuickActionOverlay(
                            user: user,
                            showsMentionAction: conversation.kind == .group,
                            onDismiss: {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                                    selectedSenderActionUser = nil
                                }
                            },
                            onMention: {
                                guard conversation.kind == .group else {
                                    selectedSenderActionUser = nil
                                    return
                                }
                                mention(user)
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                                    selectedSenderActionUser = nil
                                }
                            },
                            onDetail: {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                                    selectedSenderActionUser = nil
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                    selectedUserProfile = user
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(30)
                    }
                }
            )

        }
        .background(
            ChatBackSwipeInstaller()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            conversationHeader
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .toolbarTabBarHiddenCompat()
        .sheet(isPresented: $showDetail, onDismiss: {
            openPendingProfileConversationIfNeeded()
        }) {
            if conversation.kind == .group {
                GroupDetailView(
                    group: currentGroup,
                    onSearchHistory: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            showSearch = true
                        }
                    },
                    onPinnedMessages: {
                        showDetail = false
                        if conversation.kind == .group {
                            state.refreshPinnedMessages(for: conversationID, silent: false)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            showPinnedMessages = true
                        }
                    }
                )
                    .presentationDetentsCompat([.large])
            }
        }
        .onAppear {
            // Same-scope reappearance need not reset timeline position, but must
            // never inherit an unfinished gesture from the previous appearance.
            finishMessageTranscriptDrag()
            state.subscribeRealtimeConversation(conversationID)
            updateRealtimeAutoReadGate()
            applyInitialSearchJumpTargetIfNeeded()
            state.refreshBatchForwardContext(conversationID: conversationID)
        }
        .onReceive(state.conversationStore.$conversations) { _ in
            if isBatchForwardSelectionActive {
                state.refreshBatchForwardContext(conversationID: conversationID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            state.loadGroupDetailForConversation(conversationID, force: true, includeSecondaryData: false)
        }
        .onChangeCompat(of: isTranscriptDragRecognized) { _, isRecognized in
            // GestureState resets on cancellation too, unlike onEnded.
            if !isRecognized { finishMessageTranscriptDrag() }
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            readVisibilityEpoch &+= 1
            isClearingUnreadReminder = false
            lastVisibleReadAckToken = ""
            scrollMetricsMeasurements.layoutCallbacks.cancel()
            if phase != .active {
                state.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
                _ = nextAutomaticBottomScrollGeneration()
                finishMessageTranscriptDrag()
            }
        }
        .onDisappear {
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_DISAPPEAR - 修改开始：记录返回后 ChatView 是否真正退出
            chatBackDisappearedAttemptID = chatBackDismissAttemptID
            chatBackStuckDiagnostic(
                "chat_disappear",
                force: chatBackDismissAttemptID > 0,
                extra: "attempt=\(chatBackDismissAttemptID) elapsed_since_back_ms=\(Self.chatBackDiagnosticElapsedMS(since: chatBackDismissAttemptStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_DISAPPEAR - 修改结束：记录返回后 ChatView 是否真正退出
            readVisibilityEpoch &+= 1
            _ = nextAutomaticBottomScrollGeneration()
            scrollMetricsMeasurements.removeAll()
            finishMessageTranscriptDrag()
            searchTask?.cancel()
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_CANCEL_RENDER_REFRESH_TASK - 修改开始：离开聊天页取消延迟消息行刷新
            messageRenderCacheRefreshTask?.cancel()
            messageRenderCacheRefreshTask = nil
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_CANCEL_RENDER_REFRESH_TASK - 修改结束：离开聊天页取消延迟消息行刷新
            state.leaveBatchForwardSourceConversation(conversationID)
            state.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
            state.leaveRealtimeConversation(conversationID)
        }
        .sheet(isPresented: $showGroupAnnouncementDetail) {
            GroupAnnouncementSheet(
                group: currentGroup,
                announcementID: openedGroupAnnouncementID,
                onClose: {
                    if let announcementID = openedGroupAnnouncementID {
                        state.markGroupAnnouncementRead(groupID: currentGroup.id, announcementID: announcementID)
                    }
                }
            )
                .presentationDetentsCompat([.large])
        }
        .sheet(item: $reactionMessage) { message in
            ReactionPickerView(message: message, conversationID: conversationID)
                .presentationDetentsCompat([.height(360)])
                .presentationDragIndicatorCompat(.visible)
                .presentationCornerRadiusCompat(30)
        }
        .sheet(item: $receiptMessage) { message in
            ReadReceiptSheet(
                message: conversation.messages.first(where: { $0.id == message.id }) ?? message,
                conversation: conversation,
                readReceiptsEnabled: state.fileUploadConfig.readReceiptsEnabled
            )
                .presentationDetentsCompat([.medium, .large])
        }
        .fullScreenCover(item: $previewImageAttachment) { item in
            AttachmentImagePreviewSheet(message: currentMessageSnapshot(for: item.message), conversationID: conversationID, localURL: item.localURL)
        }
        .fullScreenCover(item: $previewVideoAttachment) { item in
            AttachmentVideoPreviewSheet(message: currentMessageSnapshot(for: item.message), localURL: item.localURL)
        }
        .sheet(item: $attachmentShareItem) { item in
            AttachmentActivityView(activityItems: [item.url]) { completed, error in
                if let error {
                    state.toast = "保存/分享失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试"))"
                } else if completed {
                    state.toast = "保存/分享已完成"
                }
            }
                .presentationDetentsCompat([.medium, .large])
        }
        .sheet(item: $attachmentPreviewDocument) { document in
            AttachmentQuickLookPreview(url: document.url)
                .ignoresSafeArea()
        }
        .sheet(item: $selectedAttachmentMessage) { message in
            AttachmentDetailSheet(
                message: conversation.messages.first(where: { $0.id == message.id }) ?? message,
                conversationID: conversationID,
                onForward: { message in
                    beginBatchForward(with: message)
                    selectedAttachmentMessage = nil
                }
            )
                .presentationDetentsCompat([.medium, .large])
        }
        .sheet(item: $selectedUserProfile, onDismiss: {
            openPendingProfileConversationIfNeeded()
        }) { user in
            UserProfileView(user: user, onOpenConversation: { conversationID in
                pendingProfileConversationID = conversationID
                selectedUserProfile = nil
            })
                .presentationDetentsCompat([.large])
        }
        .sheet(item: $editMessage) { message in
            MessageEditSheet(
                message: message,
                conversationID: conversationID,
                onAuthoritativeSuccess: { success in
                    guard editMessage?.id == success.messageID,
                          state.messageEditCurrentConversationID == conversationID,
                          let currentConversation = state.conversations.first(where: { $0.id == conversationID }),
                          let currentMessage = currentConversation.messages.first(where: { $0.id == success.messageID }),
                          messageEditAuthoritativeSuccessIsCurrent(
                            success,
                            currentScope: state.activeConversationHistoryScope,
                            currentConversationID: state.messageEditCurrentConversationID ?? "",
                            currentMessage: currentMessage
                          ) else { return false }
                    setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
                    return true
                }
            )
                .presentationDetentsCompat([.medium])
        }
        .sheet(item: $reportMessage) { message in
            MessageReportSheet(message: message, conversationID: conversationID)
                .presentationDetentsCompat([.large])
        }
        .sheet(isPresented: $showBatchForwardTargets) {
            ForwardMessageTargetSheet(
                sourceConversationID: conversationID
            )
                .presentationDetentsCompat([.large])
        }
        .sheet(isPresented: $showPinnedMessages, onDismiss: {
            performPendingPinnedJumpIfNeeded()
        }) {
            PinnedMessagesSheet(
                messages: pinnedMessages,
                onSelect: { message in
                    pendingPinnedJumpMessage = message
                    showPinnedMessages = false
                },
                onUnpin: { message in
                    state.toggleMessagePinned(messageID: message.id, in: conversationID)
                }
            )
            .presentationDetentsCompat([.medium])
        }
        .alert("对全员删除该消息？", isPresented: Binding(
            get: { adminDeleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    adminDeleteCandidate = nil
                }
            }
        )) {
            Button("取消", role: .cancel) {
                adminDeleteCandidate = nil
            }
            Button("删除", role: .destructive) {
                if let message = adminDeleteCandidate {
                    state.adminDeleteMessageForAll(messageID: message.id, in: conversationID)
                }
                adminDeleteCandidate = nil
            }
        } message: {
            Text("删除后群内所有成员不可见。")
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: actionMessage?.id)
        .onAppear {
            beginChatOpenPerfTrace(reason: "view_appear")
            beginNormalOpenScrollWindow(reason: "view_appear")
            state.prepareConversationTailWindowForEntry(conversationID)
            markSystemConversationReadOnOpenIfNeeded()
            captureInitialUnreadSnapshotIfNeeded()
            let hasCachedMessages = !conversation.messages.isEmpty
            let needsUnreadWindowRefresh = needsInitialUnreadWindowRefresh
            let needsLatestWindowRefresh = needsInitialLatestWindowRefresh && !canReuseConfirmedBottomForCurrentWindow
            let entrySyncPolicy = chatInitialEntrySyncPolicy(
                hasCachedMessages: hasCachedMessages,
                needsUnreadWindowRefresh: needsUnreadWindowRefresh,
                needsLatestWindowRefresh: needsLatestWindowRefresh,
                canReuseConfirmedBottom: canReuseConfirmedBottomForCurrentWindow
            )
            state.syncConversationMessagesIfNeeded(
                conversationID,
                force: entrySyncPolicy.forceRemoteHistory,
                silent: entrySyncPolicy.silent,
                showLoadingIndicator: entrySyncPolicy.showLoadingIndicator,
                trimToLatestWindow: true
            )
            if entrySyncPolicy.shouldWarmRefreshAfterInitialRender {
                state.scheduleWarmConversationRefreshAfterInitialRender(conversationID)
            }
            state.syncReadReceiptsIfNeeded(conversationID)
            if conversation.kind == .group {
                state.loadGroupDetailForConversation(conversationID, force: true, includeSecondaryData: false)
                state.refreshPinnedMessages(for: conversationID)
            }
        }
        .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
            // Retry a failed pre-persistence attempt even if the viewport stays
            // still. The same actual-visibility and foreground guards apply.
            markVisibleIncomingMessagesReadIfNeeded()
            state.syncReadReceiptsIfNeeded(conversationID)
            if state.shouldPollConversation(conversationID) {
                state.syncConversationMessagesIfNeeded(conversationID, force: true, silent: true, showLoadingIndicator: false)
            }
        }
        .onChangeCompat(of: currentGroupAnnouncement?.id) { _, _ in
            showGroupAnnouncement = true
            logChatSideDataReadyIfNeeded(reason: "announcement_changed")
        }
        .onChangeCompat(of: state.searchInvalidationRevision) { _, _ in
            applyLatestSearchInvalidationToConversationResults()
        }
        .onChangeCompat(of: isHistorySearchFocused) { _, isFocused in
            applySearchDismissalEffect(
                searchDismissalCoordinator.focusDidChange(isFocused: isFocused)
            )
        }
        .onChangeCompat(of: conversation.unread) { _, _ in
            markSystemConversationReadOnOpenIfNeeded()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        .onChangeCompat(of: conversation.messageCoveredThroughSeq) { _, _ in
            // Filling a sequence hole can make an already visible target safe
            // to acknowledge without changing the message or viewport token.
            markVisibleIncomingMessagesReadIfNeeded()
        }
        .navigationDestinationCompat(item: $linkedConversationRoute) { route in
            ChatView(conversationID: route.id)
        }
    }

    @ViewBuilder
    private func messageTimeline(
        reader: ScrollViewProxy,
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_PARAM - 修改开始：传入消息行缓存快照
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_PARAM - 修改结束
    ) -> some View {
        messageScrollView(
            reader: reader,
            renderMessages: renderMessages,
            renderMessageRows: renderMessageRows,
            // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_FORWARD - 修改开始：向消息滚动视图传递行缓存快照
            renderMessageRowsSnapshot: renderMessageRowsSnapshot
            // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_FORWARD - 修改结束
        )
            .contentShape(Rectangle())
            .simultaneousGesture(messageTranscriptTapGesture)
            .simultaneousGesture(messageTranscriptDragGesture)
            .onAppear {
                beginChatOpenPerfTrace(reason: "scroll_appear")
                previousMessageCount = conversation.messages.count
                refreshMessageRowCache(for: renderMessages)
                logChatFirstFrameIfNeeded(stage: "message_scroll")
                logChatHistoryReadyIfNeeded(reason: "scroll_appear")
                logChatSideDataReadyIfNeeded(reason: "scroll_appear")
                configureInitialPosition(reader)
                schedulePendingScrollTargetConsumption(reader)
            }
            .onChangeCompat(of: conversationID) { _, _ in
                beginChatOpenPerfTrace(reason: "conversation_change", force: true)
                beginNormalOpenScrollWindow(reason: "conversation_change")
                previousMessageCount = conversation.messages.count
                resetScrollPositionState(force: true)
                refreshMessageRowCache()
                configureInitialPosition(reader)
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_MESSAGE_CHANGE_COALESCE - 修改开始：避免监听整个 messages 数组导致历史多时比较卡顿
            .onReceive(state.conversationStore.$conversations) { updatedConversations in
                captureBottomBeforeMessageGrowth(updatedConversations)
                refreshHistoryAnchorBeforeMessageGrowth(updatedConversations)
                scheduleMessageRenderCacheRefreshAfterStoreChange(reader)
            }
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_MESSAGE_CHANGE_COALESCE - 修改结束：避免监听整个 messages 数组导致历史多时比较卡顿
            .onChangeCompat(of: conversation.messages.count) { _, newCount in
                let oldCount = previousMessageCount
                previousMessageCount = newCount
                logChatHistoryReadyIfNeeded(reason: "message_count_changed")
                if scrollToBottomAfterOwnSendIfNeeded(reader, oldCount: oldCount, newCount: newCount) {
                    return
                }
                let didScheduleInitialPosition = configureInitialPosition(reader)
                if !didScheduleInitialPosition {
                    let didPreserveHistoryAnchor = preserveHistoryAnchorAfterMessageChangeIfNeeded(reader, oldCount: oldCount, newCount: newCount)
                    if !didPreserveHistoryAnchor {
                        followBottomAfterMessageChangeIfNeeded(reader, oldCount: oldCount, newCount: newCount)
                    }
                    autofillOlderHistoryIfUnderfilled()
                }
            }
            .onChangeCompat(of: latestLoadedMessageSeq) { _, _ in
                handleLatestWindowProgress(reader, reason: "latest_seq_changed")
            }
            .onChangeCompat(of: conversation.lastMsgSeq) { _, _ in
                handleLatestWindowProgress(reader, reason: "last_msg_seq_changed")
            }
            .onChangeCompat(of: isLoadingConversationHistory) { _, isLoading in
                guard !isLoading else { return }
                if !configureInitialPosition(reader) {
                    if didInitialScroll,
                       isAtBottom,
                       !isUserBrowsingHistory,
                       pendingUnreadCount == 0,
                       !conversation.messages.isEmpty {
                        scheduleLatestBottomConfirmation(reader, reason: "history_loading_finished_realign")
                    }
                    handleLatestWindowProgress(reader, reason: "history_loading_finished")
                    autofillOlderHistoryIfUnderfilled()
                }
            }
            .onChangeCompat(of: latestReadableIncomingMessageReadToken) { _, _ in
                markVisibleIncomingMessagesReadIfNeeded()
            }
            .onChangeCompat(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                schedulePendingScrollTargetConsumption(reader, expectedTargetID: targetID)
            }
            .onChangeCompat(of: conversation.participants) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "participants_changed")
            }
            .onChangeCompat(of: state.contacts) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: state.contactRemarks) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: state.currentUser) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: currentGroup.members) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "group_members_changed")
            }
            .onChangeCompat(of: currentGroup.admins) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "group_admins_changed")
            }
            .onChangeCompat(of: state.myGroupMemberProjection(groupID: currentGroup.id)) { _, _ in
                guard conversation.kind == .group else { return }
                refreshMessageRowCache(allowsPrependReuse: false)
            }
    }

    private func messageScrollView(
        reader: ScrollViewProxy,
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_SCROLL_SIGNATURE_PARAM - 修改开始：消息滚动视图接收行缓存快照
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_SCROLL_SIGNATURE_PARAM - 修改结束
    ) -> some View {
        // Bind the observation to the rows participating in this layout, not a
        // newer conversation snapshot arriving before SwiftUI displays it.
        let incoming = renderMessageRows.last { row in
            row.message.kind != .system && row.message.status != .recalled
                && !row.message.isDeletedLocally && !isMessageAuthoredByCurrentUser(row.message)
                && row.message.channelSeq > 0
        }?.message
        let renderedReadSeq = incoming?.channelSeq ?? 0
        let renderedReadToken = incoming.map { "\(conversationID):\($0.channelSeq)" } ?? ""
        return GeometryReader { viewportProxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    messageListContent(
                        renderMessages: renderMessages,
                        renderMessageRows: renderMessageRows,
                        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PASS - 修改开始：列表内容使用行缓存快照生成稳定 item
                        renderMessageRowsSnapshot: renderMessageRowsSnapshot,
                        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PASS - 修改结束
                        latestIncomingID: incoming?.id
                    )
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .background(
                    GeometryReader { contentProxy in
                        let frame = contentProxy.frame(in: .named(chatScrollCoordinateSpaceName))
                        Color.clear.preference(
                            key: ChatScrollMetricsPreferenceKey.self,
                            value: ChatScrollMetricsSnapshot(
                                viewportHeight: viewportProxy.size.height,
                                contentMinY: frame.minY,
                                contentMaxY: frame.maxY,
                                renderedReadToken: renderedReadToken,
                                renderedReadSeq: renderedReadSeq,
                                readVisibilityEpoch: readVisibilityEpoch
                            )
                        )
                    }
                )
            }
            .environment(\.stickerGIFPlaybackViewport, previewImageAttachment == nil ? viewportProxy.frame(in: .global) : .zero)
            .chatScrollDismissesKeyboardInteractively()
            .coordinateSpace(name: chatScrollCoordinateSpaceName)
            .overlay(alignment: .top) {
                messageHistoryStatusOverlay
                    .padding(.top, 10)
            }
        }
        .onPreferenceChange(ChatScrollMetricsPreferenceKey.self) { metrics in
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_METRICS_CALLBACK - 修改开始：滚动指标未变时不触发聊天页布局处理
            if scrollMetricsMeasurements.replace(with: metrics) {
                scheduleTranscriptLayoutUpdate(reader)
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_METRICS_CALLBACK - 修改结束
        }
        .onPreferenceChange(ChatIncomingRowPreferenceKey.self) { row in
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_INCOMING_ROW_CALLBACK - 修改开始：最新入站消息几何无变化时跳过处理
            if !chatIncomingRowGeometryApproximatelyEqual(scrollMetricsMeasurements.incomingRow, row) {
                scrollMetricsMeasurements.incomingRow = row
                scheduleTranscriptLayoutUpdate(reader)
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_INCOMING_ROW_CALLBACK - 修改结束
        }
        .onPreferenceChange(ChatMessageTopPreferenceKey.self) { values in
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_TOP_ANCHOR_CALLBACK - 修改开始：历史锚点测量无变化时不触发滚动处理
            if messageTopMeasurements.replace(
                with: values,
                isEnabled: shouldMeasureMessageTopAnchors
            ) {
                // Never load history or publish view state from a layout callback.
                scheduleTranscriptLayoutUpdate(reader)
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_TOP_ANCHOR_CALLBACK - 修改结束
        }
    }

    @ViewBuilder
    private var messageHistoryStatusOverlay: some View {
        if shouldShowConversationHistoryLoadingPill {
            ChatHistoryStatusPill(text: "正在同步聊天记录", isLoading: true)
                .allowsHitTesting(false)
        } else if let conversationHistoryMessage {
            ChatHistoryStatusPill(text: conversationHistoryMessage, isLoading: false)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func messageListContent(
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PARAM - 修改开始：传入消息行缓存快照生成时间线 item
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot,
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PARAM - 修改结束
        latestIncomingID: String?
    ) -> some View {
        if shouldShowDirectEmptyHistoryState {
            DirectChatEmptyHistoryView(
                title: directEmptyHistoryTitle,
                subtitle: directEmptyHistorySubtitle,
                retryTitle: canRetryDirectHistorySync ? "重新同步" : nil,
                retry: {
                    state.syncConversationMessagesIfNeeded(
                        conversationID,
                        force: true,
                        silent: false,
                        showLoadingIndicator: true,
                        trimToLatestWindow: true
                    )
                }
            )
            .padding(.top, 28)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_USE - 修改开始：输入/键盘重绘时复用已生成时间线 item
        ForEach(messageTimelineItems(renderMessageRows, snapshot: renderMessageRowsSnapshot)) { item in
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_USE - 修改结束
            // Each item has one directly addressable list leaf. Building the
            // expensive bubble stays inside the lazy leaf's body, not ID discovery.
            ChatMessageLazyLeaf {
                messageTimelineItemView(item, messageCount: renderMessages.count, latestIncomingID: latestIncomingID)
            }
            .frame(height: item.isSpacing ? 8 : nil)
            .id(item.id)
        }
        messageListBottomAnchor
    }

    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_ENTRY - 修改开始：缓存消息 time/anchor/spacing item，降低输入与键盘重绘成本
    private func messageTimelineItems(
        _ rows: [ChatMessageRenderRow],
        snapshot: ChatMessageRenderRowsSnapshot
    ) -> [ChatMessageTimelineItem] {
        let unreadID = unreadDividerVisible ? firstUnreadMessageID : nil
        let unreadCount = unreadDividerVisible ? firstUnreadAnchorCount : 0
        return messageTimelineItemCache.items(
            conversationID: conversationID,
            snapshot: snapshot,
            unreadID: unreadID,
            unreadCount: unreadCount
        ) {
            buildMessageTimelineItems(rows, unreadID: unreadID, unreadCount: unreadCount)
        }
    }

    private func buildMessageTimelineItems(_ rows: [ChatMessageRenderRow], unreadID: String?, unreadCount: Int) -> [ChatMessageTimelineItem] {
        var items: [ChatMessageTimelineItem] = []
        items.reserveCapacity(rows.count * 3 + 4)
        for row in rows {
            if let text = row.timeSeparatorText {
                items.append(.init(id: "time-separator-\(row.id)", row: row, kind: .timeSeparator(text)))
                items.append(.init(id: "time-spacing-\(row.id)", row: row, kind: .spacing))
            }
            if row.id == unreadID {
                items.append(.init(id: firstUnreadMarkerID, row: row, kind: .unreadDivider(unreadCount)))
                items.append(.init(id: "unread-spacing-\(row.id)", row: row, kind: .spacing))
            }
            items.append(.init(id: historyAnchorID(for: row.id), row: row, kind: .historyAnchor))
            items.append(.init(id: row.id, row: row, kind: .message))
            items.append(.init(id: "message-spacing-\(row.id)", row: row, kind: .spacing))
        }
        return items
    }
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_ENTRY - 修改结束

    @ViewBuilder
    private func messageTimelineItemView(_ item: ChatMessageTimelineItem, messageCount: Int, latestIncomingID: String?) -> some View {
        switch item.kind {
        case .timeSeparator(let text):
            MessageTimeSeparator(text: text)
        case .unreadDivider(let count):
            NewMessagesDivider(count: count)
        case .historyAnchor:
            messageHistoryAnchor(item.row)
        case .message:
            messageRowView(item.row, messageCount: messageCount, latestIncomingID: latestIncomingID)
        case .spacing:
            Color.clear.frame(height: 8)
        }
    }

    private func messageHistoryAnchor(_ row: ChatMessageRenderRow) -> some View {
        // Give the scroll target real extent using the existing 8pt gap before
        // the bubble. A zero-height lazy target has no reliable scroll rectangle.
        Color.clear
            .frame(height: 8)
            .background {
                // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_ROW_ANCHOR_GEOMETRY - 修改开始：关闭普通滚动中的逐行 GeometryReader
                if shouldMeasureMessageTopAnchor(for: row) {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(chatScrollCoordinateSpaceName))
                        Color.clear.preference(
                            key: ChatMessageTopPreferenceKey.self,
                            value: [row.message.id: frame.minY]
                        )
                    }
                }
                // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_ROW_ANCHOR_GEOMETRY - 修改结束：关闭普通滚动中的逐行 GeometryReader
            }
    }

    @ViewBuilder
    private func messageRowView(_ row: ChatMessageRenderRow, messageCount: Int, latestIncomingID: String?) -> some View {
        let batchDisabledReason = isBatchForwardSelectionActive
            ? batchForwardDisabledReason(for: row.message)
            : nil
        let batchSelected = isBatchForwardSelectionActive && state.batchForwardState?
            .selectedSourceIDSet
            .contains(row.message.id) == true

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if isBatchForwardSelectionActive {
                    Button {
                        state.toggleBatchForwardSource(
                            messageID: row.message.id,
                            conversationID: conversationID
                        )
                    } label: {
                        Image(
                            systemName: batchSelected
                                ? "checkmark.circle.fill"
                                : (batchDisabledReason == nil ? "circle" : "nosign")
                        )
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(
                                batchSelected
                                    ? IMColor.brand
                                    : (batchDisabledReason == nil ? IMColor.muted : IMColor.danger)
                            )
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(batchDisabledReason != nil)
                    .accessibilityLabel(
                        batchDisabledReason
                            ?? (batchSelected ? "取消选择消息" : "选择消息")
                    )
                    .accessibilityValue(batchSelected ? "已选择" : "未选择")
                }
                MessageBubble(
                    message: row.message,
                    conversationID: conversationID,
                    showsSenderHeader: row.showsSenderHeader,
                    resolvedSenderUser: row.senderUser,
                    displaySenderNameOverride: row.displaySenderName,
                    isGroupConversation: conversation.kind == .group,
                    isBatchSelected: batchSelected,
                    onSelectionTap: isBatchForwardSelectionActive ? {
                        state.toggleBatchForwardSource(
                            messageID: row.message.id,
                            conversationID: conversationID
                        )
                    } : nil
                ) {
                    dismissChatKeyboardFromTranscript(trigger: .longPress)
                    guard !isReadOnlySystemConversation else { return }
                    if isBatchForwardSelectionActive {
                        state.toggleBatchForwardSource(
                            messageID: row.message.id,
                            conversationID: conversationID
                        )
                        return
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        actionMessage = row.message
                    }
                } onReadTap: {
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    guard isMessageAuthoredByCurrentUser(row.message) else {
                        state.toast = "只能查看自己发送消息的已读状态"
                        return
                    }
                    if state.fileUploadConfig.readReceiptsEnabled {
                        state.loadReadReceipts(messageID: row.message.id, in: conversationID)
                    }
                    receiptMessage = row.message
                } onSenderTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        selectedSenderActionUser = user
                    }
                } onContactCardTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedUserProfile = user
                } onMentionTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedUserProfile = user
                } onAttachmentTap: { message in
                    if isBatchForwardSelectionActive {
                        state.toggleBatchForwardSource(
                            messageID: message.id,
                            conversationID: conversationID
                        )
                        return
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    handleAttachmentTap(message)
                }
            }
            if isBatchForwardSelectionActive, let batchDisabledReason {
                Text(batchDisabledReason)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.leading, 40)
                    .accessibilityLabel(batchDisabledReason)
            }
        }
        .background {
            // Measure only the latest incoming bubble. The content rectangle of
            // a lazy stack alone can include estimated, unmounted message rows.
            if row.message.id == latestIncomingID, row.message.channelSeq > 0 {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatIncomingRowPreferenceKey.self,
                        value: ChatIncomingRowGeometry(
                            token: "\(conversationID):\(row.message.channelSeq)",
                            frame: proxy.frame(in: .named(chatScrollCoordinateSpaceName)),
                            epoch: readVisibilityEpoch
                        )
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    focusedTimelineMessageID == row.message.id
                        ? IMColor.brand.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    focusedTimelineMessageID == row.message.id
                        ? IMColor.brand.opacity(0.55)
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
        .animation(.easeInOut(duration: 0.18), value: focusedTimelineMessageID)
    }

    private var messageListBottomAnchor: some View {
        // Lazy mounting includes offscreen prefetch. Only measured geometry may
        // change bottom/history state; onAppear would fight a user's history drag.
        Color.clear
            .frame(height: messageListBottomAnchorHeight)
            .id(bottomAnchorID)
    }

    private var messageTranscriptTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                dismissChatKeyboardFromTranscript(trigger: .tap)
                dismissExpressionPanelFromTranscriptTap()
            }
    }

    private var messageTranscriptDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isTranscriptDragRecognized) { _, isRecognized, _ in
                // Only the boundary changes this value; do not publish each frame.
                if !isRecognized { isRecognized = true }
            }
            .onChanged { value in
                // Same-direction frames update only non-publishing bookkeeping.
                guard let transition = transcriptScrollControl.updateDrag(
                    translation: value.translation,
                    now: Date(),
                    suppressionInterval: automaticBottomScrollSuppressionInterval
                ) else { return }
                if transition.isStart {
                    oldestHistoryLoadAnchorID = nil
                    oldestHistoryLoadAnchorMinY = nil
                    didUserInteractWithMessageScroll = true
                    if #unavailable(iOS 16.0) {
                        dismissChatKeyboardFromTranscript(trigger: .verticalScroll)
                    }
                    _ = evaluateScrollRequest(source: .userGesture, targetID: nil, anchor: nil, userInitiated: true)
                }
                didTriggerOlderHistoryLoadForScrollIntent = false
                newestHistoryLoadAnchorSeq = 0
                switch transition.direction {
                case .history:
                    isUserBrowsingHistory = true
                    isAtBottom = false
                    logInitialAnchorDecision("suppress_auto_bottom_user_history_drag", targetID: bottomAnchorID, unreadCount: rawInitialUnreadCount())
                case .latest:
                    isUserBrowsingHistory = false
                    if didInitialScroll {
                        didScrollTowardUnreadMessages = true
                    }
                }
                updateRealtimeAutoReadGate()
                markUnreadReminderReadIfUserScrolledTowardUnread()
            }
            .onEnded { _ in
                // Finish even if the last sample becomes horizontal, and use
                // actual final direction rather than translation from origin.
                finishMessageTranscriptDrag()
            }
    }

    private func finishMessageTranscriptDrag() {
        if transcriptScrollControl.finishDrag(
            now: Date(),
            suppressionInterval: automaticBottomScrollSuppressionInterval
        ) == .latest {
            didTriggerOlderHistoryLoadForScrollIntent = false
        }
    }

    private func openConversationFromProfile(_ conversationID: String) {
        guard conversationID != self.conversationID else {
            state.toast = "已在当前会话"
            return
        }
        linkedConversationRoute = ChatLinkedConversationRoute(id: conversationID)
    }

    private func openPendingProfileConversationIfNeeded() {
        guard let conversationID = pendingProfileConversationID else { return }
        pendingProfileConversationID = nil
        DispatchQueue.main.async {
            openConversationFromProfile(conversationID)
        }
    }

    private func markSystemConversationReadOnOpenIfNeeded() {
        guard conversation.kind == .system, conversation.unread > 0 else { return }
        state.markConversationRead(conversationID, showToast: false)
    }

    private func maybeLoadOlderMessagesIfNeeded(index: Int, message: ChatMessage, messageCount: Int) {
        guard index <= 2, didInitialScroll, !isApplyingInitialScroll, messageCount > 0 else { return }
        guard didUserInteractWithMessageScroll, isUserBrowsingHistory else { return }
        guard !isLoadingConversationHistory else { return }
        guard !didTriggerOlderHistoryLoadForScrollIntent else { return }
        let anchorID = currentViewportHistoryAnchorID() ?? message.id
        guard oldestHistoryLoadAnchorID != anchorID else { return }
        guard let anchorY = measuredHistoryAnchorY(anchorID) else { return }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_APPEAR - 修改开始：顶部行出现时节流旧消息加载尝试
        guard consumeOlderHistoryLoadAttemptIfNeeded() else { return }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_APPEAR - 修改结束：顶部行出现时节流旧消息加载尝试
        // 只有真正发起了加载才关闭重试门,否则节流/引擎拒绝会把重试永久堵死。
        guard state.loadOlderMessagesIfAvailable(conversationID) else { return }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        didTriggerOlderHistoryLoadForScrollIntent = true
        isUserBrowsingHistory = true
    }

    private func maybeLoadOlderMessagesFromScrollMetrics(visibility: ChatScrollVisibility) {
        guard didInitialScroll, !isApplyingInitialScroll, !timelineMessages.isEmpty else { return }
        guard chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isUserBrowsingHistory: isUserBrowsingHistory,
            visibility: visibility
        ) else {
            return
        }
        guard !isLoadingConversationHistory else { return }
        guard let anchorID = currentViewportHistoryAnchorID() ?? timelineMessages.first?.id,
              oldestHistoryLoadAnchorID != anchorID else {
            return
        }
        guard let anchorY = measuredHistoryAnchorY(anchorID) else { return }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_METRICS - 修改开始：滚动边界几何回调节流旧消息加载尝试
        guard consumeOlderHistoryLoadAttemptIfNeeded() else { return }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_METRICS - 修改结束：滚动边界几何回调节流旧消息加载尝试
        // 只有真正发起了加载才关闭锚点门并进入历史浏览态,
        // 否则节流/引擎拒绝会让相同锚点永远不再触发加载。
        guard state.loadOlderMessagesIfAvailable(conversationID) else { return }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        didTriggerOlderHistoryLoadForScrollIntent = true
        isUserBrowsingHistory = true
    }

    /// 内容不满一屏时不会产生滚动事件,滚动几何驱动的旧消息加载永远不会触发。
    /// 该方法在初始定位完成、消息窗口变化、历史加载结束后主动补拉,直到内容
    /// 填满视口、连续补拉达到上限或确认没有更早历史为止。
    private func autofillOlderHistoryIfUnderfilled() {
        guard didInitialScroll, !isApplyingInitialScroll else { return }
        guard lastScrollVisibility.isContentUnderfilled else {
            underfilledOlderAutofillAttempts = 0
            return
        }
        guard underfilledOlderAutofillAttempts < maxUnderfilledOlderAutofillAttempts else { return }
        guard !isLoadingConversationHistory else { return }
        // 这里不加 hasOlderMessagesAvailable 前置门:窗口不可用(oldestSeq 缺失)时
        // 也要进 loadOlderMessagesIfAvailable,由 AppState 触发最新窗口恢复同步。
        let anchorID = currentViewportHistoryAnchorID() ?? timelineMessages.first?.id
        let anchorY = anchorID.flatMap(measuredHistoryAnchorY)
        guard timelineMessages.isEmpty || anchorY != nil else { return }
        guard state.loadOlderMessagesIfAvailable(conversationID) else { return }
        if let anchorID, let anchorY {
            rememberHistoryLoadAnchor(anchorID, minY: anchorY)
        }
        underfilledOlderAutofillAttempts += 1
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_LOAD_ATTEMPT_THROTTLE_HELPER - 修改开始：减少顶部边界反复扫描历史可用性
    private func consumeOlderHistoryLoadAttemptIfNeeded(
        now: Date = Date(),
        minimumInterval: TimeInterval = 0.28
    ) -> Bool {
        guard now.timeIntervalSince(lastOlderHistoryLoadAttemptAt) >= minimumInterval else {
            return false
        }
        lastOlderHistoryLoadAttemptAt = now
        return true
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_LOAD_ATTEMPT_THROTTLE_HELPER - 修改结束：减少顶部边界反复扫描历史可用性

    private func currentViewportHistoryAnchorID() -> String? {
        let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        // Prefer a marker actually in the viewport. For a tall partial row with
        // no visible marker, retain its nearest preceding marker's negative Y.
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：滚动中单次遍历锚点测量值，避免 filter/min/max 临时集合
        var nearestVisibleID: String?
        var nearestVisibleY = CGFloat.greatestFiniteMagnitude
        var nearestPrecedingID: String?
        var nearestPrecedingY = -CGFloat.greatestFiniteMagnitude
        for (id, y) in messageTopMeasurements.values where y.isFinite && y < viewportHeight {
            if y >= 0 {
                if y < nearestVisibleY {
                    nearestVisibleY = y
                    nearestVisibleID = id
                }
            } else if y > nearestPrecedingY {
                nearestPrecedingY = y
                nearestPrecedingID = id
            }
        }
        return nearestVisibleID ?? nearestPrecedingID
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func measuredHistoryAnchorY(_ anchorID: String) -> CGFloat? {
        let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
        guard viewportHeight.isFinite, viewportHeight > 0,
              let value = messageTopMeasurements[anchorID], value.isFinite else { return nil }
        return value
    }

    private func rememberHistoryLoadAnchor(_ anchorID: String, minY: CGFloat? = nil) {
        guard let value = minY ?? measuredHistoryAnchorY(anchorID), value.isFinite else { return }
        oldestHistoryLoadAnchorID = anchorID
        oldestHistoryLoadAnchorMinY = value
    }

    private func captureBottomBeforeMessageGrowth(_ updatedConversations: [Conversation]) {
        guard let updated = updatedConversations.first(where: { $0.id == conversationID }) else { return }
        let oldMessages = conversation.messages
        guard updated.messages.count > oldMessages.count else { return }
        guard didInitialScroll, !isApplyingInitialScroll, !isLoadingConversationHistory else {
            scrollMetricsMeasurements.incomingBottomFollow.reset()
            return
        }
        // A history prepend is not a newly appended message. Keep its existing
        // anchor/restoration path, even when several rows arrive in one update.
        guard let oldTail = oldMessages.last,
              updated.messages[oldMessages.count - 1].id == oldTail.id else {
            scrollMetricsMeasurements.incomingBottomFollow.reset()
            return
        }
        scrollMetricsMeasurements.incomingBottomFollow.recordAppend(
            metrics: scrollMetricsMeasurements.metrics,
            generation: automaticBottomScrollGeneration,
            eligible: pendingUnreadCount == 0 && transcriptScrollControl.direction == nil
                && !isUserBrowsingHistory && !isAutomaticBottomScrollSuppressed
        )
    }

    private var incomingBottomFollowDecision: Bool? {
        scrollMetricsMeasurements.incomingBottomFollow.decision(generation: automaticBottomScrollGeneration)
    }

    private func scheduleIncomingBottomFollow(_ reader: ScrollViewProxy) {
        guard incomingBottomFollowDecision == true else { return }
        let generation = automaticBottomScrollGeneration
        let scope = conversationID
        DispatchQueue.main.async {
            guard scope == conversationID, generation == automaticBottomScrollGeneration,
                  incomingBottomFollowDecision == true,
                  didInitialScroll, !isApplyingInitialScroll,
                  transcriptScrollControl.direction == nil,
                  !isUserBrowsingHistory, !isAutomaticBottomScrollSuppressed,
                  !conversation.messages.isEmpty else { return }
            // This source is permitted after a manual return to the bottom.
            // Its pre-append decision and generation are mandatory; ordinary
            // follow/initial/search requests still use their existing arbiter.
            _ = scrollToTargetWithoutAnimation(reader, targetID: bottomAnchorID,
                                               anchor: .bottom, source: .incomingFollowBottom)
            // Actual geometry confirms visibility/read progress, not this request.
        }
    }

    private func refreshHistoryAnchorBeforeMessageGrowth(_ updatedConversations: [Conversation]) {
        guard !isAtBottom,
              oldestHistoryLoadAnchorID != nil || isLoadingConversationHistory,
              let updated = updatedConversations.first(where: { $0.id == conversationID }),
              updated.messages.count > conversation.messages.count else { return }
        // @Published delivers the incoming array before the Store replaces it.
        // Sample the latest pre-update viewport, including continued dragging or
        // deceleration while the request waited. Do not publish geometry per frame.
        guard let anchorID = currentViewportHistoryAnchorID(),
              let anchorY = measuredHistoryAnchorY(anchorID) else {
            oldestHistoryLoadAnchorID = nil
            oldestHistoryLoadAnchorMinY = nil
            return
        }
        rememberHistoryLoadAnchor(anchorID, minY: anchorY)
    }

    private func maybeLoadNewerMessagesFromScrollMetrics() {
        guard didInitialScroll, !isApplyingInitialScroll, !timelineMessages.isEmpty else { return }
        guard didUserInteractWithMessageScroll, !isUserBrowsingHistory, isAtBottom else { return }
        guard !isLoadingConversationHistory, !isLatestMessageWindowLoaded else { return }
        guard state.hasNewerMessagesAvailable(conversationID) else { return }
        let anchorSeq = latestLoadedMessageSeq
        guard anchorSeq > 0, newestHistoryLoadAnchorSeq != anchorSeq else { return }
        newestHistoryLoadAnchorSeq = anchorSeq
        state.loadNewerMessagesIfAvailable(conversationID)
    }

    private func scheduleTranscriptLayoutUpdate(_ reader: ScrollViewProxy) {
        guard let generation = scrollMetricsMeasurements.layoutCallbacks.schedule() else { return }
        let scope = state.activeConversationHistoryScope
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        DispatchQueue.main.async {
            guard scrollMetricsMeasurements.layoutCallbacks.consume(generation),
                  scope == state.activeConversationHistoryScope,
                  targetConversationID == conversationID,
                  epoch == readVisibilityEpoch, scenePhase == .active else { return }
            handleScrollMetrics(scrollMetricsMeasurements.metrics, reader: reader)
            // A history drag may precede this layout's row anchors. Resume the
            // same guarded load only after the geometry transaction has ended.
            maybeLoadOlderMessagesFromScrollMetrics(visibility: lastScrollVisibility)
            autofillOlderHistoryIfUnderfilled()
        }
    }

    private func handleScrollMetrics(_ metrics: ChatScrollMetricsSnapshot, reader: ScrollViewProxy) {
        guard metrics.isValid else { return }
        let previousMetrics = scrollMetricsMeasurements.lastHandledMetrics
        scrollMetricsMeasurements.lastHandledMetrics = metrics
        let visibility = chatScrollVisibility(metrics: metrics)
        if canRealignBottomAfterViewportExpansion,
           chatNeedsBottomRealignmentAfterViewportExpansion(from: previousMetrics, to: metrics) {
            // Expansion can leave a large gap while semantic bottom visibility
            // stays true, so this must run before visibility deduplication.
            lastScrollVisibility = visibility
            scheduleBottomRealignmentAfterViewportExpansion(reader, previousMetrics: previousMetrics)
            return
        }
        if scrollMetricsMeasurements.incomingBottomFollow.needsLayoutCorrection(
            from: previousMetrics, to: metrics, generation: automaticBottomScrollGeneration
        ) {
            // Media growth and viewport-only shrink both need correction, even
            // when semantic visibility is unchanged across successive layouts.
            lastScrollVisibility = visibility
            isAtBottom = false
            updateRealtimeAutoReadGate()
            scheduleIncomingBottomFollow(reader)
            return
        }
        let canRepeatHistoryBoundaryCheck = chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isUserBrowsingHistory: isUserBrowsingHistory,
            visibility: visibility
        )
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_HANDLE_THROTTLE - 修改开始：减少滚动过程中重复状态处理
        let visibilityDidChange = visibility != lastScrollVisibility
        let shouldProcessRepeatedBoundaryCheck = !visibilityDidChange
            && canRepeatHistoryBoundaryCheck
            && scrollMetricsMeasurements.consumeRepeatedBoundaryCheckIfNeeded()
        // New rendered messages can leave the bottom boolean unchanged. Their
        // layout-bound read observation still needs to advance independently.
        markVisibleIncomingMessagesReadIfNeeded()
        guard visibilityDidChange || shouldProcessRepeatedBoundaryCheck else { return }
        if visibilityDidChange {
            lastScrollVisibility = visibility
            scrollMetricsMeasurements.resetRepeatedBoundaryCheckThrottle()
        }
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_HANDLE_THROTTLE - 修改结束：减少滚动过程中重复状态处理

        guard didInitialScroll, !isApplyingInitialScroll else { return }
        if visibility.isAtBottom {
            isAtBottom = true
            isUserBrowsingHistory = false
            didTriggerOlderHistoryLoadForScrollIntent = false
            transcriptScrollControl.clearSuppression()
            updateRealtimeAutoReadGate()
            rememberLatestBottomVisible()
            if hasUnreadReminder {
                if canClearUnreadReminderFromVisibleProgress {
                    clearUnreadReminderAndAckIfNeeded(reason: "bottom_visible_geometry")
                }
            } else {
                markVisibleIncomingMessagesReadIfNeeded()
            }
            maybeLoadNewerMessagesFromScrollMetrics()
        } else if isAtBottom {
            if incomingBottomFollowDecision == nil,
               canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll, !conversation.messages.isEmpty {
                scrollToLatestBottomWithoutAnimation(reader)
                rememberLatestBottomVisible()
                updateRealtimeAutoReadGate()
                return
            }
            isAtBottom = false
            updateRealtimeAutoReadGate()
        }

        if visibility.isNearHistoryBoundary {
            maybeLoadOlderMessagesFromScrollMetrics(visibility: visibility)
            autofillOlderHistoryIfUnderfilled()
        }
    }

    private var canRealignBottomAfterViewportExpansion: Bool {
        didInitialScroll && !isApplyingInitialScroll && !isLoadingConversationHistory
            && isAtBottom && !isUserBrowsingHistory && pendingUnreadCount == 0
            && transcriptScrollControl.direction == nil && !isAutomaticBottomScrollSuppressed
            && incomingBottomFollowDecision != false && !conversation.messages.isEmpty
    }

    private func scheduleBottomRealignmentAfterViewportExpansion(
        _ reader: ScrollViewProxy,
        previousMetrics: ChatScrollMetricsSnapshot
    ) {
        let scope = conversationID
        let generation = automaticBottomScrollGeneration
        DispatchQueue.main.async {
            guard scope == conversationID,
                  generation == automaticBottomScrollGeneration,
                  canRealignBottomAfterViewportExpansion,
                  chatNeedsBottomRealignmentAfterViewportExpansion(
                    from: previousMetrics, to: scrollMetricsMeasurements.metrics
                  ) else { return }
            // A manual return to bottom keeps the arbiter in jump mode. Only
            // this guarded viewport correction may bypass its followBottom veto.
            // The request never confirms delivery, visibility, or read progress.
            _ = scrollToTargetWithoutAnimation(reader, targetID: bottomAnchorID, anchor: .bottom, source: .viewportBottomRealignment)
        }
    }

    private func shouldShowSenderHeader(for message: ChatMessage, at index: Int, in messages: [ChatMessage]) -> Bool {
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

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_MESSAGE_ROW_RESOLVER - 修改开始：复用消息行解析器，支持旧消息增量构建
    private func messageSenderResolver() -> MessageSenderResolver {
        MessageSenderResolver(
            currentUser: state.currentUser,
            enterpriseName: state.currentEnterprise.name,
            conversation: conversation,
            contacts: state.contacts,
            group: conversation.kind == .group ? currentGroup : nil,
            exactGroupSelf: conversation.kind == .group
                ? state.myGroupMemberProjection(groupID: currentGroup.id)
                : nil,
            contactRemarks: state.contactRemarks
        )
    }

    private func messageRow(
        for messages: [ChatMessage],
        at index: Int,
        resolver: MessageSenderResolver
    ) -> ChatMessageRenderRow {
        let message = messages[index]
        let previousMessage = index > 0 ? messages[index - 1] : nil
        let senderUser = resolver.senderUser(for: message)
        return ChatMessageRenderRow(
            index: index,
            message: message,
            showsSenderHeader: shouldShowSenderHeader(for: message, at: index, in: messages),
            senderUser: senderUser,
            displaySenderName: resolver.displaySenderName(for: message, resolvedUser: senderUser),
            timeSeparatorText: timeSeparatorText(before: message, previous: previousMessage)
        )
    }

    private func messageRows(for messages: [ChatMessage]) -> [ChatMessageRenderRow] {
        let resolver = messageSenderResolver()
        return messages.indices.map { index in
            messageRow(for: messages, at: index, resolver: resolver)
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_MESSAGE_ROW_RESOLVER - 修改结束：复用消息行解析器，支持旧消息增量构建

    private func timeSeparatorText(before message: ChatMessage, previous: ChatMessage?) -> String? {
        guard let createdAt = message.createdAt else { return nil }
        guard let previousCreatedAt = previous?.createdAt else {
            return chatTimeSeparatorText(for: createdAt)
        }
        guard createdAt.timeIntervalSince(previousCreatedAt) > Self.messageTimeSeparatorThreshold else {
            return nil
        }
        return chatTimeSeparatorText(for: createdAt)
    }

    private func chatTimeSeparatorText(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return Self.formatMessageTime(date, format: "HH:mm")
        }
        if calendar.isDateInYesterday(date) {
            return Self.formatMessageTime(date, format: "'昨天' HH:mm")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear),
           calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return Self.formatMessageTime(date, format: "E HH:mm")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return Self.formatMessageTime(date, format: "M月d日 HH:mm")
        }
        return Self.formatMessageTime(date, format: "yyyy年M月d日 HH:mm")
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_DEFERRED_ROW_CACHE_REFRESH - 修改开始：会话消息发布后延后一拍合并刷新行缓存
    private func scheduleMessageRenderCacheRefreshAfterStoreChange(_ reader: ScrollViewProxy) {
        // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_RENDER_TASK_COALESCE - 修改开始：会话发布高频到达时复用已排队刷新，避免主线程反复取消/建 Task
        guard messageRenderCacheRefreshTask == nil else { return }
        // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_RENDER_TASK_COALESCE - 修改结束
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_RENDER_CACHE_SCHEDULE - 修改开始：定位消息发布后行缓存刷新排队
        messageRenderCacheRefreshDiagnosticID &+= 1
        let diagnosticID = messageRenderCacheRefreshDiagnosticID
        let diagnosticScheduledAt = CFAbsoluteTimeGetCurrent()
        let scheduledMessageCount = conversation.messages.count
        chatBackStuckDiagnostic(
            "render_cache_schedule",
            extra: "seq=\(diagnosticID) scheduled_messages=\(scheduledMessageCount)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_RENDER_CACHE_SCHEDULE - 修改结束：定位消息发布后行缓存刷新排队
        messageRenderCacheRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else {
                if messageRenderCacheRefreshDiagnosticID == diagnosticID {
                    messageRenderCacheRefreshTask = nil
                }
                return
            }
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_RENDER_TASK_CLEAR - 修改开始：刷新完成后释放排队标记
            defer {
                if messageRenderCacheRefreshDiagnosticID == diagnosticID {
                    messageRenderCacheRefreshTask = nil
                }
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_RENDER_TASK_CLEAR - 修改结束
            let renderMessages = timelineMessages
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_RENDER_CACHE_RUN - 修改开始：定位行缓存 token 与刷新耗时
            let tokenStartedAt = CFAbsoluteTimeGetCurrent()
            let renderToken = messageRenderChangeToken(for: renderMessages)
            let tokenElapsedMS = Self.chatBackDiagnosticElapsedMS(since: tokenStartedAt)
            guard renderToken != cachedMessageRowsRenderToken else {
                chatBackStuckDiagnostic(
                    "render_cache_skip_same_token",
                    extra: "seq=\(diagnosticID) delay_ms=\(Self.chatBackDiagnosticElapsedMS(since: diagnosticScheduledAt)) token_ms=\(tokenElapsedMS) messages=\(renderMessages.count)"
                )
                return
            }
            let refreshStartedAt = CFAbsoluteTimeGetCurrent()
            refreshMessageRowCache(for: renderMessages, knownRenderToken: renderToken)
            let refreshElapsedMS = Self.chatBackDiagnosticElapsedMS(since: refreshStartedAt)
            chatBackStuckDiagnostic(
                "render_cache_refresh",
                extra: "seq=\(diagnosticID) delay_ms=\(Self.chatBackDiagnosticElapsedMS(since: diagnosticScheduledAt)) token_ms=\(tokenElapsedMS) refresh_ms=\(refreshElapsedMS) messages=\(renderMessages.count)"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_RENDER_CACHE_RUN - 修改结束：定位行缓存 token 与刷新耗时
            logChatHistoryReadyIfNeeded(reason: "messages_changed")
            resolveReadStatusAnchorAfterSideDataIfNeeded(reader)
            schedulePendingScrollTargetConsumption(reader)
            scheduleIncomingBottomFollow(reader)
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_DEFERRED_ROW_CACHE_REFRESH - 修改结束：会话消息发布后延后一拍合并刷新行缓存

    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_ROW_SNAPSHOT - 修改开始：为消息行缓存提供稳定快照
    private func cachedRowsForRendering(messages: [ChatMessage]) -> ChatMessageRenderRowsSnapshot {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PREPEND_RENDER_FAST_PATH - 修改开始：旧消息 prepend 时渲染阶段复用已有行，避免 body 内全量重建
        if let prependedRows = olderPrependedRowsForRendering(messages: messages) {
            return messageRowsSnapshot(
                rows: prependedRows,
                version: cachedMessageRowsVersion &+ 1,
                // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：旧消息临时快照直接流式计算签名哈希，避免全量签名数组
                fingerprint: messageRowSignatureFingerprint(for: messages)
                // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
            )
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PREPEND_RENDER_FAST_PATH - 修改结束：旧消息 prepend 时渲染阶段复用已有行，避免 body 内全量重建
        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_ROW_CACHE_FAST_PATH - 修改开始：输入时复用消息行缓存避免全量签名重算
        if cachedMessageRowsConversationID == conversationID,
           cachedMessageRows.count == messages.count,
           cachedMessageRowSignatures.count == messages.count {
            if messages.isEmpty {
                return messageRowsSnapshot(
                    rows: cachedMessageRows,
                    version: cachedMessageRowsVersion,
                    fingerprint: cachedMessageRowSignatureFingerprint
                )
            }
            if cachedMessageRowSignatures.first == messages.first.map({ messageRowCacheSignature(for: $0) }),
               cachedMessageRowSignatures.last == messages.last.map({ messageRowCacheSignature(for: $0) }) {
                return messageRowsSnapshot(
                    rows: cachedMessageRows,
                    version: cachedMessageRowsVersion,
                    fingerprint: cachedMessageRowSignatureFingerprint
                )
            }
        }
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_ROW_CACHE_FAST_PATH - 修改结束：输入时复用消息行缓存避免全量签名重算
        let messageIDs = messages.map { messageRowCacheSignature(for: $0) }
        guard cachedMessageRowsConversationID == conversationID,
              cachedMessageRowSignatures == messageIDs,
              cachedMessageRows.count == messages.count else {
            return messageRowsSnapshot(
                rows: messageRows(for: messages),
                version: cachedMessageRowsVersion &+ 1,
                fingerprint: messageRowSignatureFingerprint(messageIDs)
            )
        }
        return messageRowsSnapshot(
            rows: cachedMessageRows,
            version: cachedMessageRowsVersion,
            fingerprint: cachedMessageRowSignatureFingerprint
        )
    }
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_ROW_SNAPSHOT - 修改结束

    // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_ROW_SNAPSHOT_HELPERS - 修改开始：消息行快照和指纹，仅用于 UI 缓存
    private func messageRowsSnapshot(
        rows: [ChatMessageRenderRow],
        version: Int,
        fingerprint: Int
    ) -> ChatMessageRenderRowsSnapshot {
        ChatMessageRenderRowsSnapshot(
            rows: rows,
            conversationID: conversationID,
            version: version,
            fingerprint: fingerprint
        )
    }

    private func messageRowSignatureFingerprint(_ signatures: [ChatMessageRowCacheSignature]) -> Int {
        var hasher = Hasher()
        for signature in signatures {
            hasher.combine(signature)
        }
        return hasher.finalize()
    }

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：只需要 fingerprint 时避免构造整组签名数组
    private func messageRowSignatureFingerprint(for messages: [ChatMessage]) -> Int {
        var hasher = Hasher()
        for message in messages {
            hasher.combine(messageRowCacheSignature(for: message))
        }
        return hasher.finalize()
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_ROW_SNAPSHOT_HELPERS - 修改结束

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PREPEND_ROW_CACHE_HELPERS - 修改开始：旧消息同步后增量更新消息行缓存
    private var isLikelyApplyingOlderHistoryPage: Bool {
        isLoadingConversationHistory
            || didTriggerOlderHistoryLoadForScrollIntent
            || oldestHistoryLoadAnchorID != nil
            || isUserBrowsingHistory
    }

    private func olderPrependedRowsForRendering(messages: [ChatMessage]) -> [ChatMessageRenderRow]? {
        guard isLikelyApplyingOlderHistoryPage,
              cachedMessageRowsConversationID == conversationID,
              !cachedMessageRows.isEmpty,
              messages.count > cachedMessageRows.count,
              cachedMessageRowSignatures.count == cachedMessageRows.count else {
            return nil
        }
        let prependedCount = messages.count - cachedMessageRows.count
        guard messages.indices.contains(prependedCount),
              cachedMessageRows.first?.message.id == messages[prependedCount].id,
              cachedMessageRows.last?.message.id == messages.last?.id,
              cachedMessageRowSignatures.first == messageRowCacheSignature(for: messages[prependedCount]),
              cachedMessageRowSignatures.last == messages.last.map({ messageRowCacheSignature(for: $0) }) else {
            return nil
        }
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：旧消息 prepend 行缓存用单数组追加，减少滚动加载时临时数组和拷贝
        let resolver = messageSenderResolver()
        var rows: [ChatMessageRenderRow] = []
        rows.reserveCapacity(messages.count)
        for index in messages.indices.prefix(prependedCount) {
            rows.append(messageRow(for: messages, at: index, resolver: resolver))
        }
        for (offset, cachedRow) in cachedMessageRows.enumerated() {
            let index = prependedCount + offset
            guard messages.indices.contains(index) else {
                rows.append(cachedRow)
                continue
            }
            if offset == 0 {
                rows.append(messageRow(for: messages, at: index, resolver: resolver))
                continue
            }
            rows.append(ChatMessageRenderRow(
                index: index,
                message: messages[index],
                showsSenderHeader: cachedRow.showsSenderHeader,
                senderUser: cachedRow.senderUser,
                displaySenderName: cachedRow.displaySenderName,
                timeSeparatorText: cachedRow.timeSeparatorText
            ))
        }
        return rows
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func refreshMessageRowCacheForOlderPrependIfPossible(_ messages: [ChatMessage]) -> Bool {
        guard let rows = olderPrependedRowsForRendering(messages: messages) else { return false }
        let prependedCount = messages.count - cachedMessageRows.count
        cachedMessageRows = rows
        cachedMessageRowsConversationID = conversationID
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：旧消息 prepend 签名缓存用预分配追加，避免 prefix 数组与拼接拷贝
        var nextSignatures: [ChatMessageRowCacheSignature] = []
        nextSignatures.reserveCapacity(messages.count)
        for message in messages.prefix(prependedCount) {
            nextSignatures.append(messageRowCacheSignature(for: message))
        }
        nextSignatures.append(contentsOf: cachedMessageRowSignatures)
        cachedMessageRowSignatures = nextSignatures
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_PREPEND_CACHE_VERSION - 修改开始：旧消息增量刷新后更新 UI item 缓存版本
        cachedMessageRowSignatureFingerprint = messageRowSignatureFingerprint(cachedMessageRowSignatures)
        cachedMessageRowsVersion &+= 1
        messageTimelineItemCache.reset()
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_PREPEND_CACHE_VERSION - 修改结束
        return true
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PREPEND_ROW_CACHE_HELPERS - 修改结束：旧消息同步后增量更新消息行缓存

    private func refreshMessageRowCache(for messages: [ChatMessage]? = nil, knownRenderToken: ChatMessageRenderChangeToken? = nil, allowsPrependReuse: Bool = true) {
        let sourceMessages = messages ?? timelineMessages
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PREPEND_ROW_CACHE_APPLY - 修改开始：旧消息 prepend 优先增量落缓存
        // Identity changes must re-resolve old rows even while history is prepending.
        if !allowsPrependReuse || !refreshMessageRowCacheForOlderPrependIfPossible(sourceMessages) {
            cachedMessageRows = messageRows(for: sourceMessages)
            cachedMessageRowSignatures = sourceMessages.map { messageRowCacheSignature(for: $0) }
            // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_FULL_CACHE_VERSION - 修改开始：消息行全量刷新后更新 UI item 缓存版本
            cachedMessageRowSignatureFingerprint = messageRowSignatureFingerprint(cachedMessageRowSignatures)
            cachedMessageRowsVersion &+= 1
            messageTimelineItemCache.reset()
            // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_FULL_CACHE_VERSION - 修改结束
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PREPEND_ROW_CACHE_APPLY - 修改结束：旧消息 prepend 优先增量落缓存
        cachedMessageRowsConversationID = conversationID
        cachedMessageRowsRenderToken = knownRenderToken ?? messageRenderChangeToken(for: sourceMessages)
    }

    private func messageRowCacheSignature(for message: ChatMessage) -> ChatMessageRowCacheSignature {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：避免为每条消息拼接长字符串作为 UI 缓存签名
        ChatMessageRowCacheSignature(
            id: message.id,
            senderID: message.senderId,
            senderName: message.senderName,
            text: message.text,
            contentType: message.contentType,
            rtcCallID: message.rtcCallRecord?.callID ?? "",
            rtcCallOutcome: message.rtcCallRecord?.finalOutcome.rawValue ?? "",
            rtcCallType: message.rtcCallRecord?.callType.rawValue ?? "",
            stickerCacheIdentity: message.stickerSnapshot?.cacheIdentity ?? "",
            visibleReplyQuote: visibleReplyQuote(for: message) ?? "",
            replyContextID: message.replyContext?.id ?? "",
            replyContextThumbnailURL: message.replyContext?.thumbnailURL ?? "",
            replyUnavailable: message.replyContext?.isUnavailable == true,
            status: message.status,
            time: message.time,
            createdAtSeconds: message.createdAt.map { Int64($0.timeIntervalSince1970) },
            readCount: message.readCount,
            isPinned: message.isPinned,
            isDeletedLocally: message.isDeletedLocally,
            isEdited: message.isEdited
        )
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_RENDER_CHANGE_TOKEN - 修改开始：用轻量 token 代替 messages 数组全量等值监听
    private func messageRenderChangeToken(for messages: [ChatMessage]) -> ChatMessageRenderChangeToken {
        var hasher = Hasher()
        for message in messages {
            // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：显式合并消息 UI 渲染字段，避免 ChatMessage 自动深 hash 拖慢主线程
            combineMessageRenderFingerprint(message, into: &hasher)
            // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        }
        return ChatMessageRenderChangeToken(
            count: messages.count,
            firstID: messages.first?.id ?? "",
            lastID: messages.last?.id ?? "",
            firstSeq: messages.first?.channelSeq ?? 0,
            lastSeq: messages.last?.channelSeq ?? 0,
            aggregateHash: hasher.finalize()
        )
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_RENDER_CHANGE_TOKEN - 修改结束：用轻量 token 代替 messages 数组全量等值监听

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：消息渲染 token 只覆盖 UI 可见/交互相关字段，减少主线程深层 Hashable 成本
    private func combineMessageRenderFingerprint(_ message: ChatMessage, into hasher: inout Hasher) {
        hasher.combine(message.id)
        hasher.combine(message.senderId)
        hasher.combine(message.senderName)
        hasher.combine(message.senderAvatarURL)
        hasher.combine(message.senderAvatarVersion)
        hasher.combine(message.senderAvatarUpdatedAt)
        hasher.combine(message.senderAvatarSeed)
        hasher.combine(message.text)
        hasher.combine(message.time)
        hasher.combine(message.createdAt.map { Int64($0.timeIntervalSince1970) } ?? 0)
        hasher.combine(message.channelSeq)
        hasher.combine(message.isOutgoing)
        hasher.combine(message.status.rawValue)
        hasher.combine(message.kind.rawValue)
        hasher.combine(message.contentType)
        hasher.combine(message.reactions)
        hasher.combine(message.reactionDetails)
        combineReadReceiptIDs(message.readBy, into: &hasher)
        combineReadReceiptIDs(message.unreadBy, into: &hasher)
        hasher.combine(message.readCount)
        hasher.combine(message.unreadCount)
        hasher.combine(message.readStateKnown)
        hasher.combine(message.deliveryStateKnown)
        hasher.combine(message.canViewReadDetails)
        hasher.combine(visibleReplyQuote(for: message))
        hasher.combine(message.replyContext)
        hasher.combine(message.attachmentName)
        hasher.combine(message.attachmentMeta)
        hasher.combine(message.attachmentFileID)
        hasher.combine(message.attachmentSizeBytes)
        hasher.combine(message.attachmentPreviewURL)
        hasher.combine(message.attachmentDownloadURL)
        hasher.combine(message.attachmentPreviewAvailable)
        hasher.combine(message.attachmentDownloadAvailable)
        hasher.combine(message.attachmentTransferProgress)
        hasher.combine(message.attachmentMimeType)
        hasher.combine(message.attachmentCacheKey)
        hasher.combine(message.attachmentVersion)
        hasher.combine(message.attachmentChecksum)
        hasher.combine(message.attachmentMediaCategory)
        hasher.combine(message.attachmentExtension)
        hasher.combine(message.attachmentThumbnailURL)
        hasher.combine(message.attachmentPosterURL)
        hasher.combine(message.attachmentCoverURL)
        hasher.combine(message.attachmentPreviewKind)
        hasher.combine(message.attachmentContentDisposition)
        hasher.combine(message.attachmentWidth)
        hasher.combine(message.attachmentHeight)
        hasher.combine(message.attachmentDurationSeconds)
        hasher.combine(message.attachmentUploadStatus)
        hasher.combine(message.attachmentUploadFailure)
        hasher.combine(message.isPinned)
        hasher.combine(message.isPinnedContextOnly)
        hasher.combine(message.isFavorited)
        hasher.combine(message.isDeletedLocally)
        hasher.combine(message.isEdited)
        hasher.combine(message.editRevision)
        hasher.combine(message.auditTags)
        hasher.combine(message.reportState)
        hasher.combine(message.mentionExcluded)
        hasher.combine(message.mentionAll)
        hasher.combine(message.mentionedUsers)
        hasher.combine(message.voiceWaveform)
        hasher.combine(message.stickerSnapshot)
        hasher.combine(message.rtcCallRecord)
        hasher.combine(message.systemEventType)
        hasher.combine(message.systemDisplayStyle)
        hasher.combine(message.systemColorToken)
        hasher.combine(message.systemTextColorHex)
        hasher.combine(message.systemBackgroundColorHex)
        hasher.combine(message.systemAccentColorHex)
        hasher.combine(message.groupInviteApproval)
    }

    private func combineReadReceiptIDs(_ receipts: [ReadReceipt], into hasher: inout Hasher) {
        hasher.combine(receipts.count)
        for receipt in receipts {
            hasher.combine(receipt.id)
        }
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

    private func performMessageSearch() {
        scheduleConversationSearch(immediate: true)
    }

    private func performConversationDateSearch() {
        scheduleConversationSearch(immediate: true, dateOnly: true)
    }

    private func scheduleConversationSearch(immediate: Bool = false, dateOnly: Bool = false) {
        if searchTask != nil, isSearchingMessages {
            postConversationSearchAnalytics(eventType: "cancel", response: conversationSearchResponse)
        }
        searchTask?.cancel()
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = conversationSearchDate.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        let canSearchByDate = dateOnly && isValidConversationSearchDate(date)
        guard !keyword.isEmpty || canSearchByDate else {
            searchResults = []
            conversationSearchResponse = nil
            conversationSearchTotal = 0
            conversationSearchHitSeqs = []
            conversationSearchTypeCursors = [:]
            focusedSearchResultID = nil
            isSearchingMessages = false
            if immediate {
                state.toast = dateOnly ? "请输入 YYYY-MM-DD 日期" : "请输入搜索关键词"
            }
            return
        }
        isSearchingMessages = true
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 550_000_000)
            }
            guard !Task.isCancelled else { return }
            let response = await state.tenantSearch(
                query: keyword,
                scope: "conversation",
                types: ["messages", "files"],
                limit: 20,
                conversationID: conversationID,
                date: canSearchByDate ? date : nil
            )
            await MainActor.run {
                guard generation == searchGeneration,
                      searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines) == keyword,
                      conversationSearchDate.trimmingCharacters(in: .whitespacesAndNewlines) == date else { return }
                conversationSearchResponse = response
                searchResults = conversationSearchItems(from: response)
                if let response {
                    let pagination = TenantConversationSearchPaginationState(response: response, items: searchResults)
                    conversationSearchTotal = pagination.total
                    conversationSearchHitSeqs = pagination.hitChannelSeqs
                    conversationSearchTypeCursors = pagination.typeCursors
                } else {
                    conversationSearchTotal = searchResults.count
                    conversationSearchHitSeqs = searchResults.compactMap { $0.jumpTarget?.channelSeq }
                    conversationSearchTypeCursors = [:]
                }
                isSearchingMessages = false
                if let response {
                    postConversationSearchAnalytics(eventType: searchResults.isEmpty ? "zero_result" : "success", response: response)
                }
                if canSearchByDate, let anchor = response?.conversationDateAnchor {
                    jumpToConversationDateAnchor(anchor)
                } else if immediate && searchResults.isEmpty {
                    state.toast = "没有找到相关聊天记录"
                }
            }
        }
    }

    private func conversationSearchItems(from response: RemoteTenantSearchResponse?) -> [RemoteTenantSearchResult] {
        guard let response else { return [] }
        var seen = Set<String>()
        return ["messages", "files"].flatMap { type in
            response.resultsByType[type]?.items ?? []
        }.filter { item in
            seen.insert(item.id).inserted
                && !item.isBlockedFromChatSearchDisplay
                && !conversationSearchInvalidations.contains(where: { item.matchesSearchInvalidation($0) })
        }
    }

    private func applyLatestSearchInvalidationToConversationResults() {
        guard let invalidation = state.latestSearchInvalidation else { return }
        if invalidation.isTenantScopeReset {
            searchTask?.cancel()
            searchResults = []
            conversationSearchResponse = nil
            conversationSearchTotal = 0
            conversationSearchHitSeqs = []
            conversationSearchTypeCursors = [:]
            focusedSearchResultID = nil
            conversationSearchInvalidations.removeAll()
            isSearchingMessages = false
            isLoadingMoreSearchResults = false
            return
        }
        conversationSearchInvalidations.append(invalidation)
        if conversationSearchInvalidations.count > 64 {
            conversationSearchInvalidations.removeFirst(conversationSearchInvalidations.count - 64)
        }
        searchResults.removeAll { $0.matchesSearchInvalidation(invalidation) }
        conversationSearchTotal = max(conversationSearchTotal, searchResults.count)
    }

    private func loadMoreConversationSearchResults() {
        guard !isLoadingMoreSearchResults,
              conversationSearchHasMore else { return }
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = conversationSearchDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty || isValidConversationSearchDate(date) else { return }
        let requestTypes = ["messages", "files"]
        let requestTypeCursors = conversationSearchTypeCursors
        let genericCursor = TenantConversationSearchPaginationState(
            response: conversationSearchResponse ?? RemoteTenantSearchResponse(),
            items: searchResults
        ).genericCursor(for: requestTypes)
        isLoadingMoreSearchResults = true
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = Task {
            let response = await state.tenantSearch(
                query: keyword,
                scope: "conversation",
                types: requestTypes,
                limit: 20,
                cursor: genericCursor,
                typeCursors: requestTypeCursors,
                conversationID: conversationID,
                date: isValidConversationSearchDate(date) ? date : nil
            )
            await MainActor.run {
                guard generation == searchGeneration,
                      searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines) == keyword,
                      conversationSearchDate.trimmingCharacters(in: .whitespacesAndNewlines) == date else { return }
                if let response {
                    let incoming = conversationSearchItems(from: response)
                    searchResults = stableMergedConversationSearchItems(searchResults, appending: incoming)
                    conversationSearchResponse = response
                    let pagination = TenantConversationSearchPaginationState(response: response, items: searchResults)
                    conversationSearchTotal = max(conversationSearchTotal, pagination.total, searchResults.count)
                    conversationSearchHitSeqs = stableMergedSeqs(conversationSearchHitSeqs, appending: pagination.hitChannelSeqs)
                    conversationSearchTypeCursors = pagination.typeCursors
                    postConversationSearchAnalytics(eventType: "success", response: response)
                }
                isLoadingMoreSearchResults = false
            }
        }
    }

    private var conversationSearchHasMore: Bool {
        !conversationSearchTypeCursors.isEmpty
    }

    private func stableMergedConversationSearchItems(
        _ existing: [RemoteTenantSearchResult],
        appending incoming: [RemoteTenantSearchResult]
    ) -> [RemoteTenantSearchResult] {
        var result = existing
        var indexes: [String: Int] = [:]
        for (index, item) in existing.enumerated() {
            indexes[item.id] = index
        }
        for item in incoming {
            if let index = indexes[item.id] {
                result[index] = item
            } else {
                indexes[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    private func stableMergedSeqs(_ existing: [Int64], appending incoming: [Int64]) -> [Int64] {
        var seen = Set(existing)
        var result = existing
        for seq in incoming where seen.insert(seq).inserted {
            result.append(seq)
        }
        return result
    }

    private func jumpToAdjacentSearchResult(direction: Int) {
        guard !searchResults.isEmpty else {
            state.toast = "暂无可定位的搜索结果"
            return
        }
        let currentIndex = focusedSearchResultID.flatMap { id in
            searchResults.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + direction + searchResults.count) % searchResults.count
        } else {
            nextIndex = direction < 0 ? searchResults.count - 1 : 0
        }
        let item = searchResults[nextIndex]
        focusedSearchResultID = item.id
        Task {
            await jumpToSearchResult(item)
        }
    }

    private func performPendingPinnedJumpIfNeeded() {
        guard let message = pendingPinnedJumpMessage else { return }
        pendingPinnedJumpMessage = nil
        // 旧置顶消息可能只有 context-only 副本；sheet 完整收起后再水合，
        // 消息定位请求会继续保留到目标真正进入可渲染时间线。
        Task {
            if let targetID = await state.prepareMessageJump(
                messageID: message.id,
                channelSeq: message.channelSeq,
                conversationID: conversationID
            ) {
                await MainActor.run { setScrollTarget(targetID, source: .pinnedJump) }
            } else {
                await MainActor.run { state.toast = "原消息可能已删除或不可见" }
            }
        }
    }

    private func jumpToConversationDateAnchor(_ anchor: RemoteTenantConversationDateAnchor) {
        guard let target = anchor.bestJumpTarget else {
            state.toast = anchor.status == "empty" ? "当天没有聊天记录" : "未找到日期附近消息"
            return
        }
        Task {
            if let messageID = await state.prepareSearchJumpTarget(target, conversationID: conversationID) {
                await MainActor.run {
                    setScrollTarget(messageID, source: .searchJump)
                    state.toast = anchor.status == "nearest" ? "已定位到附近消息" : "已定位到当天消息"
                }
            } else {
                await MainActor.run {
                    state.toast = "未找到日期附近消息"
                }
            }
        }
    }

    private func isValidConversationSearchDate(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func postConversationSearchAnalytics(
        eventType: String,
        response: RemoteTenantSearchResponse?,
        item: RemoteTenantSearchResult? = nil
    ) {
        let filters = Dictionary(
            (response?.parsedFilters ?? []).map { filter in
                (filter.key.isEmpty ? filter.type : filter.key, filter.value)
            },
            uniquingKeysWith: { first, _ in first }
        )
        state.postTenantSearchEvent(TenantSearchAnalyticsEvent(
            searchID: response?.searchID,
            requestID: response?.requestID,
            eventType: eventType,
            scope: "conversation",
            types: ["messages", "files"],
            resultType: item?.type,
            resultID: item?.resultID,
            resultRank: item?.rank,
            queryLength: searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).count,
            elapsedMS: response?.elapsedMS,
            filters: filters
        ))
    }

    private func jumpToSearchResult(_ item: RemoteTenantSearchResult) async {
        guard let target = item.jumpTarget else {
            await MainActor.run { state.toast = "搜索结果暂不可跳转" }
            return
        }
        if target.kind == "file",
           (target.channelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (target.messageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           target.channelSeq == nil {
            await MainActor.run { state.toast = "未找到来源消息，请到文件页查看" }
            return
        }
        if let messageID = await state.prepareSearchJumpTarget(target, conversationID: conversationID) {
            await MainActor.run {
                setScrollTarget(messageID, source: .searchJump)
            }
        } else {
            await MainActor.run {
                state.toast = "消息可能已删除、无权限或不可见"
            }
        }
    }

    private func applyInitialSearchJumpTargetIfNeeded() {
        guard !didApplyInitialSearchJumpTarget,
              !isPreparingInitialSearchJumpTarget,
              let initialSearchJumpTarget else { return }
        didApplyInitialSearchJumpTarget = true
        guard conversationListMessageJumpTarget(initialSearchJumpTarget) != nil else { return }
        isPreparingInitialSearchJumpTarget = true
        _ = evaluateScrollRequest(source: .searchJump, targetID: nil, anchor: .center, userInitiated: true)
        Task {
            if let messageID = await state.prepareSearchJumpTarget(initialSearchJumpTarget, conversationID: conversationID) {
                await MainActor.run {
                    isPreparingInitialSearchJumpTarget = false
                    setScrollTarget(messageID, source: .searchJump)
                }
            } else {
                await MainActor.run {
                    isPreparingInitialSearchJumpTarget = false
                    state.toast = "消息可能已删除、无权限或不可见"
                }
            }
        }
    }

	    private func dismissExpressionPanelFromTranscriptTap() {
        guard showEmoji || showTools else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showEmoji = false
            showTools = false
        }
	    }

    private func dismissChatKeyboardFromTranscript(
        trigger: ChatTranscriptKeyboardDismissalTrigger
    ) {
        let plan = chatTranscriptKeyboardDismissalPlan(trigger: trigger)
        guard plan.dismissesKeyboard else { return }
        dismissActiveChatKeyboard()
    }

    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_HANDLER - 修改开始：输入框聚焦时滚动到最新消息
    private func scrollToLatestMessageForComposerFocus() {
        guard didInitialScroll, !isApplyingInitialScroll, !conversation.messages.isEmpty else { return }
        isUserBrowsingHistory = false
        isAtBottom = true
        didTriggerOlderHistoryLoadForScrollIntent = false
        transcriptScrollControl.clearSuppression()
        updateRealtimeAutoReadGate()
        setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard didInitialScroll, !isApplyingInitialScroll, !conversation.messages.isEmpty else { return }
            setScrollTarget(bottomAnchorID, source: .jumpToLatest, anchor: .bottom)
        }
    }
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_HANDLER - 修改结束：输入框聚焦时滚动到最新消息

	    private func mention(_ user: IMUser) {
        guard conversation.kind == .group else { return }
	        let displayName = mentionVisibleDisplayName(for: user)
        let mentionText = "@\(displayName) "
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            input = mentionText
        } else if !input.contains(mentionText) {
            input += input.hasSuffix(" ") ? mentionText : " \(mentionText)"
        }
        rememberExternalMention(user, displayText: displayName)
        showTools = false
        showEmoji = false
    }

    private func rememberExternalMention(_ user: IMUser, displayText: String? = nil) {
        let mention = MentionIdentity(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: displayText ?? mentionVisibleDisplayName(for: user)
        )
        guard !mention.id.isEmpty else { return }
        pendingMentionUsers.removeAll { $0.id == mention.id || $0.mentionToken == mention.mentionToken }
        pendingMentionUsers.append(mention)
    }

    private func mergedMentionUsers(from composerMentions: [MentionIdentity], externalMentions: [MentionIdentity], in draft: String) -> [MentionIdentity] {
        var seen = Set<String>()
        return (composerMentions + externalMentions).filter { mention in
            guard draft.contains(mention.mentionToken), !mention.id.isEmpty else { return false }
            return seen.insert(mention.id).inserted
        }
    }

    private func startReply(to message: ChatMessage) {
        let context = replyContext(for: message)
        replyContext = context
        replyQuote = context.quoteText
        guard conversation.kind == .group,
              let replyTarget = replyMentionTarget(for: message) else { return }
        mention(replyTarget)
    }

    private func replyContext(for message: ChatMessage) -> MessageReplyContext {
        let senderName = replySenderSnapshotName(for: message)
        return MessageReplyContext(
            messageID: message.id,
            senderID: message.senderId,
            senderName: senderName,
            summary: replySummaryText(for: message),
            contentType: message.contentType.isEmpty ? message.kind.rawValue : message.contentType,
            channelSeq: message.channelSeq,
            isUnavailable: message.status == .recalled || message.isDeletedLocally,
            thumbnailURL: message.isStickerMessage ? message.stickerSnapshot?.thumbnailURL ?? "" : ""
        )
    }

    private func replyMentionTarget(for message: ChatMessage) -> IMUser? {
        guard message.kind != .system, !isMessageAuthoredByCurrentUser(message) else { return nil }
        let resolver = MessageSenderResolver(
            currentUser: state.currentUser,
            enterpriseName: state.currentEnterprise.name,
            conversation: conversation,
            contacts: state.contacts,
            group: currentGroup,
            exactGroupSelf: state.myGroupMemberProjection(groupID: currentGroup.id),
            contactRemarks: state.contactRemarks
        )
        return resolver.senderUser(for: message)
    }

    private func replyQuoteText(for message: ChatMessage) -> String {
        let senderName = replySenderDisplayName(for: message)
        let summary = replySummaryText(for: message)
        return senderName.isEmpty ? summary : "\(senderName)：\(summary)"
    }

    private func replySenderDisplayName(for message: ChatMessage) -> String {
        let resolver = MessageSenderResolver(
            currentUser: state.currentUser,
            enterpriseName: state.currentEnterprise.name,
            conversation: conversation,
            contacts: state.contacts,
            group: conversation.kind == .group ? currentGroup : nil,
            exactGroupSelf: conversation.kind == .group
                ? state.myGroupMemberProjection(groupID: currentGroup.id)
                : nil,
            contactRemarks: state.contactRemarks
        )
        let senderUser = resolver.senderUser(for: message)
        return resolver.displaySenderName(for: message, resolvedUser: senderUser)
    }

    private func replySenderSnapshotName(for message: ChatMessage) -> String {
        guard message.kind != .system else { return "系统" }
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedName.isEmpty, !isIdentifierLikeSenderName(storedName, senderID: message.senderId) {
            return storedName
        }
        return message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replySummaryText(for message: ChatMessage) -> String {
        switch message.kind {
        case .rtcCallRecord:
            return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
                ?? "[通话记录]"
        case .image:
            return "[图片]"
        case .file:
            let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            switch state.attachmentMediaCategory(for: message) {
            case "video":
                return "[视频]"
            default:
                return name.isEmpty ? "[文件]" : "[文件] \(name)"
            }
        case .voice:
            return "[语音]"
        case .video:
            return "[视频]"
        case .location:
            return "[位置]"
        case .contactCard:
            let name = (message.attachmentName ?? message.text)
                .replacingOccurrences(of: "个人名片：", with: "")
                .replacingOccurrences(of: "推荐名片：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "[名片]" : "[名片] \(name)"
        case .system:
            return "回复了一条消息"
        case .text:
            if message.isStickerMessage {
                return message.stickerSnapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText
            }
            let text = message.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "回复了一条消息" : text
        }
    }

    private var groupContext: some View {
        HStack(spacing: 10) {
            Button {
                openCurrentGroupAnnouncement()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "megaphone.fill")
                        .foregroundStyle(IMColor.brand)
                    Text("\(currentGroupAnnouncementTitle)：\(currentGroupAnnouncementPreview)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(IMColor.muted.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                closeCurrentGroupAnnouncementBanner()
            } label: {
                Group {
                    if isMarkingGroupAnnouncementRead || isOpeningGroupAnnouncementDetail {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(IMColor.muted.opacity(0.72))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isMarkingGroupAnnouncementRead || isOpeningGroupAnnouncementDetail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.82))
    }

    private func pinnedContext(messages: [ChatMessage]) -> some View {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：置顶栏渲染复用一次置顶数组，避免重复扫描
        let activeMessage = messages.isEmpty ? nil : messages[pinnedCarouselIndex % messages.count]
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        return Button {
            showPinnedMessages = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.warning)
                Text(activeMessage?.text ?? "置顶消息")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .contentTransitionOpacityCompat()
                Spacer()
                if messages.count > 1 {
                    Text("\((pinnedCarouselIndex % messages.count) + 1)/\(messages.count)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.88)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(IMColor.brand.opacity(0.06))
    }

    @discardableResult
    private func configureInitialPosition(_ reader: ScrollViewProxy) -> Bool {
        resetScrollPositionState()
        captureInitialUnreadSnapshotIfNeeded()
        if initialSearchJumpTarget != nil,
           (!didApplyInitialSearchJumpTarget || isPreparingInitialSearchJumpTarget) {
            applyInitialSearchJumpTargetIfNeeded()
            return true
        }
        guard !conversation.messages.isEmpty, !didInitialScroll else { return false }
        let shouldWaitForLatestWindow = chatShouldWaitForInitialLatestWindowRefresh(
            needsUnreadWindowRefresh: needsInitialUnreadWindowRefresh,
            needsLatestWindowRefresh: needsInitialLatestWindowRefresh,
            canReuseConfirmedBottom: canReuseConfirmedBottomForCurrentWindow
        )
        if shouldWaitForLatestWindow {
            let waitEvent = needsInitialLatestMetadataRefresh ? "wait_latest_metadata" : "wait_window"
            logInitialAnchorDecision(waitEvent, targetID: nil, unreadCount: rawInitialUnreadCount())
            scheduleProvisionalInitialBottomIfNeeded(reader, reason: waitEvent)
            if isLoadingConversationHistory {
                return true
            }
            if initialUnreadAnchorLoadAttempts < initialUnreadAnchorMaxHistoryLoads {
                initialUnreadAnchorLoadAttempts += 1
                logInitialAnchorDecision("sync_latest_window", targetID: nil, unreadCount: rawInitialUnreadCount())
                state.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: true,
                    trimToLatestWindow: true
                )
                return true
            }
            logInitialAnchorDecision("window_refresh_exhausted", targetID: nil, unreadCount: rawInitialUnreadCount())
        }

        let unreadCount = initialUnreadCountForCurrentMessageWindow()
        if shouldLoadOlderHistoryForInitialAnchor(unreadCount: unreadCount) {
            loadOlderHistoryForInitialAnchor()
            return true
        }
        didInitialScroll = true
        capturedUnreadCount = unreadCount
        pendingUnreadCount = unreadCount
        unreadDividerVisible = unreadCount > 0
        isApplyingInitialScroll = true
        if unreadCount > 0 {
            isUserBrowsingHistory = false
        }
        isAtBottom = false

        guard let target = initialScrollAnchor(unreadCount: unreadCount) else {
            isApplyingInitialScroll = false
            updateRealtimeAutoReadGate()
            return false
        }
        let shouldSkipDelayedBottomConfirmation = unreadCount == 0 && hasConfirmedLatestBottomForCurrentWindow
        logInitialAnchorDecision("schedule_initial_scroll", targetID: target.id, unreadCount: unreadCount)
        let bottomScrollGeneration = target.id == bottomAnchorID ? nextAutomaticBottomScrollGeneration() : automaticBottomScrollGeneration
        DispatchQueue.main.async {
            guard target.id != bottomAnchorID || bottomScrollGeneration == automaticBottomScrollGeneration else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            guard unreadCount > 0 || !isUserBrowsingHistory else {
                isApplyingInitialScroll = false
                isAtBottom = false
                updateRealtimeAutoReadGate()
                logInitialAnchorDecision("skip_initial_bottom_user_browsing_history", targetID: target.id, unreadCount: unreadCount)
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: target.id, anchor: target.placement.unitPoint, source: .initialAnchor) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            logInitialAnchorDecision("initial_scroll_applied", targetID: target.id, unreadCount: unreadCount)
            didAutoScrollToUnreadAnchor = unreadCount > 0
            isApplyingInitialScroll = false
            let isLatestBottom = isLatestBottomTarget(target.id)
            isAtBottom = isLatestBottom
            updateRealtimeAutoReadGate()
            if target.anchorsLastReadMessage {
                markVisibleIncomingMessagesReadIfNeeded()
            } else if unreadCount == 0 {
                if isLatestBottom && !shouldSkipDelayedBottomConfirmation {
                    scheduleLatestBottomConfirmation(reader, reason: "initial_read_bottom_confirm", force: true)
                } else if isLatestBottom {
                    rememberLatestBottomVisible()
                }
                markVisibleIncomingMessagesReadIfNeeded()
            } else if isLatestBottom {
                clearUnreadReminderAndAckIfNeeded(reason: "initial_fallback_to_latest")
                scheduleLatestBottomConfirmation(reader, reason: "initial_unread_latest_bottom_confirm", force: true)
            }
            maybeLoadOlderMessagesFromScrollMetrics(visibility: lastScrollVisibility)
            autofillOlderHistoryIfUnderfilled()
        }
        return true
    }

    private func captureInitialUnreadSnapshotIfNeeded() {
        guard initialUnreadSnapshot == nil else { return }
        initialUnreadSnapshot = max(conversation.unread, 0)
    }

    private func rawInitialUnreadCount() -> Int {
        max(initialUnreadSnapshot ?? max(conversation.unread, 0), 0)
    }

    private func initialUnreadCountForCurrentMessageWindow() -> Int {
        let rawUnread = rawInitialUnreadCount()
        guard rawUnread > 0 else { return 0 }
        return min(rawUnread, timelineMessages.count)
    }

    private func initialScrollAnchor(unreadCount: Int) -> ChatInitialScrollAnchor? {
        chatInitialScrollAnchor(
            messages: timelineMessages,
            unreadCount: unreadCount,
            lastReadSeq: conversation.lastReadSeq,
            firstUnreadMessageID: conversation.firstUnreadMessageID,
            firstUnreadSeq: conversation.firstUnreadSeq,
            firstUnreadMarkerID: firstUnreadMarkerID,
            bottomAnchorID: bottomAnchorID
        )
    }

    private func isLatestBottomTarget(_ targetID: String) -> Bool {
        targetID == bottomAnchorID || latestBottomScrollTargetID == targetID
    }

    private func firstUnreadMessageIDAfterReadCursor() -> String? {
        guard conversation.lastReadSeq > 0 else { return nil }
        return timelineMessages.first { message in
            message.channelSeq > conversation.lastReadSeq
                && message.status != .recalled
                && !message.isDeletedLocally
        }?.id
    }

    private func oldestLoadedMessageSeq() -> Int64? {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：避免上滑加载判断时 map/filter/min 分配临时数组
        var oldestSeq: Int64?
        for message in conversation.messages where message.channelSeq > 0 {
            oldestSeq = min(oldestSeq ?? message.channelSeq, message.channelSeq)
        }
        return oldestSeq
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private func shouldLoadOlderHistoryForInitialAnchor(unreadCount: Int) -> Bool {
        guard rawInitialUnreadCount() > 0, unreadCount > 0 else { return false }
        // Initial entry must stay near the latest unread/latest message window. Older
        // history is still loaded only when the user explicitly scrolls upward.
        return false
    }

    private func loadOlderHistoryForInitialAnchor() {
        guard !isLoadingConversationHistory else { return }
        initialUnreadAnchorLoadAttempts += 1
        state.loadOlderMessagesIfAvailable(conversationID)
    }

    private func handleLatestWindowProgress(_ reader: ScrollViewProxy, reason: String) {
        if !didInitialScroll {
            _ = configureInitialPosition(reader)
            return
        }
        if requestLatestWindowCatchupSyncIfNeeded(reason: reason) {
            return
        }
        _ = catchUpToLatestWindowIfNeeded(reader, reason: reason)
    }

    private func resolveReadStatusAnchorAfterSideDataIfNeeded(_ reader: ScrollViewProxy) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              !isWithinChatEntryStabilizationWindow,
              !didResolveReadStatusAnchorAfterSideData,
              rawInitialUnreadCount() == 0,
              !didUserInteractWithMessageScroll,
              let target = initialScrollAnchor(unreadCount: 0),
              target.anchorsLastReadMessage,
              conversation.messages.contains(where: { $0.id == target.id && chatMessageDisplaysReadStatusForInitialAnchor($0) }) else {
            return
        }
        didResolveReadStatusAnchorAfterSideData = true
        isApplyingInitialScroll = true
        logInitialAnchorDecision("schedule_read_status_anchor_side_data", targetID: target.id, unreadCount: 0)
        DispatchQueue.main.async {
            guard !didUserInteractWithMessageScroll,
                  conversation.messages.contains(where: { $0.id == target.id }) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: target.id, anchor: target.placement.unitPoint, source: .readAck) else {
                isApplyingInitialScroll = false
                updateRealtimeAutoReadGate()
                return
            }
            isApplyingInitialScroll = false
            isAtBottom = false
            updateRealtimeAutoReadGate()
            logInitialAnchorDecision("read_status_anchor_side_data_applied", targetID: target.id, unreadCount: 0)
        }
    }

    @discardableResult
    private func requestLatestWindowCatchupSyncIfNeeded(reason: String) -> Bool {
        guard needsInitialLatestWindowRefresh,
              rawInitialUnreadCount() == 0,
              pendingUnreadCount == 0,
              !isUserBrowsingHistory,
              !isAutomaticBottomScrollSuppressed,
              !isLoadingConversationHistory,
              initialUnreadAnchorLoadAttempts < initialUnreadAnchorMaxHistoryLoads else {
            return false
        }
        initialUnreadAnchorLoadAttempts += 1
        logInitialAnchorDecision("catchup_sync_latest_window_\(reason)", targetID: nil, unreadCount: 0)
        state.syncConversationMessagesIfNeeded(
            conversationID,
            force: true,
            silent: true,
            showLoadingIndicator: true,
            trimToLatestWindow: true
        )
        return true
    }

    @discardableResult
    private func catchUpToLatestWindowIfNeeded(_ reader: ScrollViewProxy, reason: String) -> Bool {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              !hasConfirmedLatestBottomForCurrentWindow,
              rawInitialUnreadCount() == 0,
              pendingUnreadCount == 0,
              isLatestMessageWindowLoaded,
              conversation.lastMsgSeq > 0,
              latestLoadedMessageSeq > 0,
              !hasLastReadInitialAnchorForCurrentWindow,
              !isUserBrowsingHistory,
              !isAutomaticBottomScrollSuppressed,
              !conversation.messages.isEmpty else {
            return false
        }
        didInitialLatestWindowCatchupScroll = true
        logInitialAnchorDecision("schedule_latest_bottom_catchup_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: 0)
        scheduleLatestBottomConfirmation(reader, reason: "latest_bottom_catchup_\(reason)")
        return true
    }

    private func beginNormalOpenScrollWindow(reason: String) {
        let now = Date()
        chatEntryStabilizationUntil = now.addingTimeInterval(chatEntryStabilizationDuration)
        scrollArbiter.beginNormalOpen(now: now, duration: chatEntryStabilizationDuration)
        logInitialAnchorDecision("begin_normal_open_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: rawInitialUnreadCount())
    }

    @discardableResult
    private func evaluateScrollRequest(
        source: ConversationScrollRequestSource,
        targetID: String?,
        anchor: UnitPoint?,
        userInitiated: Bool
    ) -> ConversationScrollVerdict {
        let request = ConversationScrollRequest(
            source: source,
            targetID: targetID,
            anchor: anchor,
            userInitiated: userInitiated,
            generation: scrollArbiter.generation
        )
        return scrollArbiter.evaluate(request, now: Date())
    }

    private func setScrollTarget(
        _ targetID: String,
        source: ConversationScrollRequestSource,
        anchor: UnitPoint = .center
    ) {
        oldestHistoryLoadAnchorID = nil
        oldestHistoryLoadAnchorMinY = nil
        pendingScrollTargetSource = source
        pendingScrollTargetAnchor = anchor
        scrollTargetID = targetID
    }

    private func schedulePendingScrollTargetConsumption(
        _ reader: ScrollViewProxy,
        expectedTargetID: String? = nil
    ) {
        guard let targetID = scrollTargetID,
              expectedTargetID == nil || expectedTargetID == targetID else {
            return
        }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_SCROLL_TARGET_LOOKUP_FAST_PATH - 修改开始：待滚动目标只做目标查询，避免历史多时全量建 Set
        guard canConsumePendingScrollTarget(targetID) else {
            return
        }
        // 让本轮消息状态先完成 SwiftUI diff，再交给 ScrollViewReader 定位。
        DispatchQueue.main.async {
            guard scrollTargetID == targetID else { return }
            guard canConsumePendingScrollTarget(targetID) else {
                return
            }
            consumePendingScrollTarget(reader, targetID: targetID)
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_SCROLL_TARGET_LOOKUP_FAST_PATH - 修改结束：待滚动目标只做目标查询，避免历史多时全量建 Set
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_SCROLL_TARGET_LOOKUP_HELPER - 修改开始：复用已缓存的消息行判断滚动目标
    private func canConsumePendingScrollTarget(_ targetID: String) -> Bool {
        if targetID == bottomAnchorID {
            return true
        }
        if cachedMessageRowsConversationID == conversationID,
           cachedMessageRows.contains(where: { $0.message.id == targetID }) {
            return true
        }
        return conversation.messages.contains { message in
            !message.isPinnedContextOnly && message.id == targetID
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_SCROLL_TARGET_LOOKUP_HELPER - 修改结束：复用已缓存的消息行判断滚动目标

    private func consumePendingScrollTarget(_ reader: ScrollViewProxy, targetID: String) {
        let source = pendingScrollTargetSource
        let requestedAnchor = pendingScrollTargetAnchor
        let verdict = evaluateScrollRequest(
            source: source,
            targetID: targetID,
            anchor: requestedAnchor,
            userInitiated: true
        )
        guard verdict != .deny else {
            scrollTargetID = nil
            return
        }
        let isLatestBottom = isLatestBottomTarget(targetID)
        isUserBrowsingHistory = source == .jumpToLatest ? false : !isLatestBottom
        if source != .jumpToLatest {
            isAtBottom = isLatestBottom
        }
        updateRealtimeAutoReadGate()
        if !isLatestBottom, source == .searchJump || source == .pinnedJump {
            focusTimelineMessage(targetID)
        }
        if timelineMessages.first?.id == targetID {
            // The leading message has no content before it to center. A long
            // spring jump can retain an estimated offset as lazy rows resolve.
            scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .top)
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                reader.scrollTo(targetID, anchor: requestedAnchor)
            }
        }
        if source != .jumpToLatest, isLatestBottom {
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        scrollTargetID = nil
        pendingScrollTargetSource = .searchJump
        pendingScrollTargetAnchor = .center
    }

    private func focusTimelineMessage(_ messageID: String) {
        focusedTimelineMessageGeneration += 1
        let generation = focusedTimelineMessageGeneration
        focusedTimelineMessageID = messageID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard generation == focusedTimelineMessageGeneration else { return }
            focusedTimelineMessageID = nil
        }
    }

    private func scrollToTargetWithoutAnimation(
        _ reader: ScrollViewProxy,
        targetID: String,
        anchor: UnitPoint?,
        source: ConversationScrollRequestSource
    ) -> Bool {
        let verdict = evaluateScrollRequest(source: source, targetID: targetID, anchor: anchor, userInitiated: false)
        guard verdict != .deny else { return false }
        scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: anchor)
        return true
    }

    private func scheduleLatestBottomConfirmation(_ reader: ScrollViewProxy, reason: String, force: Bool = false) {
        if !force, incomingBottomFollowDecision != nil {
            scheduleIncomingBottomFollow(reader)
            return
        }
        guard force || !hasConfirmedLatestBottomForCurrentWindow else {
            markVisibleIncomingMessagesReadIfNeeded()
            return
        }
        let targetSeq = latestBottomTargetSeq
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        let confirmationDelays = isWithinChatEntryStabilizationWindow
            ? [chatLatestBottomConfirmationDelays(force: force).first ?? 0]
            : chatLatestBottomConfirmationDelays(force: force)
        for delay in confirmationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let targetID = latestBottomScrollTargetID
                guard bottomScrollGeneration == automaticBottomScrollGeneration,
                      didInitialScroll,
                      !isApplyingInitialScroll,
                      (force || incomingBottomFollowDecision == nil),
                      (force || rawInitialUnreadCount() == 0),
                      (force || pendingUnreadCount == 0),
                      !isUserBrowsingHistory,
                      canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll,
                      !conversation.messages.isEmpty else {
                    return
                }
                guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .followBottom) else { return }
                didInitialLatestWindowCatchupScroll = true
                let currentTargetSeq = max(targetSeq, latestBottomTargetSeq)
                rememberLatestBottomVisible(seq: currentTargetSeq)
                isAtBottom = true
                updateRealtimeAutoReadGate()
                logInitialAnchorDecision("\(reason)_applied", targetID: targetID, unreadCount: 0)
                markVisibleIncomingMessagesReadIfNeeded()
            }
        }
    }

    private func followBottomAfterMessageChangeIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) {
        if incomingBottomFollowDecision != nil {
            scheduleIncomingBottomFollow(reader)
            return
        }
        guard didInitialScroll, newCount > oldCount, pendingUnreadCount == 0, !conversation.messages.isEmpty else { return }
        guard canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll else { return }
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            guard bottomScrollGeneration == automaticBottomScrollGeneration,
                  canApplyAutomaticBottomScroll || canApplyEntryStabilizationBottomScroll else { return }
            let targetID = latestBottomScrollTargetID
            if isWithinChatEntryStabilizationWindow {
                guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .followBottom) else { return }
            } else {
                guard evaluateScrollRequest(source: .followBottom, targetID: targetID, anchor: .bottom, userInitiated: false) != .deny else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    reader.scrollTo(targetID, anchor: .bottom)
                }
            }
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
    }

    private func withoutSendLayoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func scrollToLatestBottomWithoutAnimation(_ reader: ScrollViewProxy, source: ConversationScrollRequestSource = .followBottom) {
        _ = scrollToTargetWithoutAnimation(reader, targetID: latestBottomScrollTargetID, anchor: .bottom, source: source)
    }

    private func scrollToTargetWithoutAnimation(_ reader: ScrollViewProxy, targetID: String, anchor: UnitPoint?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reader.scrollTo(targetID, anchor: anchor)
        }
    }

    @discardableResult
    private func scrollToBottomAfterOwnSendIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) -> Bool {
        guard let baselineCount = pendingOwnSendScrollBaselineCount,
              newCount > oldCount,
              newCount > baselineCount,
              !conversation.messages.isEmpty else {
            return false
        }
        let newMessageCount = max(newCount - oldCount, 1)
        let newTailMessages = conversation.messages.suffix(newMessageCount)
        guard newTailMessages.contains(where: isMessageAuthoredByCurrentUser) else {
            return false
        }

        pendingOwnSendScrollBaselineCount = nil
        isUserBrowsingHistory = false
        isAtBottom = true
        transcriptScrollControl.clearSuppression()
        didTriggerOlderHistoryLoadForScrollIntent = false
        updateRealtimeAutoReadGate()

        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            guard bottomScrollGeneration == automaticBottomScrollGeneration else { return }
            scrollToLatestBottomWithoutAnimation(reader, source: .sendEcho)
            rememberLatestBottomVisible()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        return true
    }

    @discardableResult
    private func preserveHistoryAnchorAfterMessageChangeIfNeeded(_ reader: ScrollViewProxy, oldCount: Int, newCount: Int) -> Bool {
        guard didInitialScroll,
              newCount > oldCount,
              !isAtBottom,
              let anchorID = oldestHistoryLoadAnchorID,
              conversation.messages.contains(where: { $0.id == anchorID }) else {
            return false
        }
        guard let anchorY = oldestHistoryLoadAnchorMinY, anchorY.isFinite else { return false }
        let capturedConversationID = conversationID
        DispatchQueue.main.async {
            guard conversationID == capturedConversationID,
                  oldestHistoryLoadAnchorID == anchorID,
                  conversation.messages.count == newCount,
                  !isAtBottom else { return }
            let viewportHeight = scrollMetricsMeasurements.metrics.viewportHeight
            guard viewportHeight.isFinite, viewportHeight > 0 else { return }
            // Align the same point in the 8pt anchor and the viewport.
            guard viewportHeight > 8 else { return }
            let anchorPoint = UnitPoint(x: 0.5, y: anchorY / (viewportHeight - 8))
            guard evaluateScrollRequest(source: .historyPrependCompensation, targetID: anchorID, anchor: anchorPoint, userInitiated: false) != .deny else { return }
            scrollToTargetWithoutAnimation(reader, targetID: historyAnchorID(for: anchorID), anchor: anchorPoint)
            // One accepted load may apply persisted and remote pages separately.
            // Both updates must retain the measured position, not nil -> top.
        }
        return true
    }

    private func scheduleProvisionalInitialBottomIfNeeded(_ reader: ScrollViewProxy, reason: String) {
        guard !didInitialScroll,
              !didScheduleInitialProvisionalBottom,
              !isUserBrowsingHistory,
              !conversation.messages.isEmpty else {
            return
        }
        guard !hasLastReadInitialAnchorForCurrentWindow else { return }
        guard !hasConfirmedLatestBottomForCurrentWindow else { return }
        didScheduleInitialProvisionalBottom = true
        logInitialAnchorDecision("schedule_provisional_bottom_\(reason)", targetID: latestBottomScrollTargetID, unreadCount: 0)
        let bottomScrollGeneration = nextAutomaticBottomScrollGeneration()
        DispatchQueue.main.async {
            let targetID = latestBottomScrollTargetID
            guard bottomScrollGeneration == automaticBottomScrollGeneration,
                  !didInitialScroll,
                  !isUserBrowsingHistory,
                  !isAutomaticBottomScrollSuppressed,
                  !conversation.messages.isEmpty else {
                return
            }
            guard scrollToTargetWithoutAnimation(reader, targetID: targetID, anchor: .bottom, source: .initialAnchor) else { return }
            rememberLatestBottomVisible()
            isAtBottom = true
            updateRealtimeAutoReadGate()
            logInitialAnchorDecision("provisional_bottom_\(reason)_applied", targetID: targetID, unreadCount: 0)
        }
    }

    private func rememberLatestBottomVisible(seq: Int64? = nil) {
        let targetSeq = seq ?? latestBottomTargetSeq
        guard targetSeq > 0, targetSeq > latestBottomConfirmedSeq else { return }
        latestBottomConfirmedSeq = targetSeq
        state.rememberConversationBottomSeq(targetSeq, for: conversationID)
    }

    private func resetScrollPositionState(force: Bool = false) {
        let currentSessionKey = state.activeConversationHistoryScope
        guard force || scrollStateConversationID != conversationID || scrollStateSessionKey != currentSessionKey else { return }
        readVisibilityEpoch &+= 1
        scrollStateConversationID = conversationID
        scrollStateSessionKey = currentSessionKey
        pendingUnreadCount = 0
        didInitialScroll = false
        capturedUnreadCount = 0
        didAutoScrollToUnreadAnchor = false
        initialUnreadSnapshot = nil
        initialUnreadAnchorLoadAttempts = 0
        unreadDividerVisible = false
        oldestHistoryLoadAnchorID = nil
        oldestHistoryLoadAnchorMinY = nil
        newestHistoryLoadAnchorSeq = 0
        didTriggerOlderHistoryLoadForScrollIntent = false
        transcriptScrollControl.reset()
        isApplyingInitialScroll = false
        isUserBrowsingHistory = false
        isAtBottom = false
        transcriptScrollControl.clearSuppression()
        pendingOwnSendScrollBaselineCount = nil
        didScrollTowardUnreadMessages = false
        isClearingUnreadReminder = false
        lastScrollVisibility = .initial
        scrollMetricsMeasurements.removeAll()
        messageTopMeasurements.removeAll()
        scrollTargetID = nil
        pendingScrollTargetSource = .searchJump
        pendingScrollTargetAnchor = .center
        pendingPinnedJumpMessage = nil
        focusedTimelineMessageGeneration += 1
        focusedTimelineMessageID = nil
        underfilledOlderAutofillAttempts = 0
        didInitialLatestWindowCatchupScroll = false
        didScheduleInitialProvisionalBottom = false
        didResolveReadStatusAnchorAfterSideData = false
        latestBottomConfirmedSeq = state.rememberedConversationBottomSeq(for: conversationID)
        didUserInteractWithMessageScroll = false
        lastVisibleReadAckToken = ""
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_RESET_RENDER_CACHE_TASK - 修改开始：切换会话时清理延迟刷新和旧消息触发节流状态
        messageRenderCacheRefreshTask?.cancel()
        messageRenderCacheRefreshTask = nil
        cachedMessageRowsRenderToken = .empty
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_RESET - 修改开始：切换会话时清理消息 timeline item 缓存
        cachedMessageRowsVersion = 0
        cachedMessageRowSignatureFingerprint = 0
        messageTimelineItemCache.reset()
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_RESET - 修改结束
        lastOlderHistoryLoadAttemptAt = .distantPast
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_RESET_RENDER_CACHE_TASK - 修改结束：切换会话时清理延迟刷新和旧消息触发节流状态
        updateRealtimeAutoReadGate()
    }

    private var isAutomaticBottomScrollSuppressed: Bool {
        transcriptScrollControl.isSuppressed(now: Date())
    }

    private var automaticBottomScrollGeneration: Int {
        transcriptScrollControl.generation
    }

    private var canApplyAutomaticBottomScroll: Bool {
        chatCanApplyAutomaticBottomScroll(
            isUserBrowsingHistory: isUserBrowsingHistory,
            isLoadingConversationHistory: isLoadingConversationHistory,
            isAutomaticBottomScrollSuppressed: isAutomaticBottomScrollSuppressed,
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isAtBottom: isAtBottom
        )
    }

    /// 进入会话的稳定窗口内(用户还没碰过滚动),即使历史同步仍在飞行中也允许
    /// 底部跟随。进入会话时的窗口同步会在 in-flight 标记清除前 apply 消息批,
    /// 若只依赖 canApplyAutomaticBottomScroll(要求 !isLoadingConversationHistory),
    /// 这批消息落地后的跟底会被静默跳过,表现为“点进会话不在最底部”。
    private var canApplyEntryStabilizationBottomScroll: Bool {
        isWithinChatEntryStabilizationWindow
            && !didUserInteractWithMessageScroll
            && !isUserBrowsingHistory
            && !isAutomaticBottomScrollSuppressed
    }

    private func nextAutomaticBottomScrollGeneration() -> Int {
        transcriptScrollControl.nextGeneration()
    }

    private var isWithinChatEntryStabilizationWindow: Bool {
        Date() < chatEntryStabilizationUntil
    }

    private func suppressAutomaticBottomScroll(reason: String) {
        transcriptScrollControl.suppress(now: Date(), interval: automaticBottomScrollSuppressionInterval)
        logInitialAnchorDecision("suppress_auto_bottom_\(reason)", targetID: bottomAnchorID, unreadCount: rawInitialUnreadCount())
    }

    private func logInitialAnchorDecision(_ event: String, targetID: String?, unreadCount: Int) {
        print("[JHT ChatAnchor] event=\(event) conversation=\(conversationID) target=\(targetID ?? "none") unread=\(unreadCount) message_count=\(conversation.messages.count) latest_loaded_seq=\(latestLoadedMessageSeq) last_msg_seq=\(conversation.lastMsgSeq) last_read_seq=\(conversation.lastReadSeq) first_unread_seq=\(conversation.firstUnreadSeq) confirmed_bottom_seq=\(latestBottomConfirmedSeq) did_initial_scroll=\(didInitialScroll) loading=\(isLoadingConversationHistory) attempts=\(initialUnreadAnchorLoadAttempts) user_interacted=\(didUserInteractWithMessageScroll) browsing=\(isUserBrowsingHistory) at_bottom=\(isAtBottom) auto_bottom_suppressed=\(isAutomaticBottomScrollSuppressed)")
    }

    private func clearUnreadReminderLocally(readToken: String) {
        let token = latestReadableIncomingMessageReadToken
        let resolvedToken = readToken.isEmpty ? token : readToken
        if !resolvedToken.isEmpty {
            lastVisibleReadAckToken = resolvedToken
        }
        pendingUnreadCount = 0
        capturedUnreadCount = 0
        initialUnreadSnapshot = 0
        unreadDividerVisible = false
        didAutoScrollToUnreadAnchor = false
        didScrollTowardUnreadMessages = false
    }

    private func clearUnreadReminderAndAckIfNeeded(reason: String) {
        guard didInitialScroll, !isApplyingInitialScroll else { return }
        guard hasUnreadReminder, let observation = visibleIncomingReadObservation else { return }
        guard !isClearingUnreadReminder else { return }
        let token = observation.token
        let scope = state.activeConversationHistoryScope
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        isClearingUnreadReminder = true
        state.markConversationRead(conversationID, throughSeq: observation.seq, showToast: false) { success in
            guard scope == state.activeConversationHistoryScope, targetConversationID == conversationID,
                  epoch == readVisibilityEpoch else { return }
            isClearingUnreadReminder = false
            if success, conversation.lastReadSeq >= observation.seq {
                if token == latestReadableIncomingMessageReadToken {
                    clearUnreadReminderLocally(readToken: token)
                } else {
                    markVisibleIncomingMessagesReadIfNeeded()
                }
            } else {
                if !token.isEmpty, lastVisibleReadAckToken == token {
                    lastVisibleReadAckToken = ""
                }
                if let message = chatReadSyncFailureToastMessage(isAutomaticRecoveryPath: true) {
                    state.toast = message
                }
            }
        }
    }

    private func markUnreadReminderReadIfUserScrolledTowardUnread() {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              didScrollTowardUnreadMessages,
              !isUserBrowsingHistory,
              !isReadOnlySystemConversation else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "scroll_toward_unread")
    }

    private func markUnreadReminderReadIfDividerPassed() {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              didScrollTowardUnreadMessages,
              !isUserBrowsingHistory,
              !isReadOnlySystemConversation else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "unread_divider_passed")
    }

    private func markUnreadReminderReadIfUnreadMessageVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation,
              let firstUnreadMessageID,
              let firstUnreadIndex = conversation.messages.firstIndex(where: { $0.id == firstUnreadMessageID }),
              let visibleIndex = conversation.messages.firstIndex(where: { $0.id == message.id }),
              visibleIndex >= firstUnreadIndex else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "unread_message_visible")
    }

    private func markUnreadReminderReadIfLatestIncomingVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation else {
            return
        }
        guard let latest = latestReadableIncomingMessage(), latest.id == message.id else { return }
        clearUnreadReminderAndAckIfNeeded(reason: "latest_incoming_visible")
    }

    private func markUnreadReminderReadIfBottomMessageVisible(_ message: ChatMessage) {
        guard didInitialScroll,
              !isApplyingInitialScroll,
              hasUnreadReminder,
              canClearUnreadReminderFromVisibleProgress,
              !isReadOnlySystemConversation,
              conversation.messages.last?.id == message.id else {
            return
        }
        clearUnreadReminderAndAckIfNeeded(reason: "bottom_message_visible")
    }

    private var canClearUnreadReminderFromVisibleProgress: Bool {
        chatCanClearUnreadReminderFromVisibleProgress(
            isUserBrowsingHistory: isUserBrowsingHistory,
            isAtBottom: isAtBottom,
            didScrollTowardUnreadMessages: didScrollTowardUnreadMessages
        )
    }

    private var visibleIncomingReadObservation: (token: String, seq: Int64)? {
        let metrics = scrollMetricsMeasurements.metrics
        guard let seq = chatVisibleIncomingReadSequence(
            metrics: metrics,
            row: scrollMetricsMeasurements.incomingRow,
            expectedToken: latestReadableIncomingMessageReadToken,
            epoch: readVisibilityEpoch,
            isActive: scenePhase == .active,
            scopeMatches: scrollStateConversationID == conversationID
                && scrollStateSessionKey == state.activeConversationHistoryScope
        ) else { return nil }
        return (metrics.renderedReadToken, seq)
    }

    private func markVisibleIncomingMessagesReadIfNeeded() {
        guard didInitialScroll, !isApplyingInitialScroll, !isUserBrowsingHistory, !isReadOnlySystemConversation,
              let observation = visibleIncomingReadObservation else { return }
        if hasUnreadReminder {
            guard canClearUnreadReminderFromVisibleProgress else { return }
            clearUnreadReminderAndAckIfNeeded(reason: "visible_incoming_with_reminder")
            return
        }
        let token = observation.token
        guard token != lastVisibleReadAckToken else { return }
        lastVisibleReadAckToken = token
        let scope = state.activeConversationHistoryScope
        let targetConversationID = conversationID
        let epoch = readVisibilityEpoch
        state.markConversationRead(conversationID, throughSeq: observation.seq, showToast: false) { success in
            guard scope == state.activeConversationHistoryScope, targetConversationID == conversationID,
                  epoch == readVisibilityEpoch else { return }
            if (!success || conversation.lastReadSeq < observation.seq), lastVisibleReadAckToken == token {
                lastVisibleReadAckToken = ""
            }
        }
    }

    private func latestReadableIncomingMessage() -> ChatMessage? {
        conversation.messages.last { message in
            guard message.kind != .system,
                  message.status != .recalled,
                  !message.isDeletedLocally,
                  !isMessageAuthoredByCurrentUser(message) else {
                return false
            }
            return message.channelSeq > 0 || !message.id.isEmpty
        }
    }

    private func updateRealtimeAutoReadGate() {
        // Receipt of the next WS message is not proof that its row is visible.
        // The measured viewport now owns read advancement for this chat.
        state.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
    }

    private static func formatMessageTime(_ date: Date, format: String) -> String {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_TIME_FORMATTER_POOL - 修改开始：复用消息时间格式化器，减少历史批量插入时的主线程开销
        return ChatMessageDateFormatterPool.string(from: date, format: format)
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_TIME_FORMATTER_POOL - 修改结束：复用消息时间格式化器，减少历史批量插入时的主线程开销
    }
}

// JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_TIME_FORMATTER_POOL_MODEL - 修改开始：消息时间格式化器缓存池
private enum ChatMessageDateFormatterPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = formatters[format] ?? {
            let value = DateFormatter()
            value.locale = Locale(identifier: "zh_CN")
            value.dateFormat = format
            formatters[format] = value
            return value
        }()
        return formatter.string(from: date)
    }
}
// JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_TIME_FORMATTER_POOL_MODEL - 修改结束：消息时间格式化器缓存池

struct BiometricProtectedContentGate: View {
    let symbol: String
    let title: String
    let subtitle: String
    let authenticate: () async -> Void
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                Text(title)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(
                    title: isAuthenticating ? "正在验证" : "使用 Face ID 解锁",
                    systemImage: "faceid",
                    disabled: isAuthenticating
                ) {
                    guard !isAuthenticating else { return }
                    isAuthenticating = true
                    Task {
                        await authenticate()
                        await MainActor.run { isAuthenticating = false }
                    }
                }
                .frame(maxWidth: 300)
            }
            .padding(24)
        }
    }
}

private struct ChatMessageLazyLeaf<Content: View>: View {
    let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
    }
}

private struct ChatMessageTimelineItem: Identifiable {
    enum Kind {
        case timeSeparator(String)
        case unreadDivider(Int)
        case historyAnchor
        case message
        case spacing
    }

    let id: String
    let row: ChatMessageRenderRow
    let kind: Kind

    var isSpacing: Bool {
        switch kind {
        case .historyAnchor, .spacing: return true
        default: return false
        }
    }
}

private struct ChatMessageRenderRow: Identifiable {
    let index: Int
    let message: ChatMessage
    let showsSenderHeader: Bool
    let senderUser: IMUser?
    let displaySenderName: String
    let timeSeparatorText: String?

    var id: String { message.id }
}

// JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：消息行缓存结构化签名，避免 body 重绘时拼接大量字符串
private struct ChatMessageRowCacheSignature: Equatable, Hashable {
    let id: String
    let senderID: String
    let senderName: String
    let text: String
    let contentType: String
    let rtcCallID: String
    let rtcCallOutcome: String
    let rtcCallType: String
    let stickerCacheIdentity: String
    let visibleReplyQuote: String
    let replyContextID: String
    let replyContextThumbnailURL: String
    let replyUnavailable: Bool
    let status: MessageDelivery
    let time: String
    let createdAtSeconds: Int64?
    let readCount: Int?
    let isPinned: Bool
    let isDeletedLocally: Bool
    let isEdited: Bool
}
// JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

// JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_MODEL - 修改开始：缓存已展开的消息时间线 item，降低输入/键盘重绘分配
private struct ChatMessageRenderRowsSnapshot {
    let rows: [ChatMessageRenderRow]
    let conversationID: String
    let version: Int
    let fingerprint: Int

    var count: Int { rows.count }
    var firstID: String { rows.first?.id ?? "" }
    var lastID: String { rows.last?.id ?? "" }
}

private struct ChatMessageTimelineItemCacheKey: Equatable {
    let conversationID: String
    let rowVersion: Int
    let rowFingerprint: Int
    let rowCount: Int
    let firstRowID: String
    let lastRowID: String
    let unreadID: String
    let unreadCount: Int
}

private final class ChatMessageTimelineItemCache: ObservableObject {
    private var key: ChatMessageTimelineItemCacheKey?
    private var cachedItems: [ChatMessageTimelineItem] = []

    func items(
        conversationID: String,
        snapshot: ChatMessageRenderRowsSnapshot,
        unreadID: String?,
        unreadCount: Int,
        build: () -> [ChatMessageTimelineItem]
    ) -> [ChatMessageTimelineItem] {
        let nextKey = ChatMessageTimelineItemCacheKey(
            conversationID: conversationID,
            rowVersion: snapshot.version,
            rowFingerprint: snapshot.fingerprint,
            rowCount: snapshot.count,
            firstRowID: snapshot.firstID,
            lastRowID: snapshot.lastID,
            unreadID: unreadID ?? "",
            unreadCount: unreadCount
        )
        guard key != nextKey else { return cachedItems }
        let items = build()
        key = nextKey
        cachedItems = items
        return items
    }

    func reset() {
        key = nil
        cachedItems.removeAll(keepingCapacity: true)
    }
}
// JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_ITEM_CACHE_MODEL - 修改结束

// JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_RENDER_CHANGE_TOKEN_MODEL - 修改开始：消息渲染变化的轻量比较模型
private struct ChatMessageRenderChangeToken: Equatable {
    let count: Int
    let firstID: String
    let lastID: String
    let firstSeq: Int64
    let lastSeq: Int64
    let aggregateHash: Int

    static let empty = ChatMessageRenderChangeToken(
        count: 0,
        firstID: "",
        lastID: "",
        firstSeq: 0,
        lastSeq: 0,
        aggregateHash: 0
    )
}
// JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_RENDER_CHANGE_TOKEN_MODEL - 修改结束：消息渲染变化的轻量比较模型

private struct ChatScrollMetricsPreferenceKey: PreferenceKey {
    static var defaultValue: ChatScrollMetricsSnapshot { .zero }

    static func reduce(value: inout ChatScrollMetricsSnapshot, nextValue: () -> ChatScrollMetricsSnapshot) {
        let next = nextValue()
        if next.isValid {
            value = next
        }
    }
}

private struct ChatIncomingRowPreferenceKey: PreferenceKey {
    static var defaultValue: ChatIncomingRowGeometry { .empty }
    static func reduce(value: inout ChatIncomingRowGeometry, nextValue: () -> ChatIncomingRowGeometry) {
        let next = nextValue()
        if !next.token.isEmpty { value = next }
    }
}

private struct ChatMessageTopPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct MessageSenderResolver {
    let currentUser: IMUser
    let enterpriseName: String
    let contactRemarks: [String: String]
    private let usersByKey: [String: IMUser]
    private let groupNamesByKey: [String: String]

    init(
        currentUser: IMUser,
        enterpriseName: String,
        conversation: Conversation,
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
            let projectedName = GroupMemberDisplayNameResolver.projectedName(for: user)
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

    func senderUser(for message: ChatMessage) -> IMUser? {
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

    func displaySenderName(for message: ChatMessage, resolvedUser: IMUser?) -> String {
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

    static func fallbackUser(for message: ChatMessage, displayName: String, enterpriseName: String) -> IMUser? {
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

private func isIdentifierLikeSenderName(_ name: String, senderID: String) -> Bool {
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

private struct ChatBackButtonBadge: View {
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
}

enum ChatSearchDismissalIntent: Equatable {
    case close
    case selectResult
}

enum ChatSearchDismissalEffect: Equatable {
    case none
    case releaseFocus
    case dismissPanel
}

struct ChatSearchDismissalCoordinator: Equatable {
    private(set) var pendingIntent: ChatSearchDismissalIntent?

    mutating func request(
        _ intent: ChatSearchDismissalIntent,
        isFocused: Bool
    ) -> ChatSearchDismissalEffect {
        guard pendingIntent == nil else { return .none }
        pendingIntent = intent
        return isFocused ? .releaseFocus : .dismissPanel
    }

    mutating func focusDidChange(isFocused: Bool) -> ChatSearchDismissalEffect {
        guard pendingIntent != nil, !isFocused else { return .none }
        return .dismissPanel
    }

    mutating func consumePendingIntent() -> ChatSearchDismissalIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }
}

private struct ChatHistorySearchPanel: View {
    @Binding var keyword: String
    @Binding var dateText: String
    let results: [RemoteTenantSearchResult]
    let total: Int
    let hitChannelSeqs: [Int64]
    let isSearching: Bool
    let isLoadingMore: Bool
    let hasMore: Bool
    let searchFocus: FocusState<Bool>.Binding
    let onSearch: () -> Void
    let onDateSearch: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLoadMore: () -> Void
    let onClose: () -> Void
    let onSelect: (RemoteTenantSearchResult) -> Void
    let onQueryChange: () -> Void
    @State private var showDatePicker = false
    @State private var selectedDate = Date()

    private var trimmedDateText: String {
        dateText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedDateLabel: String {
        guard let date = chatSearchDate(from: trimmedDateText) else {
            return "按日期跳转"
        }
        return chatSearchDisplayDate(date)
    }

    private var selectedDateSubtitle: String {
        trimmedDateText.isEmpty ? "选择某天的聊天记录" : trimmedDateText
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                TextField("搜索历史聊天记录", text: $keyword)
                    .font(.system(size: 14, weight: .semibold))
                    .submitLabel(.search)
                    .focused(searchFocus)
                    .imReadableInputText()
                    .onSubmit(onSearch)
                    .onChangeCompat(of: keyword) { _, _ in
                        onQueryChange()
                    }
                    .accessibilityIdentifier("chat_search_input")
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IMColor.muted.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.brand)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.brand.opacity(0.10)))
                }
                .disabled(isSearching)
                .accessibilityIdentifier("chat_search_submit_button")
                Button(action: onClose) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.page.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat_search_close_button")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.96)))

            HStack(spacing: 8) {
                Button {
                    selectedDate = chatSearchDate(from: trimmedDateText) ?? Date()
                    searchFocus.wrappedValue = false
                    showDatePicker = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(IMColor.brand.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDateLabel)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(IMColor.ink)
                                .lineLimit(1)
                            Text(selectedDateSubtitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(trimmedDateText.isEmpty ? IMColor.muted : IMColor.brand)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(IMColor.muted)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .frame(height: 38)
                    .background(Capsule().fill(.white.opacity(0.92)))
                    .overlay(Capsule().stroke(trimmedDateText.isEmpty ? IMColor.line : IMColor.brand.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isSearching)
                .accessibilityIdentifier("chat_search_date_picker_button")

                Button(action: onDateSearch) {
                    Text("跳转")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(trimmedDateText.isEmpty ? IMColor.muted.opacity(0.45) : IMColor.brand))
                }
                .buttonStyle(.plain)
                .disabled(isSearching || trimmedDateText.isEmpty)
                .accessibilityIdentifier("chat_search_date_jump_button")
                Spacer(minLength: 8)
                if total > 0 || !hitChannelSeqs.isEmpty {
                    Text("共 \(max(total, results.count)) 条")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .monospacedDigit()
                }
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.88)))
                }
                .buttonStyle(.plain)
                .disabled(results.isEmpty)
                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.88)))
                }
                .buttonStyle(.plain)
                .disabled(results.isEmpty)
            }
            .padding(.horizontal, 2)

            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(IMColor.brand)
                    Text("正在搜索聊天记录")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if !results.isEmpty {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(results, id: \.id) { hit in
                            Button {
                                onSelect(hit)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(hit.type == "file" || hit.type == "files" ? "文件" : "聊天记录")
                                            .font(.system(size: 11, weight: .black))
                                            .foregroundStyle(IMColor.muted)
                                            .lineLimit(1)
                                        ChatSearchHighlightedText(
                                            text: hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (hit.snippet ?? "") : hit.title,
                                            ranges: hit.highlightRanges,
                                            field: hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "snippet" : "title",
                                            font: .system(size: 13, weight: .bold),
                                            color: IMColor.ink
                                        )
                                    }
                                    Spacer(minLength: 8)
                                    Text(hit.subtitle ?? "")
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundStyle(IMColor.muted)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat_search_result_\(hit.type)_\(hit.resultID)")
                            .accessibilityLabel("聊天搜索结果 \(hit.title)")
                        }
                        if hasMore {
                            Button(action: onLoadMore) {
                                HStack(spacing: 8) {
                                    if isLoadingMore {
                                        ProgressView()
                                            .tint(IMColor.brand)
                                    }
                                    Text(isLoadingMore ? "正在加载" : "加载更多")
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(IMColor.brand)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 238)
            } else if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !dateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("输入关键词后点击搜索，命中记录会在这里按时间展示")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.78), lineWidth: 1))
        )
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocus.wrappedValue = true
            selectedDate = chatSearchDate(from: trimmedDateText) ?? Date()
            if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onQueryChange()
            }
        }
        .sheet(isPresented: $showDatePicker) {
            ChatSearchDatePickerSheet(
                selectedDate: $selectedDate,
                currentDateText: dateText,
                onCancel: {
                    showDatePicker = false
                },
                onClear: {
                    dateText = ""
                    showDatePicker = false
                },
                onApply: { date in
                    dateText = chatSearchAPIDate(date)
                    showDatePicker = false
                    onDateSearch()
                }
            )
            .presentationDetentsCompat([.height(520)])
            .presentationDragIndicatorCompat(.hidden)
        }
    }

}

private struct ChatSearchDatePickerSheet: View {
    @Binding var selectedDate: Date
    let currentDateText: String
    let onCancel: () -> Void
    let onClear: () -> Void
    let onApply: (Date) -> Void
    @State private var visibleMonth = ChatSearchCalendarSupport.startOfMonth(Date())

    private var hasCurrentDate: Bool {
        !currentDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择聊天日期")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("跳转到某一天附近的聊天记录")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.white.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                }

                ChatSearchGregorianCalendarView(
                    selectedDate: $selectedDate,
                    visibleMonth: $visibleMonth,
                    maximumDate: Date()
                )

                HStack(spacing: 8) {
                    quickDateButton(title: "今天", date: Date())
                    quickDateButton(title: "昨天", date: ChatSearchCalendarSupport.addingDays(-1, to: Date()))
                    Button(action: onClear) {
                        Text("清空")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(hasCurrentDate ? IMColor.danger : IMColor.muted)
                            .frame(height: 36)
                            .padding(.horizontal, 14)
                            .background(Capsule().fill(.white.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasCurrentDate)
                }

                Button {
                    onApply(selectedDate)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.message.fill")
                            .font(.system(size: 13, weight: .black))
                        Text("跳转到 \(chatSearchDisplayDate(selectedDate))")
                            .font(.system(size: 15, weight: .black))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .onAppear {
            visibleMonth = ChatSearchCalendarSupport.startOfMonth(selectedDate)
        }
        .onChangeCompat(of: selectedDate) { _, newValue in
            visibleMonth = ChatSearchCalendarSupport.startOfMonth(newValue)
        }
    }

    private func quickDateButton(title: String, date: Date) -> some View {
        let isSelected = ChatSearchCalendarSupport.isSameDay(selectedDate, date)
        return Button {
            selectedDate = date
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(isSelected ? .white : IMColor.brand)
                .frame(height: 36)
                .padding(.horizontal, 14)
                .background(Capsule().fill(isSelected ? IMColor.brand : IMColor.brand.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

private struct ChatSearchGregorianCalendarView: View {
    @Binding var selectedDate: Date
    @Binding var visibleMonth: Date
    let maximumDate: Date

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var cells: [ChatSearchCalendarDay] {
        ChatSearchCalendarSupport.dayCells(
            for: visibleMonth,
            selectedDate: selectedDate,
            today: maximumDate
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text(ChatSearchCalendarSupport.monthTitle(for: visibleMonth))
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Spacer()
                Button {
                    visibleMonth = ChatSearchCalendarSupport.addingMonths(-1, to: visibleMonth)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(IMColor.page.opacity(0.82)))
                }
                .buttonStyle(.plain)

                Button {
                    visibleMonth = ChatSearchCalendarSupport.addingMonths(1, to: visibleMonth)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(ChatSearchCalendarSupport.canMoveToNextMonth(from: visibleMonth, maximumDate: maximumDate) ? IMColor.ink : IMColor.muted.opacity(0.45))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(IMColor.page.opacity(0.82)))
                }
                .buttonStyle(.plain)
                .disabled(!ChatSearchCalendarSupport.canMoveToNextMonth(from: visibleMonth, maximumDate: maximumDate))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ChatSearchCalendarSupport.weekdaySymbols, id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                }

                ForEach(cells) { cell in
                    Button {
                        selectedDate = cell.date
                        if !cell.isInDisplayedMonth {
                            visibleMonth = ChatSearchCalendarSupport.startOfMonth(cell.date)
                        }
                    } label: {
                        Text("\(cell.day)")
                            .font(.system(size: 17, weight: cell.isSelected ? .black : .semibold))
                            .foregroundStyle(dayForeground(cell))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                Circle()
                                    .fill(cell.isSelected ? IMColor.brand : Color.clear)
                                    .frame(width: 36, height: 36)
                            )
                            .overlay(
                                Circle()
                                    .stroke(cell.isToday && !cell.isSelected ? IMColor.brand.opacity(0.35) : Color.clear, lineWidth: 1.2)
                                    .frame(width: 36, height: 36)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(cell.isFuture)
                    .opacity(cell.isFuture ? 0.38 : 1)
                    .accessibilityLabel("\(ChatSearchCalendarSupport.displayDate(cell.date))")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.88), lineWidth: 1))
        .accessibilityIdentifier("chat_search_gregorian_calendar")
    }

    private func dayForeground(_ cell: ChatSearchCalendarDay) -> Color {
        if cell.isSelected {
            return .white
        }
        if !cell.isInDisplayedMonth {
            return IMColor.muted.opacity(0.42)
        }
        if cell.isToday {
            return IMColor.brand
        }
        return IMColor.ink
    }
}

struct ChatSearchCalendarDay: Identifiable, Equatable {
    let id: String
    let date: Date
    let day: Int
    let isInDisplayedMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool
}

enum ChatSearchCalendarSupport {
    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? startOfDay(date)
    }

    static func addingDays(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: value, to: date) ?? date
    }

    static func addingMonths(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: value, to: startOfMonth(date)) ?? date
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func monthTitle(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 1970)年\(components.month ?? 1)月"
    }

    static func apiDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    static func displayDate(_ date: Date) -> String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let components = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekday = weekdays[max(0, min((components.weekday ?? 1) - 1, weekdays.count - 1))]
        return "\(components.month ?? 1)月\(components.day ?? 1)日 \(weekday)"
    }

    static func canMoveToNextMonth(from month: Date, maximumDate: Date) -> Bool {
        let nextMonth = addingMonths(1, to: month)
        return calendar.compare(nextMonth, to: startOfMonth(maximumDate), toGranularity: .month) != .orderedDescending
    }

    static func dayCells(for displayedMonth: Date, selectedDate: Date, today: Date) -> [ChatSearchCalendarDay] {
        let monthStart = startOfMonth(displayedMonth)
        let monthComponents = calendar.dateComponents([.year, .month], from: monthStart)
        let leadingDays = max(0, calendar.component(.weekday, from: monthStart) - 1)
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        let todayStart = startOfDay(today)

        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: gridStart) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            let dayStart = startOfDay(date)
            let isInDisplayedMonth = components.year == monthComponents.year && components.month == monthComponents.month
            return ChatSearchCalendarDay(
                id: apiDate(date),
                date: date,
                day: components.day ?? 1,
                isInDisplayedMonth: isInDisplayedMonth,
                isSelected: isSameDay(date, selectedDate),
                isToday: isSameDay(date, today),
                isFuture: calendar.compare(dayStart, to: todayStart, toGranularity: .day) == .orderedDescending
            )
        }
    }
}

private func chatSearchDate(from text: String) -> Date? {
    let parts = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "-")
        .compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = DateComponents(calendar: calendar, timeZone: .current, year: parts[0], month: parts[1], day: parts[2])
    guard let date = components.date else { return nil }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    guard resolved.year == parts[0], resolved.month == parts[1], resolved.day == parts[2] else { return nil }
    return date
}

private func chatSearchAPIDate(_ date: Date) -> String {
    ChatSearchCalendarSupport.apiDate(date)
}

private func chatSearchDisplayDate(_ date: Date) -> String {
    ChatSearchCalendarSupport.displayDate(date)
}

private struct ChatSearchHighlightedText: View {
    let text: String
    let ranges: [RemoteTenantSearchHighlightRange]
    let field: String
    let font: Font
    let color: Color

    var body: some View {
        highlightedText
            .font(font)
            .lineLimit(1)
    }

    private var highlightedText: Text {
        let filteredRanges = ranges
            .filter { $0.field == field && $0.length > 0 }
            .sorted { $0.start < $1.start }
        guard !filteredRanges.isEmpty else {
            return Text(text).foregroundColor(color)
        }
        let characters = Array(text)
        var cursor = 0
        var rendered = Text("")
        for range in filteredRanges {
            let start = min(max(range.start, 0), characters.count)
            let end = min(max(start + range.length, start), characters.count)
            guard end > start else { continue }
            if start > cursor {
                rendered = rendered + Text(String(characters[cursor..<start])).foregroundColor(color)
            }
            rendered = rendered + Text(String(characters[start..<end])).foregroundColor(IMColor.brand)
            cursor = max(cursor, end)
        }
        if cursor < characters.count {
            rendered = rendered + Text(String(characters[cursor..<characters.count])).foregroundColor(color)
        }
        return rendered
    }
}

private struct TimelinePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(IMColor.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.76)))
    }
}

private struct ChatHistoryStatusPill: View {
    let text: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.72)
                    .tint(IMColor.brand)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(isLoading ? IMColor.brand : IMColor.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.84)))
        .padding(.horizontal, 18)
    }
}

private struct DirectChatEmptyHistoryView: View {
    let title: String
    let subtitle: String
    let retryTitle: String?
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 54, height: 54)
                .background(Circle().fill(IMColor.brand.opacity(0.10)))
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            if let retryTitle {
                Button(action: retry) {
                    Label(retryTitle, systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(IMColor.brand)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(IMColor.brand.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("direct_chat_history_retry_button")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.84))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
        )
        .accessibilityIdentifier("direct_chat_empty_history_state")
    }
}

private struct NewMessagesDivider: View {
    let count: Int
    private var displayCountText: String {
        UnreadBadgeFormatter.text(count) ?? "0"
    }

    var body: some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(IMColor.brand.opacity(0.16))
                .frame(height: 1)
            Text("\(displayCountText) 条新消息")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.brand)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.86)))
            Rectangle()
                .fill(IMColor.brand.opacity(0.16))
                .frame(height: 1)
        }
        .padding(.vertical, 3)
    }
}

private struct MessageTimeSeparator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(IMColor.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(.white.opacity(0.72))
                    .overlay(Capsule().stroke(IMColor.line.opacity(0.65), lineWidth: 1))
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .allowsHitTesting(false)
            .accessibilityLabel("消息时间 \(text)")
    }
}

private struct ReturnToBottomBar: View {
    let count: Int
    let action: () -> Void
    private var displayCountText: String {
        UnreadBadgeFormatter.text(count) ?? "0"
    }

    private var messageSummary: String {
        count > 0 ? "\(displayCountText) 条新消息" : "消息记录"
    }

    private var accessibilityTitle: String {
        count > 0 ? "\(displayCountText) 条新消息，回到底部" : "回到底部"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text(messageSummary)
                    .lineLimit(2)
                Spacer()
                Text("回到底部")
                    .lineLimit(1)
            }
            .font(.callout.weight(.bold))
            .foregroundStyle(IMColor.brand)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(IMColor.brand.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: IMColor.brand.opacity(0.10), radius: 12, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat_return_to_bottom_button")
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("平滑滚动到聊天记录底部")
    }
}

private struct PinnedMessagesSheet: View {
    let messages: [ChatMessage]
    let onSelect: (ChatMessage) -> Void
    let onUnpin: (ChatMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState

    private func displaySenderName(for message: ChatMessage) -> String {
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
        )
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetHeader(symbol: "pin.fill", title: "置顶消息", subtitle: "点击任意置顶消息后返回会话并定位到原消息。", showsCloseButton: true)
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "pin.slash")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(IMColor.muted.opacity(0.10)))
                                Text("暂无置顶消息")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("群主或管理员置顶消息后，会在这里集中查看和定位。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .plainCard(radius: 22)
                        }
                        ForEach(messages) { message in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    dismiss()
                                    onSelect(message)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: message.kind == .file ? "doc.richtext.fill" : (message.kind == .contactCard ? "person.crop.rectangle" : "text.bubble.fill"))
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(IMColor.warning)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(IMColor.warning.opacity(0.12)))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(message.kind == .file || message.kind == .contactCard ? (message.attachmentName ?? message.text) : message.text)
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.ink)
                                                .lineLimit(2)
                                            Text("\(displaySenderName(for: message)) · \(message.time)")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.to.line.compact")
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundStyle(IMColor.muted)
                                    }
                                }
                                .buttonStyle(.plain)
                                Button {
                                    onUnpin(message)
                                } label: {
                                    Image(systemName: "pin.slash.fill")
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(IMColor.warning)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(IMColor.warning.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("取消置顶")
                            }
                            .plainCard(radius: 20)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct GroupAnnouncementSheet: View {
    let group: GroupInfo
    let announcementID: String?
    let onClose: (() -> Void)?
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showPublisher = false
    @State private var didRunCloseAction = false

    init(group: GroupInfo, announcementID: String? = nil, onClose: (() -> Void)? = nil) {
        self.group = group
        self.announcementID = announcementID
        self.onClose = onClose
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var announcements: [GroupAnnouncement] {
        state.announcements(for: group.id)
    }

    private var currentAnnouncement: GroupAnnouncement? {
        if let announcementID {
            return announcements.first { $0.id == announcementID }
        }
        return announcements.first
    }

    private var canPublish: Bool {
        state.canManageGroup(currentGroup)
    }

    private var publisherName: String {
        if let createdBy = currentAnnouncement?.createdBy, !createdBy.isEmpty {
            return createdBy
        }
        return currentGroup.owner.isEmpty ? "群管理员" : currentGroup.owner
    }

    private var announcementTime: String {
        if let publishedAt = currentAnnouncement?.publishedAt, !publishedAt.isEmpty {
            return publishedAt
        }
        return currentAnnouncement?.createdAt.isEmpty == false ? currentAnnouncement!.createdAt : "刚刚"
    }

    private var displayContent: String {
        groupAnnouncementDisplayContent(
            content: currentAnnouncement?.content,
            summary: currentAnnouncement?.summary,
            groupNotice: currentGroup.notice
        )
    }

    private var hasVisibleAnnouncementContent: Bool {
        groupAnnouncementHasVisibleContent(
            content: currentAnnouncement?.content,
            summary: currentAnnouncement?.summary,
            groupNotice: currentGroup.notice
        )
    }

    private var displayTitle: String {
        let title = currentAnnouncement?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "群公告" : title
    }

    private func closeSheet() {
        if !didRunCloseAction {
            didRunCloseAction = true
            onClose?()
        }
        dismiss()
    }

    var body: some View {
        Group {
            if showPublisher {
                GroupAnnouncementEditorSheet(
                    group: currentGroup,
                    existingAnnouncement: currentAnnouncement,
                    dismissAfterPublish: false,
                    onCancel: {
                        showPublisher = false
                    },
                    onPublished: {
                        showPublisher = false
                        if let announcementID = currentAnnouncement?.id {
                            state.loadGroupAnnouncementDetail(groupID: group.id, announcementID: announcementID)
                        }
                    }
                )
                .environmentObject(state)
            } else {
                NavigationStackCompat {
                    ZStack {
                        AuroraBackground()
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "megaphone.fill")
                                            .font(.system(size: 20, weight: .black))
                                            .foregroundStyle(.white)
                                            .frame(width: 48, height: 48)
                                            .background(
                                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                                    .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            )
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("群公告")
                                                .font(.system(size: 24, weight: .black))
                                                .foregroundStyle(IMColor.ink)
                                            Text(currentGroup.name)
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        if hasVisibleAnnouncementContent {
                                            StatusPill(title: "当前有效", color: IMColor.success)
                                        }
                                        Button {
                                            closeSheet()
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 13, weight: .black))
                                                .foregroundStyle(IMColor.muted)
                                                .frame(width: 34, height: 34)
                                                .background(Circle().fill(.white.opacity(0.86)))
                                                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("关闭")
                                    }

                                    if hasVisibleAnnouncementContent {
                                        HStack(spacing: 8) {
                                            Label("发布人 \(publisherName)", systemImage: "person.crop.circle.fill")
                                            Label(announcementTime, systemImage: "clock.fill")
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(IMColor.muted)
                                    }
                                }
                                .glassCard(radius: 28)

                                if hasVisibleAnnouncementContent {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(displayTitle)
                                            .font(.system(size: 20, weight: .black))
                                            .foregroundStyle(IMColor.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Divider()
                                            .overlay(IMColor.line)
                                        Text(displayContent)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(IMColor.ink)
                                            .lineSpacing(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .plainCard(radius: 24)

                                    if let readCountSummary = currentAnnouncement?.readCountSummary {
                                        Label(readCountSummary, systemImage: "chart.bar.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(IMColor.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(12)
                                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.07)))
                                            .accessibilityIdentifier("group_announcement_read_counts")
                                    }
                                } else {
                                    EmptyStateView(
                                        symbol: "megaphone",
                                        title: "暂无群公告",
                                        subtitle: canPublish ? "发布后会同步给群成员。" : "群管理员发布后会显示在这里。"
                                    )
                                    .plainCard(radius: 24)
                                }

                                HStack(spacing: 10) {
                                    if hasVisibleAnnouncementContent {
                                        Button {
                                            UIPasteboard.general.string = displayContent
                                            state.toast = "群公告已复制"
                                        } label: {
                                            Label("复制公告", systemImage: "doc.on.doc.fill")
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.brand)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 48)
                                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if canPublish {
                                        Button {
                                            showPublisher = true
                                        } label: {
                                            Label(currentAnnouncement == nil ? "发布公告" : "编辑公告", systemImage: "megaphone.fill")
                                                .font(.system(size: 14, weight: .black))
                                                .foregroundStyle(IMColor.brand)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 48)
                                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    PrimaryButton(title: "我知道了", systemImage: "checkmark") {
                                        closeSheet()
                                    }
                                }
                            }
                            .padding(18)
                        }
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .presentationDragIndicatorCompat(.visible)
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
            if let announcementID = currentAnnouncement?.id {
                state.loadGroupAnnouncementDetail(groupID: group.id, announcementID: announcementID)
            }
        }
        .onDisappear {
            if !didRunCloseAction {
                didRunCloseAction = true
                onClose?()
            }
        }
	    }
	}

private struct GroupAnnouncementEditorSheet: View {
    let group: GroupInfo
    let existingAnnouncement: GroupAnnouncement?
    var dismissAfterPublish: Bool = true
    var onCancel: (() -> Void)? = nil
    var onPublished: (() -> Void)? = nil

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle: String
    @State private var draftContent: String
    @State private var isPublishing = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case content
    }

    init(
        group: GroupInfo,
        existingAnnouncement: GroupAnnouncement? = nil,
        dismissAfterPublish: Bool = true,
        onCancel: (() -> Void)? = nil,
        onPublished: (() -> Void)? = nil
    ) {
        self.group = group
        self.existingAnnouncement = existingAnnouncement
        self.dismissAfterPublish = dismissAfterPublish
        self.onCancel = onCancel
        self.onPublished = onPublished
        _draftTitle = State(initialValue: existingAnnouncement?.title ?? "群公告")
        _draftContent = State(initialValue: existingAnnouncement?.content ?? "")
    }

    private var isEditing: Bool { existingAnnouncement != nil }

    private var trimmedTitle: String {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "群公告" : title
    }

    private var trimmedContent: String {
        draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var publishDisabled: Bool {
        isPublishing || trimmedContent.isEmpty
    }

    private func publish() {
        guard !isPublishing else { return }
        guard !trimmedContent.isEmpty else {
            state.toast = "请输入公告内容"
            focusedField = .content
            return
        }
        isPublishing = true
        state.saveGroupAnnouncement(
            groupID: group.id,
            announcementID: existingAnnouncement?.id,
            expectedUpdatedAt: existingAnnouncement?.updatedAt,
            title: trimmedTitle,
            content: trimmedContent
        ) { success in
            isPublishing = false
            guard success else { return }
            onPublished?()
            if dismissAfterPublish {
                dismiss()
            }
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                            VStack(alignment: .leading, spacing: 5) {
                                Text(isEditing ? "编辑公告" : "发布公告")
                                    .font(.system(size: 24, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text(group.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                        }
                        .glassCard(radius: 28)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("公告标题")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            TextField("公告标题", text: $draftTitle)
                                .focused($focusedField, equals: .title)
                                .font(.system(size: 16, weight: .bold))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .imReadableInputText()
                                .padding(.horizontal, 14)
                                .frame(height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.white)
                                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                                )
                        }
                        .plainCard(radius: 24)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("公告内容", systemImage: "text.alignleft")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Spacer()
                                Text("\(draftContent.count) 字")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .monospacedDigit()
                            }

                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $draftContent)
                                    .focused($focusedField, equals: .content)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(IMColor.ink)
                                    .scrollContentBackgroundHiddenCompat()
                                    .frame(minHeight: 180)
                                    .padding(10)
                                    .background(.white)
                                if trimmedContent.isEmpty {
                                    Text("请输入公告内容，发布后成员将在群内看到最新公告")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(IMColor.muted.opacity(0.72))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }
                            }
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(focusedField == .content ? IMColor.brand.opacity(0.42) : IMColor.line, lineWidth: 1.2)
                            )
                        }
                        .plainCard(radius: 24)

                        PrimaryButton(
                            title: isPublishing ? "保存中..." : (isEditing ? "保存公告" : "发布公告"),
                            systemImage: "paperplane.fill",
                            disabled: publishDisabled,
                            action: publish
                        )
                    }
                    .padding(18)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPublishing ? "保存中" : (isEditing ? "保存" : "发布")) {
                        publish()
                    }
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(publishDisabled ? IMColor.muted : IMColor.brand)
                    .disabled(publishDisabled)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                focusedField = .content
            }
        }
    }
}

private func visibleReplyQuote(for message: ChatMessage) -> String? {
    let rawQuote = message.quote ?? message.replyContext?.quoteText
    let quote = rawQuote?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return quote?.isEmpty == false ? quote : nil
}

@MainActor
private func resolvedVisibleReplyPresentation(
    for message: ChatMessage,
    conversation: Conversation,
    state: AppState
) -> (quote: String, context: MessageReplyContext?)? {
    guard let fallbackQuote = visibleReplyQuote(for: message) else { return nil }
    guard var context = message.replyContext else {
        return (fallbackQuote, nil)
    }
    let sourceMessageID = context.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = conversation.messages.first { candidate in
        if !sourceMessageID.isEmpty, candidate.id == sourceMessageID {
            return true
        }
        return context.channelSeq > 0 && candidate.channelSeq == context.channelSeq
    }
    guard let source else {
        return (fallbackQuote, context)
    }
    let sourceUnavailable = source.status == .recalled || source.isDeletedLocally
    context.isUnavailable = sourceUnavailable
    context.summary = sourceUnavailable
        ? "原消息不可见/已删除"
        : resolvedReplySummary(for: source, state: state)
    context.contentType = source.contentType.isEmpty ? source.kind.rawValue : source.contentType
    if context.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        context.senderName = source.senderName
    }
    if source.isStickerMessage {
        context.thumbnailURL = source.stickerSnapshot?.thumbnailURL ?? context.thumbnailURL
    }
    return (context.quoteText, context)
}

@MainActor
private func resolvedReplySummary(for message: ChatMessage, state: AppState) -> String {
    switch message.kind {
    case .rtcCallRecord:
        return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
            ?? "[通话记录]"
    case .image:
        return "[图片]"
    case .file:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        switch state.attachmentMediaCategory(for: message) {
        case "video":
            return "[视频]"
        case "audio":
            return name.isEmpty ? "[音频]" : "[音频] \(name)"
        default:
            return name.isEmpty ? "[文件]" : "[文件] \(name)"
        }
    case .voice:
        return "[语音]"
    case .video:
        return "[视频]"
    case .location:
        return "[位置]"
    case .contactCard:
        let name = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[名片]" : "[名片] \(name)"
    case .system:
        return "回复了一条消息"
    case .text:
        if message.isStickerMessage {
            return message.stickerSnapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText
        }
        let text = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "回复了一条消息" : text
    }
}

private struct ReplyQuoteBlock: View {
    let quote: String
    var context: MessageReplyContext? = nil
    let outgoing: Bool
    var compact = false
    var hasTransparentBackground = false

    private var usesOutgoingFill: Bool { outgoing && !hasTransparentBackground }
    @EnvironmentObject private var state: AppState

    private var parsedQuote: (sender: String, summary: String) {
        if let context {
            let sender = replyContextDisplaySenderName(context)
            let summary = context.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                sender.isEmpty ? "原消息" : sender,
                summary.isEmpty ? (context.isUnavailable ? "原消息不可见/已删除" : "回复了一条消息") : summary
            )
        }
        let normalized = quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["：", ":"] {
            if let range = normalized.range(of: separator) {
                let sender = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sender.isEmpty, !summary.isEmpty {
                    return (sender, summary)
                }
            }
        }
        return ("回复消息", normalized.isEmpty ? "回复了一条消息" : normalized)
    }

    private func replyContextDisplaySenderName(_ context: MessageReplyContext) -> String {
        let senderID = context.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderName = context.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [senderID],
            candidates: [senderName],
            fallback: senderName.isEmpty ? "原消息" : senderName
        )
    }

    private var isStickerQuote: Bool {
        context?.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sticker"
    }

    private var resolvedThumbnailURL: String {
        state.resolvedStickerAssetURLString(context?.thumbnailURL ?? "")
    }

    var body: some View {
        let parsed = parsedQuote
        HStack(alignment: .top, spacing: 8) {
            Capsule(style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.46) : IMColor.brand.opacity(0.64))
                .frame(width: 3, height: compact ? 34 : 42)
            if isStickerQuote {
                stickerQuoteThumbnail
            }
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: compact ? 8 : 9, weight: .black))
                    Text(parsed.sender)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: context?.senderID ?? "",
                        compact: true
                    )
                }
                .font(.system(size: compact ? 11 : 12, weight: .black))
                .foregroundStyle(usesOutgoingFill ? .white.opacity(0.86) : IMColor.brand)
                Text(parsed.summary)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 8 : 9)
        .padding(.vertical, compact ? 6 : 8)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.14) : IMColor.brand.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                .stroke(usesOutgoingFill ? .white.opacity(0.16) : IMColor.brand.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                "回复 \(parsed.sender)",
                state.certificationPresentation(
                    forExactUID: context?.senderID ?? ""
                )?.accessibilityLabel,
                parsed.summary
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
    }

    private var stickerQuoteThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(usesOutgoingFill ? .white.opacity(0.16) : IMColor.brand.opacity(0.10))
            if resolvedThumbnailURL.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
            } else {
                CachedRemoteImage(
                    urlString: resolvedThumbnailURL,
                    cacheKey: "reply-sticker|\(context?.messageID ?? "")|\(context?.thumbnailURL ?? "")",
                    contentMode: .fit
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
                }
                .padding(3)
            }
        }
        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

private enum ChatSenderGroupRole {
    case owner
    case admin

    var title: String {
        switch self {
        case .owner: "群主"
        case .admin: "管理员"
        }
    }

    var symbol: String {
        switch self {
        case .owner: "crown.fill"
        case .admin: "checkmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .owner: IMColor.warning
        case .admin: IMColor.brand
        }
    }
}

private struct ChatSenderRoleIcon: View {
    let role: ChatSenderGroupRole

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: role.symbol)
                .font(.caption2.weight(.black))
            Text(role.title)
                .font(.caption2.weight(.black))
                .lineLimit(1)
        }
        .foregroundStyle(role.color)
        .padding(.horizontal, 5)
        .frame(minHeight: 17)
        .background(Capsule().fill(role.color.opacity(0.13)))
        .overlay(Capsule().stroke(role.color.opacity(0.22), lineWidth: 0.8))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(role.title)
    }
}

private func groupRoleUser(_ roleUser: IMUser, matches targetUser: IMUser) -> Bool {
    let targetKeys = [targetUser.id, targetUser.userID, targetUser.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !targetKeys.isEmpty else { return false }
    let roleKeys = [roleUser.id, roleUser.userID, roleUser.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return roleKeys.contains { targetKeys.contains($0) }
}

struct MessageBubble: View {
    let message: ChatMessage
    let conversationID: String
    let showsSenderHeader: Bool
    let resolvedSenderUser: IMUser?
    let displaySenderNameOverride: String?
    var isGroupConversation = false
    var isBatchSelected: Bool = false
    var onSelectionTap: (() -> Void)? = nil
    var onLongPress: () -> Void
    var onReadTap: () -> Void
    var onSenderTap: (IMUser) -> Void = { _ in }
    var onContactCardTap: (IMUser) -> Void = { _ in }
    var onMentionTap: (IMUser) -> Void = { _ in }
    var onAttachmentTap: (ChatMessage) -> Void = { _ in }
    @EnvironmentObject private var state: AppState

    private var isSystemMessage: Bool {
        message.kind == .system
    }

    private var isRTCCallRecordCard: Bool {
        message.rtcCallRecord != nil
    }

    private var isBubbleOutgoing: Bool {
        isSystemMessage ? false : message.isOutgoing
    }

    private var isAuthoredByCurrentUser: Bool {
        guard !isSystemMessage else { return false }
        return state.isCurrentMessageSender(message.senderId)
    }

    private var displaySenderName: String {
        if let displaySenderNameOverride, !displaySenderNameOverride.isEmpty {
            return displaySenderNameOverride
        }
        guard !isSystemMessage else { return "系统" }
        if let user = resolvedSenderUser {
            if user.isCancelledUser {
                return cancelledUserDisplayName
            }
            let name = state.remarkPreferredDisplayName(for: user, fallback: message.senderId)
            if !name.isEmpty {
                return name
            }
        }
        if isCancelledUserAvatarURL(message.senderAvatarURL) {
            return cancelledUserDisplayName
        }
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remarkName = state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: message.senderId.isEmpty ? "未知用户" : message.senderId
        )
        if !remarkName.isEmpty, remarkName != message.senderId {
            return remarkName
        }
        if !storedName.isEmpty, !isIdentifierLikeSenderName(storedName, senderID: message.senderId) {
            return storedName
        }
        return storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
    }

    private var senderGroupRole: ChatSenderGroupRole? {
        guard !isSystemMessage,
              let group = state.group(forConversationID: conversationID) ?? state.group(id: conversationID) else { return nil }
        let user = isBubbleOutgoing ? state.currentUser : senderUser
        guard let user else { return nil }
        if state.isGroupOwner(user, in: group) {
            return .owner
        }
        if group.admins.contains(where: { groupRoleUser($0, matches: user) }) {
            return .admin
        }
        return nil
    }

    private var displayMessageText: String {
        guard isSystemMessage else { return message.text }
        let prefixes = ["系统通知：", "系统通知:", "通知：", "通知:"]
        for prefix in prefixes where message.text.hasPrefix(prefix) {
            return String(message.text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.text
    }

    private var isGroupEventSystemMessage: Bool {
        message.kind == .system
            && (message.systemDisplayStyle == "group_event_notice"
                || message.systemColorToken == "im.system.group_event"
                || isGroupMembershipSystemEvent(message.systemEventType ?? "")
                || displayMessageText.contains("加入群「")
                || displayMessageText.contains("移出群「")
                || displayMessageText.contains("退出群「")
                || displayMessageText.contains("离开群「"))
    }

    private var shouldShowReactionMeta: Bool {
        !message.reactions.isEmpty && !isSystemMessage && !isGroupEventSystemMessage
    }

    private var systemEventTextColor: Color {
        Color(hexString: message.systemTextColorHex ?? "") ?? Color(hex: 0x2563EB)
    }

    private var systemEventBackgroundColor: Color {
        Color(hexString: message.systemBackgroundColorHex ?? "") ?? Color(hex: 0xEFF6FF)
    }

    private var systemEventAccentColor: Color {
        Color(hexString: message.systemAccentColorHex ?? "") ?? Color(hex: 0x3B82F6)
    }

    var body: some View {
        if message.isDeletedLocally {
            Text("原消息已删除")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.72)))
                .frame(maxWidth: .infinity)
        } else if message.status == .recalled {
            Text(message.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.72)))
                .frame(maxWidth: .infinity)
        } else if isGroupEventSystemMessage {
            bubbleContent
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 6) {
                if showsSenderHeader {
                    senderHeader
                }
                HStack {
                    if isBubbleOutgoing {
                        Spacer(minLength: 54)
                    }
                    bubbleContent
                    if !isBubbleOutgoing {
                        Spacer(minLength: 54)
                    }
                }
                bottomMeta
            }
            .frame(maxWidth: .infinity, alignment: isBubbleOutgoing ? .trailing : .leading)
        }
    }

    private var outgoingSenderDisplayName: String {
        isGroupConversation ? displaySenderName : state.currentUser.displayName
    }

    private var senderHeader: some View {
        HStack(spacing: 8) {
            if isBubbleOutgoing {
                Button {
                    onSenderTap(state.currentUser)
                } label: {
                    senderNameWithRole(
                        outgoingSenderDisplayName,
                        exactUID: state.currentUser.id,
                        role: senderGroupRole,
                        color: IMColor.muted
                    )
                }
                .buttonStyle(.plain)
                Button {
                    onSenderTap(state.currentUser)
                } label: {
                    AvatarView(name: outgoingSenderDisplayName, seed: state.currentUser.avatarSeed, size: 34, imageURL: state.currentUser.displayAvatarURL, avatarVersion: state.currentUser.avatarVersion, avatarUpdatedAt: state.currentUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: state.currentUser.id))
                }
                .buttonStyle(.plain)
            } else {
                if let senderUser {
                    Button {
                        onSenderTap(senderUser)
                    } label: {
                        AvatarView(name: displaySenderName, seed: senderUser.avatarSeed, size: 34, imageURL: senderUser.displayAvatarURL, avatarVersion: senderUser.avatarVersion, avatarUpdatedAt: senderUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: message.senderId))
                    }
                    .buttonStyle(.plain)
                } else {
                    if isSystemMessage {
                        SystemNoticeLogoAvatar(size: 34)
                    } else {
                        AvatarView(name: displaySenderName, seed: 0x7C6BFF, size: 34, certification: state.certificationPresentation(forExactUID: message.senderId))
                    }
                }
                if let senderUser {
                    Button {
                        onSenderTap(senderUser)
                    } label: {
                        senderNameWithRole(
                            displaySenderName,
                            exactUID: message.senderId,
                            role: senderGroupRole,
                            color: IMColor.peerName
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    senderNameWithRole(
                        displaySenderName,
                        exactUID: message.senderId,
                        role: senderGroupRole,
                        color: IMColor.muted
                    )
                }
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
    }

    private func senderNameWithRole(
        _ name: String,
        exactUID: String,
        role: ChatSenderGroupRole?,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            CertificationPillView(
                exactUID: exactUID,
                compact: true
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            if let role {
                ChatSenderRoleIcon(role: role)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                name,
                state.certificationPresentation(
                    forExactUID: exactUID
                )?.accessibilityLabel,
                role?.title
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
    }

    private var senderUser: IMUser? {
        if let resolvedSenderUser {
            return resolvedSenderUser
        }
        return MessageSenderResolver.fallbackUser(
            for: message,
            displayName: displaySenderName,
            enterpriseName: state.currentEnterprise.name
        )
    }

    private var rtcCallRecordPeerName: String {
        let conversation = state.conversation(id: conversationID)
        if let peer = state.directConversationCallPeer(for: conversation) {
            return state.remarkPreferredDisplayName(for: peer, fallback: conversation.title)
        }
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "对方" : title
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply = resolvedVisibleReplyPresentation(
                for: message,
                conversation: state.conversation(id: conversationID),
                state: state
            ) {
                ReplyQuoteBlock(
                    quote: reply.quote, context: reply.context, outgoing: isBubbleOutgoing,
                    hasTransparentBackground: !message.isStickerMessage && AttachmentGIFPresentation.usesBorderlessContainer(message)
                )
            }
            if let approval = message.groupInviteApproval {
                GroupInviteApprovalCard(approval: approval, compact: true)
            } else if let record = message.rtcCallRecord {
                RTCCallRecordCard(
                    record: record,
                    viewerIsCaller: message.isOutgoing,
                    peerName: rtcCallRecordPeerName,
                    outgoing: isBubbleOutgoing
                ) {
                    if let onSelectionTap {
                        onSelectionTap()
                    } else {
                        state.redialRTCCallRecord(
                            record,
                            viewerIsCaller: message.isOutgoing,
                            conversationID: conversationID
                        )
                    }
                }
            } else if message.isStickerMessage {
                StickerMessageView(message: message)
            } else if message.kind == .voice {
                VoiceBubbleContent(message: message, outgoing: isBubbleOutgoing, conversationID: conversationID)
            } else if message.kind == .file || message.kind == .image || message.kind == .video {
                FileBubbleContent(message: message, outgoing: isBubbleOutgoing, conversationID: conversationID)
            } else if message.kind == .contactCard {
                ContactCardBubbleContent(message: message, outgoing: isBubbleOutgoing) { user in
                    onContactCardTap(user)
                }
            } else if isGroupEventSystemMessage {
                Text(displayMessageText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(systemEventTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if message.kind == .system, let systemLinkedUser {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Button {
                        onSenderTap(systemLinkedUser)
                    } label: {
                        Text(systemLinkedUser.name)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.brand)
                    }
                    .buttonStyle(.plain)
                    Text(systemMessageRemainder(for: systemLinkedUser))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IMColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                MentionStyledMessageText(
                    text: displayMessageText,
                    targets: mentionTargets,
                    outgoing: isBubbleOutgoing,
                    onMentionTap: onMentionTap
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            if message.isEdited, !isGroupEventSystemMessage, !message.isStickerMessage {
                MessageEditedBadge(outgoing: isBubbleOutgoing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? 0 : 14)
        .padding(.vertical, AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? 0 : 11)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? LinearGradient(colors: [.clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing) : bubbleBackground)
        )
        .overlay {
            if isBatchSelected {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(IMColor.brand, lineWidth: 2)
            } else if isGroupEventSystemMessage {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(systemEventAccentColor.opacity(0.28), lineWidth: 1)
            } else if message.isPinned, message.isStickerMessage || !AttachmentGIFPresentation.usesBorderlessContainer(message) {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(IMColor.warning.opacity(0.8), lineWidth: 1.2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if message.isPinned, !isGroupEventSystemMessage {
                PinnedMessageIconBadge(outgoing: isBubbleOutgoing)
                    .padding(.top, -7)
                    .padding(.trailing, -7)
            }
        }
        .frame(maxWidth: AttachmentGIFPresentation.usesBorderlessContainer(message) ? 228 : (isRTCCallRecordCard ? 304 : (isGroupEventSystemMessage ? 318 : 286)), alignment: isGroupEventSystemMessage ? .center : (isBubbleOutgoing ? .trailing : .leading))
        .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .onTapGesture {
            if let onSelectionTap {
                onSelectionTap()
                return
            }
            if message.kind == .file || message.kind == .image || message.kind == .video {
                onAttachmentTap(message)
                return
            }
            guard message.kind == .contactCard, let contactCardUser else { return }
            onContactCardTap(contactCardUser)
        }
        .onLongPressGesture {
            guard !message.isRTCCallRecordMessage else { return }
            onLongPress()
        }
    }

    private var contactCardUser: IMUser? {
        guard message.kind == .contactCard else { return nil }
        let contactName = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let contactID = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contactID.isEmpty {
            if let user = state.contacts.first(where: { $0.id == contactID || $0.userID == contactID }) {
                return user
            }
            return IMUser(
                id: contactID,
                name: contactName.isEmpty ? contactID : contactName,
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "在线",
                enterprise: state.currentEnterprise.name,
                avatarSeed: UInt(bitPattern: contactID.hashValue),
                badges: []
            )
        }
        return nil
    }

    private var systemLinkedUser: IMUser? {
        guard message.kind == .system else { return nil }
        guard !isGroupEventSystemMessage else { return nil }
        guard let senderUser, senderUser.displayName != "系统", displayMessageText.hasPrefix(senderUser.displayName) else { return nil }
        return senderUser
    }

    private func systemMessageRemainder(for user: IMUser) -> String {
        let text = displayMessageText
        guard text.hasPrefix(user.name) else { return text }
        let remainder = text.dropFirst(user.name.count)
        return remainder.isEmpty ? "" : String(remainder)
    }

    private var mentionTargets: [MentionTextTarget] {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：普通文本无 @ 时跳过联系人/群成员解析，减少消息行滚动渲染主线程开销
        guard !isSystemMessage, !message.mentionExcluded, displayMessageText.contains("@") else { return [] }
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        let conversation = state.conversation(id: conversationID)
        let groupUsers = state.group(forConversationID: conversationID).map { group in
            group.members + group.admins
        } ?? []
        let users = [state.currentUser] + conversation.participants + groupUsers
        var usersByKey: [String: IMUser] = [:]
        for user in users {
            for key in mentionUserStableKeys(for: user) {
                usersByKey[key] = usersByKey[key] ?? user
            }
        }

        let structuredMentionGroups = Dictionary(grouping: message.mentionedUsers) { mention in
            mentionTargetName(mention.displayText)
        }
        let structuredTargets: [MentionTextTarget] = structuredMentionGroups.compactMap { rawName, mentions in
            guard !rawName.isEmpty, !isIdentifierLikeSenderName(rawName, senderID: "") else { return nil }
            let uniqueMentions = mentions.reduce(into: [String: MentionIdentity]()) { partial, mention in
                guard !mention.id.isEmpty else { return }
                partial[mention.id] = partial[mention.id] ?? mention
            }
            let user = uniqueMentions.count == 1
                ? uniqueMentions.values.first.flatMap { resolveMentionUser($0, usersByKey: usersByKey) }
                : nil
            return MentionTextTarget(name: rawName, user: user)
        }
        let sortedTargets = structuredTargets
        .sorted { (lhs: MentionTextTarget, rhs: MentionTextTarget) in
            if lhs.name.count == rhs.name.count {
                return lhs.name < rhs.name
            }
            return lhs.name.count > rhs.name.count
        }
        guard message.mentionAll else { return sortedTargets }
        return [MentionTextTarget(name: "所有人", user: nil, isAll: true)] + sortedTargets
    }

    private func resolveMentionUser(_ mention: MentionIdentity, usersByKey: [String: IMUser]) -> IMUser? {
        for key in [mention.imUID, mention.userID, mention.username]
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {
            if let user = usersByKey[key] {
                return user
            }
        }
        guard !mention.id.isEmpty else { return nil }
        let displayName = mentionTargetName(mention.displayText)
        return IMUser(
            id: mention.imUID.isEmpty ? mention.id : mention.imUID,
            userID: mention.userID.isEmpty ? mention.id : mention.userID,
            username: mention.username,
            name: displayName.isEmpty ? mention.id : displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: state.currentEnterprise.name,
            avatarSeed: UInt(bitPattern: mention.id.hashValue),
            badges: []
        )
    }

    private var bubbleBackground: LinearGradient {
        if isBubbleOutgoing {
            return LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isGroupEventSystemMessage {
            return LinearGradient(colors: [systemEventBackgroundColor, systemEventBackgroundColor.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [.white, .white.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var bottomMeta: some View {
        VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 5) {
            MessageMetaTags(message: message)
            if shouldShowReactionMeta {
                reactionsRow
            }
            if isAuthoredByCurrentUser {
                deliveryStatus
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
    }

    private var reactionsRow: some View {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：reaction 渲染按行号访问切片，避免每次气泡重绘构造二维数组
        VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 5) {
            ForEach(reactionRowIndices, id: \.self) { rowIndex in
                reactionRow(rowIndex)
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：reaction 行按索引访问原数组，兼容 SwiftUI ForEach 类型检查
    private var reactionRowIndices: Range<Int> {
        0..<((message.reactions.count + 4) / 5)
    }

    private func reactionRow(_ rowIndex: Int) -> some View {
        let reactions = message.reactions
        let start = rowIndex * 5
        let end = min(start + 5, reactions.count)
        return HStack(spacing: 5) {
            ForEach(start..<end, id: \.self) { index in
                reactionPill(reactions[index])
            }
        }
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

    private func reactionPill(_ reaction: Reaction) -> some View {
        Text("\(reaction.emoji) \(reaction.count)")
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(reaction.reactedByMe ? IMColor.brand.opacity(0.15) : .white.opacity(0.78)))
    }

    private var deliveryStatus: some View {
        Button {
            if message.status == .failed {
                state.resend(messageID: message.id, in: conversationID)
            } else {
                onReadTap()
            }
        } label: {
            HStack(spacing: 4) {
                if message.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                } else if deliveryShowsReadAffordance {
                    Image(systemName: deliveryText.hasPrefix("已读") ? "checkmark" : "circle")
                        .font(.system(size: 10, weight: .heavy))
                }
                Text(deliveryText)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(deliveryStatusColor)
            .padding(.horizontal, deliveryShowsReadAffordance ? 7 : 0)
            .padding(.vertical, deliveryShowsReadAffordance ? 4 : 2)
            .background {
                if deliveryShowsReadAffordance {
                    Capsule().fill(deliveryStatusColor.opacity(0.10))
                }
            }
            .overlay {
                if deliveryShowsReadAffordance {
                    Capsule().stroke(deliveryStatusColor.opacity(0.18), lineWidth: 0.7)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var deliveryShowsReadAffordance: Bool {
        guard message.status != .failed,
              message.status != .sending,
              message.status != .recalled,
              state.fileUploadConfig.readReceiptsEnabled else {
            return false
        }
        return deliveryText == "未读" || deliveryText.hasPrefix("已读")
    }

    private var deliveryStatusColor: Color {
        if message.status == .failed {
            return IMColor.danger
        }
        guard deliveryShowsReadAffordance else {
            return IMColor.muted
        }
        if deliveryText.hasPrefix("已读") {
            return IMColor.success
        }
        return Color(hex: 0x7A8497)
    }

    private var deliveryText: String {
        guard state.fileUploadConfig.readReceiptsEnabled else {
            switch message.status {
            case .sending:
                return "发送中"
            case .failed:
                return "未送达 · 点按重发"
            case .recalled:
                return "已撤回"
            case .sent:
                return message.deliveryStateKnown ? "已送达" : "已发送"
            case .read:
                return "已读"
            }
        }
        if message.readStateKnown, message.status == .sent {
            return "未读"
        }
        if message.status == .sent, !message.readBy.isEmpty {
            return readStatusText
        }
        switch message.status {
        case .sending:
            return "发送中"
        case .sent:
            return message.deliveryStateKnown ? "已送达" : "已发送"
        case .read:
            return readStatusText
        case .failed:
            return "未送达 · 点按重发"
        case .recalled:
            return "已撤回"
        }
    }

    private var readStatusText: String {
        guard message.canViewReadDetails else { return "已读" }
        let isGroupConversation = state.conversation(id: conversationID).kind == .group
        if isGroupConversation && !state.shouldShowGroupMemberCount {
            return "已读"
        }
        if let readCount = message.readCount {
            return readCount > 0 ? "已读 \(readCount)" : "已读"
        }
        return "已读"
    }
}

private struct MentionTextTarget: Hashable {
    let name: String
    let user: IMUser?
    var isAll = false

    var token: String { "@\(name)" }
}

private struct MentionTextSegment: Identifiable {
    let id = UUID()
    let text: String
    let user: IMUser?
    let isMention: Bool
    let isAll: Bool
}

private struct MentionStyledMessageText: View {
    let text: String
    let targets: [MentionTextTarget]
    let outgoing: Bool
    let onMentionTap: (IMUser) -> Void

    private var segments: [MentionTextSegment] {
        mentionTextSegments(in: text, targets: targets)
    }

    private var mentionUsersByURL: [String: IMUser] {
        segments.reduce(into: [:]) { result, segment in
            guard let user = segment.user, let url = mentionURL(for: user) else { return }
            result[url.absoluteString] = user
        }
    }

    private var attributedText: AttributedString {
        var output = AttributedString()
        let baseColor = outgoing ? Color.white : IMColor.ink
        let mentionColor = outgoing ? Color(hex: 0xEAF2FF) : Color(hex: 0x2563EB)
        let mentionAllColor = outgoing ? Color(hex: 0xFFE8A3) : Color(hex: 0xB45309)

        for segment in segments {
            var part = AttributedString(segment.text)
            part.font = segment.isMention ? .system(size: 15, weight: .heavy) : .system(size: 15, weight: .semibold)
            part.foregroundColor = segment.isAll ? mentionAllColor : (segment.isMention ? mentionColor : baseColor)
            if segment.isMention, let user = segment.user, let url = mentionURL(for: user) {
                part.link = url
            }
            output += part
        }
        return output
    }

    var body: some View {
        Text(attributedText)
            .environment(\.openURL, OpenURLAction { url in
                guard let user = mentionUsersByURL[url.absoluteString] else {
                    return .discarded
                }
                onMentionTap(user)
                return .handled
            })
    }
}

private func mentionTextSegments(in text: String, targets: [MentionTextTarget]) -> [MentionTextSegment] {
    guard !text.isEmpty, !targets.isEmpty else {
        return [MentionTextSegment(text: text, user: nil, isMention: false, isAll: false)]
    }

    var segments: [MentionTextSegment] = []
    var cursor = text.startIndex

    while cursor < text.endIndex {
        guard let match = nextMentionMatch(in: text, from: cursor, targets: targets) else {
            segments.append(MentionTextSegment(text: String(text[cursor..<text.endIndex]), user: nil, isMention: false, isAll: false))
            break
        }

        if cursor < match.range.lowerBound {
            segments.append(MentionTextSegment(text: String(text[cursor..<match.range.lowerBound]), user: nil, isMention: false, isAll: false))
        }
        segments.append(MentionTextSegment(text: String(text[match.range]), user: match.target.user, isMention: true, isAll: match.target.isAll))
        cursor = match.range.upperBound
    }

    return segments
}

private func nextMentionMatch(in text: String, from cursor: String.Index, targets: [MentionTextTarget]) -> (range: Range<String.Index>, target: MentionTextTarget)? {
    var best: (range: Range<String.Index>, target: MentionTextTarget)?
    for target in targets {
        var searchStart = cursor
        while searchStart < text.endIndex,
              let range = text.range(of: target.token, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            if isSafeMentionBoundary(in: text, range: range) {
                if best == nil
                    || range.lowerBound < best!.range.lowerBound
                    || (range.lowerBound == best!.range.lowerBound && range.upperBound > best!.range.upperBound) {
                    best = (range, target)
                }
                break
            }
            searchStart = range.upperBound
        }
    }
    return best
}

private func isSafeMentionBoundary(in text: String, range: Range<String.Index>) -> Bool {
    if range.lowerBound > text.startIndex {
        let before = text[text.index(before: range.lowerBound)]
        if isEmailOrIdentifierContinuation(before) {
            return false
        }
    }
    if range.upperBound < text.endIndex {
        let after = text[range.upperBound]
        if isEmailOrIdentifierContinuation(after) {
            return false
        }
    }
    return true
}

private func isEmailOrIdentifierContinuation(_ character: Character) -> Bool {
    if character.isLetter || character.isNumber { return true }
    return [".", "_", "-", "@"].contains(String(character))
}

private func mentionUserKey(for user: IMUser) -> String {
    let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if !id.isEmpty { return id }
    let userID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !userID.isEmpty { return userID }
    return user.username.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mentionUserStableKeys(for user: IMUser) -> [String] {
    var seen = Set<String>()
    return [user.id, user.userID, user.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

private func mentionTargetName(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix("@") {
        text.removeFirst()
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mentionVisibleDisplayName(for user: IMUser) -> String {
    if user.isCancelledUser {
        return cancelledUserDisplayName
    }
    let trimmedName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let stableKeys = Set(mentionUserStableKeys(for: user))
    if !trimmedName.isEmpty, !stableKeys.contains(trimmedName) {
        return trimmedName
    }
    return "未命名成员"
}

private func mentionURL(for user: IMUser) -> URL? {
    let key = mentionUserKey(for: user)
    guard !key.isEmpty else { return nil }
    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
    return URL(string: "im2-mention://user/\(encodedKey)")
}

private extension Array where Element == IMUser {
    func deduplicatedByMentionIdentity() -> [IMUser] {
        var seen = Set<String>()
        return filter { user in
            let key = mentionUserKey(for: user)
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }
}

private struct StickerMessageView: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage

    private var snapshot: StickerMessageSnapshot? {
        message.stickerSnapshot
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 188
        let maxHeight: CGFloat = 214
        let minSide: CGFloat = 86
        let rawWidth = CGFloat(snapshot?.width ?? 128)
        let rawHeight = CGFloat(snapshot?.height ?? 128)
        let aspect = rawWidth > 0 && rawHeight > 0 ? min(max(rawWidth / rawHeight, 0.58), 2.0) : 1
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: max(minSide, width), height: max(minSide, height))
    }

    private var thumbnailURLString: String {
        state.resolvedStickerThumbnailURL(for: snapshot)?.absoluteString ?? ""
    }

    var body: some View {
        StickerGIFPlayer(
            url: state.resolvedStickerAnimationURL(for: snapshot),
            cacheKey: state.stickerAnimationCacheKey(for: message),
            maxPixelSize: Int(max(displaySize.width, displaySize.height) * UIScreen.main.scale)
        ) {
            stickerPlaceholder
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot?.fallbackText ?? StickerMessageSnapshot.fallbackText)
        .task(id: snapshot?.cacheIdentity ?? message.id) {
            state.resolveStickerMessageAssetsIfNeeded(for: snapshot)
        }
    }

    private var stickerPlaceholder: some View {
        ZStack {
            if thumbnailURLString.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(IMColor.brand.opacity(0.78))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CachedRemoteImage(
                    urlString: thumbnailURLString,
                    cacheKey: "sticker-thumbnail|\(snapshot?.cacheIdentity ?? message.id)",
                    contentMode: .fit
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(2)
            }
        }
    }
}

enum AttachmentGIFPresentation {
    static func usesBorderlessContainer(_ message: ChatMessage) -> Bool {
        message.isStickerMessage || ((message.kind == .image || message.kind == .file)
            && isGIF(message) && message.status != .recalled && !message.isDeletedLocally)
    }

    static func isGIF(_ message: ChatMessage) -> Bool {
        GIFAttachmentUploadPolicy.isGIFCandidate(
            mimeType: message.attachmentMimeType,
            name: message.attachmentName ?? "",
            fileExtension: message.attachmentExtension
        )
    }

    static func canPlay(_ message: ChatMessage) -> Bool {
        isGIF(message) && message.status != .recalled && !message.isDeletedLocally
            && (message.attachmentSizeBytes ?? 0) <= 10_485_760
    }

    static func originalURL(localURL: URL?, downloadURL: URL?, previewURL: URL?, downloadAllowed: Bool = true, previewAllowed: Bool = true) -> URL? {
        // A thumbnail is deliberately not a candidate for animation.
        localURL ?? (downloadAllowed ? downloadURL : nil) ?? (previewAllowed ? previewURL : nil)
    }
}

private struct AttachmentGIFImage<Placeholder: View>: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    var localURL: URL? = nil
    var maxPixelSize = 768
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        Group {
            if AttachmentGIFPresentation.canPlay(message), state.mediaCacheScopeContext != nil {
                StickerGIFPlayer(
                    url: AttachmentGIFPresentation.originalURL(
                        localURL: localURL,
                        downloadURL: state.resolvedAttachmentDownloadURL(for: message),
                        previewURL: state.resolvedAttachmentPreviewURL(for: message),
                        downloadAllowed: message.attachmentDownloadAvailable || message.status == .sending,
                        previewAllowed: message.attachmentPreviewAvailable
                    ),
                    cacheKey: "\(state.mediaCacheScopeContext?.scopeHash ?? "invalid-scope")|\(state.mediaCacheScopeContext?.sessionGeneration ?? 0)|original-gif|\(message.id)|\(message.attachmentVersion)|\(message.attachmentChecksum)",
                    maxPixelSize: maxPixelSize,
                    requiresGIF: true,
                    playbackPriority: localURL != nil,
                    recoveryURL: {
                        await state.refreshedGIFAttachmentOriginalURL(message, conversationID: conversationID)
                    },
                    placeholder: placeholder
                )
            } else {
                placeholder()
            }
        }
    }
}

private struct FileBubbleContent: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let outgoing: Bool
    var conversationID: String = ""

    private var isBorderlessGIF: Bool {
        AttachmentGIFPresentation.usesBorderlessContainer(message)
    }

    private var usesOutgoingFill: Bool { outgoing && !isBorderlessGIF }

    private var progress: Double? {
        state.attachmentTransferProgress(for: message)
    }

    private var isUploadTransfer: Bool {
        state.isAttachmentUploadInProgress(message)
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_UPLOAD_STAGE_TEXT - 修改开始：无真实 PUT 进度时只展示上传阶段文本，不展示百分比进度条
    private var uploadStageLabel: String? {
        guard isUploadTransfer, progress == nil else { return nil }
        let status = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch status {
        case "put", "uploading":
            return "上传中"
        case "uploaded", "finalize", "processing":
            return "处理中"
        case "send", "message_send", "awaiting_ack":
            return "发送中"
        case "retrying":
            return "等待重试"
        default:
            return message.status == .sending ? "准备上传" : nil
        }
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_UPLOAD_STAGE_TEXT - 修改结束

    private var mediaCategory: String {
        state.attachmentMediaCategory(for: message)
    }

    private var mediaSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "audio": return "waveform"
        case "archive": return "archivebox.fill"
        default: return "doc.richtext.fill"
        }
    }

    private var mediaTitle: String {
        switch mediaCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        case "audio": return "音频"
        case "archive": return "压缩包"
        default: return "文件"
        }
    }

    private var fileName: String {
        (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名文件"
            : (message.attachmentName ?? message.text)
    }

    private var fileSizeText: String {
        if let sizeBytes = message.attachmentSizeBytes, sizeBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        return "大小待同步"
    }

    private var fileTypeBadge: String {
        let explicit = message.attachmentExtension.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pathExt = (fileName as NSString).pathExtension.uppercased()
        let category = mediaCategory.uppercased()
        let value = [explicit, pathExt, category].first { !$0.isEmpty && $0 != "FILE" && $0 != "UNKNOWN" } ?? "FILE"
        switch value {
        case "DOCX": return "DOC"
        case "XLSX": return "XLS"
        case "PPTX": return "PPT"
        case "JPEG": return "JPG"
        default: return String(value.prefix(4))
        }
    }

    private var mediaAspectRatio: CGFloat {
        if let width = message.attachmentWidth,
           let height = message.attachmentHeight,
           width > 0,
           height > 0 {
            return min(max(CGFloat(width) / CGFloat(height), 0.72), 1.85)
        }
        return mediaCategory == "video" ? 16.0 / 9.0 : 1.45
    }

    private var isMediaMessage: Bool {
        isBorderlessGIF || mediaCategory == "image" || mediaCategory == "video"
    }

    private var attachmentDownloaded: Bool {
        state.isMessageAttachmentDownloaded(message, preferPreview: false)
    }

    private var attachmentActionLabel: String {
        attachmentDownloaded ? "保存/分享" : "点击下载"
    }

    private var mediaFrameSize: CGSize {
        if isBorderlessGIF {
            let width = CGFloat(max(1, message.attachmentWidth ?? 128))
            let height = CGFloat(max(1, message.attachmentHeight ?? 128))
            let scale = min(188 / width, 214 / height)
            return CGSize(width: width * scale, height: height * scale)
        }
        let maxWidth: CGFloat = 204
        let maxHeight: CGFloat = 244
        var width = maxWidth
        var height = width / mediaAspectRatio
        if height > maxHeight {
            height = maxHeight
            width = height * mediaAspectRatio
        }
        return CGSize(width: max(132, width), height: max(118, height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isMediaMessage {
                ZStack {
                    let thumbnailURL = state.resolvedAttachmentThumbnailURL(for: message)
                    if AttachmentGIFPresentation.isGIF(message) {
                        AttachmentGIFImage(message: message, conversationID: conversationID) {
                            thumbnailPlaceholder(symbol: mediaSymbol, title: "GIF", status: "点按查看原图")
                        }
                    } else if thumbnailURL != nil || state.attachmentCanRefreshRemoteFile(message) {
                        AttachmentThumbnailImage(
                            url: thumbnailURL,
                            cacheKey: state.attachmentThumbnailCacheKey(for: message),
                            contentMode: .fill,
                            maxPixelSize: Int(max(mediaFrameSize.width, mediaFrameSize.height) * UIScreen.main.scale * 1.5),
                            scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                            networkRecoveryGeneration: state.mediaNetworkRecoveryGeneration,
                            recoveryURL: thumbnailRecoveryURL,
                            indexedCacheURL: {
                                await state.cachedUnifiedAttachmentThumbnailURL(for: message)
                            },
                            indexedCacheCommit: { data in
                                await state.cacheUnifiedAttachmentThumbnail(
                                    data,
                                    for: message,
                                    conversationID: conversationID
                                )
                            },
                            placeholder: {
                                thumbnailPlaceholder(symbol: mediaSymbol, title: mediaTitle, status: "缩略图加载中")
                            },
                            failure: {
                                thumbnailPlaceholder(symbol: mediaSymbol, title: mediaTitle, status: "缩略图加载失败，点按重试")
                            }
                        )
                    } else {
                        thumbnailPlaceholder(
                            symbol: mediaSymbol,
                            title: mediaTitle,
                            status: mediaCategory == "video" ? "暂无视频封面" : "暂无图片预览"
                        )
                    }
                    if mediaCategory == "video" {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.42)))
                    }
                }
                .frame(width: mediaFrameSize.width, height: mediaFrameSize.height)
                .clipShape(RoundedRectangle(cornerRadius: isBorderlessGIF ? 0 : 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isBorderlessGIF ? .clear : (usesOutgoingFill ? .white.opacity(0.20) : IMColor.brand.opacity(0.12)), lineWidth: 1)
                )
                .accessibilityLabel(mediaCategory == "video" ? "视频消息，点按播放" : "图片消息，点按查看原图")
            } else {
                HStack(spacing: 10) {
                    fileTypeIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileName)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.ink)
                            .lineLimit(2)
                        Text([mediaTitle, fileSizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(outgoing ? .white.opacity(0.78) : IMColor.muted)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 210, alignment: .leading)
                .accessibilityLabel("文件 \(fileName)，\(fileSizeText)，\(attachmentActionLabel)")
            }

            if !isBorderlessGIF || progress != nil || uploadStageLabel != nil || message.status == .failed || state.attachmentDownloadFailed(message) {
                HStack(spacing: 8) {
                    if let progress {
                        ProgressView(value: progress)
                            .tint(usesOutgoingFill ? .white : IMColor.brand)
                            .frame(width: 96)
                        Text(transferLabel(progress))
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                        Button {
                            if isUploadTransfer || state.canRetryAttachmentUpload(message) {
                                state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                            } else {
                                state.cancelAttachmentDownload(message)
                            }
                        } label: {
                            Text("取消")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(usesOutgoingFill ? .white : IMColor.danger)
                        }
                        .buttonStyle(.plain)
                    } else if let uploadStageLabel {
                        Label(uploadStageLabel, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.78) : IMColor.muted)
                        Spacer(minLength: 0)
                        Button {
                            state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                        } label: {
                            Text("取消")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(usesOutgoingFill ? .white : IMColor.danger)
                        }
                        .buttonStyle(.plain)
                    } else if message.status == .failed {
                        Label(state.canRetryAttachmentUpload(message) ? "发送失败 · 点按查看" : "发送失败", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.88) : IMColor.danger)
                    } else if state.attachmentDownloadFailed(message) {
                        Label("下载失败 · 点按重试", systemImage: "arrow.clockwise.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.88) : IMColor.danger)
                    } else if !isMediaMessage && message.status != .sending {
                        Label(attachmentActionLabel, systemImage: attachmentDownloaded ? "square.and.arrow.up.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(usesOutgoingFill ? .white.opacity(0.84) : IMColor.brand)
                    }
                }
            }
        }
    }

    private var fileTypeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(outgoing ? .white.opacity(0.18) : IMColor.brand.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(outgoing ? .white.opacity(0.22) : IMColor.brand.opacity(0.18), lineWidth: 1)
                )
            Text(fileTypeBadge)
                .font(.system(size: fileTypeBadge.count > 3 ? 10 : 12, weight: .black, design: .rounded))
                .foregroundStyle(outgoing ? .white : IMColor.brand)
                .padding(.horizontal, 4)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 48, height: 48)
        .accessibilityLabel("文件类型 \(fileTypeBadge)")
    }

    private func transferLabel(_ progress: Double) -> String {
        let percent = "\(Int(max(0, min(progress, 1)) * 100))%"
        if isUploadTransfer {
            // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_UPLOAD_LABEL_REAL_PERCENT - 修改开始：上传百分比只描述真实 PUT 进度
            return "上传 \(percent)"
            // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_UPLOAD_LABEL_REAL_PERCENT - 修改结束
        }
        return progress >= 0.99 ? "打开中" : "下载 \(percent)"
    }

    private func thumbnailRecoveryURL() async -> URL? {
        guard !conversationID.isEmpty else { return nil }
        do {
            return try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
        } catch {
            return nil
        }
    }

    @ViewBuilder
    private func thumbnailPlaceholder(symbol: String, title: String, status: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .bold))
            Text(status)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(usesOutgoingFill ? .white.opacity(0.72) : IMColor.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(usesOutgoingFill ? .white.opacity(0.82) : IMColor.brand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(usesOutgoingFill ? .white.opacity(0.12) : IMColor.brand.opacity(0.08)))
    }
}

private struct VoiceBubbleContent: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let outgoing: Bool
    var conversationID: String = ""

    private var isPlaying: Bool {
        state.isVoiceMessagePlaying(message)
    }

    private var playbackState: VoiceMessagePlaybackState? {
        state.voicePlaybackState(for: message)
    }

    private var progress: Double? {
        state.attachmentTransferProgress(for: message)
    }

    private var isUploadTransfer: Bool {
        state.isAttachmentUploadInProgress(message)
    }

    private var durationText: String {
        if let playbackState {
            let remaining = playbackState.remainingLabel
            return remaining.isEmpty ? "0秒" : remaining
        }
        if let seconds = message.attachmentDurationSeconds, seconds > 0 {
            return VoiceMessagePayload.durationLabel(durationMS: Int((seconds * 1_000).rounded()))
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "语音" : text
    }

    private var statusColor: Color {
        outgoing ? .white.opacity(0.82) : IMColor.muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button {
                    state.toggleVoiceMessagePlayback(message, conversationID: conversationID)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(outgoing ? IMColor.brand : .white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(outgoing ? .white : IMColor.brand))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat_voice_play_button")
                .accessibilityLabel(isPlaying ? "暂停语音消息" : "播放语音消息")

                VoiceWaveformBars(
                    samples: message.voiceWaveform,
                    active: isPlaying,
                    outgoing: outgoing,
                    height: 26,
                    barCount: 28
                )
                .frame(minWidth: 114, alignment: .leading)

                Text(durationText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(outgoing ? .white : IMColor.ink)
                    .lineLimit(1)
            }
            .frame(minWidth: 198, alignment: .leading)

            if let playbackState {
                HStack(spacing: 8) {
                    ProgressView(value: playbackState.progress)
                        .tint(outgoing ? .white : IMColor.brand)
                        .frame(width: 132)
                    Text("剩余 \(playbackState.remainingLabel.isEmpty ? "0秒" : playbackState.remainingLabel)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("语音播放进度，剩余 \(playbackState.remainingLabel.isEmpty ? "0秒" : playbackState.remainingLabel)")
            }

            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .tint(outgoing ? .white : IMColor.brand)
                        .frame(width: 92)
                    Text(voiceTransferLabel(progress))
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                    Button {
                        if isUploadTransfer {
                            state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                        } else {
                            state.cancelAttachmentDownload(message)
                        }
                    } label: {
                        Text("取消")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.danger)
                    }
                    .buttonStyle(.plain)
                } else if message.status == .failed {
                    Button {
                        state.retryAttachmentUpload(messageID: message.id, in: conversationID)
                    } label: {
                        Label(state.canRetryAttachmentUpload(message) ? "发送失败 · 重试" : "发送失败", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(outgoing ? .white.opacity(0.9) : IMColor.danger)
                    }
                    .buttonStyle(.plain)
                } else if state.attachmentDownloadFailed(message) {
                    Label("下载失败 · 点按重试", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(outgoing ? .white.opacity(0.88) : IMColor.danger)
                } else {
                    Label("语音消息", systemImage: "waveform")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(statusColor)
                }
            }
        }
        .onDisappear {
            state.stopVoiceMessagePlayback(ifPlaying: message.id)
        }
    }

    private func voiceTransferLabel(_ progress: Double) -> String {
        let percent = "\(Int(max(0, min(progress, 1)) * 100))%"
        if isUploadTransfer {
            return progress >= 0.9 ? "处理中" : "上传 \(percent)"
        }
        return progress >= 0.99 ? "打开中" : "下载 \(percent)"
    }
}

enum AttachmentThumbnailCacheIdentity {
    static func generationKey(baseKey: String, generation: UInt64) -> String {
        "generation:\(generation)|\(baseKey)"
    }
}

struct AttachmentThumbnailImage<Placeholder: View, Failure: View>: View {
    let url: URL?
    let cacheKey: String
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int = 768
    var scopeGeneration: UInt64 = 0
    var networkRecoveryGeneration: Int = 0
    var recoveryURL: (() async -> URL?)? = nil
    var indexedCacheURL: (() async -> URL?)? = nil
    var indexedCacheCommit: ((Data) async -> URL?)? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryNonce = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Button {
                    failed = false
                    retryNonce += 1
                } label: {
                    failure()
                }
                .buttonStyle(.plain)
            } else {
                placeholder()
            }
        }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_TASK_PRIORITY - 修改开始：缩略图加载降为 utility，避免下拉历史时抢占滚动
        .task(id: "\(scopeGeneration)|\(url?.absoluteString ?? "recovery-only")|\(cacheKey)|\(retryNonce)", priority: .utility) {
            await load()
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_TASK_PRIORITY - 修改结束：缩略图加载降为 utility，避免下拉历史时抢占滚动
        .onChangeCompat(of: networkRecoveryGeneration) { previous, current in
            guard current != previous, failed, image == nil else { return }
            let stableKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let generationKey = AttachmentThumbnailCacheIdentity.generationKey(
                baseKey: stableKey.isEmpty ? "thumbnail-recovery|\(url?.path ?? "missing")" : stableKey,
                generation: scopeGeneration
            )
            Task {
                guard await MediaVisibleRecoveryGate.shared.shouldRetry(
                    key: generationKey
                ) else {
                    return
                }
                await MainActor.run {
                    guard failed, image == nil else { return }
                    failed = false
                    retryNonce &+= 1
                }
            }
        }
    }

    @MainActor
    private func load() async {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOAD_SNAPSHOT - 修改开始：先快照加载参数，后台任务不捕获整个 View
        let requestedURL = url
        let requestedCacheKey = cacheKey
        let requestedMaxPixelSize = maxPixelSize
        let requestedScopeGeneration = scopeGeneration
        let requestedIndexedCacheURL = indexedCacheURL
        let requestedIndexedCacheCommit = indexedCacheCommit
        let requestedRecoveryURL = recoveryURL
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOAD_SNAPSHOT - 修改结束：先快照加载参数，后台任务不捕获整个 View
        let stableKey = requestedCacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AttachmentThumbnailDiskCache.cacheKeyFallback(for: requestedURL ?? URL(fileURLWithPath: "attachment-thumbnail-recovery-only"))
            : requestedCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let generationKey = AttachmentThumbnailCacheIdentity.generationKey(
            baseKey: stableKey,
            generation: requestedScopeGeneration
        )
        if let cached = AvatarImageCache.shared.image(for: generationKey, maxPixelSize: requestedMaxPixelSize) {
            applyThumbnailState(image: cached, failed: false)
            return
        }
        if let requestedIndexedCacheURL,
           let localURL = await requestedIndexedCacheURL(),
           !Task.isCancelled,
           let indexedImage = await AttachmentThumbnailDiskCache.localPreparedImage(from: localURL, maxPixelSize: requestedMaxPixelSize) {
            AvatarImageCache.shared.storePrepared(indexedImage, for: generationKey, maxPixelSize: requestedMaxPixelSize)
            applyThumbnailState(image: indexedImage, failed: false)
            return
        }
        applyThumbnailState(image: nil, failed: false)
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_VISIBLE_DEBOUNCE - 修改开始：快速滑过的图片不进入加载队列，减少历史滚动卡顿
        try? await Task.sleep(nanoseconds: 90_000_000)
        guard !Task.isCancelled else { return }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_VISIBLE_DEBOUNCE - 修改结束：快速滑过的图片不进入加载队列，减少历史滚动卡顿
        await AttachmentThumbnailLoadGate.shared.acquire()
        guard !Task.isCancelled else {
            await AttachmentThumbnailLoadGate.shared.release()
            return
        }
        defer {
            Task {
                await AttachmentThumbnailLoadGate.shared.release()
            }
        }
        let result: AttachmentThumbnailDownloadResult?
        if let requestedURL {
            result = await AttachmentThumbnailSingleFlight.shared.perform(key: "initial|\(generationKey)") {
                await AttachmentThumbnailDiskCache.downloadImageResult(
                    from: requestedURL,
                    cacheKey: stableKey,
                    maxPixelSize: requestedMaxPixelSize
                )
            }
        } else {
            result = nil
        }
        guard !Task.isCancelled else { return }
        if let loaded = result?.image {
            if let data = result?.data, let requestedIndexedCacheCommit {
                _ = await requestedIndexedCacheCommit(data)
            }
            guard !Task.isCancelled else { return }
            AvatarImageCache.shared.storePrepared(loaded, for: generationKey, maxPixelSize: requestedMaxPixelSize)
            applyThumbnailState(image: loaded, failed: false)
        } else if (requestedURL == nil || result?.shouldRefreshSignedURL == true),
                  let requestedRecoveryURL,
                  let recoveredURL = await requestedRecoveryURL() {
            let recoveredResult = await AttachmentThumbnailSingleFlight.shared.perform(key: "recovery|\(generationKey)") {
                await AttachmentThumbnailDiskCache.downloadImageResult(
                    from: recoveredURL,
                    cacheKey: stableKey,
                    maxPixelSize: requestedMaxPixelSize
                )
            }
            guard let recovered = recoveredResult.image else {
                applyThumbnailState(image: nil, failed: true)
                return
            }
            guard !Task.isCancelled else { return }
            if let data = recoveredResult.data, let requestedIndexedCacheCommit {
                _ = await requestedIndexedCacheCommit(data)
            }
            guard !Task.isCancelled else { return }
            AvatarImageCache.shared.storePrepared(recovered, for: generationKey, maxPixelSize: requestedMaxPixelSize)
            applyThumbnailState(image: recovered, failed: false)
        } else {
            applyThumbnailState(image: nil, failed: true)
        }
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_STATE_NO_ANIMATION - 修改开始：缩略图完成时禁用隐式动画，减少滚动中重绘压力
    @MainActor
    private func applyThumbnailState(image newImage: UIImage?, failed isFailed: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            image = newImage
            failed = isFailed
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_STATE_NO_ANIMATION - 修改结束：缩略图完成时禁用隐式动画，减少滚动中重绘压力
}

private actor AttachmentThumbnailSingleFlight {
    static let shared = AttachmentThumbnailSingleFlight()
    private var tasks: [String: Task<AttachmentThumbnailDownloadResult, Never>] = [:]

    func perform(
        key: String,
        operation: @escaping @Sendable () async -> AttachmentThumbnailDownloadResult
    ) async -> AttachmentThumbnailDownloadResult {
        if let task = tasks[key] { return await task.value }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_SINGLEFLIGHT_DETACHED - 修改开始：缩略图下载/解码任务脱离主 actor
        let task = Task.detached(priority: .utility) { await operation() }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_SINGLEFLIGHT_DETACHED - 修改结束：缩略图下载/解码任务脱离主 actor
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}

private actor AttachmentThumbnailLoadGate {
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOAD_CONCURRENCY - 修改开始：降低聊天缩略图并发，避免图片批量加载拖慢历史滚动
    static let shared = AttachmentThumbnailLoadGate(limit: 2)
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOAD_CONCURRENCY - 修改结束：降低聊天缩略图并发，避免图片批量加载拖慢历史滚动
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        running += 1
    }

    func release() {
        running = max(0, running - 1)
        if !waiters.isEmpty, running < limit {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

struct AttachmentThumbnailDownloadResult: @unchecked Sendable {
    let image: UIImage?
    let statusCode: Int?
    let data: Data?

    var shouldRefreshSignedURL: Bool {
        guard let statusCode else { return false }
        return statusCode == 401 || statusCode == 403
    }
}

enum AttachmentThumbnailDiskCache {
    static func image(for cacheKey: String, maxPixelSize: Int? = nil) async -> UIImage? {
        // Persistent bytes are owned by MediaLayeredCacheStore/cache_entry.  This legacy
        // API remains as a fail-closed compatibility shim for existing tests/callers.
        nil
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_BACKGROUND_DECODE_HELPERS - 修改开始：缩略图文件读取和解码统一放到后台
    static func localPreparedImage(from url: URL, maxPixelSize: Int? = nil) async -> UIImage? {
        (await localImageResult(from: url, maxPixelSize: maxPixelSize)).image
    }

    private static func localImageResult(from url: URL, maxPixelSize: Int? = nil) async -> AttachmentThumbnailDownloadResult {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize) else {
                return AttachmentThumbnailDownloadResult(image: nil, statusCode: nil, data: nil)
            }
            return AttachmentThumbnailDownloadResult(image: image, statusCode: nil, data: data)
        }.value
    }

    private static func preparedImageResult(
        data: Data,
        statusCode: Int?,
        maxPixelSize: Int? = nil
    ) async -> AttachmentThumbnailDownloadResult {
        await Task.detached(priority: .utility) {
            guard let image = RemoteImageDecoder.preparedImage(from: data, maxPixelSize: maxPixelSize) else {
                return AttachmentThumbnailDownloadResult(image: nil, statusCode: statusCode, data: nil)
            }
            return AttachmentThumbnailDownloadResult(image: image, statusCode: statusCode, data: data)
        }.value
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_BACKGROUND_DECODE_HELPERS - 修改结束：缩略图文件读取和解码统一放到后台

    static func downloadImage(
        from url: URL,
        cacheKey: String,
        maxPixelSize: Int? = nil,
        imageTransport: any RemoteImageTransporting = URLSessionRemoteImageTransport()
    ) async -> UIImage? {
        (await downloadImageResult(
            from: url,
            cacheKey: cacheKey,
            maxPixelSize: maxPixelSize,
            imageTransport: imageTransport
        )).image
    }

    static func downloadImageResult(
        from url: URL,
        cacheKey: String,
        maxPixelSize: Int? = nil,
        imageTransport: any RemoteImageTransporting = URLSessionRemoteImageTransport()
    ) async -> AttachmentThumbnailDownloadResult {
        if url.isFileURL {
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_LOCAL_BACKGROUND_DECODE - 修改开始：本地缩略图读取不占用主线程
            return await localImageResult(from: url, maxPixelSize: maxPixelSize)
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_LOCAL_BACKGROUND_DECODE - 修改结束：本地缩略图读取不占用主线程
        }
        do {
            let result = try await imageTransport.data(from: url)
            if let statusCode = result.statusCode, !(200..<300).contains(statusCode) {
                return AttachmentThumbnailDownloadResult(image: nil, statusCode: statusCode, data: nil)
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_THUMBNAIL_NETWORK_BACKGROUND_DECODE - 修改开始：网络缩略图数据返回后后台解码
            return await preparedImageResult(
                data: result.data,
                statusCode: result.statusCode,
                maxPixelSize: maxPixelSize
            )
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_THUMBNAIL_NETWORK_BACKGROUND_DECODE - 修改结束：网络缩略图数据返回后后台解码
        } catch {
            return AttachmentThumbnailDownloadResult(image: nil, statusCode: nil, data: nil)
        }
    }

    static func cacheKeyFallback(for url: URL) -> String {
        "thumbnail-url|\(stableHash(url.absoluteString))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private struct ContactCardBubbleContent: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let outgoing: Bool
    var onOpen: (IMUser) -> Void

    private var contactName: String {
        (message.attachmentName
            ?? message.text
                .replacingOccurrences(of: "个人名片：", with: "")
                .replacingOccurrences(of: "推荐名片：", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contactID: String {
        message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var contact: IMUser? {
        if !contactID.isEmpty {
            if let user = state.contacts.first(where: { $0.id == contactID || $0.userID == contactID }) {
                return user
            }
            return IMUser(id: contactID, name: contactName.isEmpty ? contactID : contactName, title: "", department: "", phone: "", email: "", status: "在线", enterprise: state.currentEnterprise.name, avatarSeed: UInt(bitPattern: contactID.hashValue), badges: [])
        }
        return nil
    }

    private var displayContact: IMUser {
        contact ?? IMUser(id: "contact_card_display", name: contactName.isEmpty ? "个人名片" : contactName, title: "", department: "", phone: "", email: "", status: "在线", enterprise: state.currentEnterprise.name, avatarSeed: UInt(bitPattern: contactName.hashValue), badges: [])
    }

    var body: some View {
        Button {
            guard let contact else { return }
            onOpen(contact)
        } label: {
            HStack(spacing: 10) {
                AvatarView(name: displayContact.name, seed: displayContact.avatarSeed, size: 42, imageURL: displayContact.avatarURL, avatarVersion: displayContact.avatarVersion, avatarUpdatedAt: displayContact.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: contactID))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(displayContact.name)
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(outgoing ? .white : IMColor.ink)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: contactID,
                            compact: true
                        )
                    }
                    Text("个人名片")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(outgoing ? .white.opacity(0.78) : IMColor.muted)
                }
                Spacer(minLength: 4)
                if contact != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(outgoing ? .white.opacity(0.72) : IMColor.muted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MessageEditedBadge: View {
    let outgoing: Bool

    var body: some View {
        Text("已编辑")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(outgoing ? .white.opacity(0.82) : IMColor.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(outgoing ? .white.opacity(0.16) : IMColor.muted.opacity(0.13))
            )
    }
}

private struct PinnedMessageIconBadge: View {
    let outgoing: Bool

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(outgoing ? IMColor.warning : .white)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(outgoing ? .white : IMColor.warning)
                    .shadow(color: IMColor.warning.opacity(0.22), radius: 6, y: 3)
            )
            .overlay(
                Circle()
                    .stroke(outgoing ? IMColor.warning.opacity(0.45) : .white.opacity(0.9), lineWidth: 1)
            )
            .accessibilityLabel("已置顶")
    }
}

private struct MessageMetaTags: View {
    let message: ChatMessage

    private var tags: [(String, Color)] {
        var items: [(String, Color)] = []
        if message.isFavorited {
            items.append(("收藏", IMColor.brand))
        }
        if let reportState = message.reportState {
            items.append((reportState, IMColor.danger))
        }
        for tag in message.auditTags {
            items.append((tag, IMColor.warning))
        }
        return items
    }

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.0) { tag in
                        StatusPill(title: tag.0, color: tag.1)
                    }
                }
            }
            .frame(maxWidth: 220, alignment: message.isOutgoing ? .trailing : .leading)
        }
    }
}

enum MessageReportCategory: String, CaseIterable, Hashable {
    case illegalTrade = "违规交易"
    case abuse = "辱骂骚扰"
    case spam = "广告引流"
    case sensitivePolitics = "涉政涉敏"

    static var allowedReasons: [String] {
        allCases.map(\.rawValue)
    }
}

enum MessageActionMenuKind: Hashable {
    case reply
    case copy
    case pin
    case favorite
    case forward
    case saveAttachment
    case read
    case edit
    case recall
    case adminDeleteForAll
    case report

    var accessibilityID: String {
        switch self {
        case .reply: return "reply"
        case .copy: return "copy"
        case .pin: return "pin"
        case .favorite: return "favorite"
        case .forward: return "forward"
        case .saveAttachment: return "save_attachment"
        case .read: return "read"
        case .edit: return "edit"
        case .recall: return "recall"
        case .adminDeleteForAll: return "admin_delete_for_all"
        case .report: return "report"
        }
    }
}

enum MessageActionMenuTone: Equatable {
    case normal
    case muted
    case danger

    var color: Color {
        switch self {
        case .normal:
            return IMColor.ink
        case .muted:
            return IMColor.muted
        case .danger:
            return IMColor.danger
        }
    }
}

struct MessageActionMenuDescriptor: Identifiable, Equatable {
    let kind: MessageActionMenuKind
    let symbol: String
    let title: String
    let tone: MessageActionMenuTone
    let showsDividerBefore: Bool
    var disabledReason: String? = nil

    var id: MessageActionMenuKind { kind }
}

func messageReportActionIsAvailable(message: ChatMessage, isCurrentUserSender: Bool) -> Bool {
    let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !messageID.isEmpty,
          !messageID.hasPrefix("local_"),
          !isCurrentUserSender,
          message.kind != .system,
          message.status != .sending,
          message.status != .failed,
          message.status != .recalled,
          !message.isDeletedLocally else {
        return false
    }
    return true
}

func messageActionMenuDescriptors(
    message: ChatMessage,
    canShowReadActions: Bool,
    readActionTitle: String,
    canForward: Bool,
    forwardDisabledReason: String? = nil,
    canSaveAttachment: Bool,
    canFavoriteAsset: Bool,
    canReportMessage: Bool,
    canAdminDeleteForAll: Bool,
    editDisabledReason: String? = nil,
    recallDisabledReason: String?
) -> [MessageActionMenuDescriptor] {
    guard !message.isRTCCallRecordMessage else { return [] }
    var items: [MessageActionMenuDescriptor] = [
        MessageActionMenuDescriptor(kind: .reply, symbol: "arrowshape.turn.up.left", title: "回复", tone: .normal, showsDividerBefore: false),
        MessageActionMenuDescriptor(kind: .pin, symbol: "pin", title: message.isPinned ? "取消置顶" : "置顶", tone: .normal, showsDividerBefore: false)
    ]
    if message.kind == .text {
        items.insert(MessageActionMenuDescriptor(kind: .copy, symbol: "doc.on.doc", title: "拷贝", tone: .normal, showsDividerBefore: false), at: 1)
    }
    if canFavoriteAsset {
        items.append(MessageActionMenuDescriptor(kind: .favorite, symbol: message.isFavorited ? "star.slash" : "star", title: message.isFavorited ? "取消收藏" : "收藏", tone: .normal, showsDividerBefore: false))
    }
    if canForward {
        items.append(MessageActionMenuDescriptor(kind: .forward, symbol: "arrowshape.turn.up.right", title: "转发", tone: .normal, showsDividerBefore: false))
    } else if let forwardDisabledReason,
              !forwardDisabledReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        items.append(
            MessageActionMenuDescriptor(
                kind: .forward,
                symbol: "arrowshape.turn.up.right",
                title: forwardDisabledReason,
                tone: .muted,
                showsDividerBefore: false,
                disabledReason: forwardDisabledReason
            )
        )
    }
    if canSaveAttachment {
        items.append(MessageActionMenuDescriptor(kind: .saveAttachment, symbol: "square.and.arrow.down", title: "保存", tone: .normal, showsDividerBefore: false))
    }
    if canShowReadActions {
        items.append(MessageActionMenuDescriptor(kind: .read, symbol: "checkmark.seal", title: readActionTitle, tone: .normal, showsDividerBefore: true))
    }
    if message.isOutgoing && message.kind == .text {
        items.append(MessageActionMenuDescriptor(
            kind: .edit,
            symbol: "pencil",
            title: editDisabledReason == nil ? "编辑" : "编辑（不可用）",
            tone: editDisabledReason == nil ? .normal : .muted,
            showsDividerBefore: false,
            disabledReason: editDisabledReason
        ))
    }
    if message.isOutgoing {
        let recallTitle = recallDisabledReason == nil
            ? "撤回"
            : (recallDisabledReason?.contains("超过") == true ? "撤回（已超时）" : "撤回（不可用）")
        items.append(MessageActionMenuDescriptor(
            kind: .recall,
            symbol: "arrow.uturn.backward.circle",
            title: recallTitle,
            tone: recallDisabledReason == nil ? .danger : .muted,
            showsDividerBefore: true
        ))
    }
    if canAdminDeleteForAll {
        items.append(MessageActionMenuDescriptor(
            kind: .adminDeleteForAll,
            symbol: "trash.slash.fill",
            title: "对全员删除该消息",
            tone: .danger,
            showsDividerBefore: true
        ))
    }
    if canReportMessage {
        items.append(MessageActionMenuDescriptor(
            kind: .report,
            symbol: "exclamationmark.shield.fill",
            title: "举报此消息",
            tone: .danger,
            showsDividerBefore: true
        ))
    }
    return items
}

func messageReportPreviewText(for message: ChatMessage) -> String {
    switch message.kind {
    case .rtcCallRecord:
        return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
            ?? "[通话记录]"
    case .image:
        return "[图片]"
    case .video:
        return "[视频]"
    case .file:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[文件]" : "[文件] \(name)"
    case .voice:
        return "[语音]"
    case .contactCard:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[名片]" : "[名片] \(name)"
    case .location:
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "[位置]" : "[位置] \(text)"
    case .system:
        return "[系统消息]"
    case .text:
        let text = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "[空消息]" : text
    }
}

private struct MessageActionOverlay: View {
    let message: ChatMessage
    let conversationID: String
    let canShowReadActions: Bool
    let readActionTitle: String
    let canForward: Bool
    let forwardDisabledReason: String?
    let canSaveAttachment: Bool
    let canFavoriteAsset: Bool
    let canReportMessage: Bool
    let canAdminDeleteForAll: Bool
    let editDisabledReason: String?
    let recallDisabledReason: String?
    let onDismiss: () -> Void
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onRead: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onFavorite: () -> Void
    let onForward: () -> Void
    let onSaveAttachment: () -> Void
    let onReport: () -> Void
    let onAdminDeleteForAll: () -> Void
    let onRecall: () -> Void

    private let quickReactions = ["👌", "👍", "😂", "❤️", "👎", "🔥", "🥰"]

    private var menuDescriptors: [MessageActionMenuDescriptor] {
        messageActionMenuDescriptors(
            message: message,
            canShowReadActions: canShowReadActions,
            readActionTitle: readActionTitle,
            canForward: canForward,
            forwardDisabledReason: forwardDisabledReason,
            canSaveAttachment: canSaveAttachment,
            canFavoriteAsset: canFavoriteAsset,
            canReportMessage: canReportMessage,
            canAdminDeleteForAll: canAdminDeleteForAll,
            editDisabledReason: editDisabledReason,
            recallDisabledReason: recallDisabledReason
        )
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 9) {
                Spacer(minLength: 80)
                reactionBar
                MessageActionPreview(message: message, conversationID: conversationID)
                actionMenu
                Spacer(minLength: 18)
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            .padding(.horizontal, 18)
        }
        .colorScheme(.light)
    }

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            Button(action: onMoreReactions) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(IMColor.success.opacity(0.60)))
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().stroke(Color(hex: 0xE7EBF4), lineWidth: 1))
                .shadow(color: Color(hex: 0x29345C).opacity(0.16), radius: 18, y: 10)
        )
        .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
            ReactionTail()
                .offset(x: message.isOutgoing ? -42 : 42, y: 15)
        }
    }

    private var actionMenu: some View {
        VStack(spacing: 0) {
            ForEach(menuDescriptors) { item in
                if item.showsDividerBefore {
                    MessageActionMenuDivider()
                }
                MessageActionMenuRow(
                    symbol: item.symbol,
                    title: item.title,
                    tint: item.tone.color,
                    accessibilityID: "message_action_\(item.kind.accessibilityID)",
                    disabledReason: item.disabledReason,
                    action: action(for: item.kind)
                )
            }
        }
        .frame(width: 268)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color(hex: 0xE7EBF4), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x29345C).opacity(0.18), radius: 24, y: 14)
        )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func action(for kind: MessageActionMenuKind) -> () -> Void {
        switch kind {
        case .reply:
            return onReply
        case .copy:
            return onCopy
        case .pin:
            return onPin
        case .favorite:
            return onFavorite
        case .forward:
            return onForward
        case .saveAttachment:
            return onSaveAttachment
        case .read:
            return onRead
        case .edit:
            return onEdit
        case .recall:
            return onRecall
        case .adminDeleteForAll:
            return onAdminDeleteForAll
        case .report:
            return onReport
        }
    }
}

private struct ReactionTail: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.white.opacity(0.88))
                .frame(width: 9, height: 9)
            Circle()
                .fill(.white.opacity(0.78))
                .frame(width: 5, height: 5)
        }
    }
}

private struct MessageActionPreview: View {
    let message: ChatMessage
    let conversationID: String
    @EnvironmentObject private var state: AppState

    private var displaySenderName: String {
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
        )
    }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
            senderHeader
            previewBubble
                .padding(.leading, message.isOutgoing ? 0 : 38)
                .padding(.trailing, message.isOutgoing ? 38 : 0)
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var senderHeader: some View {
        HStack(spacing: 8) {
            if message.isOutgoing {
                HStack(spacing: 4) {
                    Text(displaySenderName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    CertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
                AvatarView(name: displaySenderName, seed: message.senderAvatarSeed == 0 ? 0x5D6BFF : message.senderAvatarSeed, size: 30, imageURL: message.senderAvatarURL, avatarVersion: message.senderAvatarVersion, avatarUpdatedAt: message.senderAvatarUpdatedAt, certification: state.certificationPresentation(forExactUID: message.senderId))
            } else {
                AvatarView(name: displaySenderName, seed: message.senderAvatarSeed == 0 ? 0x7C6BFF : message.senderAvatarSeed, size: 30, imageURL: message.senderAvatarURL, avatarVersion: message.senderAvatarVersion, avatarUpdatedAt: message.senderAvatarUpdatedAt, certification: state.certificationPresentation(forExactUID: message.senderId))
                HStack(spacing: 4) {
                    Text(displaySenderName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    CertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
            }
        }
        .frame(maxWidth: 324, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var previewBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reply = resolvedVisibleReplyPresentation(
                for: message,
                conversation: state.conversation(id: conversationID),
                state: state
            ) {
                ReplyQuoteBlock(
                    quote: reply.quote, context: reply.context, outgoing: message.isOutgoing, compact: true,
                    hasTransparentBackground: !message.isStickerMessage && AttachmentGIFPresentation.usesBorderlessContainer(message)
                )
            }

            if message.isStickerMessage {
                StickerMessageView(message: message)
            } else if message.kind == .file || message.kind == .image || message.kind == .video {
                FileBubbleContent(message: message, outgoing: message.isOutgoing, conversationID: conversationID)
            } else if message.kind == .contactCard {
                ContactCardBubbleContent(message: message, outgoing: message.isOutgoing) { _ in }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(message.text)
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message.time)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.68) : IMColor.muted)
                }
            }
        }
        .foregroundStyle(message.isOutgoing ? .white : IMColor.ink)
        .padding(.horizontal, AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 13)
        .padding(.vertical, AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AttachmentGIFPresentation.usesBorderlessContainer(message) ? LinearGradient(colors: [.clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing) : (message.isOutgoing ? LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [.white, .white.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: Color.black.opacity(AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 0.10), radius: 12, y: 6)
        )
        .frame(maxWidth: AttachmentGIFPresentation.usesBorderlessContainer(message) ? 228 : 286, alignment: message.isOutgoing ? .trailing : .leading)
    }
}

private struct MessageActionMenuRow: View {
    let symbol: String
    let title: String
    var tint: Color = IMColor.ink
    var accessibilityID: String? = nil
    var disabledReason: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .disabled(disabledReason != nil)
        .buttonStyle(.plain)
        .opacity(disabledReason == nil ? 1 : 0.58)
        .accessibilityIdentifier(accessibilityID ?? "")
        .accessibilityLabel(disabledReason ?? title)
        .accessibilityValue(disabledReason == nil ? "" : "不可用")
    }
}

private struct MessageActionMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(hex: 0xE7EBF4))
            .frame(height: 1)
            .padding(.leading, 56)
            .padding(.trailing, 18)
    }
}

private struct UserQuickActionOverlay: View {
    @EnvironmentObject private var state: AppState
    let user: IMUser
    var showsMentionAction = true
    let onDismiss: () -> Void
    let onMention: () -> Void
    let onDetail: () -> Void

    private var displayName: String {
        state.remarkPreferredDisplayName(for: user)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Capsule()
                    .fill(IMColor.line)
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    AvatarView(name: displayName, seed: user.avatarSeed, size: 52, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.system(size: 19, weight: .black))
                                .foregroundStyle(IMColor.ink)
                                .lineLimit(1)
                            CertificationPillView(
                                exactUID: user.id,
                                compact: true
                            )
                        }
                        if user.isCancelledUser {
                            Text("已注销")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                        if let department = state.departmentSummary(for: user) {
                            Label(department, systemImage: "building.2.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(hex: 0xF0F3FF)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 10) {
                    UserQuickActionRow(symbol: "person.crop.circle", title: "查看详情", tint: IMColor.ink, action: onDetail)
                    if showsMentionAction {
                        UserQuickActionRow(symbol: "at", title: "@TA", tint: IMColor.brand, action: onMention)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color(hex: 0xE7EBF4), lineWidth: 1))
                    .shadow(color: Color(hex: 0x29345C).opacity(0.18), radius: 34, y: 18)
            )
            .padding(.horizontal, 28)
            .frame(maxWidth: 430)
        }
        .colorScheme(.light)
    }
}

private struct UserQuickActionRow: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.78)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ComposerInputBox: View {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    @Binding var selection: NSRange
    let isDisabled: Bool
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_INPUT_BOX - 修改开始：输入框暴露开始编辑回调
    let onBeginEditing: () -> Void
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_INPUT_BOX - 修改结束：输入框暴露开始编辑回调

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: $text,
                dynamicHeight: $dynamicHeight,
                selection: $selection,
                isEditable: !isDisabled,
                // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_INPUT_BOX_PASS - 修改开始：传递开始编辑回调
                onBeginEditing: onBeginEditing
                // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_INPUT_BOX_PASS - 修改结束：传递开始编辑回调

            )
                .frame(height: dynamicHeight)
                .padding(.horizontal, 10)
            if text.isEmpty {
                Text("输入消息")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IMColor.muted.opacity(0.42))
                    .padding(.leading, 16)
                    .padding(.top, 11)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xF3F5FA)))
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    @Binding var selection: NSRange
    let isEditable: Bool
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_TEXT_VIEW - 修改开始：UITextView 暴露开始编辑回调
    let onBeginEditing: () -> Void
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_TEXT_VIEW - 修改结束：UITextView 暴露开始编辑回调

    private let minHeight: CGFloat = 42
    private let maxHeight: CGFloat = 96

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 15, weight: .semibold)
        textView.textColor = UIColor(Color(hex: 0x111827))
        textView.tintColor = UIColor(Color(hex: 0x5B67FF))
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .none
        textView.smartInsertDeleteType = .yes
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.isScrollEnabled = false
        textView.isEditable = isEditable
        textView.selectedRange = boundedSelection(for: textView.text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if text.isEmpty, textView.text != text {
            textView.text = text
        } else if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
        }
        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_TEXT_VIEW_PROPERTY_GUARD - 修改开始：避免输入时重复设置 UITextView 属性
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        let nextTextColor = isEditable ? UIColor(Color(hex: 0x111827)) : UIColor(Color(hex: 0x8A93A8))
        if textView.textColor?.isEqual(nextTextColor) != true {
            textView.textColor = nextTextColor
        }
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_TEXT_VIEW_PROPERTY_GUARD - 修改结束：避免输入时重复设置 UITextView 属性
        let nextSelection = boundedSelection(for: textView.text)
        if textView.markedTextRange == nil, textView.selectedRange != nextSelection {
            textView.selectedRange = nextSelection
        }
        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CALL - 修改开始：复用测高缓存减少重复计算
        recalculateHeight(textView, coordinator: context.coordinator)
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CALL - 修改结束：复用测高缓存减少重复计算
//        recalculateHeight(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_RECALC - 修改开始：输入框测高缓存与无动画高度回写
    private func recalculateHeight(_ textView: UITextView, coordinator: Coordinator) {
        let targetWidth = max(textView.bounds.width, 1)
        let text = textView.text ?? ""
        guard coordinator.shouldMeasureHeight(text: text, width: targetWidth) else { return }
        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_HEIGHT_CONTENT_SIZE - 修改开始：输入时优先复用 UITextView contentSize 减少强制测高
        let contentHeight = textView.contentSize.height
        let fittingHeight = contentHeight.isFinite && contentHeight > 0
            ? contentHeight
            : textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude)).height
        let clampedHeight = min(max(fittingHeight, minHeight), maxHeight)
        let shouldScroll = fittingHeight > maxHeight
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_HEIGHT_CONTENT_SIZE - 修改结束：输入时优先复用 UITextView contentSize 减少强制测高
        coordinator.recordHeightMeasurement(
            text: text,
            width: targetWidth
        )
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
        }
        DispatchQueue.main.async {
            guard coordinator.isCurrentHeightMeasurement(text: text, width: targetWidth) else { return }
            guard abs(dynamicHeight - clampedHeight) > 0.5 else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dynamicHeight = clampedHeight
            }
        }
    }
    // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_RECALC - 修改结束：输入框测高缓存与无动画高度回写

//    private func recalculateHeight(_ textView: UITextView) {
//        let targetWidth = max(textView.bounds.width, 1)
//        let fittingSize = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
//        let clampedHeight = min(max(fittingSize.height, minHeight), maxHeight)
//        DispatchQueue.main.async {
//            if abs(dynamicHeight - clampedHeight) > 0.5 {
//                dynamicHeight = clampedHeight
//            }
//            textView.isScrollEnabled = fittingSize.height > maxHeight
//        }
//    }

    private func boundedSelection(for value: String) -> NSRange {
        let utf16Length = (value as NSString).length
        let location = max(0, min(selection.location, utf16Length))
        let length = max(0, min(selection.length, utf16Length - location))
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CACHE - 修改开始：记录上次输入框测高条件
        private var lastMeasuredText = ""
        private var lastMeasuredWidth: CGFloat = -1
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CACHE - 修改结束：记录上次输入框测高条件

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CACHE_API - 修改开始：输入框测高缓存判断
        func shouldMeasureHeight(text: String, width: CGFloat) -> Bool {
            text != lastMeasuredText || abs(width - lastMeasuredWidth) > 0.5
        }

        func isCurrentHeightMeasurement(text: String, width: CGFloat) -> Bool {
            text == lastMeasuredText && abs(width - lastMeasuredWidth) <= 0.5
        }

        func recordHeightMeasurement(
            text: String,
            width: CGFloat
        ) {
            lastMeasuredText = text
            lastMeasuredWidth = width
        }
        // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CACHE_API - 修改结束：输入框测高缓存判断

        // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_SELECTION_GUARD - 修改开始：避免文本变化和光标变化重复回写 selection
        private func updateParentSelectionIfNeeded(_ range: NSRange) {
            guard !NSEqualRanges(parent.selection, range) else { return }
            parent.selection = range
        }
        // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_SELECTION_GUARD - 修改结束：避免文本变化和光标变化重复回写 selection

        func textViewDidChange(_ textView: UITextView) {
            // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_TEXT_CHANGE_GUARD - 修改开始：输入时只回写真正变化的文本和光标
            let nextText = textView.text ?? ""
            if parent.text != nextText {
                parent.text = nextText
            }
            updateParentSelectionIfNeeded(textView.selectedRange)
            // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_TEXT_CHANGE_GUARD - 修改结束：输入时只回写真正变化的文本和光标
            // JHT_MOD_BEGIN CHAT_SEND_UI_PERF_BEGIN_HEIGHT_CHANGE - 修改开始：文本变化时走缓存测高
            parent.recalculateHeight(textView, coordinator: self)
            // JHT_MOD_END CHAT_SEND_UI_PERF_END_HEIGHT_CHANGE - 修改结束：文本变化时走缓存测高

//            parent.recalculateHeight(textView)
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_DELEGATE - 修改开始：UITextView 开始编辑时通知父级滚动
            parent.onBeginEditing()
            // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_DELEGATE - 修改结束：UITextView 开始编辑时通知父级滚动
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            // JHT_MOD_BEGIN CHAT_INPUT_TYPE_UI_PERF_BEGIN_SELECTION_CHANGE_GUARD - 修改开始：光标未变化时不触发 SwiftUI 状态更新
            updateParentSelectionIfNeeded(textView.selectedRange)
            // JHT_MOD_END CHAT_INPUT_TYPE_UI_PERF_END_SELECTION_CHANGE_GUARD - 修改结束：光标未变化时不触发 SwiftUI 状态更新
        }
    }
}

enum VoiceRecordingAppActivity: Equatable {
    case active
    case inactive
    case background

    init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}

enum VoiceRecordingComposerPhase: Equatable {
    case idle
    case requesting
    case recording
    case finalizing
    case preview
}

enum VoiceRecordingComposerFeedback: Equatable {
    case tooShort

    var message: String {
        switch self {
        case .tooShort:
            return "说话时间太短"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .tooShort:
            return "chat_voice_recording_feedback_too_short"
        }
    }
}

enum VoiceRecordingComposerLifecycleEffect: Equatable {
    case none
    case cancelAndReset
}

struct VoiceRecordingComposerLifecycle: Equatable {
    private(set) var feedback: VoiceRecordingComposerFeedback?

    mutating func presentTooShortFeedback() {
        feedback = .tooShort
    }

    mutating func beginNewAttempt() {
        feedback = nil
    }

    mutating func clearFeedback() {
        feedback = nil
    }

    mutating func transition(
        to appActivity: VoiceRecordingAppActivity,
        recordingPhase: VoiceRecordingComposerPhase
    ) -> VoiceRecordingComposerLifecycleEffect {
        guard appActivity != .active else { return .none }
        feedback = nil
        if appActivity == .inactive, recordingPhase == .requesting {
            // The system microphone permission sheet temporarily makes the app
            // inactive. Keep that user-triggered request alive unless the app
            // actually reaches the background.
            return .none
        }
        return recordingPhase == .idle ? .none : .cancelAndReset
    }
}

private struct VoiceMessageRecording {
    let data: Data
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let durationMS: Int
    let waveform: [Int]

    func replacingDurationMS(_ durationMS: Int) -> VoiceMessageRecording {
        VoiceMessageRecording(
            data: data,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            durationMS: VoiceMessagePayload.normalizedDurationMS(durationMS),
            waveform: waveform
        )
    }
}

private enum VoiceMessageRecorderError: LocalizedError {
    case tooShort
    case emptyData
    case invalidDuration
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .tooShort:
            return "说话时间太短"
        case .emptyData:
            return "语音数据读取失败，请重新录制"
        case .invalidDuration:
            return "语音时长无法读取，请重新录制"
        case .failedToStart:
            return "录音启动失败，请重试"
        }
    }
}

@MainActor
private final class VoiceMessageRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequesting = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var elapsedMS = 0
    @Published var isCanceling = false
    @Published private(set) var waveformSamples: [Int] = []

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isBusy: Bool {
        isRequesting || isRecording || isFinalizing
    }

    var composerPhase: VoiceRecordingComposerPhase {
        if isRequesting { return .requesting }
        if isRecording { return .recording }
        if isFinalizing { return .finalizing }
        return .idle
    }

    func beginRequesting() -> UInt64? {
        guard !isBusy else { return nil }
        resetRuntime(removeFile: true)
        generation &+= 1
        isRequesting = true
        return generation
    }

    func cancelRequest(_ requestGeneration: UInt64) {
        guard generation == requestGeneration, isRequesting else { return }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @discardableResult
    func cancelPendingStart() -> Bool {
        guard isRequesting else { return false }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return true
    }

    @discardableResult
    func start(requestGeneration: UInt64, onAutoFinished: @escaping () -> Void) throws -> Bool {
        guard generation == requestGeneration, isRequesting else { return false }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMessageRecordings", isDirectory: true)
        let fileURL = directory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        recordingURL = fileURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 64_000
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: TimeInterval(VoiceMessagePayload.maxDurationMS) / 1_000.0) else {
                throw VoiceMessageRecorderError.failedToStart
            }
            self.recorder = recorder
        } catch {
            resetRuntime(removeFile: true)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
        elapsedMS = 0
        waveformSamples = []
        isCanceling = false
        isRequesting = false
        isRecording = true
        startMetering()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceMessagePayload.maxDurationMS) * 1_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.generation == requestGeneration,
                  self.isRecording else { return }
            onAutoFinished()
        }
        return true
    }

    func beginFinalizing() -> UInt64? {
        guard isRecording else { return nil }
        elapsedMS = currentDurationMS()
        isRecording = false
        isFinalizing = true
        meterTimer?.invalidate()
        meterTimer = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        return generation
    }

    func finish(requestGeneration: UInt64, cancelled: Bool) throws -> VoiceMessageRecording? {
        guard generation == requestGeneration, isFinalizing else { return nil }
        let recordedWaveform = waveformSamples
        let url = recordingURL
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        defer {
            removeRecordingFile(url)
            resetRuntime(removeFile: false)
        }
        guard !cancelled else { return nil }
        guard let url else {
            throw VoiceMessageRecorderError.emptyData
        }
        guard let decodedPlayer = try? AVAudioPlayer(contentsOf: url),
              decodedPlayer.prepareToPlay(),
              let durationMS = VoiceMessagePayload.decodedDurationMS(decodedPlayer.duration) else {
            throw VoiceMessageRecorderError.invalidDuration
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw VoiceMessageRecorderError.emptyData
        }
        guard durationMS >= VoiceMessagePayload.minDurationMS else {
            throw VoiceMessageRecorderError.tooShort
        }
        return VoiceMessageRecording(
            data: data,
            name: url.lastPathComponent,
            mimeType: "audio/mp4",
            sizeBytes: Int64(data.count),
            durationMS: durationMS,
            waveform: VoiceMessagePayload.normalizedWaveform(recordedWaveform)
        )
    }

    func cancel() {
        if isRecording, let requestGeneration = beginFinalizing() {
            _ = try? finish(requestGeneration: requestGeneration, cancelled: true)
            return
        }
        generation &+= 1
        resetRuntime(removeFile: true)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMeter()
            }
        }
    }

    private func sampleMeter() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        elapsedMS = currentDurationMS()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = Int(round(min(max((Double(power) + 52.0) / 52.0, 0), 1) * 100))
        waveformSamples.append(max(4, normalized))
        if waveformSamples.count > 160 {
            waveformSamples.removeFirst(waveformSamples.count - 160)
        }
    }

    private func currentDurationMS() -> Int {
        guard let recorder else { return 0 }
        let seconds = recorder.currentTime
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return VoiceMessagePayload.normalizedDurationMS(Int((seconds * 1_000).rounded()))
    }

    private func resetRuntime(removeFile: Bool) {
        let url = recordingURL
        meterTimer?.invalidate()
        meterTimer = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        recorder?.stop()
        recorder = nil
        recordingURL = nil
        isRequesting = false
        isRecording = false
        isFinalizing = false
        isCanceling = false
        elapsedMS = 0
        if removeFile {
            removeRecordingFile(url)
        }
    }

    private func removeRecordingFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class VoiceMessagePreviewController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var recording: VoiceMessageRecording?
    @Published private(set) var playbackState: VoiceMessagePlaybackState?
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func setRecording(_ recording: VoiceMessageRecording) {
        stopPlayback(resetProgress: true)
        self.recording = recording
        playbackState = VoiceMessagePlaybackState(
            messageID: "voice-preview",
            elapsedMS: 0,
            durationMS: recording.durationMS
        )
    }

    func togglePlayback() {
        guard let recording else { return }
        if isPlaying {
            pausePlayback()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try self.player ?? AVAudioPlayer(data: recording.data)
            player.delegate = self
            guard player.prepareToPlay(),
                  let durationMS = VoiceMessagePayload.decodedDurationMS(player.duration) else {
                throw VoiceMessageRecorderError.invalidDuration
            }
            let currentElapsedMS = playbackState?.elapsedMS ?? 0
            if currentElapsedMS >= durationMS {
                player.currentTime = 0
                playbackState = VoiceMessagePlaybackState(
                    messageID: "voice-preview",
                    elapsedMS: 0,
                    durationMS: durationMS,
                    isPlaying: false
                )
            }
            guard player.play() else {
                throw VoiceMessageRecorderError.failedToStart
            }
            self.player = player
            isPlaying = true
            refreshProgress()
            startProgressTimer()
        } catch {
            stopPlayback(resetProgress: true)
        }
    }

    func discard() {
        stopPlayback(resetProgress: true)
        recording = nil
        playbackState = nil
    }

    func takeRecordingForSending() -> VoiceMessageRecording? {
        let value = recording
        discard()
        return value
    }

    private func pausePlayback() {
        player?.pause()
        refreshProgress()
        stopProgressTimer()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopPlayback(resetProgress: Bool) {
        stopProgressTimer()
        player?.stop()
        player = nil
        isPlaying = false
        if resetProgress, let recording {
            playbackState = VoiceMessagePlaybackState(messageID: "voice-preview", elapsedMS: 0, durationMS: recording.durationMS)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func refreshProgress() {
        guard let player else { return }
        guard let durationMS = VoiceMessagePayload.decodedDurationMS(player.duration) else {
            stopPlayback(resetProgress: true)
            return
        }
        let elapsedMS = min(durationMS, max(0, Int((player.currentTime * 1_000).rounded())))
        playbackState = VoiceMessagePlaybackState(
            messageID: "voice-preview",
            elapsedMS: elapsedMS,
            durationMS: durationMS,
            isPlaying: player.isPlaying
        )
        guard !player.isPlaying else { return }
        stopProgressTimer()
        isPlaying = false
        if elapsedMS >= durationMS {
            finishPlayback(playerID: ObjectIdentifier(player), reachedEnd: true)
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(playerID: playerID, reachedEnd: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(playerID: playerID, reachedEnd: false)
        }
    }

    private func finishPlayback(playerID: ObjectIdentifier, reachedEnd: Bool) {
        guard let finishedPlayer = player,
              ObjectIdentifier(finishedPlayer) == playerID else { return }
        stopProgressTimer()
        if reachedEnd,
           let durationMS = VoiceMessagePayload.decodedDurationMS(finishedPlayer.duration) {
            playbackState = VoiceMessagePlaybackState(
                messageID: "voice-preview",
                elapsedMS: durationMS,
                durationMS: durationMS,
                isPlaying: false
            )
        } else if let recording {
            playbackState = VoiceMessagePlaybackState(
                messageID: "voice-preview",
                elapsedMS: 0,
                durationMS: recording.durationMS,
                isPlaying: false
            )
        }
        finishedPlayer.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private struct VoiceWaveformBars: View {
    let samples: [Int]
    let active: Bool
    let outgoing: Bool
    var height: CGFloat = 28
    var barCount: Int = 24

    private var displaySamples: [Int] {
        VoiceMessagePayload.normalizedWaveform(samples.isEmpty ? Array(repeating: 18, count: barCount) : samples)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(displaySamples.prefix(barCount).enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(barColor.opacity(active ? 0.98 : 0.72))
                    .frame(width: 3, height: max(4, CGFloat(sample) / 100.0 * height))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        outgoing ? .white : IMColor.brand
    }
}

private struct VoiceRecordingOverlay: View {
    let elapsedMS: Int
    let waveform: [Int]
    let isCanceling: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(isCanceling ? IMColor.danger : IMColor.brand)
            VStack(alignment: .leading, spacing: 5) {
                Text(isCanceling ? "松开取消" : "正在录音 \(VoiceMessagePayload.durationLabel(durationMS: elapsedMS))")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.ink)
                VoiceWaveformBars(samples: waveform, active: true, outgoing: false, height: 18, barCount: 32)
            }
            Spacer()
            Text("60s")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill((isCanceling ? IMColor.danger : IMColor.brand).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke((isCanceling ? IMColor.danger : IMColor.brand).opacity(0.18)))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCanceling ? "松开取消语音消息" : "正在录制语音消息")
    }
}

private struct VoiceRecordingFeedbackPanel: View {
    let feedback: VoiceRecordingComposerFeedback

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(IMColor.warning)
            Text(feedback.message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IMColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(IMColor.warning.opacity(0.20))
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(feedback.accessibilityIdentifier)
        .accessibilityLabel(feedback.message)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct VoiceRecordingPreviewPanel: View {
    @ObservedObject var preview: VoiceMessagePreviewController
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        if let recording = preview.recording {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        preview.togglePlayback()
                    } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_play_button")
                    .accessibilityLabel(preview.isPlaying ? "暂停预览语音" : "回放预览语音")

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("语音待发送")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Spacer()
                            Text(previewCountdownText(recording))
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(IMColor.muted)
                        }
                        VoiceWaveformBars(samples: recording.waveform, active: preview.isPlaying, outgoing: false, height: 18, barCount: 36)
                        ProgressView(value: preview.playbackState?.progress ?? 0)
                            .tint(IMColor.brand)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        cancel()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.danger)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Capsule().fill(IMColor.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_cancel_button")

                    Button {
                        send()
                    } label: {
                        Label("发送", systemImage: "paperplane.fill")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Capsule().fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_send_button")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(IMColor.brand.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.brand.opacity(0.16)))
            )
            .accessibilityIdentifier("chat_voice_preview_panel")
            .accessibilityElement(children: .contain)
        }
    }

    private func previewCountdownText(_ recording: VoiceMessageRecording) -> String {
        guard let state = preview.playbackState, preview.isPlaying else {
            return VoiceMessagePayload.durationLabel(durationMS: recording.durationMS)
        }
        let remaining = state.remainingLabel
        return remaining.isEmpty ? "0秒" : "剩余 \(remaining)"
    }
}

private struct VoiceRecordPad: View {
    let isRecording: Bool
    let isRequesting: Bool
    let isFinalizing: Bool
    let elapsedMS: Int
    let isCanceling: Bool
    let start: () -> Void
    let finish: (Bool) -> Void
    let updateCanceling: (Bool) -> Void

    var body: some View {
        let drag = DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isRecording else { return }
                updateCanceling(value.translation.height < -54)
            }
            .onEnded { value in
                guard isRecording else { return }
                let shouldCancel = value.translation.height < -54
                updateCanceling(false)
                finish(shouldCancel)
            }

        Button {
            if isRequesting || isRecording {
                finish(false)
            } else {
                start()
            }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(isCanceling ? IMColor.danger : IMColor.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isCanceling ? IMColor.danger.opacity(0.10) : Color(hex: 0xF3F5FA))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke((isRequesting || isRecording || isFinalizing) ? IMColor.brand.opacity(0.26) : .clear, lineWidth: 1))
                )
        }
            .buttonStyle(.plain)
            .disabled(isFinalizing)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .simultaneousGesture(drag)
            .accessibilityIdentifier("chat_voice_record_pad")
            .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        if isCanceling { return "松开取消" }
        if isRequesting { return "正在启动录音 · 点击取消" }
        if isFinalizing { return "正在生成语音预览…" }
        if isRecording {
            let duration = VoiceMessagePayload.durationLabel(durationMS: elapsedMS)
            return duration.isEmpty ? "点击发送 · 上滑取消" : "\(duration) · 点击发送"
        }
        return "点击开始录音"
    }

    private var accessibilityLabel: String {
        if isRequesting { return "取消录音启动" }
        if isFinalizing { return "正在生成语音预览" }
        return isRecording ? "停止并生成语音预览" : "开始录制语音消息"
    }
}

private struct BatchForwardSelectionBar: View {
    let selectedCount: Int
    let onCancel: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("取消", action: onCancel)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(minWidth: 68, minHeight: 44)
                .accessibilityIdentifier("batch_forward_cancel")

            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 条")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text("发送时按原会话顺序排列")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Button(action: onForward) {
                Label("转发", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(IMColor.brand))
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("batch_forward_choose_targets")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IMColor.line)
                .frame(height: 1)
        }
    }
}

private struct EmojiPickerRuntimeContext: Equatable {
    let scope: EmojiPickerScope
    let catalogBaseURL: URL
}

@MainActor
private func currentEmojiPickerRuntimeContext(state: AppState) -> EmojiPickerRuntimeContext? {
    guard state.isAuthenticated else { return nil }
    let context = IMAPIContext.load()
    let appID = IMAPIContext.normalizedIOSAppID(context.appID)
    let accountID = context.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let currentTenantID = state.currentEnterprise.id.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentUserIDs = Set([
        state.currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines),
        state.currentUser.userID.trimmingCharacters(in: .whitespacesAndNewlines),
    ].filter { !$0.isEmpty })
    guard context.hasIMSession,
          !accountID.isEmpty,
          tenantID == currentTenantID,
          currentUserIDs.contains(imUID),
          let scope = try? EmojiPickerScope(
              product: "ios",
              appID: appID,
              accountID: accountID,
              tenantID: tenantID,
              imUID: imUID
          ) else {
        return nil
    }

    let catalogBaseURL = IMAPIClient.normalizedIMAPIBaseURL(context.imAPIBaseURL)
        ?? IMAPIClient.configuredAPIBases().imBase
    guard catalogBaseURL.host?.hasSuffix(".invalid") != true else { return nil }
    return EmojiPickerRuntimeContext(scope: scope, catalogBaseURL: catalogBaseURL)
}

@MainActor
private func emojiPickerRuntimeTaskKey(state: AppState, isOpen: Bool) -> String {
    [
        state.isAuthenticated ? "authenticated" : "signed-out",
        state.currentAppID,
        state.currentEnterprise.id,
        state.currentUser.id,
        state.currentUser.userID,
        isOpen ? "open" : "closed",
    ].joined(separator: "|")
}

enum ChatComposerToolAction: String, Equatable {
    case mediaAttachment
    case fileAttachment
    case voiceCall
    case videoCall
    case contactCard
}

struct ChatComposerToolDescriptor: Identifiable, Equatable {
    let action: ChatComposerToolAction
    let symbol: String
    let title: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    var id: ChatComposerToolAction { action }
}

func chatComposerToolDescriptors(
    allowsVoiceCall: Bool,
    allowsVideoCall: Bool
) -> [ChatComposerToolDescriptor] {
    var tools = [
        ChatComposerToolDescriptor(
            action: .mediaAttachment,
            symbol: "photo.on.rectangle",
            title: "照片/视频",
            accessibilityIdentifier: "chat_tool_media_attachment",
            accessibilityLabel: "选择照片或视频附件"
        ),
        ChatComposerToolDescriptor(
            action: .fileAttachment,
            symbol: "folder",
            title: "文件",
            accessibilityIdentifier: "chat_tool_file_attachment",
            accessibilityLabel: "选择文件附件"
        )
    ]
    if allowsVoiceCall {
        tools.append(ChatComposerToolDescriptor(
            action: .voiceCall,
            symbol: "phone.fill",
            title: "通话",
            accessibilityIdentifier: "chat_tool_voice_call",
            accessibilityLabel: "发起语音通话"
        ))
    }
    if allowsVideoCall {
        tools.append(ChatComposerToolDescriptor(
            action: .videoCall,
            symbol: "video.fill",
            title: "视频",
            accessibilityIdentifier: "chat_tool_video_call",
            accessibilityLabel: "发起视频通话"
        ))
    }
    tools.append(ChatComposerToolDescriptor(
        action: .contactCard,
        symbol: "person.crop.rectangle",
        title: "名片",
        accessibilityIdentifier: "chat_tool_contact_card",
        accessibilityLabel: "发送联系人名片"
    ))
    return tools
}

struct ChatComposer: View {
    let conversationID: String
    @Binding var input: String
    @Binding var replyQuote: String?
    @Binding var replyContext: MessageReplyContext?
    @Binding var showTools: Bool
    @Binding var showEmoji: Bool
    @Binding var mentionAllSelected: Bool
    var mentionGroupID = ""
    var mentionMembers: [IMUser] = []
    var mentionMembersLoading = false
    var canMentionAll = false
    var isDisabled = false
    var showsDisabledNotice = true
    var disabledTitle = AppState.globalMutedMessage
    var disabledReason = ""
    var friendActionTitle: String?
    var isApplyingFriend = false
    var allowsVoiceCall = true
    var allowsVideoCall = false
    var voiceCallAccessibilityHint = ""
    var videoCallAccessibilityHint = ""
    var startVoiceCall: () -> Void = {}
    var startVideoCall: () -> Void = {}
    var applyFriend: () -> Void = {}
    // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_COMPOSER_PARAM - 修改开始：ChatComposer 接收输入框聚焦回调
    var onBeginEditing: () -> Void = {}
    // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_COMPOSER_PARAM - 修改结束：ChatComposer 接收输入框聚焦回调
    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_PARAM - 修改开始：Composer 操作触发滚动到最新消息回调
    var onRequestLatestScroll: () -> Void = {}
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_PARAM - 修改结束：Composer 操作触发滚动到最新消息回调

    let send: (String, Bool, [MentionIdentity]) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var showPhotoPicker = false
    @State private var showStickerPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showContactPicker = false
    @State private var inputHeight: CGFloat = 42
    @State private var inputSelection = NSRange(location: 0, length: 0)
    @State private var expressionTab: ChatExpressionTab = .emoji
    @State private var emojiPickerStore: EmojiPickerStoreAdapter?
    @State private var selectedMentionUsers: [MentionIdentity] = []
    @State private var pendingAttachmentSelection: PendingAttachmentSelectionBatch?
    @State private var remoteMentionSuggestions: [IMUser] = []
    @State private var remoteMentionQuery = ""
    @State private var remoteMentionMembersLoading = false
    @State private var remoteMentionLookupReady = false
    @State private var isVoiceInputMode = false
    @StateObject private var voiceRecorder = VoiceMessageRecorderController()
    @StateObject private var voicePreview = VoiceMessagePreviewController()
    @State private var voiceRecordingLifecycle = VoiceRecordingComposerLifecycle()

    private var tools: [ChatComposerToolDescriptor] {
        chatComposerToolDescriptors(
            allowsVoiceCall: allowsVoiceCall,
            allowsVideoCall: allowsVideoCall
        )
    }

    private var toolGridColumns: [GridItem] {
        let count = sizeCategory.isAccessibilityCategory ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func accessibilityHint(for tool: ChatComposerToolDescriptor) -> String {
        switch tool.action {
        case .voiceCall:
            return voiceCallAccessibilityHint
        case .videoCall:
            return videoCallAccessibilityHint
        case .mediaAttachment, .fileAttachment, .contactCard:
            return ""
        }
    }

    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_COMPOSER_HELPERS - 修改开始：Composer 侧附件选择/确认发送定位日志
    private func chatBackStuckDiagnostic(_ event: String, force: Bool = false, extra: String = "") {
#if DEBUG
        guard force || pendingAttachmentSelection != nil else { return }
        let pendingCount = pendingAttachmentSelection?.selections.count ?? 0
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortChatBackDiagnosticID(conversationID)) input_len=\(input.count) pending_attachments=\(pendingCount)\(suffix)")
#endif
    }

    private static func shortChatBackDiagnosticID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    private static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_COMPOSER_HELPERS - 修改结束：Composer 侧附件选择/确认发送定位日志

	    private let emojis = [
	        "👍", "👎", "❤️", "😂", "🤣", "🙏", "👏", "🎉",
	        "🔥", "✅", "❌", "👀", "😀", "😃", "😄", "😁",
	        "😆", "😅", "😊", "😉", "😍", "🤩", "😎", "🥳",
	        "🤔", "😢", "😭", "😡", "😱", "👋", "👌", "✌️",
	        "🤞", "🤙", "👈", "👉", "☝️", "✊", "🤝", "💪",
	        "🙌", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
	        "💔", "❤️‍🔥", "💕", "💯", "💬", "📌", "📎", "📝",
	        "📅", "⏰", "🚀", "💡", "🔒", "🔔", "📣", "📈",
	        "⚠️", "❗", "❓", "🔍", "✨", "🌹", "☕", "⭐"
	    ]

    private var activeMentionQuery: String? {
        activeMentionRange.map { String(input[$0]).dropFirst() }.map(String.init)
    }

    private var activeMentionRange: Range<String.Index>? {
        guard let atIndex = input.lastIndex(of: "@") else { return nil }
        if atIndex > input.startIndex {
            let previous = input[input.index(before: atIndex)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }
        let queryStart = input.index(after: atIndex)
        let query = input[queryStart...]
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return atIndex..<input.endIndex
    }

    private var mentionSuggestions: [IMUser]? {
        mentionSuggestions(for: activeMentionQuery)
    }

    // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：Composer 单次重绘复用已解析的 @ 查询，减少输入时重复扫描
    private func mentionSuggestions(for query: String?) -> [IMUser]? {
        guard !isDisabled, let query else { return nil }
        let normalizedQuery = IMUserSearchMatcher.normalized(query)
        let localMembers = deduplicatedMentionMembers(mentionMembers).filter { !$0.isCancelledUser }
        let localMatches = normalizedQuery.isEmpty
            ? localMembers
            : localMembers
                .compactMap { user -> (user: IMUser, score: Int, name: String)? in
                    let name = state.remarkPreferredDisplayName(for: user)
                    guard let score = IMUserSearchMatcher.matchScore(user: user.withName(name), query: query) else {
                        return nil
                    }
                    return (user, score, name)
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map(\.user)

        let shouldUseRemote = remoteMentionQuery == query && (remoteMentionLookupReady || remoteMentionMembersLoading)
        guard shouldUseRemote else {
            return localMatches
        }

        let remoteMembers = deduplicatedMentionMembers(remoteMentionSuggestions).filter { !$0.isCancelledUser }
        let combinedMembers = normalizedQuery.isEmpty
            ? localMatches + remoteMembers
            : remoteMembers + localMatches
        return deduplicatedMentionMembers(combinedMembers)
    }

    private var mentionSearchTaskKey: String {
        mentionSearchTaskKey(for: activeMentionQuery)
    }

    private func mentionSearchTaskKey(for query: String?) -> String {
        "\(mentionGroupID)|\(query ?? "__inactive__")"
    }

    private var shouldShowMentionAllSuggestion: Bool {
        shouldShowMentionAllSuggestion(for: activeMentionQuery)
    }

    private func shouldShowMentionAllSuggestion(for query: String?) -> Bool {
        guard canMentionAll, let query else { return false }
        let normalizedQuery = IMUserSearchMatcher.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let aliases = ["@所有人", "所有人", "all", "suoyouren", "syr"]
        return aliases
            .map(IMUserSearchMatcher.normalized)
            .contains { $0.contains(normalizedQuery) || normalizedQuery.contains($0) }
    }
    // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束

    private var canSendInput: Bool {
        containsSendableMessageContent(input)
    }

    private var emojiPickerTaskKey: String {
        emojiPickerRuntimeTaskKey(state: state, isOpen: showEmoji && expressionTab == .emoji)
    }

    private var unicodeEmojiPicker: AnyView? {
        guard let emojiPickerStore else { return nil }
        return AnyView(
            EmojiPickerView(
                store: emojiPickerStore,
                onSelect: insertUnicodeEmoji
            )
        )
    }

    @MainActor
    private func synchronizeEmojiPickerRuntime() async {
        guard let runtime = currentEmojiPickerRuntimeContext(state: state) else {
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            state.emojiPickerCatalogRuntime.reset()
            return
        }
        if let emojiPickerStore {
            if emojiPickerStore.scope != runtime.scope {
                emojiPickerStore.switchScope(to: runtime.scope)
                state.emojiPickerCatalogRuntime.reset()
            }
            return
        }
        guard showEmoji, expressionTab == .emoji else { return }
        switch state.emojiPickerCatalogRuntime.begin(
            scope: runtime.scope,
            baseURL: runtime.catalogBaseURL
        ) {
        case .useCatalog(let catalog):
            emojiPickerStore = try? EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .composer
            )
            return
        case .useFallback:
            return
        case .attempt:
            break
        }
        do {
            let catalog = try await EmojiPickerCatalogLoader().load(baseURL: runtime.catalogBaseURL)
            guard currentEmojiPickerRuntimeContext(state: state) == runtime else {
                state.emojiPickerCatalogRuntime.cancelAttempt(
                    scope: runtime.scope,
                    baseURL: runtime.catalogBaseURL
                )
                return
            }
            let store = try EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .composer
            )
            guard state.emojiPickerCatalogRuntime.recordSuccess(
                catalog,
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            ) else { return }
            emojiPickerStore = store
        } catch is CancellationError {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch let error as URLError where error.code == .cancelled {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch {
            let shouldNotify = state.emojiPickerCatalogRuntime.recordFailure(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            guard shouldNotify else { return }
            guard showEmoji, expressionTab == .emoji else { return }
            state.toast = "表情目录暂不可用，已使用本地 Emoji"
        }
    }

    private func insertUnicodeEmoji(_ item: EmojiCatalogItem) {
        insertEmojiAtCurrentSelection(item.emoji)
    }

    private func insertEmojiAtCurrentSelection(_ emoji: String) {
        let result = insertEmojiAtSelection(
            text: input,
            selectionStart: inputSelection.location,
            selectionEnd: inputSelection.location + inputSelection.length,
            emoji: emoji
        )
        input = result.text
        inputSelection = NSRange(
            location: result.selectionStart,
            length: result.selectionEnd - result.selectionStart
        )
    }

    @MainActor
    private func purgeEmojiPickerIfIdentityChanged() {
        guard let emojiPickerStore,
              currentEmojiPickerRuntimeContext(state: state)?.scope != emojiPickerStore.scope
        else {
            return
        }
        emojiPickerStore.clearIdentity()
        self.emojiPickerStore = nil
    }

	    var body: some View {
	        VStack(spacing: 10) {
            if isDisabled && showsDisabledNotice {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.warning)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(IMColor.warning.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disabledTitle)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(disabledReason)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    if let friendActionTitle {
                        Button {
                            applyFriend()
                        } label: {
                            if isApplyingFriend {
                                ProgressView()
                                    .scaleEffect(0.72)
                                    .tint(.white)
                                    .frame(width: 20, height: 20)
                            } else {
                                Text(friendActionTitle)
                                    .font(.system(size: 12, weight: .black))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isApplyingFriend)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(IMColor.brand))
                        .accessibilityIdentifier("chat_apply_friend_button")
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(IMColor.warning.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.warning.opacity(0.18)))
                )
                .accessibilityIdentifier("chat_composer_disabled_notice")
            }

            if voiceRecorder.isRecording {
                VoiceRecordingOverlay(
                    elapsedMS: voiceRecorder.elapsedMS,
                    waveform: voiceRecorder.waveformSamples,
                    isCanceling: voiceRecorder.isCanceling
                )
            }

            if isVoiceInputMode, let feedback = voiceRecordingLifecycle.feedback {
                VoiceRecordingFeedbackPanel(feedback: feedback)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isVoiceInputMode, voicePreview.recording != nil {
                VoiceRecordingPreviewPanel(
                    preview: voicePreview,
                    send: sendPendingVoiceRecording,
                    cancel: cancelPendingVoiceRecording
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

	            if let replyQuote {
	                HStack(alignment: .center, spacing: 8) {
                    ReplyQuoteBlock(quote: replyQuote, context: replyContext, outgoing: false, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.replyQuote = nil
                        self.replyContext = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IMColor.muted)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.08)))
            }

            if let suggestions = mentionSuggestions {
                MentionSuggestionPanel(
	                    suggestions: suggestions,
	                    showsMentionAll: shouldShowMentionAllSuggestion,
	                    hasQuery: IMUserSearchMatcher.normalized(activeMentionQuery ?? "").isEmpty == false,
	                    isLoading: (mentionMembersLoading || remoteMentionMembersLoading) && suggestions.isEmpty,
	                    onSelect: insertMention,
	                    onSelectAll: insertMentionAll
	                )
            }

	            HStack(spacing: 9) {
                Button {
                    toggleVoiceInputMode()
                } label: {
                    Image(systemName: isVoiceInputMode ? "keyboard.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(IMColor.brand)
                        .frame(width: 38, height: 38)
                }
                .accessibilityIdentifier("chat_voice_toggle_button")

                if isVoiceInputMode {
                    VoiceRecordPad(
                        isRecording: voiceRecorder.isRecording,
                        isRequesting: voiceRecorder.isRequesting,
                        isFinalizing: voiceRecorder.isFinalizing,
                        elapsedMS: voiceRecorder.elapsedMS,
                        isCanceling: voiceRecorder.isCanceling,
                        start: beginVoiceRecording,
                        finish: { cancelled in finishVoiceRecording(cancelled: cancelled) },
                        updateCanceling: { voiceRecorder.isCanceling = $0 }
                    )
                    Button {
                        guard !isDisabled else {
                            state.toast = disabledReason
                            return
                        }
                        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_PLUS_VOICE_MODE - 修改开始：语音模式点击 + 时回到最新消息
                        requestLatestScrollForComposerAction()
                        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_PLUS_VOICE_MODE - 修改结束：语音模式点击 + 时回到最新消息
                        dismissActiveChatKeyboard()
                        withoutComposerLayoutAnimation {
                            showTools.toggle()
                            showEmoji = false
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityIdentifier("chat_tools_toggle_button")
                } else {
                    Button {
                        guard !isDisabled else {
                            state.toast = disabledReason
                            return
                        }
                        dismissActiveChatKeyboard()
                        withoutComposerLayoutAnimation {
                            showEmoji.toggle()
                            showTools = false
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityIdentifier("chat_emoji_toggle_button")
                    ComposerInputBox(
                        text: $input,
                        dynamicHeight: $inputHeight,
                        selection: $inputSelection,
                        isDisabled: isDisabled,
                        // JHT_MOD_BEGIN CHAT_INPUT_FOCUS_SCROLL_BEGIN_COMPOSER_PASS - 修改开始：ChatComposer 透传输入框聚焦回调
                        onBeginEditing: onBeginEditing
                        // JHT_MOD_END CHAT_INPUT_FOCUS_SCROLL_END_COMPOSER_PASS - 修改结束：ChatComposer 透传输入框聚焦回调
                    )
                        .disabled(isDisabled)
                        .accessibilityIdentifier("chat_message_input")
                    Button {
                        guard !isDisabled else {
                            state.toast = disabledReason
                            return
                        }
                        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_PLUS_TEXT_MODE - 修改开始：文字模式点击 + 时回到最新消息
                        requestLatestScrollForComposerAction()
                        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_PLUS_TEXT_MODE - 修改结束：文字模式点击 + 时回到最新消息
                        dismissActiveChatKeyboard()
                        withoutComposerLayoutAnimation {
                            showTools.toggle()
                            showEmoji = false
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityIdentifier("chat_tools_toggle_button")
                    Button(action: sendCurrentInput) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(isDisabled || !canSendInput ? Color(hex: 0xB9C0D6) : IMColor.brand))
                    }
                    .disabled(isDisabled || !canSendInput)
                    .accessibilityIdentifier("chat_send_button")
                }
	            }

	            if showEmoji && !isDisabled {
	                ChatExpressionPanel(
	                    conversationID: conversationID,
	                    selectedTab: $expressionTab,
	                    emojis: emojis,
	                    insertEmoji: { emoji in
	                        insertEmojiAtCurrentSelection(emoji)
	                    },
                        addStickerPhoto: {
                            showStickerPhotoPicker = true
                        },
	                    sendSticker: { item in
                        let sentReplyQuote = replyQuote
	                        let activeReplyContext = sentReplyQuote == nil ? nil : replyContext
                        let didStart = state.sendSticker(
                            item,
                            conversationID: conversationID,
                            quote: sentReplyQuote,
                            replyContext: activeReplyContext,
                            onPolicyRejected: {
                                if replyQuote == nil {
                                    replyQuote = sentReplyQuote
                                    replyContext = activeReplyContext
                                }
                            }
                        )
                        guard didStart else { return }
                        replyQuote = nil
                        replyContext = nil
                        showEmoji = false
                        showTools = false
                    },
                        unicodePicker: unicodeEmojiPicker
                )
                .environmentObject(state)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

	            if showTools && !isDisabled {
                LazyVGrid(columns: toolGridColumns, spacing: 14) {
                    ForEach(tools) { tool in
                        Button {
                            handleToolTap(tool.action)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(width: 46, height: 46)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                                Text(tool.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(sizeCategory.isAccessibilityCategory ? 2 : 1)
                                    .minimumScaleFactor(0.8)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(
                                minWidth: 52,
                                minHeight: sizeCategory.isAccessibilityCategory ? 96 : 70
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(tool.accessibilityIdentifier)
                        .accessibilityLabel(tool.accessibilityLabel)
                        .accessibilityHint(accessibilityHint(for: tool))
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground).opacity(0.96))
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerCompat(
                selectionLimit: 9,
                filter: .any(of: [.images, .videos]),
                prefersFileBackedItems: true
            ) { items in
                handlePickedAttachmentItems(items)
            }
        }
        .sheet(isPresented: $showStickerPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                handlePickedStickerItems(items)
            }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactCardPickerSheet(
                conversationID: conversationID,
                replyQuote: $replyQuote,
                replyContext: $replyContext,
                showTools: $showTools,
                // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SHEET_PASS - 修改开始：名片发送页接收回到底部回调
                onSendStarted: requestLatestScrollForComposerAction
                // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SHEET_PASS - 修改结束：名片发送页接收回到底部回调
            )
                .environmentObject(state)
                .presentationDetentsCompat([.medium, .large])
                .presentationDragIndicatorCompat(.visible)
        }
        .sheet(item: $pendingAttachmentSelection) { batch in
            AttachmentSendConfirmationSheet(batch: batch) {
                batch.removeOwnedFiles()
                pendingAttachmentSelection = nil
            } onSend: {
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_ATTACHMENT_CONFIRM - 修改开始：定位确认发送附件时同步入队耗时
                let attachmentConfirmDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
                chatBackStuckDiagnostic(
                    "attachment_confirm_send_begin",
                    force: true,
                    extra: "count=\(batch.selections.count)"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_ATTACHMENT_CONFIRM - 修改结束：定位确认发送附件时同步入队耗时
                // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_ATTACHMENT_CONFIRM_SEND - 修改开始：附件确认发送时回到最新消息
                requestLatestScrollForComposerAction()
                // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_ATTACHMENT_CONFIRM_SEND - 修改结束：附件确认发送时回到最新消息
                let sentReplyQuote = replyQuote
                let sentReplyContext = sentReplyQuote == nil ? nil : replyContext
                var startedAny = false
                var queuedMessageIDs: [String] = []
                let sendInSelectionOrder = batch.selections.count > 1
                for selection in batch.selections {
                    let didStart = state.sendAttachment(
                        kind: selection.kind,
                        name: selection.name,
                        mimeType: selection.mimeType,
                        sizeBytes: selection.sizeBytes,
                        data: selection.data,
                        fileURL: selection.fileURL,
                        removeFileWhenFinished: selection.ownsFileURL,
                        conversationID: conversationID,
                        quote: sentReplyQuote,
                        replyContext: sentReplyContext,
                        onPolicyRejected: {
                            if replyQuote == nil {
                                replyQuote = sentReplyQuote
                                replyContext = sentReplyContext
                            }
                            let existing = pendingAttachmentSelection?.selections ?? []
                            if !existing.contains(where: { $0.id == selection.id }) {
                                pendingAttachmentSelection = PendingAttachmentSelectionBatch(
                                    selections: existing + [selection]
                                )
                            }
                        },
                        automaticallyStartUpload: !sendInSelectionOrder,
                        onQueued: { messageID in
                            queuedMessageIDs.append(messageID)
                        }
                    )
                    if !didStart {
                        selection.removeOwnedFile()
                    }
                    startedAny = startedAny || didStart
                }
                if sendInSelectionOrder, !queuedMessageIDs.isEmpty {
                    state.startQueuedAttachmentUploadsInOrder(queuedMessageIDs, in: conversationID)
                }
                if startedAny {
                    replyQuote = nil
                    replyContext = nil
                }
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_ATTACHMENT_CONFIRM_END - 修改开始：记录附件确认发送同步入队结果
                chatBackStuckDiagnostic(
                    "attachment_confirm_send_end",
                    force: startedAny,
                    extra: "started=\(startedAny) queued=\(queuedMessageIDs.count) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: attachmentConfirmDiagnosticStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_ATTACHMENT_CONFIRM_END - 修改结束：记录附件确认发送同步入队结果
                showTools = false
                pendingAttachmentSelection = nil
            }
            .environmentObject(state)
            .presentationDetentsCompat([.medium])
            .presentationDragIndicatorCompat(.visible)
            .interactiveDismissDisabled(true)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { @MainActor in
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let stagedFile: PendingAttachmentFile
                    do {
                        stagedFile = try await Task.detached(priority: .userInitiated) {
                            try PendingAttachmentFileStore.stageFile(
                                from: url,
                                preferredName: url.lastPathComponent
                            )
                        }.value
                    } catch {
                        state.toast = "文件数据读取失败，请重新选择"
                        return
                    }
                    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_FILE_PICKED - 修改开始：选择文件后回到最新消息
                    requestLatestScrollForComposerAction()
                    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_FILE_PICKED - 修改结束：选择文件后回到最新消息
                    pendingAttachmentSelection = PendingAttachmentSelection(
                        kind: .file,
                        name: url.lastPathComponent,
                        mimeType: url.mimeTypeForImport(),
                        sizeBytes: stagedFile.sizeBytes,
                        fileURL: stagedFile.url,
                        ownsFileURL: true,
                        previewImage: nil
                    ).asBatch
                    showTools = false
                }
            case .failure(let error):
                state.toast = "文件选择失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重新选择"))"
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showTools)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showEmoji)
        .task(id: showEmoji) {
            guard showEmoji else { return }
            await state.prepareStickerExpressionPanel()
        }
        .task(id: emojiPickerTaskKey) {
            await synchronizeEmojiPickerRuntime()
        }
        .task(id: mentionSearchTaskKey) {
            await refreshRemoteMentionSuggestions()
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            handleVoiceRecordingScenePhase(phase)
        }
        .onChangeCompat(of: state.isAuthenticated) { _, isAuthenticated in
            guard !isAuthenticated else { return }
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            state.emojiPickerCatalogRuntime.reset()
        }
        .onDisappear {
            purgeEmojiPickerIfIdentityChanged()
        }
        .onChangeCompat(of: conversationID) { _, _ in
            cancelVoiceRecordingForNavigation()
            state.stopVoiceMessagePlayback()
        }
        .onDisappear {
            cancelVoiceRecordingForNavigation()
            state.stopVoiceMessagePlayback()
        }
    }

    private func toggleVoiceInputMode() {
        guard !isDisabled else {
            state.toast = disabledReason.isEmpty ? disabledTitle : disabledReason
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_TOGGLE - 修改开始：切换语音输入时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_TOGGLE - 修改结束：切换语音输入时回到最新消息
        dismissActiveChatKeyboard()
        withoutComposerLayoutAnimation {
            isVoiceInputMode.toggle()
            if isVoiceInputMode {
                showEmoji = false
                showTools = false
            } else {
                voiceRecorder.cancel()
                voicePreview.discard()
                voiceRecordingLifecycle.clearFeedback()
            }
        }
    }

    private func withoutComposerLayoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_HELPER - 修改开始：Composer 主动操作时请求聊天列表回到最新消息
    private func requestLatestScrollForComposerAction() {
        onRequestLatestScroll()
    }
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_HELPER - 修改结束：Composer 主动操作时请求聊天列表回到最新消息

    private func beginVoiceRecording() {
        guard !isDisabled else {
            state.toast = disabledReason.isEmpty ? disabledTitle : disabledReason
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_RECORD - 修改开始：开始录音时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_RECORD - 修改结束：开始录音时回到最新消息
        guard let requestGeneration = voiceRecorder.beginRequesting() else { return }
        voiceRecordingLifecycle.beginNewAttempt()
        voicePreview.discard()
        showEmoji = false
        showTools = false
        state.toast = "正在请求麦克风并启动录音"
        Task { @MainActor in
            guard await microphonePermissionGrantedAfterUserAction() else {
                voiceRecorder.cancelRequest(requestGeneration)
                return
            }
            do {
                guard try voiceRecorder.start(requestGeneration: requestGeneration, onAutoFinished: {
                    finishVoiceRecording(cancelled: false)
                }) else { return }
                state.toast = "正在录音"
            } catch {
                state.toast = BackendUserMessageSanitizer.sanitize(error: error, fallback: "录音启动失败，请重试")
            }
        }
    }

    private func finishVoiceRecording(cancelled: Bool) {
        if voiceRecorder.cancelPendingStart() {
            state.toast = cancelled ? "已取消语音" : "已取消尚未开始的录音"
            return
        }
        guard let requestGeneration = voiceRecorder.beginFinalizing() else { return }
        state.toast = cancelled ? "正在取消语音" : "正在结束录音并读取时长"
        Task { @MainActor in
            await Task.yield()
            do {
                guard let recording = try voiceRecorder.finish(
                    requestGeneration: requestGeneration,
                    cancelled: cancelled
                ) else {
                    if cancelled {
                        state.toast = "已取消语音"
                    }
                    return
                }
                voiceRecordingLifecycle.clearFeedback()
                voicePreview.setRecording(recording)
                showEmoji = false
                showTools = false
                state.toast = "语音已就绪"
            } catch VoiceMessageRecorderError.tooShort {
                voiceRecordingLifecycle.presentTooShortFeedback()
                state.toast = VoiceRecordingComposerFeedback.tooShort.message
            } catch {
                state.toast = BackendUserMessageSanitizer.sanitize(error: error, fallback: "录音失败，请重试")
            }
        }
    }

    private func cancelVoiceRecordingForNavigation() {
        if voiceRecorder.isBusy {
            voiceRecorder.cancel()
        }
        voicePreview.discard()
        voiceRecordingLifecycle.clearFeedback()
    }

    private func handleVoiceRecordingScenePhase(_ phase: ScenePhase) {
        let recordingPhase: VoiceRecordingComposerPhase
        if voicePreview.recording != nil {
            recordingPhase = .preview
        } else {
            recordingPhase = voiceRecorder.composerPhase
        }
        let effect = voiceRecordingLifecycle.transition(
            to: VoiceRecordingAppActivity(scenePhase: phase),
            recordingPhase: recordingPhase
        )
        guard effect == .cancelAndReset else { return }
        voiceRecorder.cancel()
        voicePreview.discard()
    }

    private func sendPendingVoiceRecording() {
        guard !isDisabled else {
            state.toast = disabledReason.isEmpty ? disabledTitle : disabledReason
            return
        }
        guard let recording = voicePreview.takeRecordingForSending() else { return }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_SEND - 修改开始：发送语音时回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_SEND - 修改结束：发送语音时回到最新消息
        let sentReplyQuote = replyQuote
        let sentReplyContext = sentReplyQuote == nil ? nil : replyContext
        let didStart = state.sendVoiceMessage(
            data: recording.data,
            name: recording.name,
            mimeType: recording.mimeType,
            sizeBytes: recording.sizeBytes,
            durationMS: recording.durationMS,
            waveform: recording.waveform,
            conversationID: conversationID,
            quote: sentReplyQuote,
            replyContext: sentReplyContext,
            onPolicyRejected: {
                if voicePreview.recording == nil {
                    voicePreview.setRecording(recording)
                }
                if replyQuote == nil {
                    replyQuote = sentReplyQuote
                    replyContext = sentReplyContext
                }
            }
        )
        guard didStart else {
            voicePreview.setRecording(recording)
            return
        }
        voiceRecordingLifecycle.clearFeedback()
        replyQuote = nil
        replyContext = nil
        showEmoji = false
        showTools = false
    }

    private func cancelPendingVoiceRecording() {
        voicePreview.discard()
        voiceRecordingLifecycle.clearFeedback()
        state.toast = "已取消语音"
    }

    private func microphonePermissionGrantedAfterUserAction() async -> Bool {
        let status = currentMicrophoneAuthorizationStatus()
        if status == .granted {
            return true
        }
        if VoiceMessagePermissionGate.shouldRequestMicrophone(
            userTriggered: true,
            businessBlocked: isDisabled,
            status: status
        ) {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                state.toast = "请在系统设置中允许麦克风，用于发送语音消息"
            }
            return granted
        }
        state.toast = "请在系统设置中允许麦克风，用于发送语音消息"
        return false
    }

    private func currentMicrophoneAuthorizationStatus() -> VoiceMicrophoneAuthorizationStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    private func handleToolTap(_ action: ChatComposerToolAction) {
        dismissActiveChatKeyboard()
        switch action {
        case .mediaAttachment:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_MEDIA_TOOL - 修改开始：点击照片/视频工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_MEDIA_TOOL - 修改结束：点击照片/视频工具时回到最新消息
            presentPhotoPicker()
        case .fileAttachment:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_FILE_TOOL - 修改开始：点击文件工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_FILE_TOOL - 修改结束：点击文件工具时回到最新消息
            showFileImporter = true
        case .voiceCall:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VOICE_CALL_TOOL - 修改开始：点击通话工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VOICE_CALL_TOOL - 修改结束：点击通话工具时回到最新消息
            showTools = false
            startVoiceCall()
        case .videoCall:
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_VIDEO_CALL_TOOL - 修改开始：点击视频工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_VIDEO_CALL_TOOL - 修改结束：点击视频工具时回到最新消息
            showTools = false
            startVideoCall()
        case .contactCard:
            guard !state.contacts.isEmpty else {
                state.toast = "暂无可发送的联系人名片"
                return
            }
            // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_TOOL - 修改开始：点击名片工具时回到最新消息
            requestLatestScrollForComposerAction()
            // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_TOOL - 修改结束：点击名片工具时回到最新消息
            showContactPicker = true
        }
    }

    private func presentPhotoPicker() {
        showPhotoPicker = true
    }

    private func handlePickedAttachmentItems(_ items: [PhotoLibraryPickedItem]) {
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_MEDIA_PICK - 修改开始：定位照片/视频选择后预览生成同步耗时
        let mediaPickDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        chatBackStuckDiagnostic(
            "media_pick_begin",
            force: true,
            extra: "items=\(items.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_MEDIA_PICK - 修改结束：定位照片/视频选择后预览生成同步耗时
        let selections = items.prefix(9).compactMap {
            PendingAttachmentSelection.photoLibrarySelection(item: $0)
        }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_MEDIA_PICK_PREPARED - 修改开始：记录照片/视频选择预览生成结果
        chatBackStuckDiagnostic(
            "media_pick_prepared",
            force: true,
            extra: "items=\(items.count) selections=\(selections.count) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: mediaPickDiagnosticStartedAt))"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_MEDIA_PICK_PREPARED - 修改结束：记录照片/视频选择预览生成结果
        guard !selections.isEmpty else {
            state.toast = "照片或视频读取失败，请重新选择"
            return
        }
        // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_MEDIA_PICKED - 修改开始：照片/视频选择完成后回到最新消息
        requestLatestScrollForComposerAction()
        // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_MEDIA_PICKED - 修改结束：照片/视频选择完成后回到最新消息
        if items.count > 9 {
            state.toast = "一次最多选择 9 张照片或视频"
        }
        pendingAttachmentSelection = PendingAttachmentSelectionBatch(selections: selections)
        showTools = false
    }

    private func handlePickedStickerItems(_ items: [PhotoLibraryPickedItem]) {
        guard let item = items.first,
              let data = item.data else {
            state.toast = "表情数据读取失败，请重新选择"
            return
        }
        expressionTab = .stickers
        showEmoji = true
        showTools = false
        state.uploadStickerImage(
            data: data,
            name: stickerPhotoLibraryFileName(contentTypes: item.contentTypes),
            conversationID: conversationID
        )
    }

    private func stickerPhotoLibraryFileName(contentTypes: [UTType]) -> String {
        let preferredType = contentTypes.first { $0.conforms(to: UTType(filenameExtension: "gif") ?? .image) }
            ?? contentTypes.first { $0.conforms(to: .png) }
            ?? contentTypes.first { $0.conforms(to: .jpeg) }
            ?? contentTypes.first { $0.conforms(to: .image) }
        let rawExtension = preferredType?.preferredFilenameExtension?.lowercased() ?? "jpg"
        let normalizedExtension = rawExtension == "jpeg" ? "jpg" : rawExtension
        return "我的表情.\(normalizedExtension)"
    }

    private func sendCurrentInput() {
        let draft = normalizedSendableMessageText(input)
        guard !draft.isEmpty else { return }
        let shouldMentionAll = mentionAllSelected && draft.contains("@所有人")
        let activeMentions = deduplicatedSelectedMentionUsers(in: draft)
        send(draft, shouldMentionAll, activeMentions)
        mentionAllSelected = false
        selectedMentionUsers.removeAll()
    }

    private func insertMention(_ user: IMUser) {
        guard let range = activeMentionRange else { return }
        let replacement = "@\(mentionVisibleDisplayName(for: user)) "
        let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count
        input.replaceSubrange(range, with: replacement)
        inputSelection = NSRange(location: insertionEnd, length: 0)
        rememberMention(user)
        showEmoji = false
        showTools = false
    }

    private func insertMentionAll() {
        guard let range = activeMentionRange else { return }
        let replacement = "@所有人 "
        let insertionEnd = input[..<range.lowerBound].utf16.count + replacement.utf16.count
        input.replaceSubrange(range, with: replacement)
        inputSelection = NSRange(location: insertionEnd, length: 0)
        mentionAllSelected = true
        showEmoji = false
        showTools = false
    }

    private func deduplicatedMentionMembers(_ users: [IMUser]) -> [IMUser] {
        var seen = Set<String>()
        return users.filter { user in
            let key = mentionUserKey(for: user)
            return seen.insert(key).inserted
        }
    }

    private func refreshRemoteMentionSuggestions() async {
        guard !isDisabled,
              let query = activeMentionQuery,
              !mentionGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remoteMentionQuery = ""
            remoteMentionSuggestions = []
            remoteMentionMembersLoading = false
            remoteMentionLookupReady = false
            return
        }
        remoteMentionQuery = query
        remoteMentionMembersLoading = true
        remoteMentionLookupReady = false
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        guard !Task.isCancelled else { return }
        let users = await state.searchGroupMentionMembers(groupID: mentionGroupID, keyword: query)
        guard !Task.isCancelled else { return }
        remoteMentionSuggestions = users
        remoteMentionQuery = query
        remoteMentionMembersLoading = false
        remoteMentionLookupReady = true
    }

    private func rememberMention(_ user: IMUser) {
        let mention = MentionIdentity(
            imUID: user.id,
            userID: user.userID,
            username: user.username,
            displayText: mentionVisibleDisplayName(for: user)
        )
        guard !mention.id.isEmpty else { return }
        selectedMentionUsers.removeAll { $0.id == mention.id || $0.mentionToken == mention.mentionToken }
        selectedMentionUsers.append(mention)
    }

    private func deduplicatedSelectedMentionUsers(in draft: String) -> [MentionIdentity] {
        var seen = Set<String>()
        return selectedMentionUsers.filter { mention in
            guard draft.contains(mention.mentionToken), !mention.id.isEmpty else { return false }
            return seen.insert(mention.id).inserted
        }
    }
}

private enum ChatExpressionTab: String, CaseIterable, Identifiable {
    case emoji
    case stickers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emoji: return "Emoji"
        case .stickers: return "表情包"
        }
    }
}

private struct ChatExpressionPanel: View {
    let conversationID: String
    @Binding var selectedTab: ChatExpressionTab
    let emojis: [String]
    let insertEmoji: (String) -> Void
    let addStickerPhoto: () -> Void
    let sendSticker: (StickerLibraryItem) -> Void
    var unicodePicker: AnyView? = nil
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isManagingStickers = false
    @State private var pendingStickerDeletion: StickerLibraryItem?
    @State private var showStickerDeleteConfirmation = false

    private let emojiColumns = [GridItem(.adaptive(minimum: 44, maximum: 58), spacing: 8)]
    private let stickerColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    private let contentHeight: CGFloat = 268
    private let panelHeight: CGFloat = 320

    private var hasManageableStickers: Bool {
        state.myStickers.contains { !$0.isLocalUploadPlaceholder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar

            ZStack(alignment: .top) {
                emojiGrid
                    .opacity(selectedTab == .emoji ? 1 : 0)
                    .offset(x: selectedTab == .emoji ? 0 : -18)
                    .allowsHitTesting(selectedTab == .emoji)

                stickerLibrary
                    .opacity(selectedTab == .stickers ? 1 : 0)
                    .offset(x: selectedTab == .stickers ? 0 : 18)
                    .allowsHitTesting(selectedTab == .stickers)
            }
            .frame(height: contentHeight)
            .clipped()
        }
        .padding(.top, 4)
        .frame(height: panelHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: selectedTab)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: isManagingStickers)
        .confirmationDialog(
            "删除这个表情？",
            isPresented: $showStickerDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let item = pendingStickerDeletion else { return }
                state.deleteSticker(item)
                pendingStickerDeletion = nil
                if state.myStickers.count <= 1 {
                    isManagingStickers = false
                }
            }
            Button("取消", role: .cancel) {
                pendingStickerDeletion = nil
            }
        } message: {
            Text("删除后不影响历史消息中的缩略图和摘要展示。")
        }
        .onChangeCompat(of: selectedTab) { _, tab in
            if tab == .emoji {
                isManagingStickers = false
            }
        }
        .task(id: selectedTab) {
            guard selectedTab == .stickers else { return }
            await state.prepareStickerExpressionPanel()
        }
        .accessibilityIdentifier("chat_expression_panel")
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ChatExpressionTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(selectedTab == tab ? IMColor.ink : IMColor.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? .white : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(selectedTab == tab ? "已选择" : "")
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    .accessibilityIdentifier("chat_expression_tab_\(tab.rawValue)")
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xF1F4FB)))

            Button {
                state.refreshStickerExpressionPanel()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(selectedTab != .stickers)
            .opacity(selectedTab == .stickers ? 1 : 0.36)
            .accessibilityLabel("刷新表情包")
            .accessibilityHint(selectedTab == .stickers ? "重新同步我的表情包" : "切换到表情包后可用")
            .accessibilityIdentifier("chat_sticker_refresh_button")
        }
    }

    private var emojiGrid: some View {
        Group {
            if let unicodePicker {
                unicodePicker
                    .accessibilityIdentifier("chat_unicode_emoji_picker")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: emojiColumns, spacing: 8) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button {
                                insertEmoji(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 26))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(emoji))
                            .accessibilityHint("插入此 Emoji")
                            .accessibilityIdentifier("chat_legacy_emoji_\(emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_"))")
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var stickerLibrary: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                myStickersSection
            }
            .padding(.bottom, 4)
        }
    }

    private var myStickersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("我的表情")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    if state.myStickers.contains(where: { $0.isProcessing }) {
                        Text("处理中")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IMColor.warning)
                    }
                }
                if state.isStickerManifestRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(IMColor.brand)
                }
                Spacer()
                if hasManageableStickers {
                    Button {
                        isManagingStickers.toggle()
                    } label: {
                        Label(isManagingStickers ? "完成" : "管理", systemImage: isManagingStickers ? "checkmark" : "slider.horizontal.3")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(isManagingStickers ? IMColor.brand : IMColor.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0xF1F4FB)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_sticker_manage_button")
                }
                Button {
                    addStickerPhoto()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.brand))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat_sticker_add_button")
            }

            if let message = state.stickerManifestErrorMessage, !message.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IMColor.warning)
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IMColor.warning.opacity(0.10)))
            }

            if state.myStickers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.brand)
                    Text(state.isStickerManifestRefreshing ? "正在同步我的表情" : "暂无我的表情")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0xF7F8FC)))
            } else {
                LazyVGrid(columns: stickerColumns, spacing: 12) {
                    ForEach(Array(state.myStickers.enumerated()), id: \.element.id) { index, item in
                        StickerLibraryCell(
                            item: item,
                            thumbnailURL: state.stickerThumbnailURL(for: item),
                            isManaging: isManagingStickers,
                            isDeleting: state.isDeletingSticker(item),
                            isSorting: state.isSortingSticker(item),
                            canMoveUp: index > 0,
                            canMoveDown: index < state.myStickers.count - 1,
                            onTap: {
                                if isManagingStickers, !item.isLocalUploadPlaceholder {
                                    return
                                } else if item.isLocalUploadPlaceholder, item.isFailed {
                                    state.retryStickerUpload(item)
                                } else {
                                    sendSticker(item)
                                }
                            },
                            onEnterManage: {
                                if !item.isLocalUploadPlaceholder {
                                    isManagingStickers = true
                                }
                            },
                            onRetry: { state.retryStickerUpload(item) },
                            onDelete: {
                                if item.isLocalUploadPlaceholder {
                                    state.deleteSticker(item)
                                } else {
                                    pendingStickerDeletion = item
                                    showStickerDeleteConfirmation = true
                                }
                            },
                            onMoveUp: { state.moveSticker(item, direction: -1) },
                            onMoveDown: { state.moveSticker(item, direction: 1) }
                        )
                    }
                }
            }
        }
    }
}

private struct StickerLibraryCell: View {
    let item: StickerLibraryItem
    let thumbnailURL: String
    let isManaging: Bool
    let isDeleting: Bool
    let isSorting: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onTap: () -> Void
    let onEnterManage: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        ZStack {
            Button(action: onTap) {
                stickerTile
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    onEnterManage()
                }
            )

            if isManaging, !item.isLocalUploadPlaceholder {
                manageOverlay
            }

            if item.isLocalUploadPlaceholder, item.isFailed {
                failedUploadOverlay
            }

            if isDeleting || isSorting {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.70))
                    .frame(width: 64, height: 64)
                ProgressView()
                    .scaleEffect(0.72)
                    .tint(IMColor.brand)
            }
        }
        .frame(height: 74)
        .accessibilityIdentifier("chat_sticker_cell_\(item.id)")
    }

    private var stickerTile: some View {
        StickerThumbnail(item: item, thumbnailURL: thumbnailURL)
            .frame(width: 64, height: 64)
            .scaleEffect(isManaging && !item.isLocalUploadPlaceholder ? 0.94 : 1)
            .overlay {
                if item.isLocalUploadPlaceholder, let title = item.uploadTileTitle {
                    StickerUploadTileOverlay(title: title, subtitle: item.uploadSubtitle, isFailed: item.isFailed)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !item.isActive && !item.isLocalUploadPlaceholder {
                    Text(item.statusTitle)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(item.isFailed ? IMColor.danger : IMColor.warning))
                        .offset(x: 6, y: -6)
                }
            }
    }

    private var manageOverlay: some View {
        ZStack {
            VStack {
                HStack {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20, weight: .black))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, IMColor.danger)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    Spacer()
                }
                Spacer()
            }

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .black))
                            .frame(width: 24, height: 20)
                            .background(Capsule().fill(.white.opacity(0.94)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp || isSorting || isDeleting)
                    .opacity(canMoveUp ? 1 : 0.36)

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .black))
                            .frame(width: 24, height: 20)
                            .background(Capsule().fill(.white.opacity(0.94)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown || isSorting || isDeleting)
                    .opacity(canMoveDown ? 1 : 0.36)
                }
                .foregroundStyle(IMColor.ink)
            }
        }
        .frame(width: 72, height: 72)
    }

    private var failedUploadOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(.white.opacity(0.94)))
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(.white.opacity(0.94)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(IMColor.danger)
            }
        }
        .frame(width: 72, height: 72)
    }
}

private struct StickerUploadTileOverlay: View {
    let title: String
    let subtitle: String?
    let isFailed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(isFailed ? 0.58 : 0.42))
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: title.count <= 3 ? 15 : 12, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let subtitle, subtitle != title {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct StickerThumbnail: View {
    let item: StickerLibraryItem
    let thumbnailURL: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: 0xF7F8FC))
            if thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: item.isLocalUploadPlaceholder ? "photo.badge.plus" : (item.source == .mine ? "face.smiling" : "sparkles"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            } else {
                CachedRemoteImage(urlString: thumbnailURL, cacheKey: item.stableThumbnailCacheKey, contentMode: .fit) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: 0xE6EAF3), lineWidth: 1))
    }
}

private struct PendingAttachmentSelection: Identifiable {
    let id = UUID()
    let kind: MessageKind
    let name: String
    let mimeType: String
    let sizeBytes: Int64?
    let data: Data?
    let fileURL: URL?
    let ownsFileURL: Bool
    let previewImage: UIImage?

    init(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64?,
        data: Data? = nil,
        fileURL: URL? = nil,
        ownsFileURL: Bool = false,
        previewImage: UIImage?
    ) {
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.fileURL = fileURL
        self.ownsFileURL = ownsFileURL
        self.previewImage = previewImage
    }

    var asBatch: PendingAttachmentSelectionBatch {
        PendingAttachmentSelectionBatch(selections: [self])
    }

    static func photoLibrarySelection(item: PhotoLibraryPickedItem) -> PendingAttachmentSelection? {
        guard item.data?.isEmpty == false || item.fileURL != nil else { return nil }
        let contentType = preferredContentType(from: item.contentTypes)
        let isVideo = contentType.map(isVideoContentType) ?? false
        let fileExtension = sanitizedExtension(
            contentType?.preferredFilenameExtension,
            fallback: isVideo ? "mov" : "jpg"
        )
        let mimeType = contentType?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
        let previewImage: UIImage?
        if let fileURL = item.fileURL {
            previewImage = isVideo
                ? videoPreviewImage(fileURL: fileURL)
                : RemoteImageDecoder.image(fromFileURL: fileURL, maxPixelSize: 320)
        } else if let data = item.data {
            previewImage = isVideo
                ? videoPreviewImage(data: data, fileExtension: fileExtension)
                : UIImage(data: data)
        } else {
            previewImage = nil
        }
        return PendingAttachmentSelection(
            kind: isVideo ? .file : .image,
            name: isVideo ? "视频消息.\(fileExtension)" : "图片消息.\(fileExtension)",
            mimeType: mimeType,
            sizeBytes: item.sizeBytes,
            data: item.data,
            fileURL: item.fileURL,
            ownsFileURL: item.fileURL != nil,
            previewImage: previewImage
        )
    }

    var effectiveSizeBytes: Int64 {
        sizeBytes
            ?? data.map { Int64($0.count) }
            ?? fileURL.flatMap { PendingAttachmentFileStore.fileSize(at: $0) }
            ?? 0
    }

    func removeOwnedFile() {
        guard ownsFileURL else { return }
        PendingAttachmentFileStore.removeManagedFile(at: fileURL)
    }

    var mediaCategory: String {
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == .image || normalizedMime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext) {
            return "image"
        }
        if normalizedMime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(ext) {
            return "video"
        }
        if normalizedMime.contains("pdf") || ext == "pdf" {
            return "pdf"
        }
        return "file"
    }

    var typeTitle: String {
        switch mediaCategory {
        case "image": return "图片"
        case "video": return "视频"
        case "pdf": return "PDF"
        default: return mimeType.isEmpty ? "普通文件" : mimeType
        }
    }

    var symbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }

    private static func preferredContentType(from contentTypes: [UTType]) -> UTType? {
        contentTypes.first(where: isVideoContentType)
            ?? contentTypes.first(where: { $0.conforms(to: .image) })
            ?? contentTypes.first
    }

    private static func isVideoContentType(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .movie) || (contentType.preferredMIMEType?.hasPrefix("video/") ?? false)
    }

    private static func sanitizedExtension(_ rawValue: String?, fallback: String) -> String {
        let value = (rawValue ?? fallback)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(value.unicodeScalars.filter { allowed.contains($0) })
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func videoPreviewImage(data: Data, fileExtension: String) -> UIImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("im2-picker-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.12, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private static func videoPreviewImage(fileURL: URL) -> UIImage? {
        let asset = AVAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.12, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct PendingAttachmentSelectionBatch: Identifiable {
    let id = UUID()
    let selections: [PendingAttachmentSelection]

    var isMultiple: Bool {
        selections.count > 1
    }

    var photoCount: Int {
        selections.filter { $0.mediaCategory == "image" }.count
    }

    var videoCount: Int {
        selections.filter { $0.mediaCategory == "video" }.count
    }

    var totalSizeBytes: Int64 {
        selections.reduce(Int64(0)) { $0 + $1.effectiveSizeBytes }
    }

    var title: String {
        guard isMultiple else { return "发送附件" }
        if photoCount == selections.count {
            return "发送照片"
        }
        if videoCount == selections.count {
            return "发送视频"
        }
        return "发送附件"
    }

    var subtitle: String {
        guard isMultiple else { return "确认名称、类型和大小后再上传发送。" }
        if photoCount == selections.count {
            return "共 \(photoCount) 张照片，确认后按队列发送。"
        }
        if videoCount == selections.count {
            return "共 \(videoCount) 个视频，确认后按队列发送。"
        }
        if photoCount > 0 {
            return "共 \(selections.count) 个附件，含 \(photoCount) 张照片，确认后按队列发送。"
        }
        return "共 \(selections.count) 个附件，确认后按队列发送。"
    }

    var confirmTitle: String {
        isMultiple ? "确认发送 \(selections.count) 个" : "确认发送"
    }

    func removeOwnedFiles() {
        selections.forEach { $0.removeOwnedFile() }
    }
}

private struct AttachmentSendConfirmationSheet: View {
    @EnvironmentObject private var state: AppState
    let batch: PendingAttachmentSelectionBatch
    let onCancel: () -> Void
    let onSend: () -> Void

    private var selections: [PendingAttachmentSelection] {
        batch.selections
    }

    private var primarySelection: PendingAttachmentSelection {
        selections.first ?? PendingAttachmentSelection(
            kind: .file,
            name: "附件",
            mimeType: "application/octet-stream",
            sizeBytes: 0,
            data: Data(),
            previewImage: nil
        )
    }

    private var sizeText: String {
        let size = batch.isMultiple ? batch.totalSizeBytes : primarySelection.effectiveSizeBytes
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var exceedsLimit: Bool {
        selections.contains { !state.fileUploadConfig.allowsUpload(sizeBytes: $0.effectiveSizeBytes) }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(
                        symbol: "paperclip.circle.fill",
                        title: batch.title,
                        subtitle: batch.subtitle,
                        showsCloseButton: false
                    )

                    summaryCard

                    HStack(spacing: 12) {
                        Button(action: onCancel) {
                            Text("取消")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                        }
                        .buttonStyle(.plain)

                        PrimaryButton(title: batch.confirmTitle, systemImage: "paperplane.fill") {
                            guard !exceedsLimit else {
                                state.toast = state.fileUploadConfig.overLimitMessage
                                return
                            }
                            onSend()
                        }
                        .disabled(exceedsLimit)
                        .accessibilityLabel(batch.confirmTitle)
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if batch.isMultiple {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selections) { selection in
                            preview(for: selection)
                                .overlay(alignment: .bottomTrailing) {
                                    Text(selection.mediaCategory == "video" ? "视频" : "照片")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(.black.opacity(0.46)))
                                        .padding(5)
                                }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(batch.subtitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("总计 \(sizeText)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(exceedsLimit ? IMColor.danger : IMColor.muted)
                    if exceedsLimit {
                        Text(state.fileUploadConfig.overLimitMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.danger)
                    }
                }
            }
            .plainCard(radius: 24)
        } else {
            HStack(alignment: .top, spacing: 14) {
                preview(for: primarySelection)
                VStack(alignment: .leading, spacing: 8) {
                    Text(primarySelection.name)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(2)
                    Text("\(primarySelection.typeTitle) · \(sizeText)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(exceedsLimit ? IMColor.danger : IMColor.muted)
                    if exceedsLimit {
                        Text(state.fileUploadConfig.overLimitMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .plainCard(radius: 24)
        }
    }

    @ViewBuilder
    private func preview(for selection: PendingAttachmentSelection) -> some View {
        if let image = selection.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(IMColor.brand.opacity(0.10))
                Image(systemName: selection.symbol)
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(IMColor.brand)
                if selection.mediaCategory == "video" {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.black.opacity(0.48)))
                        .offset(x: 24, y: 24)
                }
            }
            .frame(width: 82, height: 82)
        }
    }

    @ViewBuilder
    private var preview: some View {
        preview(for: primarySelection)
    }
}

private struct MentionSuggestionPanel: View {
    @EnvironmentObject private var state: AppState

    let suggestions: [IMUser]
    var showsMentionAll = false
    let hasQuery: Bool
    var isLoading = false
    let onSelect: (IMUser) -> Void
    var onSelectAll: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.brand)
                Text("选择提及成员")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
                Spacer()
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IMColor.brand)
                    Text("正在加载群成员")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.72)))
            } else if suggestions.isEmpty && !showsMentionAll {
                Text(hasQuery ? "没有匹配成员" : "暂无可提及成员")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.72)))
            } else {
                ScrollView(.vertical, showsIndicators: suggestions.count + (showsMentionAll ? 1 : 0) > 4) {
                    LazyVStack(spacing: 7) {
                        if showsMentionAll {
                            Button(action: onSelectAll) {
                                HStack(spacing: 10) {
                                    Image(systemName: "megaphone.fill")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(IMColor.warning))
                                    Text("@所有人")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.warning.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.warning.opacity(0.24), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("提及所有人")
                        }
                        ForEach(suggestions) { user in
                            let displayName = GroupMemberDisplayNameResolver.projectedName(for: user)
                            Button {
                                onSelect(user)
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(name: displayName, seed: user.avatarSeed, size: 34, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                                    Text(displayName)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    CertificationPillView(
                                        exactUID: user.id,
                                        compact: true
                                    )
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                [
                                    "提及 \(displayName)",
                                    state.certificationPresentation(
                                        forExactUID: user.id
                                    )?.accessibilityLabel
                                ]
                                .compactMap { $0 }
                                .joined(separator: "，")
                            )
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(IMColor.brand.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.brand.opacity(0.12), lineWidth: 1))
	        )
	    }

}

private extension URL {
    func mimeTypeForImport() -> String {
        if let type = UTType(filenameExtension: pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

private struct ContactCardPickerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let conversationID: String
    @Binding var replyQuote: String?
    @Binding var replyContext: MessageReplyContext?
    @Binding var showTools: Bool
    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SHEET_PARAM - 修改开始：名片发送前回到底部回调
    var onSendStarted: () -> Void = {}
    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SHEET_PARAM - 修改结束：名片发送前回到底部回调
    @State private var query = ""

    private var contacts: [IMUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state.contacts }
        return state.contacts.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: trimmed
            )
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "person.crop.rectangle", title: "发送名片", subtitle: "选择联系人，将名片发送到当前会话。", showsCloseButton: true)
                    SearchField(text: $query, placeholder: "搜索联系人、用户ID或拼音")
                        .accessibilityIdentifier("contact_card_search_field")
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(contacts) { user in
                                let displayName = state.remarkPreferredDisplayName(for: user)
                                Button {
                                    // JHT_MOD_BEGIN CHAT_COMPOSER_ACTION_SCROLL_BEGIN_CONTACT_SEND - 修改开始：发送名片时回到最新消息
                                    onSendStarted()
                                    // JHT_MOD_END CHAT_COMPOSER_ACTION_SCROLL_END_CONTACT_SEND - 修改结束：发送名片时回到最新消息
                                    state.shareContactCard(user, to: conversationID, quote: replyQuote)
                                    replyQuote = nil
                                    replyContext = nil
                                    showTools = false
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(displayName)
                                                    .font(.system(size: 15, weight: .black))
                                                    .foregroundStyle(IMColor.ink)
                                                    .lineLimit(1)
                                                CertificationPillView(
                                                    exactUID: user.id,
                                                    compact: true
                                                )
                                            }
                                            Text("联系人名片")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 14, weight: .black))
                                            .foregroundStyle(IMColor.brand)
                                            .frame(width: 34, height: 34)
                                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                    }
                                    .padding(13)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(.white.opacity(0.82))
                                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line))
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("contact_card_user_\(user.id)")
                                .accessibilityLabel(
                                    [
                                        "发送 \(displayName) 名片",
                                        state.certificationPresentation(
                                            forExactUID: user.id
                                        )?.accessibilityLabel
                                    ]
                                    .compactMap { $0 }
                                    .joined(separator: "，")
                                )
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ReactionPickerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    var fullPicker: AnyView? = nil
    @State private var showFullPicker = false
    @State private var emojiPickerStore: EmojiPickerStoreAdapter?
    private let reactions = ["👍", "❤️", "🔥", "🎉", "😂", "✅", "💡", "👀"]
    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 84), spacing: 12)]

    private var previewText: String {
        if message.kind == .file || message.kind == .contactCard {
            return message.attachmentName ?? message.text
        }
        return message.text
    }

    private var emojiPickerTaskKey: String {
        emojiPickerRuntimeTaskKey(state: state, isOpen: true)
    }

    private var effectiveFullPicker: AnyView? {
        if let fullPicker {
            return fullPicker
        }
        guard let emojiPickerStore else { return nil }
        return AnyView(
            EmojiPickerView(
                store: emojiPickerStore,
                onSelect: { item in
                    state.addReaction(item.emoji, to: message.id, in: conversationID)
                    emojiPickerStore.close()
                    showFullPicker = false
                    DispatchQueue.main.async {
                        dismiss()
                    }
                }
            )
        )
    }

    @MainActor
    private func synchronizeEmojiPickerRuntime() async {
        guard fullPicker == nil else { return }
        guard let runtime = currentEmojiPickerRuntimeContext(state: state) else {
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            state.emojiPickerCatalogRuntime.reset()
            return
        }
        if let emojiPickerStore {
            if emojiPickerStore.scope != runtime.scope {
                emojiPickerStore.switchScope(to: runtime.scope)
                state.emojiPickerCatalogRuntime.reset()
            }
            return
        }
        switch state.emojiPickerCatalogRuntime.begin(
            scope: runtime.scope,
            baseURL: runtime.catalogBaseURL
        ) {
        case .useCatalog(let catalog):
            emojiPickerStore = try? EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .reaction
            )
            return
        case .useFallback:
            return
        case .attempt:
            break
        }
        do {
            let catalog = try await EmojiPickerCatalogLoader().load(baseURL: runtime.catalogBaseURL)
            guard currentEmojiPickerRuntimeContext(state: state) == runtime else {
                state.emojiPickerCatalogRuntime.cancelAttempt(
                    scope: runtime.scope,
                    baseURL: runtime.catalogBaseURL
                )
                return
            }
            let store = try EmojiPickerStoreAdapter(
                catalog: catalog,
                scope: runtime.scope,
                mode: .reaction
            )
            guard state.emojiPickerCatalogRuntime.recordSuccess(
                catalog,
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            ) else { return }
            emojiPickerStore = store
        } catch is CancellationError {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch let error as URLError where error.code == .cancelled {
            state.emojiPickerCatalogRuntime.cancelAttempt(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            )
            return
        } catch {
            guard state.emojiPickerCatalogRuntime.recordFailure(
                scope: runtime.scope,
                baseURL: runtime.catalogBaseURL
            ) else { return }
            state.toast = "表情目录暂不可用，已使用本地 Emoji"
        }
    }

    @MainActor
    private func purgeEmojiPickerIfIdentityChanged() {
        guard let emojiPickerStore,
              currentEmojiPickerRuntimeContext(state: state)?.scope != emojiPickerStore.scope
        else {
            return
        }
        emojiPickerStore.clearIdentity()
        self.emojiPickerStore = nil
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "face.smiling.fill", title: "表情回应", subtitle: "选择一个表情同步到当前消息。", showsCloseButton: true)

                    Text("快速回应")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(IMColor.ink)
                        .accessibilityAddTraits(.isHeader)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(reactions, id: \.self) { emoji in
                            Button {
                                state.addReaction(emoji, to: message.id, in: conversationID)
                                dismiss()
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(IMColor.brand.opacity(0.10))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                    .stroke(.white.opacity(0.7), lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(emoji))
                            .accessibilityHint("用此 Emoji 回应当前消息")
                            .accessibilityIdentifier("quick_reaction_\(emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_"))")
                        }
                    }

                    if effectiveFullPicker != nil {
                        Button {
                            showFullPicker = true
                        } label: {
                            Label("更多 Emoji", systemImage: "ellipsis.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(IMColor.brand)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(IMColor.brand.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开完整 Unicode Emoji 目录")
                        .accessibilityIdentifier("reaction_more_emoji")
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: message.kind == .file ? "doc.richtext.fill" : (message.kind == .contactCard ? "person.crop.rectangle" : "text.bubble.fill"))
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text(previewText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .task(id: emojiPickerTaskKey) {
            await synchronizeEmojiPickerRuntime()
        }
        .onChangeCompat(of: state.isAuthenticated) { _, isAuthenticated in
            guard !isAuthenticated else { return }
            emojiPickerStore?.clearIdentity()
            emojiPickerStore = nil
            state.emojiPickerCatalogRuntime.reset()
        }
        .onDisappear {
            purgeEmojiPickerIfIdentityChanged()
        }
        .sheet(isPresented: $showFullPicker) {
            if let fullPicker = effectiveFullPicker {
                fullPicker
                    .presentationDetentsCompat([.medium, .large])
                    .presentationDragIndicatorCompat(.visible)
            }
        }
    }
}

private struct AttachmentMediaPreviewItem: Identifiable {
    let message: ChatMessage
    let localURL: URL

    var id: String {
        "\(message.id)|\(localURL.absoluteString)"
    }
}

enum AttachmentImagePreviewDismissalTrigger: Equatable {
    case closeButton
    case accessibilityEscape
    case downwardSwipe
    case leadingEdgeSwipe
}

struct AttachmentImagePreviewDismissalCoordinator: Equatable {
    private(set) var acceptedTrigger: AttachmentImagePreviewDismissalTrigger?

    mutating func request(_ trigger: AttachmentImagePreviewDismissalTrigger) -> Bool {
        guard acceptedTrigger == nil else { return false }
        acceptedTrigger = trigger
        return true
    }
}

enum AttachmentSaveCapabilityPolicy {
    private static let saveableMediaCategories: Set<String> = [
        "image", "video", "file", "document", "pdf", "spreadsheet", "archive"
    ]

    static func canSave(
        kind: MessageKind,
        mediaCategory: String,
        status: MessageDelivery,
        isDeletedLocally: Bool,
        hasResolvableAsset: Bool
    ) -> Bool {
        guard status != .sending,
              status != .failed,
              status != .recalled,
              !isDeletedLocally,
              hasResolvableAsset else {
            return false
        }
        let normalizedCategory = mediaCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if saveableMediaCategories.contains(normalizedCategory) {
            return true
        }
        return kind == .file || kind == .image || kind == .video
    }
}

enum AttachmentImagePreviewDismissalPolicy {
    static func interactiveOffset(
        startLocation: CGPoint,
        translation: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale <= 1.01 else { return .zero }
        if isDownwardIntent(translation) {
            return CGSize(width: 0, height: max(translation.height, 0))
        }
        if isLeadingEdgeIntent(startLocation: startLocation, translation: translation, viewportSize: viewportSize) {
            return CGSize(width: max(translation.width, 0), height: 0)
        }
        return .zero
    }

    static func dismissalTrigger(
        startLocation: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> AttachmentImagePreviewDismissalTrigger? {
        guard scale <= 1.01 else { return nil }
        if isDownwardIntent(translation) {
            let distance = max(translation.height, predictedEndTranslation.height)
            return distance >= downwardThreshold(for: viewportSize) ? .downwardSwipe : nil
        }
        if isLeadingEdgeIntent(startLocation: startLocation, translation: translation, viewportSize: viewportSize) {
            let distance = max(translation.width, predictedEndTranslation.width)
            return distance >= leadingEdgeThreshold(for: viewportSize) ? .leadingEdgeSwipe : nil
        }
        return nil
    }

    static func dismissalOpacity(offset: CGSize, viewportSize: CGSize) -> Double {
        let travel = max(offset.width, offset.height)
        let reference = max(min(viewportSize.width, viewportSize.height) * 0.65, 1)
        return Double(max(0.45, 1 - min(travel / reference, 0.55)))
    }

    private static func isDownwardIntent(_ translation: CGSize) -> Bool {
        translation.height > 0 && translation.height > abs(translation.width)
    }

    private static func isLeadingEdgeIntent(
        startLocation: CGPoint,
        translation: CGSize,
        viewportSize: CGSize
    ) -> Bool {
        startLocation.x <= leadingEdgeActivationWidth(for: viewportSize)
            && translation.width > 0
            && translation.width > abs(translation.height)
    }

    private static func leadingEdgeActivationWidth(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.width * 0.08, 24), 44)
    }

    private static func downwardThreshold(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.height * 0.12, 88), 140)
    }

    private static func leadingEdgeThreshold(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.width * 0.24, 84), 140)
    }
}

private struct AttachmentShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AttachmentActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onComplete: ((Bool, Error?) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async {
                onComplete?(completed, error)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AttachmentImagePreviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    let localURL: URL?
    @State private var scale: CGFloat = 1
    @State private var dismissalOffset: CGSize = .zero
    @State private var dismissalCoordinator = AttachmentImagePreviewDismissalCoordinator()
    @GestureState private var gestureScale: CGFloat = 1

    private var imageURL: URL? {
        if AttachmentGIFPresentation.isGIF(message) {
            return AttachmentGIFPresentation.originalURL(
                localURL: localURL,
                downloadURL: state.resolvedAttachmentDownloadURL(for: message),
                previewURL: state.resolvedAttachmentPreviewURL(for: message),
                downloadAllowed: message.attachmentDownloadAvailable,
                previewAllowed: message.attachmentPreviewAvailable
            )
        }
        return localURL ?? state.resolvedAttachmentBestPreviewURL(for: message)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if imageURL != nil || AttachmentGIFPresentation.isGIF(message) {
                    Group {
                        if AttachmentGIFPresentation.isGIF(message) {
                            AttachmentGIFImage(message: message, conversationID: conversationID, localURL: localURL, maxPixelSize: 1024) {
                                ProgressView().tint(.white)
                            }
                        } else if let imageURL {
                            CachedRemoteImage(urlString: imageURL.absoluteString, contentMode: .fit) {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                    .scaleEffect(effectiveScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                scale = max(1, min(scale * value, 5))
                            }
                    )
                    .padding(.horizontal, 12)
                } else {
                    unavailableView("图片暂无可用预览链接")
                }
            }
            .overlay(alignment: .top) {
                mediaTopControls(title: message.attachmentName ?? "图片") {
                    requestDismissal(.closeButton)
                } onSave: {
                    saveImage()
                }
                .accessibilityIdentifier("attachment_image_preview_controls")
            }
            .contentShape(Rectangle())
            .offset(dismissalOffset)
            .opacity(AttachmentImagePreviewDismissalPolicy.dismissalOpacity(offset: dismissalOffset, viewportSize: proxy.size))
            .simultaneousGesture(dismissalGesture(in: proxy.size))
        }
        .background(Color.black.ignoresSafeArea())
        .accessibilityAction(.escape) {
            requestDismissal(.accessibilityEscape)
        }
        .accessibilityAction(named: Text("关闭图片预览")) {
            requestDismissal(.accessibilityEscape)
        }
    }

    private var effectiveScale: CGFloat {
        max(1, min(scale * gestureScale, 5))
    }

    private func dismissalGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dismissalOffset = AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    viewportSize: viewportSize,
                    scale: effectiveScale
                )
            }
            .onEnded { value in
                let trigger = AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportSize: viewportSize,
                    scale: effectiveScale
                )
                if let trigger {
                    requestDismissal(trigger)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dismissalOffset = .zero
                    }
                }
            }
    }

    private func requestDismissal(_ trigger: AttachmentImagePreviewDismissalTrigger) {
        guard dismissalCoordinator.request(trigger) else { return }
        dismiss()
    }

    private func unavailableView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 34, weight: .bold))
            Text(text)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.86))
    }

    private func saveImage() {
        guard let imageURL else {
            state.toast = "图片暂无可保存链接"
            return
        }
        Task {
            if AttachmentGIFPresentation.isGIF(message) {
                do {
                    let original = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                    let result = await AttachmentPhotoLibrarySaver.saveOriginalImage(at: original)
                    switch result {
                    case .success: state.toast = "图片已保存到相册"
                    case .denied: state.toast = "没有相册保存权限，请在系统设置中开启"
                    case .failed, .unknownFailure: state.toast = "图片保存失败，请重试"
                    }
                } catch {
                    state.toast = "图片下载失败，请重试"
                }
                return
            }
            let image: UIImage?
            if imageURL.isFileURL {
                image = UIImage(contentsOfFile: imageURL.path)
            } else {
                image = await AvatarImageCache.shared.remoteImage(for: imageURL.absoluteString)
            }
            guard let image else {
                await MainActor.run {
                    state.toast = imageURL.isFileURL ? "图片文件不存在，请重新下载后保存" : "图片下载失败，请重试"
                }
                return
            }
            let result = await AttachmentPhotoLibrarySaver.saveImage(image)
            await MainActor.run {
                switch result {
                case .success:
                    state.toast = "图片已保存到相册"
                case .denied:
                    state.toast = "没有相册保存权限，请在系统设置中开启"
                case .failed(let message):
                    state.toast = "图片保存失败：\(message)"
                case .unknownFailure:
                    state.toast = "图片保存失败，请重试"
                }
            }
        }
    }
}

struct AttachmentVideoPreviewSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let localURL: URL?

    private var videoURL: URL? {
        localURL ?? state.resolvedAttachmentBestPreviewURL(for: message)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let videoURL {
                AttachmentInlineVideoPlayer(url: videoURL)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 36, weight: .black))
                    Text("视频暂无可播放链接")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
    }
}

private enum AttachmentPhotoLibrarySaveResult {
    case success
    case denied
    case failed(String)
    case unknownFailure
}

private enum AttachmentPhotoLibrarySaver {
    static func saveOriginalImage(at url: URL) async -> AttachmentPhotoLibrarySaveResult {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return .unknownFailure }
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else { return .denied }
        return await performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    static func saveImage(_ image: UIImage) async -> AttachmentPhotoLibrarySaveResult {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return .denied
        }
        return await performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func saveVideo(at url: URL) async -> AttachmentPhotoLibrarySaveResult {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return .denied
        }
        return await performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_PHOTOS_SENDABLE - 修改开始：对齐 Swift 6 Photos 写入闭包并发边界
    private static func performChanges(_ changes: @escaping @Sendable () -> Void) async -> AttachmentPhotoLibrarySaveResult {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume(returning: .success)
                } else if let error {
                    continuation.resume(returning: .failed(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试")))
                } else {
                    continuation.resume(returning: .unknownFailure)
                }
            }
        }
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_PHOTOS_SENDABLE - 修改结束
}

private struct AttachmentInlineVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            controller.player?.pause()
            controller.player = AVPlayer(url: url)
        }
        controller.showsPlaybackControls = true
        controller.player?.play()
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: url)
    }

    final class Coordinator {
        var currentURL: URL

        init(currentURL: URL) {
            self.currentURL = currentURL
        }
    }
}

private struct ForwardMessageTargetSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let sourceConversationID: String
    @State private var targetSearchDraft = ""
    @State private var targetSearchDebounceTask: Task<Void, Never>?
    @State private var targetPageLimits: [BatchForwardTargetTab: Int] = [
        .friend: 20,
        .group: 20
    ]
    private let targetPageSize = 20

    private var supportedTargets: [BatchForwardTargetCandidate] {
        state.batchForwardTargetCandidates()
    }

    private var visibleTargets: [BatchForwardTargetCandidate] {
        Array(
            allFilteredTargets.prefix(
                max(targetPageSize, targetPageLimits[activeTab] ?? targetPageSize)
            )
        )
    }

    private var allFilteredTargets: [BatchForwardTargetCandidate] {
        state.batchForwardVisibleTargetCandidates(
            from: supportedTargets,
            initialLimit: .max
        )
    }

    private var activeTab: BatchForwardTargetTab {
        state.batchForwardState?.activeTargetTab ?? .friend
    }

    private var selectedSourceCount: Int {
        state.batchForwardState?.selectedSourceIDSet.count ?? 0
    }

    private var selectedTargetCount: Int {
        state.batchForwardState?.selectedTargets.count ?? 0
    }

    private var selectedTargetKeys: [String] {
        state.batchForwardState?.selectedTargetIdentityKeysInOrder ?? []
    }

    private var hasMoreTargets: Bool {
        visibleTargets.count < allFilteredTargets.count
    }

    private var isSubmitting: Bool {
        guard let phase = state.batchForwardState?.submissionPhase else {
            return false
        }
        if case .submitting = phase {
            return true
        }
        return false
    }

    private var committedBatchID: String? {
        guard let phase = state.batchForwardState?.submissionPhase else {
            return nil
        }
        if case .committed(let batchID) = phase {
            return batchID
        }
        return nil
    }

    private var failurePresentation: (title: String, detail: String)? {
        guard let phase = state.batchForwardState?.submissionPhase else {
            return nil
        }
        switch phase {
        case .retryableFailure(let message):
            let detail = message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                "转发未完成",
                detail.isEmpty ? "请检查选择后使用同一批次重试。" : detail
            )
        case .uncertain(let message):
            let detail = message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                "结果待确认",
                detail.isEmpty
                    ? "网络中断时服务端可能已提交；重试会复用同一批次，不会重复发送。"
                    : detail
            )
        case .idle, .submitting, .committed:
            return nil
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { targetSearchDraft },
            set: { query in
                targetSearchDraft = query
            }
        )
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "arrowshape.turn.up.right.fill",
                        title: "批量转发",
                        subtitle: "\(selectedSourceCount) 条消息 → \(selectedTargetCount) 个会话",
                        showsCloseButton: !isSubmitting
                    )

                    targetTabs

                    SearchField(
                        text: searchBinding,
                        placeholder: activeTab == .friend ? "搜索好友" : "搜索群聊"
                    )

                    if !selectedTargetKeys.isEmpty {
                        selectedTargetChips
                    }

                    if visibleTargets.isEmpty {
                        EmptyStateView(
                            symbol: "bubble.left.and.bubble.right",
                            title: searchBinding.wrappedValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty ? "暂无可转发会话" : "没有匹配会话",
                            subtitle: activeTab == .friend
                                ? "可选择一个或多个好友。"
                                : "可选择一个或多个群聊。"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleTargets) { candidate in
                                    targetRow(candidate)
                                }
                                if hasMoreTargets {
                                    Button("查看更多") {
                                        targetPageLimits[activeTab, default: targetPageSize]
                                            += targetPageSize
                                    }
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .accessibilityIdentifier("batch_forward_expand_targets")
                                    .accessibilityHint("每次加载最多 \(targetPageSize) 个结果")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let failurePresentation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failurePresentation.title)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.danger)
                            Text(failurePresentation.detail)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(IMColor.danger.opacity(0.08))
                        )
                        .accessibilityElement(children: .combine)
                    }

                    Button {
                        state.submitBatchForward()
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(
                                isSubmitting
                                    ? "正在转发"
                                    : (failurePresentation == nil ? "确认转发" : "使用同一批次重试")
                            )
                                .font(.system(size: 15, weight: .black))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(
                                    selectedSourceCount > 0 && selectedTargetCount > 0
                                        ? IMColor.brand
                                        : IMColor.muted.opacity(0.45)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        isSubmitting
                            || selectedSourceCount == 0
                            || selectedTargetCount == 0
                    )
                    .accessibilityIdentifier("batch_forward_submit")
                    .accessibilityHint("消息将按原会话顺序发送")
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicatorCompat(.visible)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            targetSearchDraft = state.batchForwardState?.targetSearchQuery ?? ""
        }
        .onChange(of: targetSearchDraft) { query in
            targetSearchDebounceTask?.cancel()
            targetPageLimits[activeTab] = targetPageSize
            targetSearchDebounceTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Task.checkCancellation()
                    state.setBatchForwardTargetSearchQuery(query)
                } catch {
                    return
                }
            }
        }
        .onChange(of: committedBatchID) { batchID in
            if batchID != nil {
                dismiss()
            }
        }
        .onDisappear {
            targetSearchDebounceTask?.cancel()
        }
    }

    private var targetTabs: some View {
        HStack(spacing: 8) {
            targetTabButton(.friend, title: "好友", symbol: "person.fill")
            targetTabButton(.group, title: "群聊", symbol: "person.3.fill")
        }
    }

    private func targetTabButton(
        _ tab: BatchForwardTargetTab,
        title: String,
        symbol: String
    ) -> some View {
        Button {
            state.setBatchForwardTargetTab(tab)
            targetPageLimits[tab] = max(
                targetPageSize,
                targetPageLimits[tab] ?? targetPageSize
            )
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(activeTab == tab ? .white : IMColor.ink)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(activeTab == tab ? IMColor.brand : .white.opacity(0.78))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
        .accessibilityIdentifier("batch_forward_tab_\(tab.rawValue)")
    }

    private var selectedTargetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedTargetKeys, id: \.self) { identityKey in
                    if let target = state.batchForwardState?
                        .targetsByIdentity[identityKey] {
                        Button {
                            state.removeBatchForwardTarget(identityKey: identityKey)
                        } label: {
                            HStack(spacing: 5) {
                                Text(target.displayName)
                                    .lineLimit(1)
                                Image(systemName: "xmark.circle.fill")
                            }
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(
                                Capsule().fill(IMColor.brand.opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityLabel("移除目标 \(target.displayName)")
                    }
                }
            }
        }
        .accessibilityIdentifier("batch_forward_selected_targets")
    }

    @ViewBuilder
    private func targetAvatar(for candidate: BatchForwardTargetCandidate) -> some View {
        if candidate.isGroup {
            GroupAvatarView(
                name: candidate.target.displayName,
                seed: candidate.avatarSeed,
                size: 44,
                imageURL: candidate.avatarURL,
                avatarVersion: candidate.avatarVersion,
                avatarUpdatedAt: candidate.avatarUpdatedAt,
                imageCacheKey: state.groupAvatarCacheKey(
                    groupID: candidate.target.channelID,
                    avatarURL: candidate.avatarURL,
                    avatarVersion: candidate.avatarVersion,
                    avatarUpdatedAt: candidate.avatarUpdatedAt
                )
            )
        } else {
            AvatarView(
                name: candidate.target.displayName,
                seed: candidate.avatarSeed,
                size: 44,
                imageURL: candidate.avatarURL,
                avatarVersion: candidate.avatarVersion,
                avatarUpdatedAt: candidate.avatarUpdatedAt,
                certification: state.certificationPresentation(
                    forExactUID: targetCertificationUID(for: candidate)
                )
            )
        }
    }

    private func targetRow(_ candidate: BatchForwardTargetCandidate) -> some View {
        let selected = state.isBatchForwardTargetSelected(candidate.target)
        let certificationUID = targetCertificationUID(for: candidate)
        return Button {
            state.toggleBatchForwardTarget(candidate.target)
        } label: {
            HStack(spacing: 12) {
                targetAvatar(for: candidate)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.target.displayName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if !candidate.isGroup {
                        CertificationPillView(
                            exactUID: certificationUID,
                            compact: true
                        )
                    }
                    Text(candidate.subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(selected ? IMColor.brand : IMColor.muted)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.84)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityLabel(
            [
                "\(selected ? "取消选择" : "选择") \(candidate.target.displayName)",
                state.certificationPresentation(
                    forExactUID: certificationUID
                )?.accessibilityLabel
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("forward_target_row_\(candidate.identityKey)")
    }

    private func targetCertificationUID(
        for candidate: BatchForwardTargetCandidate
    ) -> String {
        guard !candidate.isGroup else { return "" }
        let actorUID = state.batchForwardState?.scope.actorUID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = candidate.target.channelID
            .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "|" })
            .map {
                String($0).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
        if parts.count == 2, !actorUID.isEmpty {
            let actorMatches = parts.filter { $0 == actorUID }
            guard actorMatches.count == 1 else { return "" }
            return parts.first(where: { $0 != actorUID }) ?? ""
        }
        let directUID = candidate.target.channelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actorUID.isEmpty,
              parts.count == 1,
              directUID == parts[0],
              directUID != actorUID else {
            return ""
        }
        return directUID
    }
}

struct AttachmentDetailSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let conversationID: String
    var onForward: ((ChatMessage) -> Void)? = nil
    @State private var previewDocument: AttachmentLocalPreviewDocument?
    @State private var previewVideoAttachment: AttachmentMediaPreviewItem?
    @State private var shareItem: AttachmentShareItem?
    @State private var isPreparingPreview = false
    @State private var isPreparingShare = false

    private var progress: Double? {
        state.attachmentTransferProgress(for: message)
    }

    private var fileName: String {
        message.attachmentName ?? message.text
    }

    private var sizeText: String {
        if let size = message.attachmentSizeBytes, size > 0 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return "大小待同步"
    }

    private var mediaCategory: String {
        state.attachmentMediaCategory(for: message)
    }

    private var mediaSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill.on.rectangle.fill"
        case "video": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "audio": return "waveform"
        case "archive": return "archivebox.fill"
        default: return "doc.fill"
        }
    }

    private var detailTitle: String {
        switch mediaCategory {
        case "image": return "图片详情"
        case "video": return "视频详情"
        case "pdf": return "PDF 详情"
        default: return "文件详情"
        }
    }

    private var previewTitle: String {
        switch mediaCategory {
        case "image": return "查看原图"
        case "video": return "播放视频"
        case "pdf": return "阅读 PDF"
        default: return "系统预览"
        }
    }

    private var previewSymbol: String {
        switch mediaCategory {
        case "image": return "photo.fill"
        case "video": return "play.circle.fill"
        case "pdf": return "doc.text.magnifyingglass"
        default: return "eye.fill"
        }
    }

    private var previewURL: URL? {
        state.resolvedAttachmentBestPreviewURL(for: message)
    }

    private var previewAvailable: Bool {
        if state.attachmentCanRefreshRemoteFile(message) {
            return true
        }
        if mediaCategory == "video" {
            return previewURL != nil || state.resolvedAttachmentDownloadURL(for: message) != nil
        }
        return previewURL != nil
    }

    private var downloadAvailable: Bool {
        state.resolvedAttachmentDownloadURL(for: message) != nil || state.attachmentCanRefreshRemoteFile(message)
    }

    private var canRetryUpload: Bool {
        state.canRetryAttachmentUpload(message)
    }

    private var canCancelUpload: Bool {
        state.isAttachmentUploadInProgress(message) || canRetryUpload
    }

    private var batchForwardDisabledReason: String? {
        switch state.batchForwardEligibility(
            for: message,
            in: conversationID
        ) {
        case .selectable:
            return nil
        case .disabled(let reason):
            return reason
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(
                            symbol: mediaSymbol,
                            title: detailTitle,
                            subtitle: "使用后端返回的预览 / 下载链接，不在客户端拼接存储地址。",
                            showsCloseButton: true
                        )

                        fileSummary
                        if let progress {
                            progressCard(progress)
                        }
                        if let failureMessage = state.attachmentUploadFailureMessage(for: message) {
                            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(IMColor.danger.opacity(0.08))
                                )
                        }
                        actionGrid
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicatorCompat(.visible)
        .sheet(item: $previewDocument) { document in
            AttachmentQuickLookPreview(url: document.url)
        }
        .fullScreenCover(item: $previewVideoAttachment) { item in
            AttachmentVideoPreviewSheet(message: item.message, localURL: item.localURL)
        }
        .sheet(item: $shareItem) { item in
            AttachmentActivityView(activityItems: [item.url]) { completed, error in
                if let error {
                    state.toast = "保存/分享失败：\(BackendUserMessageSanitizer.sanitize(error: error, fallback: "请重试"))"
                } else if completed {
                    state.toast = "保存/分享已完成"
                }
            }
                .presentationDetentsCompat([.medium, .large])
        }
    }

    private var fileSummary: some View {
        HStack(spacing: 14) {
            ZStack {
                if mediaCategory == "image" || mediaCategory == "video" {
                    AttachmentThumbnailImage(
                        url: state.resolvedAttachmentThumbnailURL(for: message) ?? previewURL,
                        cacheKey: state.attachmentThumbnailCacheKey(for: message),
                        contentMode: .fill,
                        scopeGeneration: state.mediaCacheScopeContext?.sessionGeneration ?? 0,
                        networkRecoveryGeneration: state.mediaNetworkRecoveryGeneration,
                        recoveryURL: {
                            try? await state.prepareMessageAttachmentLocalFile(
                                message,
                                conversationID: conversationID,
                                preferPreview: true
                            )
                        },
                        indexedCacheURL: {
                            await state.cachedUnifiedAttachmentThumbnailURL(for: message)
                        },
                        indexedCacheCommit: { data in
                            await state.cacheUnifiedAttachmentThumbnail(
                                data,
                                for: message,
                                conversationID: conversationID
                            )
                        }
                    ) {
                        summaryIcon
                    } failure: {
                        summaryIcon
                    }
                    if mediaCategory == "video" {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.black.opacity(0.42)))
                    }
                } else {
                    summaryIcon
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(fileName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                Text([message.attachmentMeta, sizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .plainCard(radius: 24)
    }

    private var summaryIcon: some View {
        Image(systemName: mediaSymbol)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(IMColor.brand)
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand.opacity(0.12)))
    }

    private func progressCard(_ progress: Double) -> some View {
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DETAIL_REAL_PROGRESS_TEXT - 修改开始：详情页只展示真实传输百分比，不再称为阶段进度
        let boundedProgress = max(0, min(progress, 1))
        let percentText = "\(Int(boundedProgress * 100))%"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.isAttachmentUploadInProgress(message) ? "上传中" : "下载中")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text(percentText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
            }
            ProgressView(value: boundedProgress)
                .tint(IMColor.brand)
        }
        .plainCard(radius: 22)
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DETAIL_REAL_PROGRESS_TEXT - 修改结束
    }

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            attachmentActionTile(previewTitle, symbol: previewSymbol, enabled: previewAvailable && !isPreparingPreview) {
                openPreview()
            }
            attachmentActionTile("分享", symbol: "square.and.arrow.up.fill", enabled: downloadAvailable && !isPreparingShare) {
                prepareShare()
            }
            if let onForward {
                if let batchForwardDisabledReason {
                    attachmentActionTile(
                        batchForwardDisabledReason,
                        symbol: "arrowshape.turn.up.right.fill",
                        enabled: false,
                        accessibilityLabel: batchForwardDisabledReason
                    ) {}
                } else {
                    attachmentActionTile("转发", symbol: "arrowshape.turn.up.right.fill", enabled: true) {
                        onForward(message)
                    }
                }
            }
            if canRetryUpload {
                attachmentActionTile("重试上传", symbol: "arrow.clockwise.circle.fill", enabled: true) {
                    state.retryAttachmentUpload(messageID: message.id, in: conversationID)
                }
            }
            if canCancelUpload {
                attachmentActionTile("取消发送", symbol: "xmark.circle.fill", tint: IMColor.danger, enabled: true) {
                    state.cancelAttachmentUpload(messageID: message.id, in: conversationID)
                    dismiss()
                }
            }
        }
    }

    private func openPreview() {
        if mediaCategory == "image" {
            state.openMessageAttachment(message, conversationID: conversationID, preferPreview: true)
            return
        }
        if mediaCategory == "video" {
            isPreparingPreview = true
            Task {
                guard await state.authorizeProtectedAccess(.filePreview) else {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                    return
                }
                do {
                    let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: true)
                    await MainActor.run {
                        isPreparingPreview = false
                        previewVideoAttachment = AttachmentMediaPreviewItem(message: message, localURL: localURL)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        isPreparingPreview = false
                    }
                } catch {
                    await MainActor.run {
                        isPreparingPreview = false
                        state.toast = "视频下载失败，无法播放，请重试"
                    }
                }
            }
            return
        }
        guard let previewURL else {
            state.toast = "当前附件暂无可预览链接"
            return
        }
        isPreparingPreview = true
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingPreview = false
                }
                return
            }
            do {
                let localURL = try await AttachmentSystemPreviewLoader.download(
                    previewURL,
                    suggestedName: fileName,
                    cacheIdentity: state.attachmentSystemPreviewCacheIdentity(for: message)
                )
                await MainActor.run {
                    isPreparingPreview = false
                    previewDocument = AttachmentLocalPreviewDocument(url: localURL)
                }
            } catch {
                await MainActor.run {
                    isPreparingPreview = false
                    state.openMessageAttachment(message, conversationID: conversationID, preferPreview: true)
                }
            }
        }
    }

    private func prepareShare() {
        isPreparingShare = true
        Task {
            guard await state.authorizeProtectedAccess(.filePreview) else {
                await MainActor.run {
                    isPreparingShare = false
                }
                return
            }
            do {
                let localURL = try await state.prepareMessageAttachmentLocalFile(message, conversationID: conversationID, preferPreview: false)
                await MainActor.run {
                    isPreparingShare = false
                    shareItem = AttachmentShareItem(url: localURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    isPreparingShare = false
                    state.toast = "下载失败，请重试"
                }
            }
        }
    }
}

private struct AttachmentLocalPreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private enum AttachmentSystemPreviewLoader {
    static func download(_ remoteURL: URL, suggestedName: String, cacheIdentity: String? = nil) async throws -> URL {
        try await SystemPreviewLoader.download(remoteURL, suggestedName: suggestedName, cacheIdentity: cacheIdentity)
    }
}

@MainActor
private func mediaTopControls(title: String, onClose: @escaping () -> Void, onSave: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
        mediaOverlayIconButton(symbol: "xmark", label: "关闭图片预览", action: onClose)
            .accessibilityIdentifier("attachment_image_preview_close_button")
            .keyboardShortcut(.cancelAction)

        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        mediaOverlayIconButton(symbol: "square.and.arrow.down", label: "保存", action: onSave)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .safeAreaPaddingTopCompat(8)
    .background(
        LinearGradient(
            colors: [.black.opacity(0.74), .black.opacity(0.36), .black.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("媒体查看操作栏")
}

@MainActor
private func mediaOverlayIconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(0.46)))
            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
}

@MainActor
private func attachmentActionButton(_ title: String, symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(.white.opacity(0.16)))
    }
    .buttonStyle(.plain)
}

@MainActor
private func attachmentActionTile(
    _ title: String,
    symbol: String,
    tint: Color = IMColor.brand,
    enabled: Bool,
    accessibilityLabel: String? = nil,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(enabled ? tint : IMColor.muted)
                .frame(width: 44, height: 44)
                .background(Circle().fill((enabled ? tint : IMColor.muted).opacity(0.12)))
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(enabled ? IMColor.ink : IMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.76)))
    }
    .disabled(!enabled)
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel ?? title)
    .accessibilityValue(enabled ? "" : "不可用")
}

struct ReadReceiptSheet: View {
    let message: ChatMessage
    let conversation: Conversation
    let readReceiptsEnabled: Bool
    @EnvironmentObject private var state: AppState

    private var isDirectConversation: Bool {
        conversation.kind == .direct
    }

    private var showAggregateCounts: Bool {
        isDirectConversation || state.shouldShowGroupMemberCount
    }

    private var peer: IMUser? {
        conversation.participants.first { $0.id != message.senderId } ?? conversation.participants.first
    }

    private var peerDisplayName: String {
        guard let peer else { return "对方" }
        return state.remarkPreferredDisplayName(for: peer, fallback: "对方")
    }

    private var directRead: Bool {
        message.status == .read || !message.readBy.isEmpty
    }

    private var canViewReceiptDetails: Bool {
        message.canViewReadDetails
    }

    private var readReceiptCount: Int? {
        guard showAggregateCounts else { return nil }
        return message.readCount
    }

    private var unreadReceiptCount: Int? {
        guard showAggregateCounts else { return nil }
        if let unreadCount = message.unreadCount {
            return unreadCount
        }
        return nil
    }

    private var unreadSectionTitle: String {
        if let unreadReceiptCount, showAggregateCounts {
            return "未读 \(unreadReceiptCount)"
        }
        return "未读明细"
    }

    private var unreadEmptyText: String {
        if let unreadReceiptCount, showAggregateCounts {
            if unreadReceiptCount == 0 {
                return "暂无未读成员"
            }
            return "后端未返回未读成员明细，当前按群成员数和已读数推算仍有 \(unreadReceiptCount) 人未读。"
        }
        return "后端暂未返回未读统计或成员明细，无法确认未读人数。"
    }

    private var directStatusTitle: String {
        if message.isOutgoing {
            return directRead ? "对方已读" : "对方未读"
        }
        return "你已读此消息"
    }

    private var directStatusDetail: String {
        if let receipt = message.readBy.first {
            return "已读时间 \(receipt.time)"
        }
        if message.isOutgoing {
            return directRead ? "已确认送达并读取" : "消息已送达，等待对方查看"
        }
        return "当前设备已完成阅读"
    }

    private var directReceiptExactUID: String {
        message.isOutgoing ? peer?.id ?? "" : state.currentUser.id
    }

    private var directReceiptDisplayName: String {
        message.isOutgoing
            ? peerDisplayName
            : state.currentUser.displayName
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(
                            symbol: "checkmark.seal.fill",
                            title: readReceiptsEnabled ? (canViewReceiptDetails && !isDirectConversation ? "已读列表" : "已读状态") : "已读状态",
                            subtitle: readReceiptsEnabled ? (canViewReceiptDetails && !isDirectConversation ? "查看群成员对这条消息的读取状态。" : "查看这条消息是否已被读取。") : "当前企业未开通",
                            showsCloseButton: true
                        )

                        if !readReceiptsEnabled {
                            readReceiptDisabledCard
                        } else if !canViewReceiptDetails {
                            anonymousReceiptCard
                        } else if isDirectConversation {
                            directReceiptCard
                            reactionSection
                        } else {
                            receiptSection(
                                title: readReceiptCount.map { "已读 \($0)" } ?? "已读明细",
                                receipts: message.readBy,
                                read: true,
                                emptyText: "暂无成员已读"
                            )
                            reactionSection
                            receiptSection(title: unreadSectionTitle, receipts: message.unreadBy, read: false, emptyText: unreadEmptyText)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicatorCompat(.visible)
    }

    private var readReceiptDisabledCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 54, height: 54)
                .background(Circle().fill(IMColor.muted.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                Text("当前企业未开通")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
            }
            Spacer()
        }
        .plainCard(radius: 24)
    }

    private var anonymousReceiptCard: some View {
        HStack(spacing: 14) {
            Image(systemName: directRead ? "checkmark.seal.fill" : "clock.fill")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(directRead ? IMColor.success : IMColor.muted)
                .frame(width: 52, height: 52)
                .background(Circle().fill((directRead ? IMColor.success : IMColor.muted).opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(directRead ? "已读" : "未读")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    StatusPill(title: directRead ? "已读" : "未读", color: directRead ? IMColor.success : IMColor.muted)
                }
                Text(directRead ? "对方已读取这条消息" : "对方暂未读取这条消息")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
        }
        .plainCard(radius: 24)
    }

    private var directReceiptCard: some View {
        HStack(spacing: 14) {
            AvatarView(
                name: directReceiptDisplayName,
                seed: message.isOutgoing
                    ? (peer?.avatarSeed ?? 0x7C6BFF)
                    : state.currentUser.avatarSeed,
                size: 50,
                badgeColor: directRead ? IMColor.success : IMColor.muted,
                imageURL: message.isOutgoing
                    ? peer?.displayAvatarURL ?? ""
                    : state.currentUser.displayAvatarURL,
                avatarVersion: message.isOutgoing
                    ? peer?.avatarVersion ?? ""
                    : state.currentUser.avatarVersion,
                avatarUpdatedAt: message.isOutgoing
                    ? peer?.avatarUpdatedAt ?? ""
                    : state.currentUser.avatarUpdatedAt,
                certification: state.certificationPresentation(
                    forExactUID: directReceiptExactUID
                )
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(directReceiptDisplayName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    CertificationPillView(
                        exactUID: directReceiptExactUID,
                        compact: true
                    )
                    StatusPill(title: directRead ? "已读" : "未读", color: directRead ? IMColor.success : IMColor.muted)
                }
                Text(directStatusTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.ink)
                Text(directStatusDetail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
        }
        .plainCard(radius: 24)
    }

    private func receiptSection(title: String, receipts: [ReadReceipt], read: Bool, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            if receipts.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.68)))
            } else {
                ForEach(receipts) { receipt in
                    ReceiptRow(receipt: receipt, read: read)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
            }
        }
        .plainCard(radius: 24)
    }

    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("回应清单")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            if message.reactionDetails.isEmpty {
                Text("暂无回应")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.68)))
            } else {
                ForEach(message.reactionDetails) { reaction in
                    ReactionDetailRow(reaction: reaction)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
            }
        }
        .plainCard(radius: 24)
    }
}

struct MessageEditAuthoritativeSuccess: Equatable {
    let scope: String
    let conversationID: String
    let messageID: String
    let submittedText: String
    let expectedRevision: Int64
    let authoritativeRevision: Int64
}

func messageEditAuthoritativeSuccess(
    saved: Bool,
    scope: String,
    currentScope: String,
    conversationID: String,
    currentConversationID: String,
    messageID: String,
    submittedText: String,
    expectedRevision: Int64,
    currentMessage: ChatMessage?
) -> MessageEditAuthoritativeSuccess? {
    let normalizedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard saved,
          !scope.isEmpty,
          scope == currentScope,
          conversationID == currentConversationID,
          let currentMessage,
          currentMessage.id == messageID,
          currentMessage.editRevision > expectedRevision,
          currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText else { return nil }
    return MessageEditAuthoritativeSuccess(
        scope: scope,
        conversationID: conversationID,
        messageID: messageID,
        submittedText: normalizedText,
        expectedRevision: expectedRevision,
        authoritativeRevision: currentMessage.editRevision
    )
}

func messageEditAuthoritativeSuccessIsCurrent(
    _ success: MessageEditAuthoritativeSuccess,
    currentScope: String,
    currentConversationID: String,
    currentMessage: ChatMessage?
) -> Bool {
    guard success.scope == currentScope,
          success.conversationID == currentConversationID,
          let currentMessage,
          currentMessage.id == success.messageID,
          currentMessage.editRevision >= success.authoritativeRevision,
          currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == success.submittedText else { return false }
    return true
}

struct MessageEditSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    let onAuthoritativeSuccess: (MessageEditAuthoritativeSuccess) -> Bool
    @State private var draft: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(
        message: ChatMessage,
        conversationID: String,
        onAuthoritativeSuccess: @escaping (MessageEditAuthoritativeSuccess) -> Bool
    ) {
        self.message = message
        self.conversationID = conversationID
        self.onAuthoritativeSuccess = onAuthoritativeSuccess
        _draft = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStackCompat {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(symbol: "pencil.and.outline", title: "编辑消息", subtitle: "修改发送内容，保存后会显示已编辑状态。", showsCloseButton: true)
                TextEditor(text: $draft)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minHeight: 130)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xF3F5FA)))
                    .scrollContentBackgroundHiddenCompat()
                if isSaving {
                    Text("等待服务端确认编辑结果…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                PrimaryButton(title: isSaving ? "正在保存" : "保存编辑", systemImage: "checkmark", disabled: isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        let submittedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let submissionScope = state.activeConversationHistoryScope
                        let expectedRevision = state.conversations
                            .first(where: { $0.id == conversationID })?
                            .messages.first(where: { $0.id == message.id })?
                            .editRevision ?? message.editRevision
                        let saved = await state.editMessage(messageID: message.id, in: conversationID, newText: submittedText)
                        isSaving = false
                        let currentMessage = state.conversations
                            .first(where: { $0.id == conversationID })?
                            .messages.first(where: { $0.id == message.id })
                        guard let success = messageEditAuthoritativeSuccess(
                            saved: saved,
                            scope: submissionScope,
                            currentScope: state.activeConversationHistoryScope,
                            conversationID: conversationID,
                            currentConversationID: state.messageEditCurrentConversationID ?? "",
                            messageID: message.id,
                            submittedText: submittedText,
                            expectedRevision: expectedRevision,
                            currentMessage: currentMessage
                        ), onAuthoritativeSuccess(success) else { return }
                        dismiss()
                    }
                }
                Spacer()
            }
            .padding(18)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MessageReportSheet: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage
    let conversationID: String
    @State private var reason = MessageReportCategory.illegalTrade.rawValue
    @State private var description = ""
    @State private var inlineMessage: String?
    @State private var isSubmitting = false
    @State private var isLookingUp = false
    @State private var readOnlyReport: RemoteMessageReport?
    @Environment(\.dismiss) private var dismiss

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReadOnly: Bool {
        readOnlyReport != nil
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !isLookingUp
            && !isReadOnly
            && MessageReportCategory.allowedReasons.contains(reason)
            && !trimmedDescription.isEmpty
    }

    private var senderName: String {
        if isCancelledUserAvatarURL(message.senderAvatarURL) {
            return cancelledUserDisplayName
        }
        let name = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [name],
            fallback: name.isEmpty ? "未知用户" : name
        )
    }

    private var senderUserID: String {
        let uid = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return uid.isEmpty ? "未知用户ID" : uid
    }

    private var senderAvatarSeed: UInt {
        message.senderAvatarSeed == 0 ? UInt(bitPattern: senderUserID.hashValue) : message.senderAvatarSeed
    }

    var body: some View {
        NavigationStackCompat {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(
                        symbol: "exclamationmark.shield.fill",
                        title: "举报此消息",
                        subtitle: isReadOnly ? "该消息已举报成功，以下为上次提交内容。" : "请选择违规类型并填写理由，举报内容会提交给企业审核。",
                        showsCloseButton: true
                    )
                    if isLookingUp {
                        Label("正在检查举报状态", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.72)))
                            .accessibilityIdentifier("message_report_lookup_loading")
                    }
                    if isReadOnly {
                        Label("已举报成功", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.success.opacity(0.12)))
                            .accessibilityIdentifier("message_report_readonly_banner")
                    }
                    reportedSenderCard
                    reportedMessageCard
                    VStack(alignment: .leading, spacing: 10) {
                        Text("举报分类")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        VStack(spacing: 9) {
                            ForEach(MessageReportCategory.allCases, id: \.self) { item in
                                Button {
                                    guard !isReadOnly, !isLookingUp else { return }
                                    reason = item.rawValue
                                    inlineMessage = nil
                                } label: {
                                    HStack {
                                        Text(item.rawValue)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(IMColor.ink)
                                        Spacer()
                                        Image(systemName: reason == item.rawValue ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(reason == item.rawValue ? IMColor.brand : IMColor.muted)
                                    }
                                    .padding(14)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.82)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isReadOnly || isLookingUp)
                                .accessibilityIdentifier("message_report_reason_\(item.rawValue)")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("举报理由")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $description)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(minHeight: 118)
                                .padding(10)
                                .scrollContentBackgroundHiddenCompat()
                                .disabled(isReadOnly || isLookingUp)
                                .accessibilityIdentifier("message_report_description_input")
                            if description.isEmpty && !isReadOnly {
                                Text("请补充举报理由")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(IMColor.muted.opacity(0.56))
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.86)))
                    }
                    if let inlineMessage {
                        Text(inlineMessage)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isReadOnly ? IMColor.success : IMColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("message_report_inline_error")
                    }
                    if !isReadOnly {
                        PrimaryButton(
                            title: isLookingUp ? "检查中..." : (isSubmitting ? "提交中..." : "提交举报"),
                            systemImage: "paperplane.fill",
                            disabled: !canSubmit,
                            action: submitReport
                        )
                        .accessibilityIdentifier("message_report_submit_button")
                    }
                }
                .padding(18)
            }
            .background(AuroraBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: message.id) {
            await loadExistingReportIfNeeded()
        }
    }

    private var reportedSenderCard: some View {
        HStack(spacing: 12) {
            AvatarView(
                name: senderName,
                seed: senderAvatarSeed,
                size: 48,
                imageURL: message.senderAvatarURL,
                avatarVersion: message.senderAvatarVersion,
                avatarUpdatedAt: message.senderAvatarUpdatedAt,
                certification: state.certificationPresentation(
                    forExactUID: message.senderId
                )
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
                Text("用户ID \(senderUserID)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.84)))
        .accessibilityIdentifier("message_report_sender_card")
    }

    private var reportedMessageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("被举报消息")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted)
            Text(messageReportPreviewText(for: message))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.84)))
        .accessibilityIdentifier("message_report_message_card")
    }

    private func submitReport() {
        guard !isSubmitting else { return }
        guard canSubmit else {
            inlineMessage = "请选择分类并填写举报理由"
            return
        }
        isSubmitting = true
        inlineMessage = nil
        let selectedReason = reason
        let reportDescription = trimmedDescription
        let reportMessageID = message.id
        let reportConversationID = conversationID
        Task {
            let result = await state.submitMessageReportDetailed(
                messageID: reportMessageID,
                in: reportConversationID,
                reason: selectedReason,
                description: reportDescription
            )
            await MainActor.run {
                isSubmitting = false
                switch result {
                case .submitted:
                    dismiss()
                case .alreadyReported(let report):
                    applyReadOnlyReport(report)
                case .failed:
                    inlineMessage = "提交失败，请稍后重试"
                }
            }
        }
    }

    @MainActor
    private func applyReadOnlyReport(_ report: RemoteMessageReport) {
        readOnlyReport = report
        let reportedReason = report.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reportedReason.isEmpty {
            reason = reportedReason
        }
        description = report.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        inlineMessage = nil
    }

    private func loadExistingReportIfNeeded() async {
        guard !isSubmitting, readOnlyReport == nil else { return }
        await MainActor.run {
            isLookingUp = true
            inlineMessage = nil
        }
        let report = await state.lookupMessageReport(messageID: message.id, in: conversationID)
        await MainActor.run {
            isLookingUp = false
            if let report {
                applyReadOnlyReport(report)
            }
        }
    }
}

struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let title: String
    let subtitle: String
    var showsCloseButton = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(IMColor.brand))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsCloseButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.86)))
                        .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
        }
    }
}

private struct ReceiptRow: View {
    @EnvironmentObject private var state: AppState

    let receipt: ReadReceipt
    let read: Bool

    private var displayName: String {
        state.remarkPreferredDisplayName(for: receipt.user, fallback: "未知用户")
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: displayName, seed: receipt.user.avatarSeed, size: 38, badgeColor: read ? IMColor.success : IMColor.muted, imageURL: receipt.user.avatarURL, avatarVersion: receipt.user.avatarVersion, avatarUpdatedAt: receipt.user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: receipt.user.id))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: receipt.user.id,
                        compact: true
                    )
                }
                Text(read ? "已读时间 \(receipt.time)" : "暂未读取")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            StatusPill(title: read ? "已读" : "未读", color: read ? IMColor.success : IMColor.muted)
        }
    }
}

private struct ReactionDetailRow: View {
    @EnvironmentObject private var state: AppState

    let reaction: ReactionDetail

    private var displayName: String {
        state.remarkPreferredDisplayName(for: reaction.user, fallback: "未知用户")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(reaction.emoji)
                .font(.system(size: 22))
                .frame(width: 38, height: 38)
                .background(Circle().fill(IMColor.brand.opacity(0.1)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: reaction.user.id,
                        compact: true
                    )
                }
                Text("回应时间 \(reaction.time)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            StatusPill(title: "回应", color: IMColor.brand)
        }
    }
}
