// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct FindUserResultContent<Avatar: View, Certification: View>: View {
    let liveItem: UserSearchResult
    let relationTitle: String
    let relationColor: Color
    let canApply: Bool
    let isApplying: Bool
    let isAnyApplying: Bool
    let buttonTitle: String
    let onCopy: @MainActor (String) -> Void
    let onApply: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(item: UserSearchResult, relationTitle: String, relationColor: Color, canApply: Bool,
                isApplying: Bool, isAnyApplying: Bool, buttonTitle: String, onCopy: @escaping @MainActor (String) -> Void,
                onApply: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.liveItem = item
        self.relationTitle = relationTitle
        self.relationColor = relationColor
        self.canApply = canApply
        self.isApplying = isApplying
        self.isAnyApplying = isAnyApplying
        self.buttonTitle = buttonTitle
        self.onCopy = onCopy
        self.onApply = onApply
        self.avatar = avatar
        self.certification = certification
    }

    public var body: some View {
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(liveItem.displayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                    relationPill
                }
                CopyableUserIDText(
                    value: liveItem.userID.isEmpty ? liveItem.id : liveItem.userID,
                    prefix: "用户 ID：",
                    font: .system(size: 12, weight: .semibold),
                    color: IMColor.muted,
                    onCopy: onCopy // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
                )
                if !liveItem.phone.isEmpty {
                    Text("手机号：\(liveItem.phone)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            applyButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(liveItem.canApplyFriend ? IMColor.brand.opacity(0.18) : IMColor.line, lineWidth: 1)
                )
        )
        .accessibilityIdentifier("find_user_result_\(liveItem.id)")
    }

    private var relationPill: some View {
        Text(relationTitle)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(relationColor)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(relationColor.opacity(0.12)))
    }

    private var applyButton: some View {
        Button(action: onApply) {
            Group {
                if isApplying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .black))
                }
            }
            .foregroundStyle(canApply ? .white : IMColor.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 92, height: 36)
            .background(Capsule().fill(canApply ? IMColor.brand : IMColor.page))
        }
        .buttonStyle(.plain)
        .disabled(!canApply || isAnyApplying)
        .accessibilityIdentifier("find_user_apply_\(liveItem.id)")
        .accessibilityLabel("添加好友 \(liveItem.displayName)")
    }

}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END
