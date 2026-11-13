import IM4Features
import ImageIO
import UIKit
import SwiftUI
import XCTest
@testable import WenDaTong

// WDT_IOS1_NATIVE_NAV_REGRESSION_20261023_BEGIN
private struct ItemNavigationProbeRoute: Identifiable, Hashable {
    let id: String
    let messageID: String?
}

@MainActor
private final class ItemNavigationProbeModel: ObservableObject {
    @Published var route: ItemNavigationProbeRoute?
}

private struct ItemNavigationProbe: View {
    @ObservedObject var model: ItemNavigationProbeModel
    let onRootAppear: () -> Void
    let onDestinationAppear: (ItemNavigationProbeRoute, @escaping () -> Void) -> Void

    var body: some View {
        NavigationStackCompat {
            Text("Root")
                .onAppear(perform: onRootAppear)
                .navigationDestinationCompat(item: $model.route) { route in
                    ItemNavigationProbeDestination(route: route, onAppear: onDestinationAppear)
                }
        }
    }
}

private struct ItemNavigationProbeDestination: View {
    @Environment(\.dismiss) private var dismiss
    let route: ItemNavigationProbeRoute
    let onAppear: (ItemNavigationProbeRoute, @escaping () -> Void) -> Void

    var body: some View {
        Text(route.id)
            .onAppear { onAppear(route, { dismiss() }) }
    }
}
// WDT_IOS1_NATIVE_NAV_REGRESSION_20261023_END

extension DesignSystemTests {
    // WDT_IOS1_NATIVE_NAV_REGRESSION_20261023_BEGIN
    func testItemNavigationShowsSelectedRouteAndCanDismissThenOpenAnother() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Native item destinations require iOS 17+") }
        let model = ItemNavigationProbeModel()
        let first = ItemNavigationProbeRoute(id: "conversation-a", messageID: "search-result-a")
        let second = ItemNavigationProbeRoute(id: "conversation-b", messageID: nil)
        var observed: [ItemNavigationProbeRoute] = []
        var dismissDestination: (() -> Void)?
        var rootExpectation = expectation(description: "root appeared")
        var destinationExpectation = expectation(description: "first destination appeared")
        let controller = UIHostingController(rootView: ItemNavigationProbe(
            model: model,
            onRootAppear: { rootExpectation.fulfill() },
            onDestinationAppear: { route, dismiss in
                observed.append(route)
                dismissDestination = dismiss
                destinationExpectation.fulfill()
            }
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [rootExpectation], timeout: 3)
        XCTAssertTrue(observed.isEmpty, "An empty selection must not mount a destination")
        model.route = first
        await fulfillment(of: [destinationExpectation], timeout: 3)
        XCTAssertEqual(observed, [first], "Preserve both conversation and search-jump payload")
        XCTAssertEqual(model.route, first)

        rootExpectation = expectation(description: "returned to root")
        try XCTUnwrap(dismissDestination)()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        await fulfillment(of: [rootExpectation], timeout: 3)
        XCTAssertNil(model.route, "Native back/dismiss must clear the selection")

        destinationExpectation = expectation(description: "second destination appeared")
        model.route = second
        await fulfillment(of: [destinationExpectation], timeout: 3)
        XCTAssertEqual(observed, [first, second], "Do not reuse the previous destination")
        XCTAssertEqual(model.route, second)
    }
    // WDT_IOS1_NATIVE_NAV_REGRESSION_20261023_END

