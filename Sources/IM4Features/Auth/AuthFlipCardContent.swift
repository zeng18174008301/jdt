// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI

public struct AuthFlipCardContent<Login: View, Register: View>: View {
    let phoneAuthEnabled: Bool
    let showRegister: Bool
    let isFlipping: Bool
    let loginContentHeight: CGFloat
    let login: () -> Login
    let register: () -> Register
    public init(phoneAuthEnabled: Bool, showRegister: Bool, isFlipping: Bool, loginContentHeight: CGFloat,
                @ViewBuilder login: @escaping () -> Login, @ViewBuilder register: @escaping () -> Register) {
        self.phoneAuthEnabled = phoneAuthEnabled; self.showRegister = showRegister; self.isFlipping = isFlipping
        self.loginContentHeight = loginContentHeight; self.login = login; self.register = register
    }
    public var body: some View {
        GeometryReader { geo in
            let maxCard = max(380, geo.size.height - 6)
            content(maxCard: maxCard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    @ViewBuilder private func content(maxCard: CGFloat) -> some View {
        let h = AuthFlipLayoutPolicy.loginCardHeight(
            phoneAuthEnabled: phoneAuthEnabled, // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            availableHeight: maxCard,
            measuredContentHeight: loginContentHeight
        )
        ZStack(alignment: .top) {
            if isFlipping {
                cardFace(login(), height: h, shadowRadius: 14, shadowY: 9) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    .modifier(FlipOpacity(pct: showRegister ? 0 : 1))
                    .rotation3DEffect(.degrees(showRegister ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                cardFace(register(), height: h, shadowRadius: 14, shadowY: 9, cornerRadius: 32, fillOpacity: 0.92) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    .modifier(FlipOpacity(pct: showRegister ? 1 : 0))
                    .rotation3DEffect(.degrees(showRegister ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            } else if showRegister {
                cardFace(register(), height: h, cornerRadius: 32, fillOpacity: 0.92) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            } else {
                cardFace(login(), height: h) // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.6, dampingFraction: 0.84), value: showRegister)
    }

    private func cardFace<Content: View>(
        _ content: Content,
        height: CGFloat,
        shadowRadius: CGFloat = 22,
        shadowY: CGFloat = 14,
        cornerRadius: CGFloat = 28,
        fillOpacity: Double = 0.86
    ) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
            .authGlass(shadowRadius: shadowRadius, shadowY: shadowY, cornerRadius: cornerRadius, fillOpacity: fillOpacity)
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
