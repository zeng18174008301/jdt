import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_BEGIN
public struct ChatHeaderInput: Equatable {
    public let title: String
    public let isGroup: Bool
    public let groupMemberSubtitle: String?
    public let isBatchSelecting: Bool
    public let selectedSourceCount: Int
    public let isReadOnlySystem: Bool
    public let backUnreadCount: Int

    public init(title: String,
        isGroup: Bool,
        groupMemberSubtitle: String? = nil,
        isBatchSelecting: Bool,
        selectedSourceCount: Int,
        isReadOnlySystem: Bool,
        backUnreadCount: Int) {
        self.title = title
        self.isGroup = isGroup
        self.groupMemberSubtitle = groupMemberSubtitle
        self.isBatchSelecting = isBatchSelecting
        self.selectedSourceCount = selectedSourceCount
        self.isReadOnlySystem = isReadOnlySystem
        self.backUnreadCount = backUnreadCount
    }
}

public struct ChatHeaderActions {
    public let back: () -> Void
    public let search: () -> Void
    public let more: () -> Void

    public init(back: @escaping () -> Void,
        search: @escaping () -> Void,
        more: @escaping () -> Void) {
        self.back = back
        self.search = search
        self.more = more
    }
}

public struct ChatConversationHeaderView: View {
    let input: ChatHeaderInput
    let actions: ChatHeaderActions

    public var body: some View {
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
                Button(action: actions.back) {
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
                    Button(action: actions.search) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("chat_search_button")
                    .accessibilityLabel("搜索聊天记录")

                    Button(action: actions.more) {
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

    public init(input: ChatHeaderInput,
        actions: ChatHeaderActions) {
        self.input = input
        self.actions = actions
    }
}
// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_END
