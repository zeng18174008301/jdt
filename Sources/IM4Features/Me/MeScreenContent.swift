// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum MeSettingsRoute: String, Identifiable, Hashable {
    case notifications
    case security
    case phoneBinding
    case realName
    case devices
    case inbox
    case accountCancellation
    case contactUs
    case about

    public var id: String { rawValue }
}

public struct MeScreenContent<Profile: View, Enterprise: View, InviteCode: View>: View {
    @Binding var route: MeSettingsRoute?
    let phoneBindingSubtitle: String
    let realNameSubtitle: String
    let cachedUnreadAnnouncementCount: Int
    let profile: () -> Profile
    let enterprise: () -> Enterprise
    let inviteCode: () -> InviteCode
    let onReauthenticate: () -> Void
    let onShowCache: () -> Void
    let onShowLogout: () -> Void
    public init(route: Binding<MeSettingsRoute?>, phoneBindingSubtitle: String, realNameSubtitle: String,
                unreadAnnouncementCount: Int, @ViewBuilder profile: @escaping () -> Profile,
                @ViewBuilder enterprise: @escaping () -> Enterprise, @ViewBuilder inviteCode: @escaping () -> InviteCode,
                onReauthenticate: @escaping () -> Void, onShowCache: @escaping () -> Void, onShowLogout: @escaping () -> Void) {
        _route = route; self.phoneBindingSubtitle = phoneBindingSubtitle; self.realNameSubtitle = realNameSubtitle
        self.cachedUnreadAnnouncementCount = unreadAnnouncementCount; self.profile = profile; self.enterprise = enterprise
        self.inviteCode = inviteCode; self.onReauthenticate = onReauthenticate; self.onShowCache = onShowCache; self.onShowLogout = onShowLogout
    }
    public var body: some View {
        ZStack {
    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    profile()
                    enterprise()
                    inviteCode()

                    VStack(spacing: 12) {
                        SettingsRow(symbol: "bell.badge.fill", title: "通知", subtitle: "接收通知消息") {
                            route = .notifications
                        }
                        SettingsRow(symbol: "lock.shield.fill", title: "账号安全", subtitle: "密码、Face ID、登录提醒") {
                            route = .security
                        }
                        SettingsRow(symbol: "arrow.clockwise.circle.fill", title: "重新验证登录", subtitle: "使用当前账号恢复连接，保留本机聊天数据") {
                            onReauthenticate()
                        }
                        SettingsRow(symbol: "iphone.gen3", title: "绑定手机号", subtitle: phoneBindingSubtitle) {
                            route = .phoneBinding
                        }
                        SettingsRow(symbol: "checkmark.seal.fill", title: "实名认证", subtitle: realNameSubtitle) {
                            route = .realName
                        }
                        SettingsRow(symbol: "tray.full.fill", title: "公告收件箱", subtitle: "只查看企业公告内容", badgeCount: cachedUnreadAnnouncementCount) {
                            route = .inbox
                        }
                        SettingsRow(symbol: "person.crop.circle.badge.xmark", title: "注销账号", subtitle: "删除账号资料并退出当前设备", tint: IMColor.danger, titleColor: IMColor.danger) {
                            route = .accountCancellation
                        }
                        SettingsRow(symbol: "externaldrive.fill", title: "缓存", subtitle: "图片、文件与聊天缓存") {
                            onShowCache()
                        }
                        SettingsRow(symbol: "envelope.fill", title: "联系我们", subtitle: "联系邮箱与反馈") {
                            route = .contactUs
                        }
                        SettingsRow(symbol: "info.circle.fill", title: "关于 问达通", subtitle: "版本信息、用户协议和隐私政策") {
                            route = .about
                        }
                    }
                    .im4PlainCard(radius: 24)

                    LogoutButton {
                        onShowLogout()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .im4ScrollBounceBehaviorBasedOnSizeCompat()
        }
    }
}

private struct LogoutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .black))
                Text("退出登录")
                    .font(.system(size: 16, weight: .black))
            }
            .foregroundStyle(IMColor.danger)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(IMColor.danger.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: IMColor.danger.opacity(0.08), radius: 18, y: 8)
            )
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
