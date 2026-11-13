// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct AboutAppContent<LegalLinks: View>: View {
    let displayName: String
    let versionText: String
    let onLogoTap: () -> Void
    let legalLinks: () -> LegalLinks

    public init(displayName: String, versionText: String, onLogoTap: @escaping () -> Void,
                @ViewBuilder legalLinks: @escaping () -> LegalLinks) {
        self.displayName = displayName
        self.versionText = versionText
        self.onLogoTap = onLogoTap
        self.legalLinks = legalLinks
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "info.circle.fill", title: "关于 问达通", subtitle: "版本信息与协议内容。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            AboutAppMark()
                                // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onLogoTap()
                                }
                                // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayName)
                                    .font(.system(size: 21, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("iOS")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 10) {
                            AboutInfoRow(title: "版本", value: versionText)
                        }
                    }
                    .im4GlassCard(radius: 28)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("协议内容")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        legalLinks()
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
