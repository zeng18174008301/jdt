// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupDetailSummaryContent<Avatar: View>: View {
    let name: String
    let memberSummary: String
    let roleTitle: String?
    let roleColor: Color
    let canManage: Bool
    let notice: String
    let description: String
    let avatar: () -> Avatar
    let onEdit: () -> Void

    public init(name: String, memberSummary: String, roleTitle: String?, roleColor: Color, canManage: Bool,
                notice: String, description: String, @ViewBuilder avatar: @escaping () -> Avatar,
                onEdit: @escaping () -> Void) {
        self.name = name
        self.memberSummary = memberSummary
        self.roleTitle = roleTitle
        self.roleColor = roleColor
        self.canManage = canManage
        self.notice = notice
        self.description = description
        self.avatar = avatar
        self.onEdit = onEdit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(memberSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    if let roleTitle {
                        StatusPill(title: roleTitle, color: roleColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if canManage {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                            .overlay(Circle().stroke(IMColor.brand.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("编辑群资料")
                }
            }
            // WDT_APP_CONTRACT_20261021_14: placeholders are presentation-only.
            VStack(spacing: 10) {
                GroupDetailInformationRow(
                    symbol: "megaphone.fill",
                    text: notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无群公告" : notice,
                    tint: IMColor.brand
                )
                GroupDetailInformationRow(
                    symbol: "text.alignleft",
                    text: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无群描述" : description,
                    tint: IMColor.violet
                )
            }
        }
        .im4GlassCard(radius: 24)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
