// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct DeviceSessionsContent: View {
    let sessions: [DeviceSession]
    let toggleBlocked: @MainActor (String) -> Void

    public init(sessions: [DeviceSession], toggleBlocked: @escaping @MainActor (String) -> Void) {
        self.sessions = sessions
        self.toggleBlocked = toggleBlocked
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    SheetHeader(symbol: "iphone.and.arrow.forward", title: "在线设备", subtitle: "管理已登录设备、同步窗口与安全状态。")
                    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110
                    ForEach(sessions) { device in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: device.platform == "iOS" ? "iphone" : device.platform == "Web" ? "globe" : "desktopcomputer")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(device.isBlocked ? IMColor.danger : IMColor.brand)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill((device.isBlocked ? IMColor.danger : IMColor.brand).opacity(0.10)))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                    Text("\(device.platform) · \(device.lastSeen)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(IMColor.muted)
                                }
                                Spacer()
                                StatusPill(title: device.status, color: device.isBlocked ? IMColor.danger : IMColor.success)
                            }
                            HStack {
                                StatusPill(title: device.isBound ? "已绑定" : "未绑定", color: device.isBound ? IMColor.success : IMColor.muted)
                                Spacer()
                                Button(device.isBlocked ? "解除封禁" : "封禁设备") {
                                    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110
                                    toggleBlocked(device.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .im4PlainCard(radius: 22)
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
