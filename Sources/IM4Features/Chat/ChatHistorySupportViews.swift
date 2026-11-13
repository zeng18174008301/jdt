import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_TIME_FORMATTER_POOL_MODEL - 修改开始：消息时间格式化器缓存池
enum ChatMessageDateFormatterPool {
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

public enum ChatSearchDismissalIntent: Equatable {
    case close
    case selectResult
}

public enum ChatSearchDismissalEffect: Equatable {
    case none
    case releaseFocus
    case dismissPanel
}

public struct ChatSearchDismissalCoordinator: Equatable {
    private(set) var pendingIntent: ChatSearchDismissalIntent?

    mutating public func request(
        _ intent: ChatSearchDismissalIntent,
        isFocused: Bool
    ) -> ChatSearchDismissalEffect {
        guard pendingIntent == nil else { return .none }
        pendingIntent = intent
        return isFocused ? .releaseFocus : .dismissPanel
    }

    mutating public func focusDidChange(isFocused: Bool) -> ChatSearchDismissalEffect {
        guard pendingIntent != nil, !isFocused else { return .none }
        return .dismissPanel
    }

    mutating public func consumePendingIntent() -> ChatSearchDismissalIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
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

public struct ChatHistoryStatusPill: View {
    let text: String
    let isLoading: Bool

    public var body: some View {
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

    public init(text: String,
        isLoading: Bool) {
        self.text = text
        self.isLoading = isLoading
    }
}

public struct DirectChatEmptyHistoryView: View {
    let title: String
    let subtitle: String
    let retryTitle: String?
    var retry: () -> Void

    public var body: some View {
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

    public init(title: String,
        subtitle: String,
        retryTitle: String? = nil,
        retry: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.retryTitle = retryTitle
        self.retry = retry
    }
}

struct NewMessagesDivider: View {
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

struct MessageTimeSeparator: View {
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

struct ReturnToBottomBar: View {
#if DEBUG
    static var captureBoundAction: ((Int, @escaping () -> Void) -> Void)?
#endif
    let count: Int
    let action: () -> Void
    @Environment(\.sizeCategory) private var sizeCategory
    @ScaledMetric(relativeTo: .callout) private var textPointSize: CGFloat = 14
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
#if DEBUG
        let _ = Self.captureBoundAction?(count, action)
#endif
        Button(action: action) {
            // WDT_CHAT_FIX5_RETURN_BOTTOM_20261023_BEGIN
            Group {
                if sizeCategory.isAccessibilityCategory {
                    VStack(spacing: 4) {
                        Text("回到底部")
                            .lineLimit(2)
                        Label(messageSummary, systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(messageSummary)
                            .lineLimit(2)
                        Text("回到底部")
                            .lineLimit(2)
                    }
                }
            }
            .font(.system(size: textPointSize, weight: .bold))
            .foregroundStyle(IMColor.brand)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(.white.opacity(0.96))
                    .overlay(
                        Capsule()
                            .stroke(IMColor.brand.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: IMColor.ink.opacity(0.10), radius: 8, y: 3)
            )
            .contentShape(Capsule())
            // WDT_CHAT_FIX5_RETURN_BOTTOM_20261023_END
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat_return_to_bottom_button")
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("平滑滚动到聊天记录底部")
    }
}

