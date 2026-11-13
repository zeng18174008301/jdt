import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112: Call-screen idle timer coordinator is in CallScreenViews.swift.

@MainActor
enum VideoCallOrientationPolicy {
    static var isVideoCallPresented = false
}

@MainActor
final class BlueStoneApplicationDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		if NotificationSettingsScreenshot.isRequested { return true } // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111
		IMRuntimeColdLaunchLifecycle.shared.beginProcessLaunch()
		UNUserNotificationCenter.current().delegate = self
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: only start the system call layer when this build explicitly enables it.
        if !JHTRuntimeFeatureFlags.disableRTCRuntime,
           SystemCallIntegrationPolicy.usesSystemCallIntegration {
            CallKitPushVoiceCallManager.shared.start()
        }
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
		if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
			_ = IOSNotificationRuntime.shared.handleRemoteNotification(remote, processState: .terminated)
            // JHT_MOD_BEGIN NOTIFICATION_TAP_COLD_LAUNCH_20260917 - 修改开始：冷启动由通知进入时也投递打开会话事件
            if application.applicationState != .background {
                _ = IOSNotificationRuntime.shared.handleNotificationResponse(remote)
            }
            // JHT_MOD_END NOTIFICATION_TAP_COLD_LAUNCH_20260917 - 修改结束
		}
		return true
	}

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !NotificationSettingsScreenshot.isRequested else { return } // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111
        IOSNotificationRuntime.shared.updateStandardToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        guard !NotificationSettingsScreenshot.isRequested else { return } // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111
        IOSNotificationRuntime.shared.invalidateStandardToken()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
        if NotificationSettingsScreenshot.isRequested {
            completionHandler(.noData)
            return
        }
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END
        let state: IOSNotificationProcessState = application.applicationState == .active ? .foregroundVisible : .backgroundAlive
        let action = IOSNotificationRuntime.shared.handleRemoteNotification(userInfo, processState: state)
        completionHandler(action == .ignore ? .noData : .newData)
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if VideoCallOrientationPolicy.isVideoCallPresented || VideoCallScreenshotScenario.requested != nil {
            return .allButUpsideDown
        }
        return .portrait
    }
}

extension BlueStoneApplicationDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let values = sendableNotificationStringValues(notification.request.content.userInfo)
        completionHandler([])
        Task { @MainActor in
            _ = IOSNotificationRuntime.shared.handleRemoteNotification(
                Dictionary(uniqueKeysWithValues: values.map { (AnyHashable($0.key), $0.value as Any) }),
                processState: .foregroundVisible
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let values = sendableNotificationStringValues(response.notification.request.content.userInfo)
        completionHandler()
        Task { @MainActor in
            _ = IOSNotificationRuntime.shared.handleNotificationResponse(
                Dictionary(uniqueKeysWithValues: values.map { (AnyHashable($0.key), $0.value as Any) })
            )
        }
    }

}

private nonisolated func sendableNotificationStringValues(_ userInfo: [AnyHashable: Any]) -> [String: String] {
    var result: [String: String] = [:]
    func append(_ values: [AnyHashable: Any]) {
        for (key, value) in values {
            if let text = value as? String {
                result[String(describing: key)] = text
            } else if let nested = value as? [AnyHashable: Any] {
                append(nested)
            }
        }
    }
    append(userInfo)
    return result
}

enum AccessDiagnosticsOverlayCapability {
    static var isEntryCompiledForCurrentBuild: Bool {
        true
    }

    static func isEntryCompiled(debugBuild _: Bool, internalCapabilityEnabled _: Bool) -> Bool {
        isEntryCompiledForCurrentBuild
    }
}

// WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
@main
struct WenDaTongApp: App { // WDT_IOS1_WENDATONG_TARGET_NAMES_20261113
    @UIApplicationDelegateAdaptor(BlueStoneApplicationDelegate.self) private var applicationDelegate
    @StateObject private var preloginStartup: NotificationSettingsScreenshot.Startup

    init() {
        StableTabBarAppearance.install()
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        #if targetEnvironment(simulator) && DEBUG
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        if !NotificationSettingsScreenshot.isRequested {
            SimulatorAccessEnvironment.ensureDefaultSelection()
        }
        #endif
        _preloginStartup = StateObject(wrappedValue: NotificationSettingsScreenshot.Startup())
    }

    var body: some Scene {
        WindowGroup {
            if let gate = preloginStartup.gate {
                PreloginBootstrapStartupView(gate: gate)
            } else {
                NotificationSettingsScreenshot.Content()
            }
        }
    }
}
// WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END

