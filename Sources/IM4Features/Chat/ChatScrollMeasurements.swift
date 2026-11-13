import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

public struct ChatScrollMetricsSnapshot: Equatable, Sendable {
    public let viewportHeight: CGFloat
    public let contentMinY: CGFloat
    public let contentMaxY: CGFloat
    var renderedReadToken: String = ""
    var renderedReadSeq: Int64 = 0
    public var readVisibilityEpoch: Int = 0

    static public let zero = ChatScrollMetricsSnapshot(viewportHeight: 0, contentMinY: 0, contentMaxY: 0)

    public var isValid: Bool {
        viewportHeight > 0
            && contentMinY.isFinite
            && contentMaxY.isFinite
            && contentMaxY >= contentMinY
    }

    var contentHeight: CGFloat {
        max(0, contentMaxY - contentMinY)
    }

    public var bottomDistance: CGFloat {
        contentMaxY - viewportHeight
    }
}

public struct ChatScrollReadLayout {
    public let token: String
    public let sequence: Int64
    public let epoch: Int

    @available(iOS 18.0, *)
    public func metrics(for geometry: ScrollGeometry) -> ChatScrollMetricsSnapshot {
        // The container size excludes the safe-area insets, but the raw
        // offset starts at -contentInsets.top. Use viewport coordinates.
        let top = -(geometry.contentOffset.y + geometry.contentInsets.top)
        return metrics(
            viewportHeight: geometry.containerSize.height,
            contentMinY: top,
            contentMaxY: top + geometry.contentSize.height
        )
    }

    public func metrics(viewportHeight: CGFloat, contentMinY: CGFloat, contentMaxY: CGFloat) -> ChatScrollMetricsSnapshot {
        ChatScrollMetricsSnapshot(
            viewportHeight: viewportHeight,
            contentMinY: contentMinY,
            contentMaxY: contentMaxY,
            renderedReadToken: token,
            renderedReadSeq: sequence,
            readVisibilityEpoch: epoch
        )
    }

    public init(token: String,
        sequence: Int64,
        epoch: Int) {
        self.token = token
        self.sequence = sequence
        self.epoch = epoch
    }
}

public struct ChatIncomingRowGeometry: Equatable, Sendable {
    public let token: String
    public let frame: CGRect
    public let epoch: Int
    static public let empty = ChatIncomingRowGeometry(token: "", frame: .null, epoch: -1)
}

// WDT_CHAT_UNREAD_BADGE_20261021_BEGIN: a visible outgoing tail also proves the user reached the latest messages.
public func chatReadAcknowledgementTarget<Messages: BidirectionalCollection>(in messages: Messages) -> ChatMessage?
where Messages.Element == ChatMessage {
    messages.last { message in
        message.channelSeq > 0
            && message.kind != .system
            && !message.isPinnedContextOnly
            && message.status != .sending
            && message.status != .failed
    }
}
// WDT_CHAT_UNREAD_BADGE_20261021_END

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

public struct ChatScrollVisibility: Equatable, Sendable {
    public let isAtBottom: Bool
    public let isNearHistoryBoundary: Bool
    public let isContentUnderfilled: Bool

    public init(isAtBottom: Bool, isNearHistoryBoundary: Bool, isContentUnderfilled: Bool = false) {
        self.isAtBottom = isAtBottom
        self.isNearHistoryBoundary = isNearHistoryBoundary
        self.isContentUnderfilled = isContentUnderfilled
    }

    static public let initial = ChatScrollVisibility(isAtBottom: false, isNearHistoryBoundary: false)
}

// JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_COMPARE - 修改开始：键盘/输入导致的重复布局回调用近似比较去噪
func chatCGFloatApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
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

