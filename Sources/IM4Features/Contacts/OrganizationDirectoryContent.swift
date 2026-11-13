// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct OrganizationDirectoryContent<Nodes: View>: View {
    let isSyncing: Bool
    let hasTree: Bool
    let hasNodes: Bool
    let errorMessage: String?
    let nodes: () -> Nodes
    let onRetry: () -> Void

    public init(isSyncing: Bool, hasTree: Bool, hasNodes: Bool, errorMessage: String?,
                @ViewBuilder nodes: @escaping () -> Nodes, onRetry: @escaping () -> Void) {
        self.isSyncing = isSyncing
        self.hasTree = hasTree
        self.hasNodes = hasNodes
        self.errorMessage = errorMessage
        self.nodes = nodes
        self.onRetry = onRetry
    }

    public var body: some View {
        if isSyncing && !hasTree {
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
            RemoteLoadingStateView(
                title: "正在同步组织架构",
                subtitle: "正在拉取部门和成员数据。"
            )
        } else if let error = errorMessage, !hasTree {
            VStack(alignment: .leading, spacing: 12) {
                EmptyStateView(symbol: "wifi.exclamationmark", title: "组织架构同步失败", subtitle: error)
                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                    onRetry()
                }
            }
        } else if hasTree {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .black))
                        Text(error)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(IMColor.warning)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider().opacity(0.72)
                }

                if hasNodes {
                    nodes()
                } else {
                    EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "当前企业还没有部门数据。")
                        .padding(.vertical, 22)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            )
        } else {
            EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "当前企业还没有部门数据。")
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
