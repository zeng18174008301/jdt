// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupMuteContent: View {
    @Binding var isOn: Bool
    let onClose: () -> Void

    public init(isOn: Binding<Bool>, onClose: @escaping () -> Void) {
        _isOn = isOn
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(symbol: "bell.slash.fill", title: "群免打扰", subtitle: isOn ? "该群未读使用灰色标识，不计入底部会话红点。" : "开启后保留未读，但不产生红色提醒。", showsCloseButton: true)
                GroupToggleRow(
                    title: "开启免打扰",
                    subtitle: isOn ? "当前已开启免打扰" : "当前正常接收提醒",
                    isOn: $isOn
                )
                    .im4PlainCard(radius: 24)
                PrimaryButton(title: "完成", systemImage: "checkmark") {
                    onClose()
                }
            }
            .padding(18)
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END
