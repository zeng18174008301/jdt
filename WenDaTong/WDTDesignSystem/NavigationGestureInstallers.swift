// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit

// WDT_IOS1_NAV_COMPAT_20261023_BEGIN
// UIKit keeps its own transition target and action; screen-scoped owners restore their predecessor.
public struct SystemBackSwipeInstaller: UIViewControllerRepresentable {
    public init(isScreenScoped: Bool = false, allowsBackSwipe: Bool = true) {
        self.isScreenScoped = isScreenScoped
        self.allowsBackSwipe = allowsBackSwipe
    }

    // WDT_CHAT_EDGE_BACK_20261102: opt in only for screens that hide the navigation bar.
    var isScreenScoped = false
    var allowsBackSwipe = true

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIViewController(context: Context) -> HostController {
        let host = HostController()
        host.coordinator = context.coordinator
        host.isScreenScoped = isScreenScoped
        context.coordinator.allowsBackSwipe = allowsBackSwipe
        return host
    }

    public func updateUIViewController(_ host: HostController, context: Context) {
        host.coordinator = context.coordinator
        host.isScreenScoped = isScreenScoped
        context.coordinator.allowsBackSwipe = allowsBackSwipe
        DispatchQueue.main.async { [weak host] in
            host?.installIfVisible()
        }
    }

    public static func dismantleUIViewController(_ host: HostController, coordinator: Coordinator) {
        coordinator.uninstall()
        host.coordinator = nil
    }

    public final class HostController: UIViewController {
        public weak var coordinator: Coordinator?
        public var isScreenScoped = false
        private var isVisible = false

        public func installIfVisible() {
            guard !isScreenScoped || isVisible else { return }
            coordinator?.install(from: self)
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            installIfVisible()
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            if isScreenScoped {
                coordinator?.uninstall()
            }
        }
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        public override init() { super.init() }
        public var allowsBackSwipe = true
        private weak var navigation: UINavigationController?
        private weak var installedGesture: UIGestureRecognizer?
        private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        private var originalEnabled = false

        public func install(from host: UIViewController) {
            var ancestor: UIViewController? = host
            while let candidate = ancestor {
                if let nav = (candidate as? UINavigationController) ?? candidate.navigationController {
                    install(on: nav)
                    return
                }
                ancestor = candidate.parent
            }
        }

        public func install(on nav: UINavigationController) {
            guard let gesture = nav.interactivePopGestureRecognizer else { return }
            if installedGesture === gesture { return }
            uninstall()
            navigation = nav
            installedGesture = gesture
            originalDelegate = gesture.delegate
            originalEnabled = gesture.isEnabled
            gesture.delegate = self
            gesture.isEnabled = true
        }

        public func uninstall() {
            // Do not overwrite an owner that replaced us during a transition.
            if let gesture = installedGesture, gesture.delegate === self {
                gesture.delegate = originalDelegate
                gesture.isEnabled = originalEnabled
            }
            installedGesture = nil
            navigation = nil
            originalDelegate = nil
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === installedGesture, let navigation else { return false }
            return allowsBackSwipe
                && navigation.viewControllers.count > 1
                && navigation.transitionCoordinator == nil
                && navigation.presentedViewController == nil
        }
    }
}
// WDT_IOS1_NAV_COMPAT_20261023_END

// WDT_CHAT_EDGE_BACK_FIX_20261102_BEGIN
// Use the native recognizer's existing target/action so UIKit owns progress and cancellation.
public struct ChatInteractiveBackSwipeInstaller: UIViewRepresentable {
    public init(allowsBackSwipe: Bool) { self.allowsBackSwipe = allowsBackSwipe }

    var allowsBackSwipe: Bool

    public func makeUIView(context: Context) -> ProbeView { ProbeView() }

    public func updateUIView(_ view: ProbeView, context: Context) {
        view.owner.allowsBackSwipe = allowsBackSwipe
        view.scheduleRefresh()
    }

