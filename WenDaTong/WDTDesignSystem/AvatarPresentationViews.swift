// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_BEGIN
import SwiftUI
import UIKit

public struct CertificationDisplay: Equatable, Sendable {
    public let visibleLabel: String
    public let accessibilityLabel: String
    public init(visibleLabel: String, accessibilityLabel: String) {
        self.visibleLabel = visibleLabel
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct AvatarDecorationContent<Content: View>: View {
    let size: CGFloat
    let badgeColor: Color?
    let isCancelledAvatar: Bool
    let resolvedName: String
    let visibleCertification: CertificationDisplay?
    let avatarBody: Content

    public init(size: CGFloat, badgeColor: Color?, isCancelledAvatar: Bool, resolvedName: String, visibleCertification: CertificationDisplay?, @ViewBuilder avatarBody: () -> Content) {
        self.size = size
        self.badgeColor = badgeColor
        self.isCancelledAvatar = isCancelledAvatar
        self.resolvedName = resolvedName
        self.visibleCertification = visibleCertification
        self.avatarBody = avatarBody()
    }

    public var body: some View {
 // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        ZStack {
            avatarBody
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        visibleCertification == nil
                            ? .white.opacity(0.65)
                            : Color(hex: 0x2F6BFF).opacity(0.92),
                        lineWidth: visibleCertification == nil ? 1 : max(1.5, size * 0.045)
                    )
                )
            if let badgeColor, !isCancelledAvatar {
                Circle()
                    .fill(badgeColor)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(
                        width: size,
                        height: size,
                        alignment: .bottomLeading
                    )
            }
            if visibleCertification != nil {
                Image(systemName: "checkmark.shield.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(hex: 0x2F6BFF))
                    .font(.system(size: max(11, size * 0.28), weight: .bold))
                    .padding(max(1, size * 0.025))
                    .background(Circle().fill(Color.white))
                    .frame(
                        width: size,
                        height: size,
                        alignment: .bottomTrailing
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [resolvedName, visibleCertification?.accessibilityLabel]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "，")
        )
        }
}

public struct CancelledAvatarContent: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {

        Circle()
            .fill(Color(hex: 0xD8DEE8))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color(hex: 0x8F98A8))
            )
        }
}

public struct InitialsAvatarContent: View {
    let seed: UInt
    let size: CGFloat
    let initials: String

    public init(seed: UInt, size: CGFloat, initials: String) {
        self.seed = seed
        self.size = size
        self.initials = initials
    }

    public var body: some View {

        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: seed).opacity(0.92), Color(hex: seed).opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            )
        }
}

public struct AvatarBitmapContent: View {
    let image: UIImage

    public init(image: UIImage) {
        self.image = image
    }

    public var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
    }
}

public struct CertificationPillContent: View {
    let resolvedPresentation: CertificationDisplay?
    let compact: Bool
    let maximumLineCount: Int?
    let colorScheme: ColorScheme

    public init(presentation: CertificationDisplay?, compact: Bool, maximumLineCount: Int?, colorScheme: ColorScheme) {
        self.resolvedPresentation = presentation
        self.compact = compact
        self.maximumLineCount = maximumLineCount
        self.colorScheme = colorScheme
    }

    public var body: some View {

        // Keep a mounted view while the presentation is nil so the fetch task runs.
        VStack(alignment: .leading, spacing: 0) {
            if let resolvedPresentation {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .fixedSize()
                    Text(resolvedPresentation.visibleLabel)
                }
                .font(
                    compact
                        ? Font.caption2.weight(.semibold)
                        : Font.caption.weight(.semibold)
                )
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color(hex: 0xA9C2FF)
                        : Color(hex: 0x245DE8)
                )
                .lineLimit(compact ? nil : maximumLineCount)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, compact ? 5 : 6)
                .padding(.vertical, compact ? 2 : 3)
                .background(
                    RoundedRectangle(
                        cornerRadius: compact ? 7 : 9,
                        style: .continuous
                    )
                        .fill(
                            Color(hex: 0x2F6BFF)
                                .opacity(colorScheme == .dark ? 0.28 : 0.10)
                        )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: compact ? 7 : 9,
                        style: .continuous
                    )
                        .stroke(
                            Color(hex: 0x2F6BFF)
                                .opacity(colorScheme == .dark ? 0.58 : 0.22),
                            lineWidth: 0.75
                        )
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(resolvedPresentation.accessibilityLabel)
            }
        }
        }
}

public struct GroupDefaultAvatarContent: View {
    let image: Image
    let size: CGFloat
    let contentScale: CGFloat

    public init(image: Image, size: CGFloat, contentScale: CGFloat = 1) {
        self.image = image
        self.size = size
        self.contentScale = contentScale
    }

    public var body: some View {

        let scale = max(contentScale, 1)
        image
            .resizable()
            .scaledToFill()
            .frame(width: size * scale, height: size * scale)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            .accessibilityLabel("群聊")
        }
}

public struct SystemNoticeAvatarContent: View {
    let image: Image
    let size: CGFloat

    public init(image: Image, size: CGFloat) {
        self.image = image
        self.size = size
    }

    public var body: some View {

        image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(1.28)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            .accessibilityLabel("系统通知")
        }
}

public struct RemoteImageContent<Placeholder: View>: View {
    let image: UIImage?
    let contentMode: ContentMode
    let placeholder: () -> Placeholder

    public init(image: UIImage?, contentMode: ContentMode, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.image = image
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
    }
}

public struct EnterpriseFallbackIcon: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {

        Image(systemName: "building.2.crop.circle.fill")
            .font(.system(size: size * 0.40, weight: .bold))
            .foregroundStyle(.white)
        }
}

public struct EnterpriseLogoContent<Content: View>: View {
    let accentHex: UInt
    let size: CGFloat
    let cornerRadius: CGFloat
    let accessibilityLabel: String
    let content: Content

    public init(accentHex: UInt, size: CGFloat, cornerRadius: CGFloat, accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        self.accentHex = accentHex
        self.size = size
        self.cornerRadius = cornerRadius
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    public var body: some View {

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: accentHex), IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay { content }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 1)
            )
            .accessibilityLabel(accessibilityLabel)
        }
}

public struct EnterpriseClippedContent<Content: View>: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let content: Content

    public init(size: CGFloat, cornerRadius: CGFloat, @ViewBuilder content: () -> Content) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_COMPONENTS_20261110_END
