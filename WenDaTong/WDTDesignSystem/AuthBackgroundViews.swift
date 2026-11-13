// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit

public struct AuroraBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    IMColor.page,
                    Color(hex: 0xEEF1FF),
                    Color(hex: 0xEAF8FF)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [IMColor.brand.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [IMColor.cyan.opacity(0.10), .clear],
                center: .trailing,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - 登录 / 注册 动态背景(方案 B:Metal 流动极光 + 稀疏粒子)
// 仅用于 AuthRootView;聊天页仍用静态的 AuroraBackground。
// 性能:着色器走 GPU(不占主线程)、限 20fps、慢速流动;开启「减弱动态效果」时退回静态背景。
public struct AuthBackground: View {
    public init(isAnimating: Bool = true) { self.isAnimating = isAnimating }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var pausedDate = Date()
    @State private var pausedElapsed: TimeInterval = 0

    var isAnimating = true
    private let frameInterval: TimeInterval = 1.0 / 30.0

    public var body: some View {
        ZStack {
            if reduceMotion {
                AuroraBackground()
            } else {
                GeometryReader { geo in
                    if isAnimating {
                        TimelineView(.periodic(from: .now, by: frameInterval)) { tl in
                            auroraFrame(size: geo.size, date: tl.date)
                        }
                    } else {
                        auroraFrame(size: geo.size, date: pausedDate)
                    }
                }
                .ignoresSafeArea()
                .onChangeCompat(of: isAnimating) { _, animating in
                    if animating {
                        start = Date().addingTimeInterval(-pausedElapsed)
                    } else {
                        pausedDate = Date()
                        pausedElapsed = pausedDate.timeIntervalSince(start)
                    }
                }

                AuthParticles(isAnimating: isAnimating)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func auroraFrame(size: CGSize, date: Date) -> some View {
        let t = Float(date.timeIntervalSince(start)) * 0.06
        if #available(iOS 17.0, *) {
            Rectangle()
                .colorEffect(
                ShaderLibrary.auroraFlow(
                    .float2(Float(size.width), Float(size.height)),
                    .float(t)
                )
            )
        } else {
            LinearGradient(
                colors: [
                    Color(hex: 0xAEB8FF),
                    Color(hex: 0xDDE3FF),
                    Color(hex: 0xF7FAFF)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct AuthParticles: View {
    var isAnimating = true
    @State private var start = Date()
    @State private var pausedDate = Date()
    @State private var pausedElapsed: TimeInterval = 0

    private let frameInterval: TimeInterval = 1.0 / 30.0

    private struct Dot { var x0, y0, vx, vy, r, a, ph: Double }
    @State private var dots: [Dot] = (0..<20).map { _ in
        Dot(x0: .random(in: 0...1),
            y0: .random(in: 0...1),
            vx: .random(in: -0.006...0.006),
            vy: -Double.random(in: 0.005...0.020),
            r:  .random(in: 1.2...3.2),
            a:  .random(in: 0.36...0.88),
            ph: .random(in: 0...6.2832))
    }

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.periodic(from: .now, by: frameInterval)) { tl in
                    particleCanvas(date: tl.date)
                }
            } else {
                particleCanvas(date: pausedDate)
            }
        }
        .onChangeCompat(of: isAnimating) { _, animating in
            if animating {
                start = Date().addingTimeInterval(-pausedElapsed)
            } else {
                pausedDate = Date()
                pausedElapsed = pausedDate.timeIntervalSince(start)
            }
        }
    }

    private func particleCanvas(date: Date) -> some View {
        Canvas { ctx, size in
            let t = date.timeIntervalSince(start) * 1.5
            for d in dots {
                var x = (d.x0 + d.vx * t).truncatingRemainder(dividingBy: 1.0)
                var y = (d.y0 + d.vy * t).truncatingRemainder(dividingBy: 1.0)
                if x < 0 { x += 1 }
                if y < 0 { y += 1 }
                let cx = CGFloat(x) * size.width
                let cy = CGFloat(y) * size.height
                let alpha = max(0.0, d.a * (0.6 + 0.4 * sin(d.ph + t * 0.6)))
                let rr = CGFloat(d.r * 3.9)
                let rect = CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)
                let grad = Gradient(stops: [
                    .init(color: .white.opacity(alpha), location: 0),
                    .init(color: .white.opacity(0), location: 1)
                ])
                ctx.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(grad, center: CGPoint(x: cx, y: cy),
                                          startRadius: 0, endRadius: rr)
                )
            }
        }
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END