    public static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.isActive = false
        view.owner.uninstall()
    }

    public final class ProbeView: UIView {
        public let owner = Owner()
        public var isActive = true
        private var refreshScheduled = false
        private var waitingForTransition = false

        public init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { owner.uninstall() }
            scheduleRefresh()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            scheduleRefresh()
        }

        public func scheduleRefresh() {
            guard isActive, !refreshScheduled else { return }
            refreshScheduled = true
            // SwiftUI may apply hidden-navigation-bar preferences after updating this probe.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshIfVisible()
            }
        }

        public func refreshIfVisible() {
            guard isActive, window != nil else { owner.uninstall(); return }
            var ancestor = jhtNearestViewController()
            while let screen = ancestor {
                if let navigation = screen.parent as? UINavigationController {
                    if let transition = navigation.transitionCoordinator {
                        if !waitingForTransition {
                            waitingForTransition = true
                            let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                                self?.waitingForTransition = false
                                self?.scheduleRefresh()
                            }
                            if !registered { waitingForTransition = false }
                        }
                        return
                    }
                    guard navigation.topViewController === screen else { owner.uninstall(); return }
                    owner.install(on: navigation, screen: screen)
                    return
                }
                ancestor = screen.parent
            }
            owner.uninstall()
        }
    }

    public final class Owner: NSObject, UIGestureRecognizerDelegate {
        public override init() { super.init() }
        public var allowsBackSwipe = true
        private weak var navigation: UINavigationController?
        private weak var screen: UIViewController?
        private weak var installedGesture: UIGestureRecognizer?
        private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        private var originalEnabled = false

        public func install(on navigation: UINavigationController, screen: UIViewController) {
            guard navigation.topViewController === screen,
                  screen.viewIfLoaded?.window != nil,
                  navigation.transitionCoordinator == nil,
                  let gesture = navigation.interactivePopGestureRecognizer else { return }
            if installedGesture !== gesture {
                uninstall()
                installedGesture = gesture
                originalDelegate = gesture.delegate
                originalEnabled = gesture.isEnabled
            } else if gesture.delegate !== self {
                // UIKit can replace the delegate when applying navigation preferences.
                originalDelegate = gesture.delegate
                originalEnabled = gesture.isEnabled
            }
            self.navigation = navigation
            self.screen = screen
            if gesture.delegate !== self { gesture.delegate = self }
            if !gesture.isEnabled { gesture.isEnabled = true }
        }

        public func uninstall() {
            if let gesture = installedGesture, gesture.delegate === self {
                gesture.delegate = originalDelegate
                gesture.isEnabled = originalEnabled
            }
            installedGesture = nil
            navigation = nil
            screen = nil
            originalDelegate = nil
        }

        private var canBegin: Bool {
            guard allowsBackSwipe, let navigation, let screen else { return false }
            return screen.viewIfLoaded?.window != nil
                && navigation.topViewController === screen
                && navigation.viewControllers.count > 1
                && navigation.transitionCoordinator == nil
                && navigation.presentedViewController == nil
                && screen.presentedViewController == nil
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === installedGesture && canBegin
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only competing gestures inside chat yield to the edge pan; no permanent dependencies.
            guard gestureRecognizer === installedGesture, otherGestureRecognizer !== gestureRecognizer,
                  canBegin, let screenView = screen?.viewIfLoaded,
                  let otherView = otherGestureRecognizer.view else { return false }
            return otherView.isDescendant(of: screenView)
        }
    }
}
// WDT_CHAT_EDGE_BACK_FIX_20261102_END

private extension UIApplication {
    func jhtTopViewController() -> UIViewController? {
        let activeWindow = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return activeWindow?.rootViewController?.jhtTopMost()
    }
}

private extension UIView {
    func jhtNearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    func jhtOwningNavigationController() -> UINavigationController? {
        if let navigation = jhtNearestViewController() as? UINavigationController {
            return navigation
        }
        return jhtNearestViewController()?.navigationController
    }
}

