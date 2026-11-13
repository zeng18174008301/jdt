// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct PhoneBindingStatusPanel: View {
    let isVerified: Bool
    let phoneText: String

    public init(isVerified: Bool, phoneText: String) { self.isVerified = isVerified; self.phoneText = phoneText }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(isVerified ? IMColor.success : IMColor.brand)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle()
                            .fill((isVerified ? IMColor.success : IMColor.brand).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(isVerified ? "手机号已验证" : "手机号待验证")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(phoneText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(isVerified ? IMColor.ink : IMColor.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Text(isVerified ? "已验证" : "待验证")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(isVerified ? IMColor.success : IMColor.brand)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill((isVerified ? IMColor.success : IMColor.brand).opacity(0.12)))
            }

            HStack(spacing: 12) {
                PhoneBindingInfoTile(title: "认证状态", value: isVerified ? "已通过" : "未完成")
                PhoneBindingInfoTile(title: "绑定手机号", value: phoneText)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(IMColor.line, lineWidth: 1)
                )
                .shadow(color: Color(im4Hex: 0x5D6BFF, alpha: 0.10), radius: 24, y: 12)
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END
