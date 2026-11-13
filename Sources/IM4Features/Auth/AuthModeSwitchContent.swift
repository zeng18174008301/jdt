// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthModeSwitchContent<Mode: Identifiable & Equatable & RawRepresentable>: View where Mode.RawValue == String {
    @Binding var mode: Mode
    let modes: [Mode]
    let phoneMode: Mode
    let suffix: String
    let onChange: () -> Void
    @Namespace private var namespace

    public init(mode: Binding<Mode>, modes: [Mode], phoneMode: Mode, suffix: String, onChange: @escaping () -> Void) {
        _mode = mode; self.modes = modes; self.phoneMode = phoneMode; self.suffix = suffix; self.onChange = onChange
    }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(modes) { item in
                Button {
                    guard mode != item else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        mode = item
                        onChange()
                    }
                } label: {
                    ZStack {
                        if mode == item {
                            Capsule()
                                .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .leading, endPoint: .trailing))
                                .matchedGeometryEffect(id: "authModePill", in: namespace)
                                .shadow(color: IMColor.brand.opacity(0.18), radius: 10, y: 5)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: item == phoneMode ? "iphone" : "person.text.rectangle")
                            Text("\(item.rawValue)\(suffix)")
                        }
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(mode == item ? .white : IMColor.brand)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Color(im4Hex: 0xEEF2FF).opacity(0.92))
                .overlay(Capsule().stroke(.white.opacity(0.84), lineWidth: 1))
        )
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
