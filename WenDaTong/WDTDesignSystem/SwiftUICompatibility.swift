// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
import Combine
import Foundation
import SwiftUI
import UIKit

public enum JHTPresentationDetentCompat {
    case medium
    case large
    case height(CGFloat)

    @available(iOS 16.0, *)
    var native: PresentationDetent {
        switch self {
        case .medium:
            return .medium
        case .large:
            return .large
        case .height(let value):
            return .height(value)
        }
    }
}

public enum JHTPresentationVisibilityCompat {
    case hidden
    case visible

    var native: Visibility {
        switch self {
        case .hidden:
            return .hidden
        case .visible:
            return .visible
        }
    }
}

extension View {
    func imReadableInputText() -> some View {
        foregroundStyle(IMColor.ink)
            .tint(IMColor.brand)
            .colorScheme(.light)
    }

    @ViewBuilder
    func navigationDestinationCompat<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(
                NavigationLink(
                    destination: destination(),
                    isActive: isPresented,
                    label: { EmptyView() }
                )
                .hidden()
            )
        }
    }

    // WDT_IOS1_NAV_COMPAT_20261023_BEGIN
    @ViewBuilder
    func navigationDestinationCompat<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            modifier(ItemNavigationCompatModifier(item: item, destination: destination))
        }
    }
    // WDT_IOS1_NAV_COMPAT_20261023_END

    @ViewBuilder
    func presentationDetentsCompat(_ detents: [JHTPresentationDetentCompat]) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents(Set(detents.map(\.native)))
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationDragIndicatorCompat(_ visibility: JHTPresentationVisibilityCompat) -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(visibility.native)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationCornerRadiusCompat(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            presentationCornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationBackgroundClearCompat() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.clear)
        } else {
            self
        }
    }

    @ViewBuilder
    func presentationBackgroundUltraThinMaterialCompat() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.ultraThinMaterial)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollBounceBehaviorBasedOnSizeCompat() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarTabBarHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbar(.hidden, for: .tabBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarNavigationBarDarkCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarNavigationBarPageBackgroundCompat() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(IMColor.page, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func contentTransitionOpacityCompat() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }

    @ViewBuilder
    func safeAreaPaddingTopCompat(_ length: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            safeAreaPadding(.top, length)
        } else {
            padding(.top, length)
        }
    }
}

// WDT_IOS1_NAV_COMPAT_20261023_BEGIN
public struct ItemNavigationCompatModifier<Item: Identifiable & Hashable, Destination: View>: ViewModifier {
    public init(item: Binding<Item?>, destination: @escaping (Item) -> Destination) {
        _item = item
        self.destination = destination
    }

    @Binding var item: Item?
    let destination: (Item) -> Destination
    @State private var retainedItem: Item?

    private var isPresented: Binding<Bool> {
        Binding(get: { item != nil }, set: { if !$0 { item = nil } })
    }

    @ViewBuilder private var presentedContent: some View {
        if let value = item ?? retainedItem {
            destination(value).id(value.id)
        }
    }

    @ViewBuilder public func body(content: Content) -> some View {
        Group {
            if #available(iOS 16.0, *) {
                content.navigationDestination(isPresented: isPresented) { presentedContent }
            } else {
                content.background(NavigationLink(destination: presentedContent, isActive: isPresented) { EmptyView() }.hidden())
            }
        }
        .onAppear { if let item { retainedItem = item } }
        .onChange(of: item) { if let value = $0 { retainedItem = value } }
    }
}
// WDT_IOS1_NAV_COMPAT_20261023_END

public struct NavigationStackCompat<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
                    .background(SystemBackSwipeInstaller()) // WDT_IOS1_NAV_COMPAT_20261023
            }
        } else {
            NavigationView {
                content()
                    .background(SystemBackSwipeInstaller()) // WDT_IOS1_NAV_COMPAT_20261023
            }
            .navigationViewStyle(.stack)
        }
    }
}

public struct ViewThatFitsCompat<Content: View>: View {
    let axes: Axis.Set
    private let content: () -> Content

    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: axes) {
                content()
            }
        } else {
            content()
        }
    }
}

public struct LabeledContentCompat: View {
    let title: String
    let value: String

    public init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(IMColor.muted)
        }
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, action)
        } else {
            // WDT_IOS1_CHANGE_COMPAT_20261023_BEGIN
            modifier(LegacyChangeObserver(value: value, action: action))
            // WDT_IOS1_CHANGE_COMPAT_20261023_END
        }
    }
}

// WDT_IOS1_CHANGE_COMPAT_20261023_BEGIN
public struct LegacyChangeObserver<Value: Equatable>: ViewModifier {
    public init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
    }

    let value: Value
    let action: (Value, Value) -> Void
    public func body(content: Content) -> some View {
        content.onChange(of: value) { [value] newValue in
            action(value, newValue)
        }
    }
}
// WDT_IOS1_CHANGE_COMPAT_20261023_END

// WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_BEGIN
public struct PublisherSnapshotView<Value: Equatable, Content: View>: View {
    @State private var value: Value
    let updates: AnyPublisher<Value, Never>
    let content: (Value) -> Content

    public init(
        initialValue: Value,
        updates: AnyPublisher<Value, Never>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        _value = State(initialValue: initialValue)
        self.updates = updates
        self.content = content
    }

    public var body: some View {
        content(value)
            .onReceive(updates) { updated in
                if updated != value { value = updated }
            }
    }
}
// WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END
