// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthPasswordRequirementContent: View {
    let hasLength: Bool
    let hasLetterAndNumber: Bool
    let isMatched: Bool

    public init(hasLength: Bool, hasLetterAndNumber: Bool, isMatched: Bool) {
        self.hasLength = hasLength
        self.hasLetterAndNumber = hasLetterAndNumber
        self.isMatched = isMatched
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("密码格式要求")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(IMColor.ink)
            RequirementRow(title: "8-20 位字符", passed: hasLength)
            RequirementRow(title: "至少包含字母和数字", passed: hasLetterAndNumber)
            RequirementRow(title: "两次输入的密码一致", passed: isMatched)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IMColor.brand.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.brand.opacity(0.10), lineWidth: 1))
        )
    }
}

private struct RequirementRow: View {
    let title: String
    let passed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(passed ? IMColor.success : IMColor.muted.opacity(0.55))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passed ? IMColor.ink : IMColor.muted)
        }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
