// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct QuickLookPresentationContent<Preview: View>: View {
    let preview: Preview
    let onClose: () -> Void

    public init(preview: Preview, onClose: @escaping () -> Void) {
        self.preview = preview
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
                .ignoresSafeArea()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.56)))
                    .overlay(Circle().stroke(.white.opacity(0.26), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END
