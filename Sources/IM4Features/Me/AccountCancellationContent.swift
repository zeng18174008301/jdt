// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct AccountCancellationContent: View {
    @Binding var reason: String
    @State private var showConfirm = false
    let isSubmitting: Bool
    let deletionNotice: String
    let onDismiss: () -> Void
    let onSubmit: () -> Void

    public init(reason: Binding<String>, isSubmitting: Bool, deletionNotice: String,
                onDismiss: @escaping () -> Void, onSubmit: @escaping () -> Void) {
        _reason = reason
        self.isSubmitting = isSubmitting
        self.deletionNotice = deletionNotice
        self.onDismiss = onDismiss
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(IMColor.danger)
                                .frame(width: 58, height: 58)
                                .background(Circle().fill(IMColor.danger.opacity(0.10)))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("注销账号")
                                    .font(.system(size: 28, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("提交成功后将立即退出当前账号，并清除本机登录状态。")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("重要提醒", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.danger)
                            Text(deletionNotice)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(IMColor.danger.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(IMColor.danger.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .im4GlassCard(radius: 28)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("注销原因（选填）")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        TextEditor(text: $reason)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(IMColor.ink)
                            .frame(minHeight: 104)
                            .im4ScrollContentBackgroundHiddenCompat()
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.82)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(IMColor.line.opacity(0.72), lineWidth: 1)
                            )
                    }
                    .im4PlainCard(radius: 24)

                    HStack(spacing: 12) {
                        Button {
                            onDismiss()
                        } label: {
                            Label("取消注销", systemImage: "xmark")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(IMColor.warning)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.warning.opacity(0.12)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(IMColor.warning.opacity(0.26), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard !isSubmitting else { return }
                            showConfirm = true
                        } label: {
                            Label(isSubmitting ? "提交中" : "确认注销", systemImage: "trash.fill")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认注销账号？", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认注销", role: .destructive) {
                onSubmit()
            }
        } message: {
            Text("请再次确认。注销成功后将立即退出当前账号。")
        }
    }

}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
