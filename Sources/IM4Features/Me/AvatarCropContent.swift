// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4DesignSystem

public struct AvatarCropContent: View {
    let image: UIImage
    let imageSize: CGSize
    let previewSize: CGFloat
    let scaleRange: ClosedRange<CGFloat>
    let isUploading: Bool
    let inlineMessage: String?
    let onClose: () -> Void
    let onUpload: (CGFloat, CGSize) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    public init(image: UIImage, imageSize: CGSize, previewSize: CGFloat, scaleRange: ClosedRange<CGFloat>,
                isUploading: Bool, inlineMessage: String?, onClose: @escaping () -> Void,
                onUpload: @escaping (CGFloat, CGSize) -> Void) {
        self.image = image
        self.imageSize = imageSize
        self.previewSize = previewSize
        self.scaleRange = scaleRange
        self.isUploading = isUploading
        self.inlineMessage = inlineMessage
        self.onClose = onClose
        self.onUpload = onUpload
    }

    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { scale },
            set: { updateScale($0, syncGestureBaseline: true) }
        )
    }

    public var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 18) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("裁剪头像")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("拖动图片调整位置，双指缩放到合适大小")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.72)))
                            .overlay(Circle().stroke(IMColor.line.opacity(0.9), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("关闭头像裁剪")
                }

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: previewSize, height: previewSize)
                        .clipShape(Circle())
                        .gesture(dragGesture.simultaneously(with: magnifyGesture))
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: previewSize, height: previewSize)
                        .shadow(color: IMColor.brand.opacity(0.18), radius: 18, y: 8)
                    Circle()
                        .stroke(IMColor.brand.opacity(0.28), lineWidth: 1)
                        .frame(width: previewSize + 8, height: previewSize + 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Slider(value: scaleBinding, in: scaleRange) {
                    Text("缩放")
                }
                .tint(IMColor.brand)

                if let inlineMessage {
                    Text(inlineMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(inlineMessage.contains("成功") ? IMColor.success : IMColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                PrimaryButton(title: isUploading ? "上传中..." : "上传头像", systemImage: "arrow.up.circle.fill", disabled: isUploading) {
                    onUpload(scale, offset)
                }
            }
        }
        .onAppear {
            clampCropState(syncGestureBaseline: true)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, scale: scale)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                updateScale(lastScale * value, syncGestureBaseline: false)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private func updateScale(_ proposedScale: CGFloat, syncGestureBaseline: Bool) {
        let nextScale = AvatarCropBounds.clampedScale(proposedScale, range: scaleRange)
        scale = nextScale
        offset = clampedOffset(offset, scale: nextScale)
        if syncGestureBaseline {
            lastScale = nextScale
            lastOffset = offset
        }
    }

    private func clampCropState(syncGestureBaseline: Bool) {
        scale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        offset = clampedOffset(offset, scale: scale)
        if syncGestureBaseline {
            lastScale = scale
            lastOffset = offset
        }
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        AvatarCropBounds.clampedOffset(
            imageSize: imageSize,
            previewSize: previewSize,
            scale: scale,
            proposed: proposed
        )
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
