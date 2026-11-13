import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
enum NotificationSettingsScreenshot {
    static let isRequested: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--notification-settings-screenshot")
        #else
        return false
        #endif
    }()

    @MainActor
    final class Startup: ObservableObject {
        let gate: PreloginBootstrapStartupGate? = NotificationSettingsScreenshot.isRequested
            ? nil
            : PreloginBootstrapStartupGate(plan: PreloginBootstrapStartupConfiguration.load())
    }

    struct Content: View {
        var body: some View {
            #if DEBUG
            GeometryReader { _ in
                ZStack {
                    NavigationStackCompat {
                        NotificationSettingsView(readOnly: true)
                    }
                }
            }
            #else
            EmptyView()
            #endif
        }
    }
}
// WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END

struct NotificationSettingsView: View {
    @State private var notificationEnabled = false
    @State private var isResolvingNotificationPermission = false
    @State private var notificationPermissionTask: Task<Void, Never>?
    @State private var notificationPermissionGeneration = 0

    // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
    #if DEBUG
    private let readOnly: Bool

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
    }
    #endif
    // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END

    var body: some View {
        // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_BEGIN
        NotificationSettingsContent(enabled: Binding(get: { notificationEnabled }, set: { value in handleNotificationToggle(value) }),
            isResolvingPermission: isResolvingNotificationPermission)
        // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_END
        .onAppear {
            scheduleNotificationPermissionRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            scheduleNotificationPermissionRefresh()
        }
        .onDisappear {
            cancelNotificationPermissionRefresh()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }

    private func scheduleNotificationPermissionRefresh() {
        notificationPermissionTask?.cancel()
        notificationPermissionGeneration += 1
        let generation = notificationPermissionGeneration
        notificationPermissionTask = Task { @MainActor in
            await refreshNotificationPermission()
            guard notificationPermissionGeneration == generation else { return }
            notificationPermissionTask = nil
        }
    }

    private func cancelNotificationPermissionRefresh() {
        notificationPermissionGeneration += 1
        notificationPermissionTask?.cancel()
        notificationPermissionTask = nil
    }

    @MainActor
    private func handleNotificationToggle(_ enabled: Bool) {
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_BEGIN
        #if DEBUG
        guard !readOnly else { return }
        #endif
        // WDT_IOS1_NOTIFICATION_SCREENSHOT_SAFE_ENTRY_20261111_END
        if enabled {
            Task { await enableNotificationPermissionIfNeeded() }
        } else {
            openAppNotificationSettings()
        }
    }

    @MainActor
    private func refreshNotificationPermission() async {
        let status = await IOSNotificationPermissionCoordinator.shared.currentStatus()
        notificationEnabled = status.permitsRemoteNotificationRegistration
    }

    @MainActor
    private func enableNotificationPermissionIfNeeded() async {
        guard !isResolvingNotificationPermission else { return }
        isResolvingNotificationPermission = true
        defer { isResolvingNotificationPermission = false }

        let initialStatus = await IOSNotificationPermissionCoordinator.shared.currentStatus()
        if initialStatus == .denied || initialStatus == .unknown {
            notificationEnabled = false
            openAppNotificationSettings()
            return
        }
        let resolvedStatus = await IOSNotificationPermissionCoordinator.shared.requestFromUserGestureIfNeeded()
        notificationEnabled = resolvedStatus.permitsRemoteNotificationRegistration
    }

    @MainActor
    private func openAppNotificationSettings() {
        let settingsURLString: String
        if #available(iOS 16.0, *) {
            settingsURLString = UIApplication.openNotificationSettingsURLString
        } else {
            settingsURLString = UIApplication.openSettingsURLString
        }
        guard let url = URL(string: settingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