public func chatIncomingRowGeometryApproximatelyEqual(
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
@MainActor
final public class ChatMessageTopMeasurementStore: ObservableObject {
    private(set) public var values: [String: CGFloat] = [:]

    // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_DEDUPE - 修改开始：几何测量无变化时不调度聊天页滚动处理
    @discardableResult
    public func replace(with values: [String: CGFloat], isEnabled: Bool) -> Bool {
        let nextValues = isEnabled ? values : [:]
        guard !chatGeometryValuesApproximatelyEqual(self.values, nextValues) else { return false }
        self.values = nextValues
        return true
    }
    // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_GEOMETRY_DEDUPE - 修改结束

    public func removeAll() {
        values.removeAll(keepingCapacity: true)
    }

    public subscript(messageID: String) -> CGFloat? {
        values[messageID]
    }

    public init() {}
}

/// Gesture bookkeeping is deliberately not published. Only a start or direction
/// change asks ChatView to update semantic state, read gates and diagnostics.
@MainActor
final public class ChatTranscriptScrollControl: ObservableObject {
    // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110
    public let intents = ChatScrollIntentStateMachine()
    public enum Direction: Equatable {
        case history
        case latest
    }

    public struct Transition: Equatable {
        public let isStart: Bool
        public let direction: Direction
    }

    private(set) public var direction: Direction?
    private(set) public var generation = 0
    private(set) var suppressedUntil = Date.distantPast
    private var previousVerticalTranslation: CGFloat = 0
    private var heldHistorySuppression = false

    public func updateDrag(translation: CGSize, now: Date, suppressionInterval: TimeInterval) -> Transition? {
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
    public func finishDrag(now: Date, suppressionInterval: TimeInterval) -> Direction? {
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

    public func isSuppressed(now: Date) -> Bool {
        heldHistorySuppression || now < suppressedUntil
    }

    public func suppress(now: Date, interval: TimeInterval) {
        suppressedUntil = now.addingTimeInterval(interval)
        _ = nextGeneration()
    }

    public func clearSuppression() {
        suppressedUntil = .distantPast
        // Bottom visibility may change during a drag; it cannot release the
        // active gesture's latch. Explicit jump requests still use the arbiter.
    }

    public func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    public func reset() {
        intents.reset() // WDT_IOS1_REFACTOR_SCROLL_INTENT_20261110
        direction = nil
        previousVerticalTranslation = 0
        heldHistorySuppression = false
        suppressedUntil = .distantPast
        // Never reuse a generation captured by work from the previous scope.
        _ = nextGeneration()
    }

    public init() {}
}

/// Captures the viewport before @Published replaces the message array. A burst
/// retains its first bottom decision while layout catches up; any newer scroll
/// intent invalidates it, including work queued for late media layout.
public struct ChatIncomingBottomFollowState {
    private var generation: Int?
    private var follows = false

    public func decision(generation current: Int) -> Bool? {
        generation == current ? follows : nil
    }

    public func needsLayoutCorrection(from previous: ChatScrollMetricsSnapshot,
                               to metrics: ChatScrollMetricsSnapshot, generation current: Int) -> Bool {
        decision(generation: current) == true && metrics.isValid
            && !chatScrollVisibility(metrics: metrics).isAtBottom
            && (metrics.contentHeight != previous.contentHeight
                || metrics.viewportHeight != previous.viewportHeight)
    }

    mutating public func recordAppend(metrics: ChatScrollMetricsSnapshot, generation current: Int, eligible: Bool) {
        let wasFollowing = decision(generation: current) == true
        follows = eligible && (wasFollowing || chatScrollVisibility(metrics: metrics).isAtBottom)
        generation = current
    }

    mutating public func reset() {
        generation = nil
        follows = false
    }
}

/// Geometry callbacks run inside SwiftUI's layout transaction. Coalesce them
/// into one next-run-loop update, and invalidate scheduled work on departure.
public struct ChatLayoutCallbackCoalescer {
    private(set) public var generation = 0
    private var scheduled = false

    mutating public func schedule() -> Int? {
        guard !scheduled else { return nil }
        scheduled = true
        return generation
    }

    mutating public func consume(_ expectedGeneration: Int) -> Bool {
        guard scheduled, generation == expectedGeneration else { return false }
        scheduled = false
        return true
    }

    mutating public func cancel() {
        generation &+= 1
        scheduled = false
    }
}

extension View {
    @ViewBuilder
    func chatObserveScrollGeometry(
        enabled: Bool,
        readLayout: ChatScrollReadLayout,
        onMetrics: @escaping (ChatScrollMetricsSnapshot) -> Void
    ) -> some View {
        if #available(iOS 18.0, *), enabled {
            self.onScrollGeometryChange(for: ChatScrollMetricsSnapshot.self) { geometry in
                readLayout.metrics(for: geometry)
            } action: { _, metrics in
                onMetrics(metrics)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func chatTrackScrollPhase(_ activity: ChatMediaScrollActivity) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollPhaseChange { _, phase in
                activity.recordScrollPhase(isScrolling: phase.isScrolling)
            }
        } else {
            self
        }
    }
}

/// Retain geometry outside published state so a measurement cannot invalidate
/// the same view hierarchy that just produced it.
@MainActor
final public class ChatScrollMetricsMeasurementStore: ObservableObject {
    private(set) public var metrics = ChatScrollMetricsSnapshot.zero
    public var lastHandledMetrics = ChatScrollMetricsSnapshot.zero
    public var layoutCallbacks = ChatLayoutCallbackCoalescer()
    public var incomingRow = ChatIncomingRowGeometry.empty
    public var incomingBottomFollow = ChatIncomingBottomFollowState()
    // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_STORE - 修改开始：记录滚动边界重复检查节流时间
    private var lastRepeatedBoundaryCheckAt = Date.distantPast
    // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_STORE - 修改结束：记录滚动边界重复检查节流时间

    // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_METRICS_DEDUPE - 修改开始：滚动指标无有效变化时跳过后续主线程处理
    @discardableResult
    public func replace(with metrics: ChatScrollMetricsSnapshot) -> Bool {
        guard metrics.isValid else { return false }
        guard !chatScrollMetricsApproximatelyEqual(self.metrics, metrics) else { return false }
        self.metrics = metrics
        return true
    }
    // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_METRICS_DEDUPE - 修改结束

    // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_API - 修改开始：普通滚动中节流重复边界处理
    public func consumeRepeatedBoundaryCheckIfNeeded(
        now: Date = Date(),
        minimumInterval: TimeInterval = 0.12
    ) -> Bool {
        guard now.timeIntervalSince(lastRepeatedBoundaryCheckAt) >= minimumInterval else {
            return false
        }
        lastRepeatedBoundaryCheckAt = now
        return true
    }

    public func resetRepeatedBoundaryCheckThrottle() {
        lastRepeatedBoundaryCheckAt = .distantPast
    }
    // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_API - 修改结束：普通滚动中节流重复边界处理

    public func removeAll() {
        metrics = .zero
        lastHandledMetrics = .zero
        layoutCallbacks.cancel()
        incomingRow = .empty
        incomingBottomFollow.reset()
        // JHT_MOD_BEGIN CHAT_SCROLL_UI_PERF_BEGIN_METRICS_THROTTLE_RESET - 修改开始：重置滚动边界节流状态
        resetRepeatedBoundaryCheckThrottle()
        // JHT_MOD_END CHAT_SCROLL_UI_PERF_END_METRICS_THROTTLE_RESET - 修改结束：重置滚动边界节流状态
    }

    public init() {}
}

struct ChatScrollMetricsPreferenceKey: PreferenceKey {
    static var defaultValue: ChatScrollMetricsSnapshot { .zero }

    static func reduce(value: inout ChatScrollMetricsSnapshot, nextValue: () -> ChatScrollMetricsSnapshot) {
        let next = nextValue()
        if next.isValid {
            value = next
        }
    }
}

public struct ChatIncomingRowPreferenceKey: PreferenceKey {
    static public var defaultValue: ChatIncomingRowGeometry { .empty }
    static public func reduce(value: inout ChatIncomingRowGeometry, nextValue: () -> ChatIncomingRowGeometry) {
        let next = nextValue()
        if !next.token.isEmpty { value = next }
    }
}

public struct ChatMessageTopPreferenceKey: PreferenceKey {
    static public var defaultValue: [String: CGFloat] { [:] }

    static public func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
