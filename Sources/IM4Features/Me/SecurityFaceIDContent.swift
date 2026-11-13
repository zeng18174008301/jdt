// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct SecurityFaceIDContent: View {
    let enabledBinding: Binding<Bool>
    @Binding var unlockChats: Bool
    @Binding var previewFiles: Bool
    @Binding var sliderVerified: Bool
    let isUpdating: Bool
    let hasChanges: Bool
    let onSave: () -> Void

    public init(enabled: Binding<Bool>, unlockChats: Binding<Bool>, previewFiles: Binding<Bool>,
                sliderVerified: Binding<Bool>, isUpdating: Bool, hasChanges: Bool, onSave: @escaping () -> Void) {
        self.enabledBinding = enabled
        _unlockChats = unlockChats
        _previewFiles = previewFiles
        _sliderVerified = sliderVerified
        self.isUpdating = isUpdating
        self.hasChanges = hasChanges
        self.onSave = onSave
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "faceid", title: "Face ID", subtitle: "用于快速解锁会话、文件预览和敏感操作确认。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "faceid")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(enabledBinding.wrappedValue ? "Face ID 已开启" : "Face ID 已关闭")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("用于保护会话、文件预览和敏感操作确认，可随时关闭。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(spacing: 0) {
                            SecurityToggleRow(
                                title: isUpdating ? "正在验证 Face ID" : "启用 Face ID",
                                subtitle: "验证成功后才会开启并保存保护",
                                isOn: enabledBinding
                            )
                            .disabled(isUpdating)
                            SecurityDivider()
                            SecurityToggleRow(title: "解锁会话", subtitle: "打开私密会话前验证", isOn: $unlockChats)
                                .opacity(enabledBinding.wrappedValue ? 1 : 0.42)
                                .disabled(!enabledBinding.wrappedValue || isUpdating)
                            SecurityDivider()
                            SecurityToggleRow(title: "文件预览确认", subtitle: "预览企业文件前验证", isOn: $previewFiles)
                                .opacity(enabledBinding.wrappedValue ? 1 : 0.42)
                                .disabled(!enabledBinding.wrappedValue || isUpdating)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.82)))

                        SliderVerification(verified: $sliderVerified)

                        Text("先完成滑块验证；开启时会立即显示系统 Face ID 验证，取消或失败不会改变当前设置。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        PrimaryButton(
                            title: isUpdating ? "正在更新" : "保存保护范围",
                            systemImage: "checkmark",
                            disabled: !hasChanges || isUpdating
                        ) {
                            onSave()
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
