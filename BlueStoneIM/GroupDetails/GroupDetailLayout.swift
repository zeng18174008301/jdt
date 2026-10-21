import SwiftUI

// WDT_GROUP_DETAIL_LAYOUT_20261021: presentation only; keep the shared settings style unchanged.
struct GroupDetailMenuRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = IMColor.brand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRow(symbol: symbol, title: title, subtitle: subtitle, tint: tint, action: nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 56, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GroupDetailMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(IMColor.line)
            .frame(height: 1)
            .padding(.leading, 52)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
    }
}

struct GroupDetailInformationRow: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(IMColor.muted)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.07)))
    }
}
