@testable import IM4Features
import SwiftUI
@testable import WenDaTong

// Frozen 9be69 render body. Original action implementations are exercised in App factory tests.
struct ChatHeader9BE69Reference: View {
    let input: ChatHeaderInput
    var body: some View {
        let backUnreadBadgeText = UnreadBadgeFormatter.text(input.backUnreadCount) ?? ""
        return ZStack {
            VStack(spacing: 2) {
                Text(
                    input.isBatchSelecting
                        ? "已选 \(input.selectedSourceCount) 条"
                        : input.title
                )
                    .font(.headline.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat_centered_conversation_title")
                    .accessibilityAddTraits(.isHeader)
                if !input.isBatchSelecting,
                   input.isGroup,
                   let groupMemberSubtitleText = input.groupMemberSubtitle {
                    Text(groupMemberSubtitleText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // The symmetric fixed-width center lane is independent of the
            // asymmetric action lanes, so a narrow device cannot shift or
            // collapse the title while the text itself still truncates.
            .frame(width: 136)
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                Button {} label: {
                    if input.isBatchSelecting {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .frame(width: 44, height: 44)
                    } else {
                        ChatBackButtonBadge(count: input.backUnreadCount, text: backUnreadBadgeText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("chat_back_button")
                .accessibilityLabel(
                    input.isBatchSelecting
                        ? "取消多选"
                        : (input.backUnreadCount > 0
                            ? "返回，会话列表还有\(backUnreadBadgeText)条未读消息"
                            : "返回")
                )

                Spacer(minLength: 0)

                if !input.isReadOnlySystem && !input.isBatchSelecting {
                    Button {} label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat_search_button")
                    .accessibilityLabel("搜索聊天记录")

                    Button {} label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat_more_button")
                    .accessibilityLabel("会话详情")
                }
            }
            // Product contract keeps back physically left and actions right;
            // the centered title still inherits the surrounding text direction.
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: 56)
        .padding(.horizontal, 8)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct ChatAnnouncement9BE69Reference: View {
    let title: String
    let preview: String
    let isBusy: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button {

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
}

struct ChatMute9BE69Reference: View {
    let muteBanner: GroupMuteBannerDecision?
    let detail: String
    @ViewBuilder
    var body: some View {
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
}
