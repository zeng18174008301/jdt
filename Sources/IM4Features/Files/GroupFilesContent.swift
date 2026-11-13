// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct GroupFilesContent<Row: View>: View {
    let isEmpty: Bool
    let isSyncing: Bool
    let syncError: String?
    let rows: () -> Row
    let onRetry: () -> Void

    public init(isEmpty: Bool, isSyncing: Bool, syncError: String?,
                @ViewBuilder rows: @escaping () -> Row, onRetry: @escaping () -> Void) {
        self.isEmpty = isEmpty
        self.isSyncing = isSyncing
        self.syncError = syncError
        self.rows = rows
        self.onRetry = onRetry
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "folder.fill", title: "群文件", subtitle: "预览、下载和转发群内文件。", showsCloseButton: true)
                    if isSyncing && isEmpty {
                        RemoteLoadingStateView(
                            title: "正在同步群文件",
                            subtitle: "正在从企业文件服务拉取当前群可见文件。"
                        )
                    } else if let syncError, isEmpty {
                        EmptyStateView(symbol: "wifi.exclamationmark", title: "群文件同步失败", subtitle: syncError)
                        PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                            onRetry()
                        }
                    } else if isEmpty {
                        EmptyStateView(symbol: "folder.badge.questionmark", title: "暂无群文件", subtitle: "群成员上传的文件会在这里展示。")
                    } else {
                        if isSyncing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.72)
                                Text("正在刷新群文件")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                Spacer()
                            }
                            .im4PlainCard(radius: 18)
                        }
                        rows()
                    }
                }
                .padding(18)
            }
        }
    }
}

public struct GroupFileRowContent<Avatar: View, Progress: View>: View {
    let file: FileDisplayInput
    let canForward: Bool
    let avatar: () -> Avatar
    let progress: () -> Progress
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onForward: () -> Void

    public init(file: FileDisplayInput, canForward: Bool, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder progress: @escaping () -> Progress, onOpen: @escaping () -> Void,
                onDownload: @escaping () -> Void, onForward: @escaping () -> Void) {
        self.file = file
        self.canForward = canForward
        self.avatar = avatar
        self.progress = progress
        self.onOpen = onOpen
        self.onDownload = onDownload
        self.onForward = onForward
    }

    public var body: some View {
            VStack(alignment: .leading, spacing: 14) {
            Button {
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    avatar()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        Text("\(file.size) · \(file.owner) · \(file.time)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    StatusPill(title: file.type, color: IMColor.brand)
                }
            }
            .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        GroupSheetActionButton(title: "预览", symbol: "eye.fill") {
                            onOpen()
                        }
                            GroupSheetActionButton(title: "下载", symbol: "arrow.down.circle.fill") {
                            onDownload()
                    }
                    GroupSheetActionButton(title: "转发", symbol: "arrowshape.turn.up.right.fill") {
                        onForward()
                    }
                    .disabled(!canForward) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                    .opacity(canForward ? 1 : 0.45) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                }
            progress()
        }
        .im4PlainCard(radius: 22)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
