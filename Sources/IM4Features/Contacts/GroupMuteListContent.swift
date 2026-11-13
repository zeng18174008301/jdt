// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupMuteListContent<Rows: View>: View {
    let canManage: Bool
    let canAddMember: Bool
    let isLoading: Bool
    let isEmpty: Bool
    let errorMessage: String?
    let onAddMember: () -> Void
    let onRetry: () -> Void
    let rows: () -> Rows

    public init(canManage: Bool, canAddMember: Bool, isLoading: Bool, isEmpty: Bool,
                errorMessage: String?, onAddMember: @escaping () -> Void,
                onRetry: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        self.canManage = canManage
        self.canAddMember = canAddMember
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.errorMessage = errorMessage
        self.onAddMember = onAddMember
        self.onRetry = onRetry
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "person.crop.circle.badge.exclamationmark.fill",
                        title: "禁言名单",
                        subtitle: canManage ? "名单成员不能在该群发送消息、附件或表情回应。" : "仅群主或管理员可查看和管理。",
                        showsCloseButton: true
                    )

                    if canManage {
                        PrimaryButton(
                            title: "添加禁言成员",
                            systemImage: "person.badge.minus",
                            disabled: !canAddMember
                        ) {
                            onAddMember()
                        }
                        .accessibilityIdentifier("group_mute_list_add_button")
                    }

                    if let error = errorMessage, !isEmpty {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(IMColor.warning)
                            Text(error)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("重试") {
                                onRetry()
                            }
                            .font(.system(size: 12, weight: .black))
                            .buttonStyle(.bordered)
                            .tint(IMColor.warning)
                            .accessibilityIdentifier("group_mute_list_retry_button")
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.warning.opacity(0.10)))
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if isLoading, isEmpty {
                                ProgressView("正在同步禁言名单")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            } else if !canManage {
                                EmptyStateView(symbol: "lock.shield.fill", title: "无权限查看", subtitle: "禁言名单仅群主或管理员可查看。")
                            } else if let error = errorMessage {
                                EmptyStateView(
                                    symbol: "wifi.exclamationmark",
                                    title: "禁言名单同步失败",
                                    subtitle: error
                                )
                                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                                    onRetry()
                                }
                                .accessibilityIdentifier("group_mute_list_retry_button")
                            } else if isEmpty {
                                EmptyStateView(symbol: "speaker.wave.2.fill", title: "暂无禁言成员", subtitle: "添加后，成员将不能在该群发送文本、附件或表情回应。")
                            } else {
                                rows()
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .refreshable {
                        onRetry()
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

public struct GroupMuteListRowContent<Avatar: View, Certification: View>: View {
    let targetUID: String
    let displayID: String
    let displayName: String
    let reasonText: String
    let operatorText: String
    let createdAtText: String
    let isMutating: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopyUserID: @MainActor (String) -> Void
    let onRemove: () -> Void

    public init(targetUID: String, displayID: String, displayName: String, reasonText: String,
                operatorText: String, createdAtText: String, isMutating: Bool,
                @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                onCopyUserID: @escaping @MainActor (String) -> Void, onRemove: @escaping () -> Void) {
        self.targetUID = targetUID
        self.displayID = displayID
        self.displayName = displayName
        self.reasonText = reasonText
        self.operatorText = operatorText
        self.createdAtText = createdAtText
        self.isMutating = isMutating
        self.avatar = avatar
        self.certification = certification
        self.onCopyUserID = onCopyUserID
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                    StatusPill(title: "已禁言", color: IMColor.warning)
                }
                CopyableUserIDText(
                    value: displayID,
                    prefix: "用户ID：",
                    font: .system(size: 11, weight: .semibold),
                    color: IMColor.muted,
                    onCopy: onCopyUserID
                )
                Text("原因：\(reasonText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text("操作人：\(operatorText) · \(createdAtText)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                if isMutating {
                    ProgressView()
                        .scaleEffect(0.72)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.warning)
                        .frame(width: 34, height: 34)
                }
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
            .background(Circle().fill(IMColor.warning.opacity(0.12)))
            .accessibilityLabel("解除禁言")
            .accessibilityIdentifier("group_mute_list_remove_\(targetUID)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
