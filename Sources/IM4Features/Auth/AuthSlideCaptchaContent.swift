// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4DesignSystem

public struct SlideCaptchaDragPoint {
    public let x: Double
    public let y: Double
    public let t: Int
}

public struct AuthSlideCaptchaContent: View {
    let width: Int
    let height: Int
    let pieceSize: Int
    let pieceY: Int
    let backgroundImage: () -> UIImage?
    let pieceImage: () -> UIImage?
    let onCancel: () -> Void
    let onComplete: (Double, Int, [SlideCaptchaDragPoint]) -> Void

    public init(width: Int, height: Int, pieceSize: Int, pieceY: Int,
                backgroundImage: @escaping () -> UIImage?, pieceImage: @escaping () -> UIImage?,
                onCancel: @escaping () -> Void, onComplete: @escaping (Double, Int, [SlideCaptchaDragPoint]) -> Void) {
        self.width = width
        self.height = height
        self.pieceSize = pieceSize
        self.pieceY = pieceY
        self.backgroundImage = backgroundImage
        self.pieceImage = pieceImage
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    @State private var dragX: CGFloat = 0
    @State private var startedAt = Date()
    @State private var points: [SlideCaptchaDragPoint] = []

    public var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录安全验证")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("验证通过后才会继续校验账号和密码。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        onCancel() // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(im4Hex: 0xF3F5FA)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭滑动验证")
                }

                slideBody
            }
            .padding(18)
            .frame(maxWidth: 390)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 30, y: 16)
            )
            .padding(.horizontal, 20)
        }
    }

    private var slideBody: some View {
        GeometryReader { proxy in
            let naturalWidth = CGFloat(max(width, 240))
            let naturalHeight = CGFloat(max(height, 120))
            let displayWidth = min(proxy.size.width, naturalWidth)
            let scale = displayWidth / naturalWidth
            let displayHeight = naturalHeight * scale
            let pieceSize = CGFloat(max(self.pieceSize, 32))
            let naturalMax = max(1, naturalWidth - pieceSize)
            let pieceY = min(max(0, CGFloat(self.pieceY)), max(0, naturalHeight - pieceSize))
            VStack(spacing: 14) {
                ZStack(alignment: .topLeading) {
                    captchaImage(backgroundImage())
                        .frame(width: displayWidth, height: displayHeight)
                        .clipped()
                    captchaImage(pieceImage())
                        .frame(width: pieceSize * scale, height: pieceSize * scale)
                        .offset(x: dragX * scale, y: pieceY * scale)
                        .shadow(color: Color.black.opacity(0.28), radius: 8, y: 4)
                }
                .frame(width: displayWidth, height: displayHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IMColor.line))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(im4Hex: 0xEDF1FA))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(IMColor.brand.opacity(0.16))
                        .frame(width: max(44, dragX * scale + 44))
                    Text("按住滑块拖动到缺口位置")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                    Circle()
                        .fill(IMColor.brand)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.white)
                        )
                        .offset(x: min(max(0, dragX * scale), max(0, displayWidth - 44)))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let nextX = min(max(value.translation.width / max(scale, 0.01), 0), naturalMax)
                                    dragX = nextX
                                    recordPoint(y: value.location.y)
                                }
                                .onEnded { value in
                                    recordPoint(y: value.location.y, force: true)
                                    onComplete(Double(dragX), max(1, Int(Date().timeIntervalSince(startedAt) * 1000)), points)
                                }
                        )
                }
                .frame(width: displayWidth, height: 48)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .onAppear {
                startedAt = Date()
                points = []
                dragX = 0
            }
        }
        .frame(height: 236)
    }

    @ViewBuilder
    private func captchaImage(_ value: UIImage?) -> some View {
        if let image = value {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(im4Hex: 0xEEF2F7))
                .overlay(
                    Text("图片加载失败")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                )
        }
    }

    private func recordPoint(y: CGFloat, force: Bool = false) {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        if !force, let last = points.last, elapsed - last.t < 60 { return }
        points.append(SlideCaptchaDragPoint(x: Double(dragX), y: Double(y), t: elapsed))
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
