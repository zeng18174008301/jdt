import SwiftUI

struct RTCCallRecordCard: View {
    let record: RTCCallRecordPayload
    let viewerIsCaller: Bool
    let peerName: String
    let outgoing: Bool
    let onRedial: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var iconSize = 20
    @State private var isRedialConfirmationPresented = false

    private var redialConfirmation: RTCCallRecordRedialConfirmation {
        RTCCallRecordRedialConfirmation(
            record: record,
            viewerIsCaller: viewerIsCaller,
            peerName: peerName
        )
    }

    var body: some View {
        // One immutable projection per render, never a cross-record/state cache.
        let presentation = record.presentation(viewerIsCaller: viewerIsCaller, timeZone: timeZone)
        let confirmation = redialConfirmation
        Button {
            isRedialConfirmationPresented = true
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityLayout(presentation)
                } else {
                    compactLayout(presentation)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(
            RTCCallRecordCardButtonStyle(
                background: cardBackground,
                border: cardBorder,
                reduceMotion: reduceMotion
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            presentation.accessibilityLabel(
                peerName: peerName,
                viewerIsCaller: viewerIsCaller,
                outcome: record.finalOutcome
            )
        )
        .accessibilityValue(presentation.statusText)
        .accessibilityHint("打开再次拨打确认，不会立即发起呼叫")
        .accessibilityIdentifier("rtc_call_record_\(record.callID)")
        .confirmationDialog(
            confirmation.title,
            isPresented: $isRedialConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(confirmation.actionTitle, action: onRedial)
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmation.message)
        }
    }

    private func compactLayout(_ presentation: RTCCallRecordPresentation) -> some View {
        HStack(spacing: 11) {
            callIcon(presentation)
            titleAndStatus(presentation)
                .frame(maxWidth: .infinity, alignment: .leading)
            divider
            redialAffordance
        }
    }

    private func accessibilityLayout(_ presentation: RTCCallRecordPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                callIcon(presentation)
                titleAndStatus(presentation)
            }
            Divider()
                .overlay(cardBorder.opacity(0.65))
            redialAffordance
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    private func callIcon(_ presentation: RTCCallRecordPresentation) -> some View {
        Image(systemName: presentation.systemImageName)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(toneColor(presentation))
            .frame(width: max(44, iconSize + 22), height: max(44, iconSize + 22))
            .background(Circle().fill(toneColor(presentation).opacity(colorSchemeContrast == .increased ? 0.22 : 0.13)))
            .overlay(Circle().stroke(toneColor(presentation).opacity(0.30), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func titleAndStatus(_ presentation: RTCCallRecordPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(presentation.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(2)
                Text(presentation.directionLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(toneColor(presentation))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(toneColor(presentation).opacity(0.12)))
            }
            Text(presentation.statusText)
                .font(.subheadline)
                .foregroundStyle(toneColor(presentation))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(presentation.dialedAtText)
                .font(.caption)
                .foregroundStyle(primaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(cardBorder.opacity(0.65))
            .frame(width: 1, height: 34)
            .accessibilityHidden(true)
    }

    private var redialAffordance: some View {
        HStack(spacing: 4) {
            Text("再次呼叫")
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(redialColor)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return outgoing ? Color(red: 0.08, green: 0.19, blue: 0.34) : Color(red: 0.12, green: 0.14, blue: 0.17)
        }
        return outgoing ? Color(red: 0.91, green: 0.95, blue: 1.00) : .white
    }

    private var cardBorder: Color {
        if colorSchemeContrast == .increased {
            return colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.56)
        }
        return colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.10, blue: 0.14)
    }

    private var redialColor: Color {
        colorScheme == .dark ? Color(red: 0.49, green: 0.70, blue: 1.00) : Color(red: 0.11, green: 0.36, blue: 0.88)
    }

    private func toneColor(_ presentation: RTCCallRecordPresentation) -> Color {
        switch presentation.tone {
        case .neutral:
            return colorScheme == .dark ? Color(red: 0.78, green: 0.82, blue: 0.88) : Color(red: 0.34, green: 0.38, blue: 0.46)
        case .brand:
            return redialColor
        case .muted:
            return colorScheme == .dark ? Color(red: 0.65, green: 0.69, blue: 0.75) : Color(red: 0.43, green: 0.47, blue: 0.54)
        case .danger:
            return colorScheme == .dark ? Color(red: 1.00, green: 0.43, blue: 0.45) : Color(red: 0.79, green: 0.12, blue: 0.16)
        case .warning:
            return colorScheme == .dark ? Color(red: 1.00, green: 0.67, blue: 0.30) : Color(red: 0.72, green: 0.34, blue: 0.04)
        }
    }
}

private struct RTCCallRecordCardButtonStyle: ButtonStyle {
    let background: Color
    let border: Color
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        configuration.isPressed ? border.opacity(1.0) : border,
                        lineWidth: configuration.isPressed ? 1.8 : 1
                    )
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.02 : 0.08), radius: configuration.isPressed ? 1 : 7, y: 2)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
