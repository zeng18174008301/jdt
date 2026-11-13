// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

// 斜线圆弧过渡:x 线性平移、y 二次曲线(走弧线)、带轻微旋转
private struct ArcOffset: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var fromLeading: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let dir: CGFloat = fromLeading ? -1 : 1
        return content
            .offset(x: dir * progress * 620, y: -(progress * progress) * 72)
            .rotationEffect(.degrees(Double(dir * progress * 6)))
            .opacity(Double(1 - progress * 0.25))
    }
}

public extension AnyTransition {
    static func im4AuthArc(fromLeading: Bool) -> AnyTransition {
        .modifier(active: ArcOffset(progress: 1, fromLeading: fromLeading),
                  identity: ArcOffset(progress: 0, fromLeading: fromLeading))
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
