// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct NewFriendsContent<Row: View>: View {
    let requests: [FriendRequest]
    let row: (FriendRequest) -> Row

    public init(requests: [FriendRequest], @ViewBuilder row: @escaping (FriendRequest) -> Row) {
        self.requests = requests
        self.row = row
    }

    public var body: some View {
        List {
            Section {
                if requests.isEmpty {
                    EmptyStateView(symbol: "person.crop.circle.badge.plus", title: "暂无新朋友申请", subtitle: "收到新的好友申请后，会在这里处理通过或忽略。")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(requests) { request in
                        row(request)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}

public struct FriendRequestRowContent<Avatar: View, Certification: View>: View {
    let request: FriendRequest
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopy: @MainActor (String) -> Void
    let onReject: () -> Void
    let onAccept: () -> Void
    let onCancel: () -> Void
    let isCancelling: Bool

    public init(request: FriendRequest, isCancelling: Bool, onReject: @escaping () -> Void, onAccept: @escaping () -> Void, onCancel: @escaping () -> Void,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onCopy: @escaping @MainActor (String) -> Void) {
        self.request = request
        self.avatar = avatar
        self.certification = certification
        self.onCopy = onCopy
        self.isCancelling = isCancelling
        self.onReject = onReject
        self.onAccept = onAccept
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(request.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                }
                Text("\(request.source) · \(request.message)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
                if !request.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CopyableUserIDText(
                        value: request.userID,
                        prefix: "用户ID：",
                        font: .system(size: 12, weight: .semibold),
                        color: IMColor.muted,
                        onCopy: onCopy // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if request.isPendingIncoming {
                HStack(spacing: 8) {
                    FriendRequestActionButton(title: "忽略", style: .secondary) {
                        onReject()
                    }
                    .accessibilityIdentifier("friend_request_reject_\(request.id)")

                    FriendRequestActionButton(title: "接受", style: .primary) {
                        onAccept()
                    }
                    .accessibilityIdentifier("friend_request_accept_\(request.id)")
                }
                .frame(width: 114, alignment: .trailing)
            } else if request.canCancel {
                FriendRequestActionButton(
                    title: isCancelling ? "取消中" : "取消申请",
                    style: .secondary
                ) {
                    onCancel()
                }
                .disabled(isCancelling)
                .accessibilityIdentifier("friend_request_cancel_\(request.id)")
            } else {
                StatusPill(
                    title: request.statusLabel,
                    color: request.accepted ? IMColor.success : (request.direction == "outgoing" ? IMColor.warning : IMColor.muted)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("friend_request_row_\(request.id)")
    }
}

private struct FriendRequestActionButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let style: Style
    let action: () -> Void

    private var foreground: Color {
        style == .primary ? .white : IMColor.muted
    }

    private var background: Color {
        style == .primary ? IMColor.brand : Color.white.opacity(0.72)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: 52, height: 38)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background))
                .overlay(
                    Capsule()
                        .stroke(style == .primary ? Color.clear : IMColor.line.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
