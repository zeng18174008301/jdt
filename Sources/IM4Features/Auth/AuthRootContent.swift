// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthRootContent<Card: View>: View {
    let animatesBackground: Bool
    let onLogoTap: () -> Void
    let card: () -> Card
    public init(animatesBackground: Bool, onLogoTap: @escaping () -> Void, @ViewBuilder card: @escaping () -> Card) {
        self.animatesBackground = animatesBackground; self.onLogoTap = onLogoTap; self.card = card
    }
    public var body: some View {
        ZStack {
            AuthBackground(isAnimating: animatesBackground)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    AuthBrandLockup(logoSize: 52, logoCornerRadius: 16, titleSize: 21, subtitleSize: 11, onLogoTap: onLogoTap)
                    Spacer()
                }
                Color.clear.frame(height: 22)
                card()
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

public struct AuthBrandLockup: View {
    let logoSize: CGFloat
    let logoCornerRadius: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    var onLogoTap: (() -> Void)? = nil
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    public init(logoSize: CGFloat, logoCornerRadius: CGFloat, titleSize: CGFloat, subtitleSize: CGFloat,
                onLogoTap: (() -> Void)? = nil) {
        self.logoSize = logoSize; self.logoCornerRadius = logoCornerRadius; self.titleSize = titleSize
        self.subtitleSize = subtitleSize; self.onLogoTap = onLogoTap
    }
    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("LoginLogo")
                .resizable()
                .scaledToFill()
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                )
                .shadow(color: IMColor.brand.opacity(0.28), radius: 15, y: 8)
                // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                .contentShape(RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous))
                .onTapGesture {
                    onLogoTap?()
                }
                // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

            VStack(alignment: .leading, spacing: 7) {
                Text("问达通")
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [IMColor.ink, Color(im4Hex: 0x2B3558)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .white.opacity(0.55), radius: 0, x: 0, y: 1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(IMColor.brand.opacity(0.72))
                        .frame(width: 4, height: 4)
                    Text("高效简洁沟通")
                        .font(.system(size: subtitleSize, weight: .bold))
                        .foregroundStyle(IMColor.muted.opacity(0.92))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.46))
                        .overlay(Capsule().stroke(.white.opacity(0.52), lineWidth: 0.8))
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
