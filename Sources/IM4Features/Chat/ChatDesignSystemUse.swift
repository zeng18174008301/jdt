import SwiftUI
import IM4DesignSystem

extension Color {
    init(im4Hex hex: UInt, alpha: Double = 1) {
        self = DesignSystemModuleExports.color(hex: hex, alpha: alpha)
    }

    init?(im4HexString hexString: String, alpha: Double = 1) {
        guard let color = DesignSystemModuleExports.color(hexString: hexString, alpha: alpha) else { return nil }
        self = color
    }
}

extension View {
    func im4GlassCard(radius: CGFloat = 26) -> some View {
        DesignSystemModuleExports.glassCard(self, radius: radius)
    }

    func im4PlainCard(radius: CGFloat = 22) -> some View {
        DesignSystemModuleExports.plainCard(self, radius: radius)
    }

    func im4ImReadableInputText() -> some View {
        DesignSystemModuleExports.imReadableInputText(self)
    }

    func im4PresentationDetentsCompat(_ detents: [JHTPresentationDetentCompat]) -> some View {
        DesignSystemModuleExports.presentationDetentsCompat(self, detents)
    }

    func im4PresentationDragIndicatorCompat(_ visibility: JHTPresentationVisibilityCompat) -> some View {
        DesignSystemModuleExports.presentationDragIndicatorCompat(self, visibility)
    }

    func im4PresentationCornerRadiusCompat(_ radius: CGFloat) -> some View {
        DesignSystemModuleExports.presentationCornerRadiusCompat(self, radius)
    }

    func im4PresentationBackgroundClearCompat() -> some View {
        DesignSystemModuleExports.presentationBackgroundClearCompat(self)
    }

    func im4PresentationBackgroundUltraThinMaterialCompat() -> some View {
        DesignSystemModuleExports.presentationBackgroundUltraThinMaterialCompat(self)
    }

    func im4ScrollBounceBehaviorBasedOnSizeCompat() -> some View {
        DesignSystemModuleExports.scrollBounceBehaviorBasedOnSizeCompat(self)
    }

    func im4ScrollContentBackgroundHiddenCompat() -> some View {
        DesignSystemModuleExports.scrollContentBackgroundHiddenCompat(self)
    }

    func im4ToolbarTabBarHiddenCompat() -> some View {
        DesignSystemModuleExports.toolbarTabBarHiddenCompat(self)
    }

    func im4ToolbarNavigationBarDarkCompat() -> some View {
        DesignSystemModuleExports.toolbarNavigationBarDarkCompat(self)
    }

    func im4ToolbarNavigationBarPageBackgroundCompat() -> some View {
        DesignSystemModuleExports.toolbarNavigationBarPageBackgroundCompat(self)
    }

    func im4ContentTransitionOpacityCompat() -> some View {
        DesignSystemModuleExports.contentTransitionOpacityCompat(self)
    }

    func im4SafeAreaPaddingTopCompat(_ length: CGFloat) -> some View {
        DesignSystemModuleExports.safeAreaPaddingTopCompat(self, length)
    }

    func im4NavigationDestinationCompat<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        DesignSystemModuleExports.navigationDestinationCompat(self, isPresented: isPresented, destination: destination)
    }

    func im4NavigationDestinationCompat<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        DesignSystemModuleExports.navigationDestinationCompat(self, item: item, destination: destination)
    }

    func im4OnChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        DesignSystemModuleExports.onChangeCompat(self, of: value, perform: action)
    }
}
