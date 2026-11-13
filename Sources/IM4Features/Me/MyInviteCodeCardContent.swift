// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct MeInviteCodePresentation: Sendable {
    let title: String
    let subtitle: String
    let copyValue: String?
    let isUsableForRegistration: Bool
    let isWarning: Bool
    let shouldShowStats: Bool
    public init(title: String, subtitle: String, copyValue: String?, isUsableForRegistration: Bool, isWarning: Bool, shouldShowStats: Bool) {
        self.title = title; self.subtitle = subtitle; self.copyValue = copyValue
        self.isUsableForRegistration = isUsableForRegistration; self.isWarning = isWarning; self.shouldShowStats = shouldShowStats
    }
}
public struct MeInviteCodeCounts: Sendable {
    let inviteCount: Int
    let joinedCount: Int
    let pendingCount: Int
    public init(inviteCount: Int, joinedCount: Int, pendingCount: Int) {
        self.inviteCount = inviteCount; self.joinedCount = joinedCount; self.pendingCount = pendingCount
    }
}
public struct MyInviteCodeCardContent: View {
    let presentation: MeInviteCodePresentation
    let counts: MeInviteCodeCounts?
    let isLoading: Bool
    let copy: (String) -> Void
    let refresh: () -> Void
    public init(presentation: MeInviteCodePresentation, counts: MeInviteCodeCounts?, isLoading: Bool,
                copy: @escaping (String) -> Void, refresh: @escaping () -> Void) {
        self.presentation = presentation; self.counts = counts; self.isLoading = isLoading; self.copy = copy; self.refresh = refresh
    }
    private var canCopy: Bool { presentation.copyValue != nil }
    private var statusColor: Color {
        if presentation.isUsableForRegistration { return IMColor.success }
        if presentation.isWarning { return IMColor.warning }
        return IMColor.muted
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("我的邀请码")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                    Text(presentation.title)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(presentation.subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if let copyValue = presentation.copyValue {
                        copy(copyValue)
                    } else {
                        refresh()
                    }
                } label: {
                    Text(canCopy ? "复制" : "刷新")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(canCopy ? IMColor.brand : IMColor.muted)
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background(Capsule().fill((canCopy ? IMColor.brand : IMColor.muted).opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .opacity(isLoading ? 0.65 : 1)
            }

            if let counts = counts, presentation.shouldShowStats {
                HStack(spacing: 8) {
                    inviteStat(title: "邀请", value: counts.inviteCount)
                    inviteStat(title: "已加入", value: counts.joinedCount)
                    inviteStat(title: "待审批", value: counts.pendingCount)
                }
            }
        }
        .im4GlassCard(radius: 24)
    }

    private func inviteStat(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(IMColor.muted)
            Text("\(value)")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.58))
        )
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