    // WDT_IOS1_NAV_COMPAT_20261023_BEGIN
    func testLegacyItemNavigationPushPopAndReentryStayBoundToRoute() async throws {
        let probe = LegacyNavigationProbe()
        let host = UIHostingController(rootView: LegacyNavigationProbeView(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let nav = controller as? UINavigationController { return nav }
            for child in controller.children {
                if let nav = navigation(in: child) { return nav }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let nav = try XCTUnwrap(navigation(in: host), "Navigation hierarchy: \(host.children.map { String(describing: type(of: $0)) })")
        for id in ["first", "second", "third"] {
            probe.route = LegacyNavigationRoute(id: id)
            for _ in 0..<50 {
                if nav.viewControllers.count == 2 && nav.transitionCoordinator == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(nav.viewControllers.count, 2)
            let gesture = try XCTUnwrap(nav.interactivePopGestureRecognizer)
            XCTAssertTrue(gesture.isEnabled)
            XCTAssertTrue(gesture.delegate is SystemBackSwipeInstaller.Coordinator)
            if id == "first" {
                probe.route = LegacyNavigationRoute(id: "replacement")
                for _ in 0..<50 {
                    if probe.lastAppearedID == "replacement" { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertEqual(probe.lastAppearedID, "replacement", "A different conversation must receive fresh destination state")
                XCTAssertEqual(nav.viewControllers.count, 2)
            }
            nav.popViewController(animated: false)
            for _ in 0..<50 {
                if probe.route == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(probe.route)
            XCTAssertEqual(nav.viewControllers.count, 1)
        }
    }

    func testSystemBackGestureHasSingleOwnerAndRestoresPreviousDelegate() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let original = gesture.delegate
        let originalEnabled = gesture.isEnabled
        let coordinator = SystemBackSwipeInstaller.Coordinator()
        coordinator.install(on: navigation)
        XCTAssertTrue(gesture.delegate === coordinator)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(gesture))
        navigation.pushViewController(UIViewController(), animated: false)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(gesture))
        coordinator.install(on: navigation)
        coordinator.uninstall()
        XCTAssertTrue(gesture.delegate === original)
        XCTAssertEqual(gesture.isEnabled, originalEnabled)
    }

    func testSystemBackGestureTeardownDoesNotClobberLaterOwner() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let first = SystemBackSwipeInstaller.Coordinator()
        let replacement = SystemBackSwipeInstaller.Coordinator()
        first.install(on: navigation)
        gesture.delegate = replacement
        first.uninstall()
        XCTAssertTrue(gesture.delegate === replacement)
    }

    // WDT_CHAT_EDGE_BACK_20261102_BEGIN
    func testChatBackSwipeOnlyInstallsWhileVisibleAndRestoresContainerOwner() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let containerOwner = SystemBackSwipeInstaller.Coordinator()
        containerOwner.install(on: navigation)
        let chatOwner = SystemBackSwipeInstaller.Coordinator()
        let host = SystemBackSwipeInstaller.HostController()
        host.coordinator = chatOwner
        host.isScreenScoped = true
        navigation.pushViewController(host, animated: false)
        navigation.setNavigationBarHidden(true, animated: false)
        gesture.isEnabled = false

        host.installIfVisible()
        XCTAssertFalse(gesture.isEnabled, "An offscreen update must not take ownership")
        XCTAssertTrue(gesture.delegate === containerOwner)

        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertTrue(gesture.delegate === chatOwner)
        XCTAssertTrue(chatOwner.gestureRecognizerShouldBegin(gesture))

        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        host.installIfVisible()
        XCTAssertTrue(gesture.delegate === containerOwner)
        XCTAssertFalse(gesture.isEnabled, "Leaving chat must restore the prior enabled state")

        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertTrue(gesture.delegate === chatOwner, "Reentering chat must re-enable edge back")
        chatOwner.uninstall()
        containerOwner.uninstall()
    }

    func testChatBackSwipeDoesNotBypassBatchSelectionOrPopRoot() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let coordinator = SystemBackSwipeInstaller.Coordinator()
        coordinator.install(on: navigation)
        defer { coordinator.uninstall() }
        navigation.pushViewController(UIViewController(), animated: false)
        coordinator.allowsBackSwipe = false
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(gesture))
        coordinator.allowsBackSwipe = true
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(gesture))
        navigation.popViewController(animated: false)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(gesture))
    }
    // WDT_CHAT_EDGE_BACK_20261102_END
    // WDT_IOS1_NAV_COMPAT_20261023_END

    // WDT_CHAT_EDGE_BACK_FIX_20261102_BEGIN
    func testChatInteractiveBackReenablesNativeGestureAfterNavigationPreferencesChange() async throws {
        let root = UIViewController()
        let chat = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.setViewControllers([root, chat], animated: false)
        navigation.setNavigationBarHidden(true, animated: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(chat.view.window === window)
        XCTAssertNil(navigation.transitionCoordinator)
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let probe = ChatInteractiveBackSwipeInstaller.ProbeView()
        probe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        chat.view.addSubview(probe)
        defer {
            ChatInteractiveBackSwipeInstaller.dismantleUIView(probe, coordinator: ())
        }
        let original = gesture.delegate
        gesture.isEnabled = false
        probe.refreshIfVisible()
        XCTAssertTrue(navigation.interactivePopGestureRecognizer === gesture, "Keep UIKit's interactive transition, not a separate swipe-to-dismiss recognizer")
        XCTAssertTrue(gesture.delegate === probe.owner)
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertFalse(probe.isUserInteractionEnabled, "The 1pt probe must not intercept chat touches")

        gesture.isEnabled = false
        probe.refreshIfVisible()
        XCTAssertTrue(gesture.isEnabled, "Reconcile even when the recognizer instance has not changed")
        gesture.delegate = original
        gesture.isEnabled = false
        probe.refreshIfVisible()
        XCTAssertTrue(gesture.delegate === probe.owner)
        XCTAssertTrue(gesture.isEnabled)

        ChatInteractiveBackSwipeInstaller.dismantleUIView(probe, coordinator: ())
        probe.refreshIfVisible()
        XCTAssertTrue(gesture.delegate === original)
        XCTAssertFalse(gesture.isEnabled, "A queued refresh must not reinstall after teardown")
    }

    func testChatInteractiveBackIsScopedToTopChatAndDoesNotBypassSelection() async throws {
        let root = UIViewController()
        let chat = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.setViewControllers([root, chat], animated: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(chat.view.window === window)
        XCTAssertNil(navigation.transitionCoordinator)
        let owner = ChatInteractiveBackSwipeInstaller.Owner()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        owner.install(on: navigation, screen: chat)
        defer { owner.uninstall() }
        XCTAssertTrue(owner.gestureRecognizerShouldBegin(gesture))
        let transcript = UIScrollView(frame: chat.view.bounds)
        chat.view.addSubview(transcript)
        XCTAssertTrue(owner.gestureRecognizer(gesture, shouldBeRequiredToFailBy: transcript.panGestureRecognizer))
        let unrelatedPan = UIPanGestureRecognizer()
        navigation.view.addGestureRecognizer(unrelatedPan)
        XCTAssertFalse(owner.gestureRecognizer(gesture, shouldBeRequiredToFailBy: unrelatedPan))
        XCTAssertFalse(owner.gestureRecognizer(gesture, shouldBeRequiredToFailBy: gesture))

        owner.allowsBackSwipe = false
        XCTAssertFalse(owner.gestureRecognizerShouldBegin(gesture))
        XCTAssertFalse(owner.gestureRecognizer(gesture, shouldBeRequiredToFailBy: transcript.panGestureRecognizer))
        owner.allowsBackSwipe = true
        XCTAssertTrue(owner.gestureRecognizerShouldBegin(gesture))

        navigation.pushViewController(UIViewController(), animated: false)
        XCTAssertFalse(owner.gestureRecognizerShouldBegin(gesture), "An offscreen chat must not handle another screen's swipe")
        let replacement = SystemBackSwipeInstaller.Coordinator()
        gesture.delegate = replacement
        owner.uninstall()
        XCTAssertTrue(gesture.delegate === replacement, "Do not overwrite a subsequent screen's gesture owner")
        navigation.popToRootViewController(animated: false)
        owner.install(on: navigation, screen: chat)
        XCTAssertFalse(owner.gestureRecognizerShouldBegin(gesture))
    }

    func testChatInteractiveBackInstallsInHiddenBarSwiftUINavigationAndSupportsReentry() async throws {
        let probe = LegacyNavigationProbe()
        let host = UIHostingController(rootView: ChatInteractiveNavigationProbeView(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func navigation(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            for child in controller.children {
                if let navigation = navigation(in: child) { return navigation }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let navigation = try XCTUnwrap(navigation(in: host))
        for id in ["first-chat", "second-chat"] {
            probe.route = LegacyNavigationRoute(id: id)
            for _ in 0..<75 {
                if navigation.viewControllers.count == 2, navigation.transitionCoordinator == nil,
                   navigation.interactivePopGestureRecognizer?.delegate is ChatInteractiveBackSwipeInstaller.Owner { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
            let owner = try XCTUnwrap(gesture.delegate as? ChatInteractiveBackSwipeInstaller.Owner)
            XCTAssertEqual(navigation.viewControllers.count, 2)
            XCTAssertTrue(navigation.isNavigationBarHidden)
            XCTAssertTrue(gesture.isEnabled)
            XCTAssertTrue(owner.gestureRecognizerShouldBegin(gesture))

            navigation.popViewController(animated: false)
            for _ in 0..<50 {
                if probe.route == nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNil(probe.route, "Native pop must still synchronize the SwiftUI conversation route")
            XCTAssertEqual(navigation.viewControllers.count, 1)
            XCTAssertFalse(gesture.delegate === owner)
        }
    }
    // WDT_CHAT_EDGE_BACK_FIX_20261102_END

    // WDT_IOS1_CHANGE_COMPAT_20261023_BEGIN
    func testLegacyOnChangeReportsActualPreviousValueAndSkipsInitialRender() async throws {
        let probe = LegacyChangeProbe()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIHostingController(rootView: LegacyChangeProbeView(probe: probe))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(probe.changes.isEmpty)
        probe.value = 2
        try await Task.sleep(nanoseconds: 100_000_000)
        probe.value = 5
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.changes.map { $0.0 }, [0, 2])
        XCTAssertEqual(probe.changes.map { $0.1 }, [2, 5])
    }
    // WDT_IOS1_CHANGE_COMPAT_20261023_END

    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    func testChatMessagePresentationStateIsPerPageAndReleasedWithOwner() {
        var first: ChatMessagePresentationState? = ChatMessagePresentationState()
        weak var weakFirst = first
        let second = ChatMessagePresentationState()
        XCTAssertFalse(first === second)
        first = nil
        XCTAssertNil(weakFirst)
        XCTAssertNil(second.actionMessage)
        print("IOS1_CHAT_VALUE_LAYOUT chat=\(MemoryLayout<ChatView>.size) message=\(MemoryLayout<ChatMessage>.size) old_inline_states=\(8 * MemoryLayout<State<ChatMessage?>>.size) new_state_object=\(MemoryLayout<StateObject<ChatMessagePresentationState>>.size)")
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
}

// WDT_IOS1_CHANGE_COMPAT_20261023_BEGIN
@MainActor
private final class LegacyChangeProbe: ObservableObject {
    @Published var value = 0
    var changes: [(Int, Int)] = []
}
private struct LegacyChangeProbeView: View {
    @ObservedObject var probe: LegacyChangeProbe
    var body: some View {
        Text("\(probe.value)").modifier(LegacyChangeObserver(value: probe.value) { old, new in
            probe.changes.append((old, new))
        })
    }
}
// WDT_IOS1_CHANGE_COMPAT_20261023_END

// WDT_IOS1_NAV_COMPAT_20261023_BEGIN
private struct LegacyNavigationRoute: Identifiable, Hashable { let id: String }
@MainActor
private final class LegacyNavigationProbe: ObservableObject {
    @Published var route: LegacyNavigationRoute?
    var lastAppearedID: String?
}
private struct LegacyNavigationProbeView: View {
    @ObservedObject var probe: LegacyNavigationProbe
    var body: some View {
        NavigationStackCompat {
            Text("root").modifier(ItemNavigationCompatModifier(item: $probe.route) { item in
                Text(item.id).navigationBarBackButtonHidden(true)
                    .onAppear { probe.lastAppearedID = item.id }
            })
        }
    }
}
// WDT_IOS1_NAV_COMPAT_20261023_END

// WDT_CHAT_EDGE_BACK_FIX_20261102_BEGIN
private struct ChatInteractiveNavigationProbeView: View {
    @ObservedObject var probe: LegacyNavigationProbe
    var body: some View {
        NavigationStackCompat {
            Text("conversations").modifier(ItemNavigationCompatModifier(item: $probe.route) { item in
                ScrollView {
                    Text(item.id).frame(maxWidth: .infinity, minHeight: 1200)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in })
                .background(
                    ChatInteractiveBackSwipeInstaller(allowsBackSwipe: true)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                )
                .navigationBarBackButtonHidden(true)
                .navigationBarHidden(true)
            })
        }
    }
}
// WDT_CHAT_EDGE_BACK_FIX_20261102_END
