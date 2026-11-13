// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AvatarEditContent<Avatar: View>: View {
    let avatar: () -> Avatar
    let onClose: () -> Void
    let onChoosePhoto: () -> Void

    public init(@ViewBuilder avatar: @escaping () -> Avatar, onClose: @escaping () -> Void,
                onChoosePhoto: @escaping () -> Void) {
        self.avatar = avatar
        self.onClose = onClose
        self.onChoosePhoto = onChoosePhoto
    }

    public var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 38, height: 5)
                    .padding(.top, 2)

                HStack(alignment: .center, spacing: 14) {
                    avatar()
                        .shadow(color: IMColor.brand.opacity(0.10), radius: 14, y: 8)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("修改头像")
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("选择照片后裁剪为圆形头像")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.72)))
                            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭头像操作")
                }
                .padding(.top, 8)

                Button {
                    onChoosePhoto()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .shadow(color: IMColor.brand.opacity(0.18), radius: 12, y: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("从相册选择")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text("支持 JPG / PNG，上传前可拖动和缩放裁剪")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(IMColor.page.opacity(0.9)))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.white.opacity(0.94))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                            )
                            .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 10)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从相册选择头像")

                Button {
                    onClose()
                } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.62))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.75), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