private struct PreloginBootstrapStartupView: View {
    @ObservedObject var gate: PreloginBootstrapStartupGate
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch gate.state {
            case let .ready(platformBase):
                BlueStoneRuntimeRoot(trustedPlatformBase: platformBase)
            case .resolving:
                PreloginBootstrapStatusView(
                    title: "正在建立安全连接",
                    message: "正在验证服务入口，请稍候。",
                    showsProgress: true,
                    retry: nil
                )
            case .blocked:
                PreloginBootstrapStatusView(
                    title: "安全连接暂不可用",
                    message: "未能验证可信服务入口。请检查网络后重试。",
                    showsProgress: false,
                    retry: gate.retry
                )
            }
        }
        .task {
            await gate.start()
        }
    }
}

private struct BlueStoneRuntimeRoot: View {
    @StateObject private var state: AppState

    init(trustedPlatformBase: URL?) {
        let api: IMAPIClient
        if let trustedPlatformBase {
            api = IMAPIClient(
                platformBase: trustedPlatformBase,
                trustedPreloginPlatformBase: trustedPlatformBase
            )
        } else {
            api = IMAPIClient()
        }
        _state = StateObject(
            wrappedValue: AppState(
                api: api,
                // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: China-review build keeps RTC calls in-app and avoids CallKit singleton initialization.
                voiceCallSystem: JHTRuntimeFeatureFlags.disableRTCRuntime || !SystemCallIntegrationPolicy.usesSystemCallIntegration
                    ? NoopVoiceCallSystemIntegration()
                    : CallKitPushVoiceCallManager.shared
                // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
            )
        )
    }

    var body: some View {
        RootView()
            .appStateEnvironment(state)
    }
}

private struct PreloginBootstrapStatusView: View {
    let title: String
    let message: String
    let showsProgress: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("正在验证安全服务入口")
            } else if let retry {
                Button("安全重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("重新获取并验证可信服务入口")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private enum StableTabBarAppearance {
    @MainActor
    static func install() {
        let normalItemColor = UIColor(red: 0x66 / 255.0, green: 0x70 / 255.0, blue: 0x85 / 255.0, alpha: 0.90)
        let selectedItemColor = UIColor(red: 0x17 / 255.0, green: 0x20 / 255.0, blue: 0x33 / 255.0, alpha: 1)
        let backgroundColor = UIColor.white.withAlphaComponent(0.82)
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = backgroundColor
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.05)

        configure(
            appearance.stackedLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )
        configure(
            appearance.inlineLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )
        configure(
            appearance.compactInlineLayoutAppearance,
            normalItemColor: normalItemColor,
            selectedItemColor: selectedItemColor
        )

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = selectedItemColor
        tabBar.unselectedItemTintColor = normalItemColor
    }

    @MainActor
    private static func configure(
        _ itemAppearance: UITabBarItemAppearance,
        normalItemColor: UIColor,
        selectedItemColor: UIColor
    ) {
        let normalTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: normalItemColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        let selectedTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: selectedItemColor,
            .font: UIFont.systemFont(ofSize: 11, weight: .bold)
        ]
        itemAppearance.normal.iconColor = normalItemColor
        itemAppearance.normal.titleTextAttributes = normalTitleAttributes
        itemAppearance.selected.iconColor = selectedItemColor
        itemAppearance.selected.titleTextAttributes = selectedTitleAttributes
        itemAppearance.disabled.iconColor = normalItemColor.withAlphaComponent(0.45)
        itemAppearance.disabled.titleTextAttributes = [
            .foregroundColor: normalItemColor.withAlphaComponent(0.45),
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        itemAppearance.normal.badgeBackgroundColor = UIColor(red: 0xFF / 255.0, green: 0x5D / 255.0, blue: 0x73 / 255.0, alpha: 1)
        itemAppearance.selected.badgeBackgroundColor = itemAppearance.normal.badgeBackgroundColor
    }
}

@MainActor
private final class IncomingCallOverlayWindowCoordinator {
    static let shared = IncomingCallOverlayWindowCoordinator()

    private var overlayWindow: UIWindow?
    private weak var boundScene: UIWindowScene?

