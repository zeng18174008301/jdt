// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct FileRefreshHintView: View {
    let isRefreshing: Bool
    let errorMessage: String?
    let hasCachedFiles: Bool
    let lastRefreshedAt: Date?
    let retry: () -> Void

    public init(isRefreshing: Bool, errorMessage: String?, hasCachedFiles: Bool, lastRefreshedAt: Date?, retry: @escaping () -> Void) {
        self.isRefreshing = isRefreshing; self.errorMessage = errorMessage; self.hasCachedFiles = hasCachedFiles
        self.lastRefreshedAt = lastRefreshedAt; self.retry = retry
    }
    public var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(IMColor.brand)
            } else {
                Image(systemName: errorMessage == nil ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(errorMessage == nil ? IMColor.brand : IMColor.danger)
            }
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(errorMessage == nil ? IMColor.muted : IMColor.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
            if errorMessage?.isEmpty == false, !isRefreshing {
                Button("重试", action: retry)
                    .font(.system(size: 12, weight: .bold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("favorite_assets_retry_button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke((errorMessage == nil ? IMColor.line : IMColor.danger.opacity(0.18)), lineWidth: 1)
                )
        )
    }

    private var statusText: String {
        if isRefreshing {
            return "正在刷新资料列表..."
        }
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let lastRefreshedAt {
            return "资料列表已刷新 \(Self.timeFormatter.string(from: lastRefreshedAt))"
        }
        return hasCachedFiles ? "下拉刷新资料列表，当前显示上次缓存内容" : "下拉刷新资料列表"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

public struct FileLoadMoreFooter: View {
    let isLoading: Bool
    let hasLocalMore: Bool
    let canLoadRemoteMore: Bool
    let failed: Bool
    let retry: (() -> Void)?

    public init(isLoading: Bool, hasLocalMore: Bool, canLoadRemoteMore: Bool, failed: Bool, retry: (() -> Void)?) {
        self.isLoading = isLoading; self.hasLocalMore = hasLocalMore; self.canLoadRemoteMore = canLoadRemoteMore
        self.failed = failed; self.retry = retry
    }
    public var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(IMColor.brand)
            } else {
                Image(systemName: hasLocalMore || canLoadRemoteMore ? "arrow.down" : "checkmark.circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(failed ? IMColor.danger : IMColor.muted)
            if let retry, failed, !isLoading {
                Button("重试加载", action: retry)
                    .font(.system(size: 12, weight: .bold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("favorite_assets_page_retry_button")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var title: String {
        if isLoading { return "正在加载更多资料..." }
        if failed { return "加载更多资料失败，已保留当前资料" }
        if hasLocalMore { return "继续下滑显示更多资料" }
        if canLoadRemoteMore { return "继续下滑加载更多资料" }
        return "没有更多资料"
    }
}

public enum FilePreviewOpenState: Equatable {
    case idle
    case cached
    case loading
    case failed

    public var isLoading: Bool {
        self == .loading
    }

    public var previewActionTitle: String? {
        switch self {
        case .idle:
            return nil
        case .cached:
            return "已缓存"
        case .loading:
            return "准备中"
        case .failed:
            return "重试"
        }
    }

    public func pillTitle(defaultTitle: String) -> String {
        switch self {
        case .idle:
            return defaultTitle
        case .cached:
            return "已缓存"
        case .loading:
            return "下载中"
        case .failed:
            return "重试"
        }
    }

    public func pillColor(defaultColor: Color) -> Color {
        switch self {
        case .idle:
            return defaultColor
        case .cached:
            return IMColor.success
        case .loading:
            return IMColor.brand
        case .failed:
            return IMColor.danger
        }
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
