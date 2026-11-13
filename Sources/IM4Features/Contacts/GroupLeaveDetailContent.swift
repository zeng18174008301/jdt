// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupLeaveDetailContent: View {
    let groupName: String
    let isSubmitting: Bool
    let isScopeValid: Bool
    let actionErrorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var showFinalConfirmation = false

    public init(groupName: String, isSubmitting: Bool, isScopeValid: Bool, actionErrorMessage: String?,
                onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.groupName = groupName
        self.isSubmitting = isSubmitting
        self.isScopeValid = isScopeValid
        self.actionErrorMessage = actionErrorMessage
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var canContinue: Bool { isScopeValid && !isSubmitting }

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
                        Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(IMColor.danger))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("退出群聊")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text(groupName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("退出后的影响")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        GroupDissolveEffectRow(symbol: "bell.slash.fill", text: "你将不再接收该群的新消息")
                        GroupDissolveEffectRow(symbol: "bubble.left.and.bubble.right.fill", text: "该群会话会从你的会话列表中移除")
                        GroupDissolveEffectRow(symbol: "person.crop.circle.badge.minus", text: "其他群成员不会被移出，群聊仍会继续")
                    }
                    .im4PlainCard(radius: 22)

                    Text("退出后如需重新加入，需由群成员再次邀请或重新申请。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isScopeValid {
                        Text("群聊状态、账号或你的群角色已变化，请返回后重试")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_leave_scope_error")
                    }

                    if let actionErrorMessage, !actionErrorMessage.isEmpty {
                        Text(actionErrorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_leave_error_message")
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
                        .accessibilityIdentifier("group_leave_cancel_button")

                        Button(role: .destructive) {
                            guard canContinue else { return }
                            showFinalConfirmation = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                                Text(isSubmitting ? "退出中..." : "退出群聊")
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
                        .accessibilityIdentifier("group_leave_continue_button")
                    }
                }
                .padding(18)
            }
        }
        .alert("最终确认退出群聊？", isPresented: $showFinalConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认退出", role: .destructive) {
                guard canContinue else { return }
                onConfirm()
            }
            .accessibilityIdentifier("group_leave_final_confirm_button")
        } message: {
            Text("你即将退出“\(groupName)”。退出后该群会话会从你的列表移除。")
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
