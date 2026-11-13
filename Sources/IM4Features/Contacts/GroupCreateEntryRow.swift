// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupCreateEntryRow: View {
    public init() {  }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand))
                .shadow(color: IMColor.brand.opacity(0.14), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("创建群聊")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text("设置群名，选择好友后立即创建")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted.opacity(0.72))
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END
