import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
public enum DesignSystemModuleExports {
    public static func presenceBadgeColor(for status: String, offlineColor: Color = IMColor.muted) -> Color? {
        IM4DesignSystem.presenceBadgeColor(for: status, offlineColor: offlineColor)
    }

    public static func color(hex: UInt, alpha: Double = 1) -> Color {
        Color(hex: hex, alpha: alpha)
    }

    public static func color(hexString: String, alpha: Double = 1) -> Color? {
        Color(hexString: hexString, alpha: alpha)
    }

    @MainActor
    public static func glassCard<Root: View>(_ root: Root, radius: CGFloat = 26) -> some View {
        root.glassCard(radius: radius)
    }

    @MainActor
    public static func plainCard<Root: View>(_ root: Root, radius: CGFloat = 22) -> some View {
        root.plainCard(radius: radius)
    }

    @MainActor
    public static func imReadableInputText<Root: View>(_ root: Root) -> some View {
        root.imReadableInputText()
    }

    @MainActor
    public static func presentationDetentsCompat<Root: View>(_ root: Root, _ detents: [JHTPresentationDetentCompat]) -> some View {
        root.presentationDetentsCompat(detents)
    }

    @MainActor
    public static func presentationDragIndicatorCompat<Root: View>(_ root: Root, _ visibility: JHTPresentationVisibilityCompat) -> some View {
        root.presentationDragIndicatorCompat(visibility)
    }

    @MainActor
    public static func presentationCornerRadiusCompat<Root: View>(_ root: Root, _ radius: CGFloat) -> some View {
        root.presentationCornerRadiusCompat(radius)
    }

    @MainActor
    public static func presentationBackgroundClearCompat<Root: View>(_ root: Root) -> some View {
        root.presentationBackgroundClearCompat()
    }

    @MainActor
    public static func presentationBackgroundUltraThinMaterialCompat<Root: View>(_ root: Root) -> some View {
        root.presentationBackgroundUltraThinMaterialCompat()
    }

    @MainActor
    public static func scrollBounceBehaviorBasedOnSizeCompat<Root: View>(_ root: Root) -> some View {
        root.scrollBounceBehaviorBasedOnSizeCompat()
    }

    @MainActor
    public static func scrollContentBackgroundHiddenCompat<Root: View>(_ root: Root) -> some View {
        root.scrollContentBackgroundHiddenCompat()
    }

    @MainActor
    public static func toolbarTabBarHiddenCompat<Root: View>(_ root: Root) -> some View {
        root.toolbarTabBarHiddenCompat()
    }

    @MainActor
    public static func toolbarNavigationBarDarkCompat<Root: View>(_ root: Root) -> some View {
        root.toolbarNavigationBarDarkCompat()
    }

    @MainActor
    public static func toolbarNavigationBarPageBackgroundCompat<Root: View>(_ root: Root) -> some View {
        root.toolbarNavigationBarPageBackgroundCompat()
    }

    @MainActor
    public static func contentTransitionOpacityCompat<Root: View>(_ root: Root) -> some View {
        root.contentTransitionOpacityCompat()
    }

    @MainActor
    public static func safeAreaPaddingTopCompat<Root: View>(_ root: Root, _ length: CGFloat) -> some View {
        root.safeAreaPaddingTopCompat(length)
    }

    @MainActor
    public static func navigationDestinationCompat<Root: View, Destination: View>(
        _ root: Root,
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        root.navigationDestinationCompat(isPresented: isPresented, destination: destination)
    }

    @MainActor
    public static func navigationDestinationCompat<Root: View, Item: Identifiable & Hashable, Destination: View>(
        _ root: Root,
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        root.navigationDestinationCompat(item: item, destination: destination)
    }

    @MainActor
    public static func onChangeCompat<Root: View, Value: Equatable>(
        _ root: Root,
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        root.onChangeCompat(of: value, perform: action)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END

private struct StickerGIFPlaybackViewportKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    public var stickerGIFPlaybackViewport: CGRect? {
        get { self[StickerGIFPlaybackViewportKey.self] }
        set { self[StickerGIFPlaybackViewportKey.self] = newValue }
    }
}
