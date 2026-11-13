// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct NotificationSettingsContent: View {
    @Binding var enabled: Bool
    let isResolvingNotificationPermission: Bool

    public init(enabled: Binding<Bool>, isResolvingPermission: Bool) {
        _enabled = enabled
        isResolvingNotificationPermission = isResolvingPermission
    }

    public var body: some View {
        Form {
            Toggle("开启通知提醒", isOn: $enabled)
                .disabled(isResolvingNotificationPermission)
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
