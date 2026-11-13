// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum ContactProfileActionMode {
    case selfProfile
    case cancelled
    case blocked
    case friend
    case pendingFriendRequest
    case nonFriend
}

public struct ContactProfileContent<Summary: View>: View {
    let actionMode: ContactProfileActionMode
    let canBlock: Bool
    let canDelete: Bool
    let showsAddFriend: Bool
    let showsFriendRequestsDisabled: Bool
    let addFriendButtonTitle: String
    let addFriendButtonDisabled: Bool
    let summary: () -> Summary
    let onStartChat: () -> Void
    let onCall: () -> Void
    let onRemark: () -> Void
    let onShare: () -> Void
    let onBlock: () -> Void
    let onDelete: () -> Void
    let onAddFriend: () -> Void

    public init(actionMode: ContactProfileActionMode, canBlock: Bool, canDelete: Bool,
                showsAddFriend: Bool, showsFriendRequestsDisabled: Bool, addFriendButtonTitle: String,
                addFriendButtonDisabled: Bool, @ViewBuilder summary: @escaping () -> Summary,
                onStartChat: @escaping () -> Void, onCall: @escaping () -> Void, onRemark: @escaping () -> Void,
                onShare: @escaping () -> Void, onBlock: @escaping () -> Void, onDelete: @escaping () -> Void,
                onAddFriend: @escaping () -> Void) {
        self.actionMode = actionMode
        self.canBlock = canBlock
        self.canDelete = canDelete
        self.showsAddFriend = showsAddFriend
        self.showsFriendRequestsDisabled = showsFriendRequestsDisabled
        self.addFriendButtonTitle = addFriendButtonTitle
        self.addFriendButtonDisabled = addFriendButtonDisabled
        self.summary = summary
        self.onStartChat = onStartChat
        self.onCall = onCall
        self.onRemark = onRemark
        self.onShare = onShare
        self.onBlock = onBlock
        self.onDelete = onDelete
        self.onAddFriend = onAddFriend
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    summary()

                    switch actionMode {
                    case .friend:
                        HStack(spacing: 10) {
                            PrimaryButton(title: "发起会话", systemImage: "bubble.left.fill") {
                                onStartChat()
                            }
                            .accessibilityIdentifier("profile_start_chat_button")
                            IconButton(symbol: "phone.fill") {
                                onCall()
                            }
                            .accessibilityIdentifier("profile_call_button")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("资料操作")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .padding(.horizontal, 2)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ProfileInlineActionButton(title: "设置备注", symbol: "pencil", tint: IMColor.brand) {
                                    onRemark()
                                }
                                .accessibilityIdentifier("profile_set_remark_button")
                                ProfileInlineActionButton(title: "发送名片", symbol: "person.text.rectangle", tint: IMColor.cyan) {
                                    onShare()
                                }
                                .accessibilityIdentifier("profile_share_card_button")
                                if canBlock { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                                    ProfileInlineActionButton(title: "拉黑", symbol: "hand.raised.fill", tint: IMColor.danger, isDestructive: true) {
                                        onBlock()
                                    }
                                    .accessibilityIdentifier("profile_block_button")
                                }
                                if canDelete { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                                    ProfileInlineActionButton(title: "删除好友", symbol: "trash.fill", tint: IMColor.danger, isDestructive: true) {
                                        onDelete()
                                    }
                                    .accessibilityIdentifier("profile_delete_friend_button")
                                }
                            }
                        }
                        .im4PlainCard(radius: 24)
                    case .nonFriend, .pendingFriendRequest:
                        if showsAddFriend {
                            PrimaryButton(title: addFriendButtonTitle, systemImage: "person.badge.plus", disabled: addFriendButtonDisabled) {
                                onAddFriend()
                            }
                            .accessibilityIdentifier("profile_add_friend_button")
                        } else if showsFriendRequestsDisabled {
                            Label("管理员已关闭好友申请", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                        }
                    case .cancelled:
                        Label("该用户已注销，无法互动", systemImage: "person.crop.circle.badge.xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                    case .selfProfile, .blocked:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 48)
                .padding(.bottom, 18)
            }

        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
