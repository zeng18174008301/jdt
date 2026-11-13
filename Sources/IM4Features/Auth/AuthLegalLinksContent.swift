// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum AuthLegalLinksStyle { case auth, settings }
public struct AuthLegalLinksContent<Link: Identifiable & Equatable & RawRepresentable>: View where Link.RawValue == String {
    @Binding var isAccepted: Bool
    let prefix: String
    let style: AuthLegalLinksStyle
    let showsConsentToggle: Bool
    let shakeTrigger: Int
    let consentAccessibilityIdentifier: String?
    let links: [Link]
    let terms: Link
    let privacy: Link
    let activeType: Link?
    let isPresented: Bool
    let title: (Link) -> String
    let symbol: (Link) -> String
    let open: (Link) -> Void
    public init(prefix: String, style: AuthLegalLinksStyle, isAccepted: Binding<Bool>, showsConsentToggle: Bool,
                shakeTrigger: Int, consentAccessibilityIdentifier: String?, links: [Link], terms: Link, privacy: Link,
                activeType: Link?, isPresented: Bool, title: @escaping (Link) -> String, symbol: @escaping (Link) -> String,
                open: @escaping (Link) -> Void) {
        self.prefix = prefix; self.style = style; _isAccepted = isAccepted; self.showsConsentToggle = showsConsentToggle
        self.shakeTrigger = shakeTrigger; self.consentAccessibilityIdentifier = consentAccessibilityIdentifier
        self.links = links; self.terms = terms; self.privacy = privacy; self.activeType = activeType; self.isPresented = isPresented
        self.title = title; self.symbol = symbol; self.open = open
    }
    @ViewBuilder
    public var body: some View {
        switch style {
        case .auth:
            authContent
        case .settings:
            settingsContent
        }
    }

    private var authContent: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsConsentToggle {
                consentCheckbox
            }
            authLegalText
        }
        .font(.system(size: 11.5, weight: .semibold))
        .authAuxiliaryControlLeadingAligned()
        .multilineTextAlignment(.leading)
        .modifier(AgreementShakeEffect(trigger: shakeTrigger))
    }

    private var consentCheckbox: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isAccepted.toggle()
            }
        } label: {
            Image(systemName: isAccepted ? "checkmark.square.fill" : "square")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(consentTint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAccepted ? "已勾选协议" : "勾选协议")
        .modifier(AuthConsentIdentifier(identifier: consentAccessibilityIdentifier))
    }

    private var authLegalText: some View {
        ViewThatFitsCompat(in: .horizontal) {
            HStack(spacing: 4) {
                authPrefixText
                legalAuthButton(terms)
                Text("和")
                    .foregroundStyle(IMColor.muted)
                legalAuthButton(privacy)
            }

            VStack(alignment: .leading, spacing: 6) {
                authPrefixText
                HStack(spacing: 10) {
                    legalAuthButton(terms)
                    legalAuthButton(privacy)
                }
            }
        }
    }

    private var consentTint: Color {
        if isAccepted {
            return IMColor.brand
        }
        return shakeTrigger > 0 ? IMColor.danger : IMColor.muted
    }

    private var authPrefixText: some View {
        Text(prefix)
            .foregroundStyle(IMColor.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var settingsContent: some View {
        VStack(spacing: 10) {
            ForEach(links) { type in
                legalSettingsButton(type)
            }
        }
    }

    private func legalAuthButton(_ type: Link) -> some View {
        Button {
            open(type)
        } label: {
            HStack(spacing: 4) {
                if activeType == type {
                    ProgressView()
                        .scaleEffect(0.72)
                        .frame(width: 12, height: 12)
                }
                Text(title(type))
                    .underline()
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .foregroundStyle(IMColor.brand)
        }
        .buttonStyle(.plain)
        .disabled(isPresented)
        .accessibilityIdentifier("auth_legal_\(type.rawValue)_button")
    }

    private func legalSettingsButton(_ type: Link) -> some View {
        Button {
            open(type)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(type))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(type))
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("查看平台后台下发的协议内容")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if activeType == type {
                    ProgressView()
                        .scaleEffect(0.78)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(IMColor.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.68))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(IMColor.brand.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isPresented)
    }

}

private struct AgreementShakeEffect: GeometryEffect {
    private let travelDistance: CGFloat = 7
    private let shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    init(trigger: Int) {
        self.animatableData = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * shakesPerUnit * 2),
                y: 0
            )
        )
    }
}

private struct AuthConsentIdentifier: ViewModifier {
    let identifier: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
