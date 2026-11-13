// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct SupportContactContent: View {
    let isEmailConfigured: Bool
    let normalizedEmail: String?
    let statusText: String
    let isRefreshingPolicy: Bool
    let onOpenMail: (String) -> Void

    public init(isEmailConfigured: Bool, normalizedEmail: String?, statusText: String,
                isRefreshingPolicy: Bool, onOpenMail: @escaping (String) -> Void) {
        self.isEmailConfigured = isEmailConfigured
        self.normalizedEmail = normalizedEmail
        self.statusText = statusText
        self.isRefreshingPolicy = isRefreshingPolicy
        self.onOpenMail = onOpenMail
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "envelope.fill", title: "联系我们", subtitle: "通过当前邮箱联系支持团队。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: isEmailConfigured ? "envelope.badge.fill" : "envelope.slash.fill")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(isEmailConfigured ? IMColor.brand : IMColor.muted)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill((isEmailConfigured ? IMColor.brand : IMColor.muted).opacity(0.12)))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(isEmailConfigured ? "联系邮箱" : "暂未配置联系邮箱")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text(statusText)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let email = normalizedEmail, isEmailConfigured {
                            Button {
                                onOpenMail(email)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "at")
                                        .font(.system(size: 15, weight: .black))
                                    Text(email)
                                        .font(.system(size: 16, weight: .black))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.78)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 13, weight: .black))
                                }
                                .foregroundStyle(IMColor.brand)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(IMColor.brand.opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)

                            PrimaryButton(title: "发送邮件", systemImage: "paperplane.fill", disabled: false) {
                                onOpenMail(email)
                            }
                        } else {
                            PrimaryButton(title: isRefreshingPolicy ? "正在刷新..." : "发送邮件", systemImage: "paperplane.fill", disabled: true) {}
                        }
                    }
                    .im4GlassCard(radius: 28)
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
