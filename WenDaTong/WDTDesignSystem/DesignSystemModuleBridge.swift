import Combine
import SwiftUI
import UIKit
import IM4DesignSystem

// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
typealias IMColor = IM4DesignSystem.IMColor
typealias UnreadBadgeFormatter = IM4DesignSystem.UnreadBadgeFormatter
typealias AvatarCropBounds = IM4DesignSystem.AvatarCropBounds
typealias SliderVerificationPolicy = IM4DesignSystem.SliderVerificationPolicy
typealias AuroraBackground = IM4DesignSystem.AuroraBackground
typealias AuthBackground = IM4DesignSystem.AuthBackground
typealias SearchField = IM4DesignSystem.SearchField
typealias PinnedSearchTopMask = IM4DesignSystem.PinnedSearchTopMask
typealias Chip = IM4DesignSystem.Chip
typealias StatusPill = IM4DesignSystem.StatusPill
typealias PrimaryButton = IM4DesignSystem.PrimaryButton
typealias CopyableUserIDText = IM4DesignSystem.CopyableUserIDText
typealias IconButton = IM4DesignSystem.IconButton
typealias FormInput = IM4DesignSystem.FormInput
typealias SliderVerification = IM4DesignSystem.SliderVerification
typealias EmptyStateView = IM4DesignSystem.EmptyStateView
typealias RemoteLoadingStateView = IM4DesignSystem.RemoteLoadingStateView
typealias JHTPresentationDetentCompat = IM4DesignSystem.JHTPresentationDetentCompat
typealias JHTPresentationVisibilityCompat = IM4DesignSystem.JHTPresentationVisibilityCompat
typealias LabeledContentCompat = IM4DesignSystem.LabeledContentCompat
typealias SystemBackSwipeInstaller = IM4DesignSystem.SystemBackSwipeInstaller
typealias ChatInteractiveBackSwipeInstaller = IM4DesignSystem.ChatInteractiveBackSwipeInstaller
typealias PinnedSearchHeader<Content: View> = IM4DesignSystem.PinnedSearchHeader<Content>
typealias ItemNavigationCompatModifier<Item: Identifiable & Hashable, Destination: View> = IM4DesignSystem.ItemNavigationCompatModifier<Item, Destination>
typealias NavigationStackCompat<Content: View> = IM4DesignSystem.NavigationStackCompat<Content>
typealias ViewThatFitsCompat<Content: View> = IM4DesignSystem.ViewThatFitsCompat<Content>
typealias LegacyChangeObserver<Value: Equatable> = IM4DesignSystem.LegacyChangeObserver<Value>
typealias PublisherSnapshotView<Value: Equatable, Content: View> = IM4DesignSystem.PublisherSnapshotView<Value, Content>

func presenceBadgeColor(for status: String, offlineColor: Color = IMColor.muted) -> Color? {
    DesignSystemModuleExports.presenceBadgeColor(for: status, offlineColor: offlineColor)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self = DesignSystemModuleExports.color(hex: hex, alpha: alpha)
    }

    init?(hexString: String, alpha: Double = 1) {
        guard let color = DesignSystemModuleExports.color(hexString: hexString, alpha: alpha) else { return nil }
        self = color
    }
}

extension View {
    func glassCard(radius: CGFloat = 26) -> some View {
        DesignSystemModuleExports.glassCard(self, radius: radius)
    }

    func plainCard(radius: CGFloat = 22) -> some View {
        DesignSystemModuleExports.plainCard(self, radius: radius)
    }

    func imReadableInputText() -> some View {
        DesignSystemModuleExports.imReadableInputText(self)
    }

    func presentationDetentsCompat(_ detents: [JHTPresentationDetentCompat]) -> some View {
        DesignSystemModuleExports.presentationDetentsCompat(self, detents)
    }

    func presentationDragIndicatorCompat(_ visibility: JHTPresentationVisibilityCompat) -> some View {
        DesignSystemModuleExports.presentationDragIndicatorCompat(self, visibility)
    }

    func presentationCornerRadiusCompat(_ radius: CGFloat) -> some View {
        DesignSystemModuleExports.presentationCornerRadiusCompat(self, radius)
    }

    func presentationBackgroundClearCompat() -> some View {
        DesignSystemModuleExports.presentationBackgroundClearCompat(self)
    }

    func presentationBackgroundUltraThinMaterialCompat() -> some View {
        DesignSystemModuleExports.presentationBackgroundUltraThinMaterialCompat(self)
    }

    func scrollBounceBehaviorBasedOnSizeCompat() -> some View {
        DesignSystemModuleExports.scrollBounceBehaviorBasedOnSizeCompat(self)
    }

    func scrollContentBackgroundHiddenCompat() -> some View {
        DesignSystemModuleExports.scrollContentBackgroundHiddenCompat(self)
    }

    func toolbarTabBarHiddenCompat() -> some View {
        DesignSystemModuleExports.toolbarTabBarHiddenCompat(self)
    }

    func toolbarNavigationBarDarkCompat() -> some View {
        DesignSystemModuleExports.toolbarNavigationBarDarkCompat(self)
    }

    func toolbarNavigationBarPageBackgroundCompat() -> some View {
        DesignSystemModuleExports.toolbarNavigationBarPageBackgroundCompat(self)
    }

    func contentTransitionOpacityCompat() -> some View {
        DesignSystemModuleExports.contentTransitionOpacityCompat(self)
    }

    func safeAreaPaddingTopCompat(_ length: CGFloat) -> some View {
        DesignSystemModuleExports.safeAreaPaddingTopCompat(self, length)
    }

    func navigationDestinationCompat<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        DesignSystemModuleExports.navigationDestinationCompat(self, isPresented: isPresented, destination: destination)
    }

    func navigationDestinationCompat<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        DesignSystemModuleExports.navigationDestinationCompat(self, item: item, destination: destination)
    }

    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        DesignSystemModuleExports.onChangeCompat(self, of: value, perform: action)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END

// Shared image gesture geometry has one DesignSystem owner for Chat and Contacts.
typealias AttachmentImagePreviewDismissalTrigger = IM4DesignSystem.AttachmentImagePreviewDismissalTrigger
typealias AttachmentImagePreviewDismissalCoordinator = IM4DesignSystem.AttachmentImagePreviewDismissalCoordinator
typealias AttachmentImagePreviewDismissalPolicy = IM4DesignSystem.AttachmentImagePreviewDismissalPolicy
