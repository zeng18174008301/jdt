// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthEnterpriseMiniCardContent<Logo: View>: View {
    let name: String
    let displayCode: String
    let selected: Bool
    let trailingText: String?
    let canEnterWorkspace: Bool
    let unavailableText: String
    let inviteLine: String
    let logo: () -> Logo

    public init(name: String, displayCode: String, selected: Bool, trailingText: String?, canEnterWorkspace: Bool,
                unavailableText: String, inviteLine: String, @ViewBuilder logo: @escaping () -> Logo) {
        self.name = name
        self.displayCode = displayCode
        self.selected = selected
        self.trailingText = trailingText
        self.canEnterWorkspace = canEnterWorkspace
        self.unavailableText = unavailableText
        self.inviteLine = inviteLine
        self.logo = logo
    }

    private var shouldShowUnavailableText: Bool {
        !unavailableText.isEmpty && unavailableText != trailingText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        HStack(spacing: 10) {
            logo()
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !displayCode.isEmpty {
                    Text("企业码 \(displayCode)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                if shouldShowUnavailableText {
                    Text(unavailableText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .lineLimit(1)
                }
                if !inviteLine.isEmpty {
                    Text(inviteLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(IMColor.success)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("当前企业")
            } else if let trailingText {
                Text(trailingText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(canEnterWorkspace ? IMColor.brand : IMColor.danger)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill((canEnterWorkspace ? IMColor.brand : IMColor.danger).opacity(0.10)))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected ? Color(im4Hex: 0xF7FFFB) : IMColor.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(selected ? IMColor.success.opacity(0.34) : IMColor.line, lineWidth: 1)
                )
        )
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
