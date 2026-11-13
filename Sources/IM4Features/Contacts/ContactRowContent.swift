// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ContactDirectoryRowContent<Avatar: View, Certification: View>: View {
    let row: ContactDirectoryRowInput


    private var displayName: String {
        row.displayName
    }

    let avatar: () -> Avatar
    let certification: () -> Certification
    public init(row: ContactDirectoryRowInput, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.row = row; self.avatar = avatar; self.certification = certification
    }
    public var body: some View {
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_ROW_USE_PRESENTATION - 修改开始：通讯录行只消费预计算展示模型，不再滚动时读取 AppState
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if row.certification != nil {
                        certification()
                    }
                }
                if let userNumber = row.userNumber {
                    Text("用户编号：\(userNumber)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let department = row.departmentSummary {
                    Text(department)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_ROW_USE_PRESENTATION - 修改结束：通讯录行只消费预计算展示模型，不再滚动时读取 AppState
    }
}

public struct ContactRowContent<Avatar: View, Certification: View>: View {
    let displayName: String
    let userNumber: String?
    let isCancelled: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    public init(displayName: String, userNumber: String?, isCancelled: Bool, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.displayName = displayName; self.userNumber = userNumber; self.isCancelled = isCancelled
        self.avatar = avatar; self.certification = certification
    }
    public var body: some View {
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                }
                if let userNumber = userNumber {
                    Text("用户编号：\(userNumber)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isCancelled {
                    Text("已注销")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .im4PlainCard(radius: 22)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