private extension UIViewController {
    func jhtTopMost() -> UIViewController {
        if let presentedViewController {
            return presentedViewController.jhtTopMost()
        }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.jhtTopMost() ?? navigation
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.jhtTopMost() ?? tab
        }
        return self
    }

    func jhtNavigationControllers() -> [UINavigationController] {
        var result: [UINavigationController] = []
        collectNavigationControllers(into: &result)
        return result
    }

    private func collectNavigationControllers(into result: inout [UINavigationController]) {
        if let navigation = self as? UINavigationController {
            result.append(navigation)
        }
        if let navigationController, !result.contains(where: { $0 === navigationController }) {
            result.append(navigationController)
        }
        for child in children {
            child.collectNavigationControllers(into: &result)
        }
        if let tab = self as? UITabBarController {
            tab.viewControllers?.forEach { $0.collectNavigationControllers(into: &result) }
        }
        presentedViewController?.collectNavigationControllers(into: &result)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END

public enum AttachmentImagePreviewDismissalTrigger: Equatable {
    case closeButton
    case accessibilityEscape
    case downwardSwipe
    case leadingEdgeSwipe
}

public struct AttachmentImagePreviewDismissalCoordinator: Equatable {
    public init() {}
    public private(set) var acceptedTrigger: AttachmentImagePreviewDismissalTrigger?

    public mutating func request(_ trigger: AttachmentImagePreviewDismissalTrigger) -> Bool {
        guard acceptedTrigger == nil else { return false }
        acceptedTrigger = trigger
        return true
    }

    // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_BEGIN
    public mutating func reject(_ trigger: AttachmentImagePreviewDismissalTrigger) {
        guard acceptedTrigger == trigger else { return }
        acceptedTrigger = nil
    }
    // WDT_IOS1_ATTACHMENT_DISMISS_ADMISSION_20261110_END
}



public enum AttachmentImagePreviewDismissalPolicy {
    public static func interactiveOffset(
        startLocation: CGPoint,
        translation: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale <= 1.01 else { return .zero }
        if isDownwardIntent(translation) {
            return CGSize(width: 0, height: max(translation.height, 0))
        }
        if isLeadingEdgeIntent(startLocation: startLocation, translation: translation, viewportSize: viewportSize) {
            return CGSize(width: max(translation.width, 0), height: 0)
        }
        return .zero
    }

    public static func dismissalTrigger(
        startLocation: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> AttachmentImagePreviewDismissalTrigger? {
        guard scale <= 1.01 else { return nil }
        if isDownwardIntent(translation) {
            let distance = max(translation.height, predictedEndTranslation.height)
            return distance >= downwardThreshold(for: viewportSize) ? .downwardSwipe : nil
        }
        if isLeadingEdgeIntent(startLocation: startLocation, translation: translation, viewportSize: viewportSize) {
            let distance = max(translation.width, predictedEndTranslation.width)
            return distance >= leadingEdgeThreshold(for: viewportSize) ? .leadingEdgeSwipe : nil
        }
        return nil
    }

    public static func dismissalOpacity(offset: CGSize, viewportSize: CGSize) -> Double {
        let travel = max(offset.width, offset.height)
        let reference = max(min(viewportSize.width, viewportSize.height) * 0.65, 1)
        return Double(max(0.45, 1 - min(travel / reference, 0.55)))
    }

    private static func isDownwardIntent(_ translation: CGSize) -> Bool {
        translation.height > 0 && translation.height > abs(translation.width)
    }

    private static func isLeadingEdgeIntent(
        startLocation: CGPoint,
        translation: CGSize,
        viewportSize: CGSize
    ) -> Bool {
        startLocation.x <= leadingEdgeActivationWidth(for: viewportSize)
            && translation.width > 0
            && translation.width > abs(translation.height)
    }

    private static func leadingEdgeActivationWidth(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.width * 0.08, 24), 44)
    }

    private static func downwardThreshold(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.height * 0.12, 88), 140)
    }

    private static func leadingEdgeThreshold(for viewportSize: CGSize) -> CGFloat {
        min(max(viewportSize.width * 0.24, 84), 140)
    }
}