    func update(call: IncomingVoiceCall?, state: AppState, scenePhase: ScenePhase) {
        let showsCapabilityAlert = state.rtcCapabilityAlertMessage != nil
        guard scenePhase == .active, call != nil || showsCapabilityAlert else {
            hide()
            return
        }
        guard let scene = activeWindowScene() else { return }
        if call != nil {
            // Dismiss the underlying keyboard without clearing its draft. The
            // incoming window must cover a composing page as well as idle pages.
            scene.windows.first(where: { $0.isKeyWindow })?.endEditing(true)
        }
        if boundScene !== scene || overlayWindow == nil {
            hide()
            let window = UIWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.windowLevel = .alert + 1
            let controller = UIHostingController(
                rootView: IncomingCallGlobalWindowView().appStateEnvironment(state)
            )
            controller.view.backgroundColor = .clear
            controller.view.accessibilityViewIsModal = true
            window.rootViewController = controller
            overlayWindow = window
            boundScene = scene
        }
        // One opaque, modal window covers normal pages and already-presented sheets.
        // Keep the existing scene/lifecycle authority; do not compete with call covers.
        overlayWindow?.rootViewController?.view.accessibilityViewIsModal = true
        overlayWindow?.frame = scene.coordinateSpace.bounds
        overlayWindow?.isHidden = false
    }

    func hide() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
        boundScene = nil
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
    }
}

private struct IncomingCallGlobalWindowView: View {
    @EnvironmentObject private var state: AppState
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
    @EnvironmentObject private var callStore: CallStore

    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.rtcCapabilityAlertStore.observe { message in
            windowContent(capabilityMessage: message)
        }
    }
    // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_END

    private func windowContent(capabilityMessage: String?) -> some View { // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
        GeometryReader { _ in
            if let message = capabilityMessage { // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 20) {
                        Text("通话提示")
                            .font(.headline)
                        Text(message)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("rtc_capability_alert_message")
                        Button("知道了") {
                            state.rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("rtc_capability_alert_dismiss")
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .systemBackground)))
                    .padding(.horizontal, 24)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rtc_capability_alert")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let call = callStore.incomingVoiceCall {
                    IncomingCallScreen(call: call)
                        .id(call.id)
                        .environment(\.avatarImageRouteContext, state.avatarImageRouteContext)
                        .accessibilityIdentifier("incoming_call_global_overlay")
                }
            }
        }
    }
}

// WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
private extension SplashOverlayStore {
    @MainActor
    func observe<Value: Equatable, Content: View>(
        _ project: @escaping (Snapshot) -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        PublisherSnapshotView(initialValue: project(snapshot), updates: updates(project), content: content)
    }
}
// WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END

// WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110: forced-auth presentation bindings are in AuthViews.swift.

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112_BEGIN
    #if DEBUG
    private var mountsNormalContentForTesting = false

    init() {}

    init(mountingNormalContentForTesting: Bool) {
        mountsNormalContentForTesting = mountingNormalContentForTesting
    }
    #endif
    // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112_END
    @ObservedObject private var accessDiagnostics = AccessDiagnostics.shared
    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
    @State private var observedCalls: CallStore.RootPresentation?
    @State private var observedLaunch: BootstrapPresentationStore.Launch? // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110

    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.authenticationPresentationStore.observeAuthentication { authenticated in
            rootContent(authenticated: authenticated)
        }
    }

    // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END
    private func rootContent(authenticated: Bool) -> some View {
        let calls = observedCalls ?? state.callStore.rootPresentation
        let launch = observedLaunch ?? state.bootstrapPresentationStore.launch // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END
        // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112_BEGIN
        #if DEBUG
        let notificationSettingsScreenshotRequested = !mountsNormalContentForTesting && NotificationSettingsScreenshot.isRequested
        #else
        let notificationSettingsScreenshotRequested = false
        let mountsNormalContentForTesting = false
        #endif
        // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112_END
        return GeometryReader { proxy in
            ZStack {
                if notificationSettingsScreenshotRequested {
                    NavigationStackCompat {
                        NotificationSettingsView()
                    }
                } else if let videoScenario = VideoCallScreenshotScenario.requested {
                    VideoCallScreenshotHost(scenario: videoScenario)
                        .environmentObject(state)
                } else if launch.isShowingLaunchSplash { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                    SessionRestoreView()
                        .transition(.opacity)
                } else if let groupLifecycleScenario = state.groupLifecycleScreenshotScenario {
                    GroupLifecycleScreenshotHost(scenario: groupLifecycleScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let groupHistoryScenario = state.groupHistoryVisibilityScreenshotScenario {
                    GroupHistoryVisibilityScreenshotHost(scenario: groupHistoryScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let globalPolicyScenario = state.globalPolicyScreenshotScenario {
                    GlobalPolicyScreenshotHost(scenario: globalPolicyScenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if let avatarStage4Scenario = state.avatarStage4ScreenshotScenario {
                    AvatarStage4ScreenshotHost(scenario: avatarStage4Scenario)
                        .environmentObject(state)
                        .transition(.opacity)
                } else if authenticated { // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                    // WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_BEGIN
                    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
                    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
                    state.sessionReauthenticationStore.observe(\.isPresented) { isPresented in
                        state.observeDepartmentAvailability { departmentEnabled in
                            MainShellView(
                                selection: state.mainTabSelection,
                                contactsTitle: departmentEnabled ? "伙伴" : MainTab.contacts.title,
                                conversationStore: state.conversationStore,
                                contactStore: state.contactStore,
                                onShellAppear: state.noteMainShellAppeared,
                                // WDT_IOS1_PRODUCTION_ROOT_FIXTURE_20261112
                                updateApplicationBadge: mountsNormalContentForTesting ? { _ in } : IOSNotificationRuntime.shared.updateApplicationBadge
                            )
                        }
                        .allowsHitTesting(!isPresented)
                        .accessibilityHidden(isPresented)
                    }
                    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
                    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
                    // WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_END
                        .transition(.move(edge: .trailing).combined(with: .opacity))

                    // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
                    if let call = calls.minimizedVideoCall {
                        VStack {
                            MinimizedVideoCallBar(session: call)
                            Spacer()
                        }
                        .padding(.top, max(proxy.safeAreaInsets.top, 0))
                        .zIndex(28)
                    }
                } else {
                    AuthRootView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_BEGIN
                if VideoCallScreenshotScenario.requested == nil {
                    state.toastPresentationStore.observe { toast in
                        if let toast {
                            VStack {
                                Spacer()
                                Text(toast)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 11)
                                    .background(Capsule().fill(Color.black.opacity(0.78)))
                                    .padding(.bottom, 18)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .zIndex(20)
                }
                // WDT_IOS1_REFACTOR_TOAST_OBSERVATION_20261110_END

                // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
                state.sessionReauthenticationStore.observe(\.presentationID) { presentationID in
                    if let presentationID {
                        SessionReauthenticationView(presentationID: presentationID)
                            .environmentObject(state)
                            .id(presentationID)
                    }
                }
                .zIndex(40)
                // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END

                // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_BEGIN
                state.slideCaptchaPresentationStore.observe { challenge in
                    if let challenge {
                        IOSSlideCaptchaVerificationOverlay(
                            presentationStore: state.slideCaptchaPresentationStore,
                            challenge: challenge
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .zIndex(50)
                // WDT_IOS1_REFACTOR_SLIDE_CAPTCHA_OBSERVATION_20261110_END

                if accessDiagnostics.isVisible {
                    AccessDebugOverlayHost(
                        diagnostics: accessDiagnostics,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .zIndex(35)
                }

                Color.clear // WDT_IOS1_NAV_COMPAT_20261023: navigation container owns the system gesture.
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
                state.splashOverlayStore.observe({ $0.presentation != nil }) { isPresented in
                    TabBarVisibilityController(isHidden: authenticated && isPresented) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END

                IOSRiskTelemetryWindowSceneInstaller { windowScene in
                    state.iosRiskTelemetryBind(windowScene: windowScene)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
                if authenticated { // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
                    state.splashOverlayStore.observe({ $0 }) { overlay in
                        if let splash = overlay.presentation {
                            SplashOverlay(
                                presentation: splash,
                                remainingSeconds: overlay.remainingSeconds,
                                canSkip: overlay.canSkip,
                                onSkip: {
                                    state.dismissSplashOverlay()
                                }
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.all)
                            .transition(.opacity)
                        }
                    }
                    .zIndex(90)
                }
                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: authenticated) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: launch.isRestoringSession)
            .animation(.easeOut(duration: 0.28), value: launch.isShowingLaunchSplash)
            .onReceive(state.bootstrapPresentationStore.$launch) { updated in
                if updated != observedLaunch { observedLaunch = updated }
            }
            // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
            .onReceive(state.callStore.rootPresentationUpdates) { updated in
                if updated != observedCalls { observedCalls = updated }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: calls.incoming)
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_BEGIN
            .fullScreenCover(item: Binding(
                get: { state.presentedCallSession },
                set: { state.presentedCallSession = $0 }
            )) { session in
                if session.isVideoCall {
                    VideoCallScreen(session: session)
                        .environmentObject(state)
                } else {
                    VoiceCallScreen(session: session)
                        .environmentObject(state)
                }
            }
            .fullScreenCover(item: Binding(
                get: { calls.preview },
                set: { state.videoCallPreview = $0 }
            )) { preview in
                VideoCallPreviewScreen(preview: preview)
                    .environmentObject(state)
            }
            .fullScreenCover(item: Binding(
                get: { calls.terminalResult },
                set: { state.videoCallTerminalResult = $0 }
            )) { result in
                VideoCallTerminalResultScreen(result: result)
                    .environmentObject(state)
            }
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110_END
            .modifier(ForcedAppPolicyAuthPresentationModifier(state: state)) // WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110
            .task {
                RTCCallIdleTimerCoordinator.shared.update(activeCallID: state.activeVoiceCall?.id)
                // WDT_IOS1_COLD_RESTORE_INITIAL_SCENE_ENTRY_20261111_BEGIN
                state.appInitialSceneDidBecomeAvailable(isActive: scenePhase == .active)
                // WDT_IOS1_COLD_RESTORE_INITIAL_SCENE_ENTRY_20261111_END
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: state.incomingVoiceCall,
                    state: state,
                    scenePhase: scenePhase
                )
                if scenePhase == .active, !shouldSuppressNotificationPermissionRequestForTestScenario {
                    await IOSNotificationPermissionCoordinator.shared.sceneDidBecomeActive()
                }
            }
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
            .onChangeCompat(of: calls.incoming) { _, call in
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: call,
                    state: state,
                    scenePhase: scenePhase
                )
            }
            // WDT_IOS1_REFACTOR_CALL_OBSERVATION_20261110
            .onChangeCompat(of: calls.activeCallID) { _, activeCallID in
                RTCCallIdleTimerCoordinator.shared.update(activeCallID: activeCallID)
            }
            // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_BEGIN
            .background {
                state.rtcCapabilityAlertStore.observe { message in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .onChangeCompat(of: message) { _, _ in
                            IncomingCallOverlayWindowCoordinator.shared.update(
                                call: state.incomingVoiceCall,
                                state: state,
                                scenePhase: scenePhase
                            )
                        }
                }
            }
            // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110_END
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                state.iosRiskScreenshotDetected()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                // Telemetry is deliberately silent: this callback only refreshes the bound
                // session and queues a content-free fact. Do not add toast, alert, haptics,
                // sound, local notification, or any other screenshot-time user feedback here.
                state.iosRiskScreenshotDetected()
            }
            .onChangeCompat(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    state.appDidEnterForeground()
                    state.handleVideoApplicationWillEnterForeground()
                    if !shouldSuppressNotificationPermissionRequestForTestScenario {
                        Task {
                            await IOSNotificationPermissionCoordinator.shared.sceneDidBecomeActive()
                        }
                    }
                case .inactive:
                    state.appDidBecomeInactive()
                case .background:
                    state.appDidEnterBackground()
                    state.handleVideoApplicationDidEnterBackground()
                @unknown default:
                    state.appDidBecomeInactive()
                }
                IncomingCallOverlayWindowCoordinator.shared.update(
                    call: state.incomingVoiceCall,
                    state: state,
                    scenePhase: phase
                )
            }
            .onDisappear {
                IncomingCallOverlayWindowCoordinator.shared.hide()
                RTCCallIdleTimerCoordinator.shared.reset()
            }
            .onReceive(Timer.publish(every: 45, on: .main, in: .common).autoconnect()) { _ in
                guard scenePhase == .active else { return }
                Task {
                    _ = await state.refreshCurrentAppPolicyAndDepartmentRuntime(reason: "active_timer", force: true)
                    await state.refreshCurrentEnterpriseProfile(silent: true)
                }
            }
        }
        .environment(\.avatarImageRouteContext, state.avatarImageRouteContext)
    }

    private var shouldSuppressNotificationPermissionRequestForTestScenario: Bool {
        #if DEBUG
        if VideoCallScreenshotScenario.requested != nil
            || ProcessInfo.processInfo.arguments.contains("--notification-settings-screenshot")
            || ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("--auth-policy-screenshot=")
                || $0.hasPrefix("--avatar-stage4-screenshot=")
                || $0.hasPrefix("--group-lifecycle-screenshot=")
                || $0.hasPrefix("--group-history-screenshot=")
                || $0.hasPrefix("--global-policy-screenshot=")
                || $0.hasPrefix("--license-quota-screenshot=")
                || $0.hasPrefix("--registration-resolution-screenshot=")
            }) {
            return true
        }
        #endif
        return false
    }
}
