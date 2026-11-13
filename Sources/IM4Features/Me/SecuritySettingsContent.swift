// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct SecuritySettingsContent<Password: View, FaceID: View, FaceIDLabel: View, DeviceLimit: View, LoginLogSection: View>: View {
    let loginAccountText: String
    let onCopy: @MainActor (String) -> Void
    let password: () -> Password
    let faceID: () -> FaceID
    let faceIDLabel: () -> FaceIDLabel
    let deviceLimit: () -> DeviceLimit
    let loginLog: () -> LoginLogSection

    public init(loginAccountText: String, onCopy: @escaping @MainActor (String) -> Void,
                @ViewBuilder password: @escaping () -> Password, @ViewBuilder faceID: @escaping () -> FaceID,
                @ViewBuilder faceIDLabel: @escaping () -> FaceIDLabel, @ViewBuilder deviceLimit: @escaping () -> DeviceLimit,
                @ViewBuilder loginLog: @escaping () -> LoginLogSection) {
        self.loginAccountText = loginAccountText
        self.onCopy = onCopy
        self.password = password
        self.faceID = faceID
        self.faceIDLabel = faceIDLabel
        self.deviceLimit = deviceLimit
        self.loginLog = loginLog
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "lock.shield.fill", title: "账号安全", subtitle: "管理登录密码、Face ID 与账号登录提醒。")

                    VStack(spacing: 0) {
                        SecurityInfoRowContent(symbol: "person.text.rectangle.fill", title: "登录账号",
                            value: loginAccountText, copyValue: loginAccountText == "未设置" ? nil : loginAccountText,
                            onCopy: onCopy)
                        SecurityDivider()
                        NavigationLink {
                            password()
                        } label: {
                            SecurityActionRow(symbol: "key.fill", title: "密码", subtitle: "更新登录密码", value: "已设置")
                        }
                        .buttonStyle(.plain)
                        SecurityDivider()
                        NavigationLink {
                            faceID()
                        } label: {
                            faceIDLabel()
                        }
                        .buttonStyle(.plain)
                    }
                    .securityListCard(radius: 24)

                    VStack(alignment: .leading, spacing: 8) {
                        SecuritySectionTitle("设备与安全")
                        VStack(spacing: 0) {
                            SecurityInfoRowContent(symbol: "clock.arrow.circlepath", title: "同步窗口", value: "30 天", onCopy: onCopy)
                            SecurityDivider()
                            deviceLimit()
                        }
                        .securityListCard(radius: 24)
                    }

                    loginLog()
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}

public struct SecurityLoginLogContent: View {
    let isLoading: Bool
    let loadFailed: Bool
    let logs: [LoginLog]
    let reload: @MainActor () async -> Void

    public init(isLoading: Bool, loadFailed: Bool, logs: [LoginLog], reload: @escaping @MainActor () async -> Void) {
        self.isLoading = isLoading
        self.loadFailed = loadFailed
        self.logs = logs
        self.reload = reload
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecuritySectionTitle("登录日志")
            if isLoading && logs.isEmpty {
                ProgressView("正在同步登录日志…")
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .im4PlainCard(radius: 22)
            } else if loadFailed && logs.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(symbol: "exclamationmark.shield", title: "登录日志加载失败", subtitle: "请检查网络后重试，现有会话不会受影响。")
                    Button("重新加载") {
                        Task { await reload() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if logs.isEmpty {
                EmptyStateView(symbol: "doc.text.magnifyingglass", title: "暂无登录日志", subtitle: "后台同步登录审计后会在这里展示。")
            } else {
                VStack(spacing: 12) {
                    ForEach(logs) { log in
                        SecurityLoginLogCard(log: log)
                    }
                }
            }
        }
    }
}

public struct SecurityInfoRowContent: View {
    let symbol: String
    let title: String
    let value: String
    var copyValue: String? = nil

    let onCopy: @MainActor (String) -> Void

    public init(symbol: String, title: String, value: String, copyValue: String? = nil, onCopy: @escaping @MainActor (String) -> Void) {
        self.symbol = symbol
        self.title = title
        self.value = value
        self.copyValue = copyValue
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(spacing: 14) {
            SecurityIcon(symbol: symbol)
            Text(title)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(IMColor.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IMColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            guard let copyValue else { return }
            onCopy(copyValue)
        })
        .accessibilityLabel(copyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制")
    }
}

private struct SecurityLoginLogCard: View {
    let log: LoginLog

    var body: some View {
        HStack(spacing: 14) {
            SecurityIcon(symbol: log.result.contains("成功") ? "checkmark.shield.fill" : "exclamationmark.shield.fill", tint: log.result.contains("成功") ? IMColor.success : IMColor.danger)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(log.device) · \(log.result)")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Text("\(log.location) · \(log.time)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
        }
        .frame(minHeight: 58)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IMColor.line, lineWidth: 1))
        )
    }
}

private extension View {
    func securityListCard(radius: CGFloat = 22) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(IMColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(IMColor.line, lineWidth: 1)
                    )
            )
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END
