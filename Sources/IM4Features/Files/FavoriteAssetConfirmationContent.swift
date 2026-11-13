// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct FavoriteAssetConfirmationContent: View {
    let isCancellingFavoriteAsset: Bool
    let isPresented: Bool
    let onKeep: () -> Void
    let onUnfavorite: () -> Void

    public init(isCancelling: Bool, isPresented: Bool, onKeep: @escaping () -> Void, onUnfavorite: @escaping () -> Void) {
        isCancellingFavoriteAsset = isCancelling
        self.isPresented = isPresented
        self.onKeep = onKeep
        self.onUnfavorite = onUnfavorite
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    onKeep()
                }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("取消收藏这项资料？")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("确认后它会从资料列表移除，不会删除原消息。")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button {
                        onKeep()
                    } label: {
                        Text("保留")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(IMColor.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.9))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onUnfavorite()
                    } label: {
                        HStack(spacing: 8) {
                            if isCancellingFavoriteAsset {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("取消收藏")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(IMColor.danger)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.18), radius: 24, y: 12)
            )
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isPresented)
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
