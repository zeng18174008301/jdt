// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupDissolveDetailContent: View {
    let groupName: String
    let isSubmitting: Bool
    let isPreviewLoading: Bool
    let isScopeValid: Bool
    let canContinue: Bool
    let memberCount: Int?
    let previewErrorMessage: String?
    let actionErrorMessage: String?
    let onRetryPreview: (() -> Void)?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var showFinalConfirmation = false

    public init(groupName: String, isSubmitting: Bool, isPreviewLoading: Bool, isScopeValid: Bool,
                canContinue: Bool, memberCount: Int?, previewErrorMessage: String?, actionErrorMessage: String?,
                onRetryPreview: (() -> Void)?, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.groupName = groupName
        self.isSubmitting = isSubmitting
        self.isPreviewLoading = isPreviewLoading
        self.isScopeValid = isScopeValid
        self.canContinue = canContinue
        self.memberCount = memberCount
        self.previewErrorMessage = previewErrorMessage
        self.actionErrorMessage = actionErrorMessage
        self.onRetryPreview = onRetryPreview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(IMColor.muted.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(IMColor.danger))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("解散该群")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text(groupName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                    }

                    previewStatus

                    if !isScopeValid && !isPreviewLoading {
                        Text("群聊状态、账号或你的群角色已变化，请返回后重试")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_dissolve_scope_error")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("影响范围")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        if let memberCount {
                            GroupDissolveEffectRow(symbol: "person.3.fill", text: "将影响 \(memberCount) 名成员")
                        }
                        GroupDissolveEffectRow(symbol: "bubble.left.and.bubble.right.fill", text: "所有成员的群会话都会从列表移除")
                        GroupDissolveEffectRow(symbol: "folder.fill", text: "群资料、成员、文件和群历史入口将不再可见")
                        GroupDissolveEffectRow(symbol: "bell.badge.fill", text: "原成员会收到个人系统通知")
                    }
                    .im4PlainCard(radius: 22)

                    Text("如果你只是想退出群聊，请先转让群主后再退出。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("解散后不可恢复，请确认是否继续。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    if let actionErrorMessage, !actionErrorMessage.isEmpty {
                        Text(actionErrorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_dissolve_action_error")
                    }

                    HStack(spacing: 10) {
                        Button {
                            guard !isSubmitting else { return }
                            onCancel()
                        } label: {
                            Text("取消")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(.white.opacity(0.88))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .opacity(isSubmitting ? 0.62 : 1)
                        .accessibilityIdentifier("group_dissolve_cancel_button")

                        Button(role: .destructive) {
                            guard canContinue else { return }
                            showFinalConfirmation = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(
                                    isPreviewLoading
                                        ? "读取中..."
                                        : (isSubmitting ? "解散中..." : "继续解散")
                                )
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(canContinue ? IMColor.danger : Color(im4Hex: 0xB8C0D8))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canContinue)
                        .accessibilityIdentifier("group_dissolve_continue_button")
                    }
                }
                .padding(18)
            }
        }
        .alert("最终确认解散群聊？", isPresented: $showFinalConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认解散", role: .destructive) {
                guard canContinue else { return }
                onConfirm()
            }
            .accessibilityIdentifier("group_dissolve_final_confirm_button")
        } message: {
            Text("你即将解散“\(groupName)”。所有成员将失去该群会话，且操作不可恢复。")
        }
    }

    @ViewBuilder
    private var previewStatus: some View {
        if isPreviewLoading {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(IMColor.brand)
                Text("正在读取解散影响范围…")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.76)))
            .accessibilityIdentifier("group_dissolve_preview_loading")
        } else if let previewErrorMessage, !previewErrorMessage.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(previewErrorMessage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetryPreview {
                    Button {
                        guard !isSubmitting, !isPreviewLoading else { return }
                        onRetryPreview()
                    } label: {
                        Label("重新读取影响范围", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(IMColor.brand)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(IMColor.brand.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_dissolve_preview_retry_button")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger.opacity(0.06)))
            .accessibilityIdentifier("group_dissolve_preview_error")
        }

    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
