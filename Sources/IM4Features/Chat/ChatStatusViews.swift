import IM4Domain
import IM4DesignSystem
import SwiftUI

// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_BEGIN
public struct ChatGroupAnnouncementView: View {
    let title: String
    let preview: String
    let isBusy: Bool
    let open: () -> Void
    let close: () -> Void

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                open()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "megaphone.fill")
                        .foregroundStyle(IMColor.brand)
                    Text("\(title)：\(preview)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(IMColor.muted.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                close()
            } label: {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(IMColor.muted.opacity(0.72))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.82))
    }

    public init(title: String,
        preview: String,
        isBusy: Bool,
        open: @escaping () -> Void,
        close: @escaping () -> Void) {
        self.title = title
        self.preview = preview
        self.isBusy = isBusy
        self.open = open
        self.close = close
    }
}

public struct ChatGroupMuteStatusView: View {
    let muteBanner: GroupMuteBannerDecision?
    let detail: String

    @ViewBuilder
    public var body: some View {
        if let muteBanner {
            HStack(spacing: 10) {
                Image(systemName: muteBanner.isRepairRequired ? "exclamationmark.triangle.fill" : "speaker.slash.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(muteBanner.isRepairRequired ? IMColor.danger : IMColor.warning)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(
                            (muteBanner.isRepairRequired ? IMColor.danger : IMColor.warning)
                                .opacity(0.12)
                        )
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(muteBanner.title)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer(minLength: 4)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(IMColor.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(IMColor.warning.opacity(0.16), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat_group_mute_active_banner")
            .accessibilityLabel("\(muteBanner.title)。\(detail)")
        }
    }

    public init(muteBanner: GroupMuteBannerDecision? = nil,
        detail: String) {
        self.muteBanner = muteBanner
        self.detail = detail
    }
}
// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_END
