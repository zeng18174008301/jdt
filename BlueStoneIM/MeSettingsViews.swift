import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct MeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showEnterpriseSwitcher = false
    @State private var showCacheDialog = false
    @State private var showLogoutConfirm = false
    @State private var showAvatarActions = false
    @State private var showNicknameEditor = false
    @State private var showUsernameEditor = false
    @State private var isLoggingOut = false
    @State private var route: MeSettingsRoute?
    @State private var appPolicyRefreshTask: Task<Void, Never>?
    @State private var appPolicyRefreshGeneration = 0
    @State private var inviteCodeRefreshTask: Task<Void, Never>?
    @State private var inviteCodeRefreshGeneration = 0
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：我的 Tab 入口刷新节流与公告 badge 缓存
    @State private var lastAutomaticMeEntryRefreshAt: Date?
    @State private var cachedUnreadAnnouncementCount = 0
    private let automaticMeEntryRefreshInterval: TimeInterval = 45
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    private var shouldShowMyInviteCodeCard: Bool {
        state.myInviteCode?.shouldHidePersonalInviteModule != true
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    profileCard
                    EnterpriseCard(
                        enterprise: state.currentEnterprise,
                        isSwitchingEnabled: state.canOpenEnterpriseSwitcher(for: state.currentEnterprise)
                    ) {
                        showEnterpriseSwitcher = true
                    }
                    if shouldShowMyInviteCodeCard {
                        MyInviteCodeCard(
                            inviteCode: state.myInviteCode,
                            isLoading: state.isMyInviteCodeLoading,
                            errorMessage: state.myInviteCodeErrorMessage
                        ) { code in
                            UIPasteboard.general.string = code
                            state.toast = "邀请码已复制"
                        } refresh: {
                            startInviteCodeRefresh(force: true)
                        }
                    }

                    VStack(spacing: 12) {
                        SettingsRow(symbol: "bell.badge.fill", title: "通知", subtitle: "接收通知消息") {
                            route = .notifications
                        }
                        SettingsRow(symbol: "lock.shield.fill", title: "账号安全", subtitle: "密码、Face ID、登录提醒") {
                            route = .security
                        }
                        SettingsRow(symbol: "arrow.clockwise.circle.fill", title: "重新验证登录", subtitle: "使用当前账号恢复连接，保留本机聊天数据") {
                            state.beginSessionReauthentication()
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
                            showCacheDialog = true
                        }
                        SettingsRow(symbol: "envelope.fill", title: "联系我们", subtitle: "联系邮箱与反馈") {
                            route = .contactUs
                        }
                        SettingsRow(symbol: "info.circle.fill", title: "关于 问达通", subtitle: "版本信息、用户协议和隐私政策") {
                            route = .about
                        }
                    }
                    .plainCard(radius: 24)

                    LogoutButton {
                        showLogoutConfirm = true
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .scrollBounceBehaviorBasedOnSizeCompat()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $route) { route in
            switch route {
            case .notifications:
                NotificationSettingsView()
            case .security:
                SecuritySettingsView()
            case .phoneBinding:
                PhoneBindingFlowView()
            case .realName:
                RealNameVerificationFlowView()
            case .devices:
                DeviceSessionsView()
            case .inbox:
                InboxCenterView()
            case .accountCancellation:
                AccountCancellationView()
            case .contactUs:
                ContactUsView()
            case .about:
                AboutJianHuiTongView()
            }
        }
        .sheet(isPresented: $showEnterpriseSwitcher) {
            EnterpriseSwitcherView()
                .presentationDetentsCompat([.medium, .large])
        }
        .onAppear {
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：切回我的页时复用近期入口数据，减少重复策略/邀请码请求
            refreshUnreadAnnouncementCountCache()
            startMeEntryRefreshTasksIfNeeded()
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        .onDisappear {
            cancelMeEntryRefreshTasks()
        }
        .onChangeCompat(of: state.currentEnterprise.id) { _, _ in
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：企业切换仍保持即时刷新，不受 Tab 切换节流影响
            lastAutomaticMeEntryRefreshAt = nil
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
            startInviteCodeRefresh(force: true)
        }
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：公告未读只在收件箱变化时重算
        .onReceive(state.contactStore.$inboxItems) { _ in
            refreshUnreadAnnouncementCountCache()
        }
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        .sheet(isPresented: $showNicknameEditor) {
            NicknameEditSheet {
                showNicknameEditor = false
            }
                .presentationDetentsCompat([.height(368)])
                .presentationDragIndicatorCompat(.hidden)
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
        }
        .sheet(isPresented: $showUsernameEditor) {
            UsernameEditSheet {
                showUsernameEditor = false
            }
                .presentationDetentsCompat([.height(384)])
                .presentationDragIndicatorCompat(.hidden)
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
        }
        .sheet(isPresented: $showAvatarActions) {
            AvatarEditSheet()
                .presentationDetentsCompat([.height(340)])
                .presentationDragIndicatorCompat(.hidden)
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
        }
        .alert("清理缓存？", isPresented: $showCacheDialog) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task { await state.clearApplicationCaches() }
            }
        } message: {
            Text("会保留收藏和已下载文件记录。")
        }
        .alert("退出登录？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                performConfirmedLogout()
            }
        } message: {
            Text("退出后将回到登录页，本机登录状态将被清除。")
        }
    }

    private func performConfirmedLogout() {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        showLogoutConfirm = false
        state.logout()
        isLoggingOut = false
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：我的 Tab 自动入口刷新节流与公告 badge 缓存
    private func startMeEntryRefreshTasksIfNeeded() {
        guard !isMeEntryRefreshInFlight else { return }
        let now = Date()
        if hasReusableMeEntryData,
           let lastAutomaticMeEntryRefreshAt,
           now.timeIntervalSince(lastAutomaticMeEntryRefreshAt) < automaticMeEntryRefreshInterval {
            return
        }
        lastAutomaticMeEntryRefreshAt = now
        startMeEntryRefreshTasks()
    }

    private var isMeEntryRefreshInFlight: Bool {
        appPolicyRefreshTask != nil || inviteCodeRefreshTask != nil || state.isMyInviteCodeLoading
    }

    private var hasReusableMeEntryData: Bool {
        state.currentAppPolicy != nil
            && (state.myInviteCode != nil || state.myInviteCodeErrorMessage != nil)
    }

    private func refreshUnreadAnnouncementCountCache() {
        let nextValue = state.inboxItems.reduce(0) { count, item in
            item.isAnnouncement && !item.isRead ? count + 1 : count
        }
        guard cachedUnreadAnnouncementCount != nextValue else { return }
        cachedUnreadAnnouncementCount = nextValue
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    private func startMeEntryRefreshTasks() {
        startAppPolicyRefresh()
        startInviteCodeRefresh(force: true)
    }

    private func cancelMeEntryRefreshTasks() {
        appPolicyRefreshGeneration += 1
        appPolicyRefreshTask?.cancel()
        appPolicyRefreshTask = nil
        inviteCodeRefreshGeneration += 1
        inviteCodeRefreshTask?.cancel()
        inviteCodeRefreshTask = nil
    }

    private func startAppPolicyRefresh() {
        appPolicyRefreshTask?.cancel()
        appPolicyRefreshGeneration += 1
        let generation = appPolicyRefreshGeneration
        appPolicyRefreshTask = Task { @MainActor in
            _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
            guard appPolicyRefreshGeneration == generation else { return }
            appPolicyRefreshTask = nil
        }
    }

    private func startInviteCodeRefresh(force: Bool) {
        inviteCodeRefreshTask?.cancel()
        inviteCodeRefreshGeneration += 1
        let generation = inviteCodeRefreshGeneration
        inviteCodeRefreshTask = Task { @MainActor in
            await state.refreshMyInviteCode(force: force)
            guard inviteCodeRefreshGeneration == generation else { return }
            inviteCodeRefreshTask = nil
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    showAvatarActions = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        AvatarView(name: state.currentUser.name, seed: state.currentUser.avatarSeed, size: 70, imageURL: state.currentUser.avatarURL, avatarVersion: state.currentUser.avatarVersion, avatarUpdatedAt: state.currentUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: state.currentUser.id))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(IMColor.brand))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改头像")

                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFitsCompat(in: .horizontal) {
                        HStack(spacing: 8) {
                            nicknameEditButton
                                .layoutPriority(4)
                            currentDepartmentBadge
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            nicknameEditButton
                            currentDepartmentBadge
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                profileInfoTile(
                    title: "用户ID",
                    value: profileUserNumber,
                    symbol: "number",
                    status: "点击复制",
                    statusColor: IMColor.brand,
                    copyValue: profileUserNumber
                ) {
                    state.copyUserID(profileUserNumber)
                }
                if state.currentUser.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profileInfoTile(
                        title: "用户账号",
                        value: profileUsernameText,
                        symbol: "person.text.rectangle",
                        status: "去设置",
                        statusColor: IMColor.brand
                    ) {
                        showUsernameEditor = true
                    }
                } else {
                    profileInfoTile(
                        title: "用户账号",
                        value: profileUsernameText,
                        symbol: "person.text.rectangle",
                        status: "已设置",
                        statusColor: IMColor.success
                    )
                }
            }
            .padding(.top, 2)
        }
        .glassCard(radius: 28)
    }

    private var nicknameEditButton: some View {
        Button {
            showNicknameEditor = true
        } label: {
            HStack(spacing: 6) {
                Text(state.currentUser.name)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(8)
                CertificationPillView(
                    exactUID: state.currentUser.id,
                    compact: true
                )
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColor.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var currentDepartmentBadge: some View {
        if let department = state.departmentSummary(for: state.currentUser) {
            VerificationPill(
                symbol: "building.2.fill",
                title: department,
                color: IMColor.brand
            )
            .frame(maxWidth: 76, alignment: .leading)
            .layoutPriority(0)
        }
    }

    private var profileUserNumber: String {
        let id = state.currentUser.userID.isEmpty ? state.currentUser.id : state.currentUser.userID
        return id == "u_me" ? "未获取" : id.uppercased()
    }

    private var profileUsernameText: String {
        let username = state.currentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "未设置" : username
    }

    private var phoneBindingSubtitle: String {
        guard !state.currentUser.phone.isEmpty else { return "未绑定" }
        return state.currentUser.phoneVerified ? "\(settingsPhoneDisplayText(state.currentUser.phone)) · 已验证" : "\(settingsPhoneDisplayText(state.currentUser.phone)) · 未验证"
    }

    private var realNameSubtitle: String {
        if state.currentUser.realNameVerified { return "已认证" }
        let status = state.currentUser.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.lowercased() {
        case "pending", "submitted", "reviewing":
            return "审核中"
        case "rejected", "failed", "denied":
            return "认证未通过"
        default:
            return "未认证"
        }
    }

    private func maskedPhone(_ phone: String) -> String {
        settingsPhoneDisplayText(phone)
    }

    @ViewBuilder
    private func profileInfoTile(title: String, value: String, symbol: String, status: String, statusColor: Color, copyValue: String? = nil, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(statusColor.opacity(0.12)))
                    Text(title)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                    Spacer(minLength: 0)
                }
                if let copyValue {
                    CopyableUserIDText(
                        value: copyValue,
                        font: .system(size: 13, weight: .black),
                        color: IMColor.ink
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(value)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(status)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(statusColor.opacity(0.10), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

private enum MeSettingsRoute: String, Identifiable, Hashable {
    case notifications
    case security
    case phoneBinding
    case realName
    case devices
    case inbox
    case accountCancellation
    case contactUs
    case about

    var id: String { rawValue }
}

private struct MyInviteCodeCard: View {
    let inviteCode: RemoteMyInviteCode?
    let isLoading: Bool
    let errorMessage: String?
    let copy: (String) -> Void
    let refresh: () -> Void

    private var presentation: MyInviteCodePresentation {
        MyInviteCodePresentation(
            inviteCode: inviteCode,
            isLoading: isLoading,
            errorMessage: errorMessage
        )
    }

    private var canCopy: Bool {
        presentation.copyValue != nil
    }

    private var statusColor: Color {
        if presentation.isUsableForRegistration { return IMColor.success }
        if presentation.isWarning { return IMColor.warning }
        return IMColor.muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("我的邀请码")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                    Text(presentation.title)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(presentation.subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if let copyValue = presentation.copyValue {
                        copy(copyValue)
                    } else {
                        refresh()
                    }
                } label: {
                    Text(canCopy ? "复制" : "刷新")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(canCopy ? IMColor.brand : IMColor.muted)
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background(Capsule().fill((canCopy ? IMColor.brand : IMColor.muted).opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .opacity(isLoading ? 0.65 : 1)
            }

            if let item = inviteCode?.item, presentation.shouldShowStats {
                HStack(spacing: 8) {
                    inviteStat(title: "邀请", value: item.inviteCount)
                    inviteStat(title: "已加入", value: item.joinedCount)
                    inviteStat(title: "待审批", value: item.pendingCount)
                }
            }
        }
        .glassCard(radius: 24)
    }

    private func inviteStat(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(IMColor.muted)
            Text("\(value)")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.58))
        )
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

private struct AboutJianHuiTongView: View {
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    @EnvironmentObject private var state: AppState
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "问达通"
    }

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "info.circle.fill", title: "关于 问达通", subtitle: "版本信息与协议内容。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            AboutAppMark()
                                // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    state.registerAccessDiagnosticsLogoTap(entry: .loggedInAboutLogo)
                                }
                                // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayName)
                                    .font(.system(size: 21, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("iOS")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 10) {
                            AboutInfoRow(title: "版本", value: versionText)
                        }
                    }
                    .glassCard(radius: 28)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("协议内容")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        LegalDocumentLinksView(prefix: "", style: .settings)
                    }
                    .glassCard(radius: 28)

                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        .onDisappear {
            state.resetAccessDiagnosticsLogoTapSequence(entry: .loggedInAboutLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

}

private struct AboutAppMark: View {
    var body: some View {
        Image("LoginLogo")
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: IMColor.brand.opacity(0.18), radius: 12, y: 6)
    }
}

private struct AboutInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
    }
}

private struct ContactUsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var isRefreshingPolicy = false

    private var policy: RemoteAppCurrentPolicy? {
        state.currentAppPolicy
    }

    private var normalizedEmail: String? {
        SupportContactMailto.normalizedEmail(policy?.supportContactEmail ?? "")
    }

    private var isEmailConfigured: Bool {
        policy?.supportContactConfigured == true && normalizedEmail != nil
    }

    private var statusText: String {
        if isEmailConfigured { return "点击邮箱或发送邮件按钮联系我们。" }
        if state.currentAppPolicyErrorMessage != nil { return "应用策略暂不可用，请稍后重试。" }
        return "暂未配置联系邮箱"
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "envelope.fill", title: "联系我们", subtitle: "通过当前邮箱联系支持团队。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: isEmailConfigured ? "envelope.badge.fill" : "envelope.slash.fill")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(isEmailConfigured ? IMColor.brand : IMColor.muted)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill((isEmailConfigured ? IMColor.brand : IMColor.muted).opacity(0.12)))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(isEmailConfigured ? "联系邮箱" : "暂未配置联系邮箱")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text(statusText)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let email = normalizedEmail, isEmailConfigured {
                            Button {
                                openMail(email)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "at")
                                        .font(.system(size: 15, weight: .black))
                                    Text(email)
                                        .font(.system(size: 16, weight: .black))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.78)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 13, weight: .black))
                                }
                                .foregroundStyle(IMColor.brand)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(IMColor.brand.opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)

                            PrimaryButton(title: "发送邮件", systemImage: "paperplane.fill", disabled: false) {
                                openMail(email)
                            }
                        } else {
                            PrimaryButton(title: isRefreshingPolicy ? "正在刷新..." : "发送邮件", systemImage: "paperplane.fill", disabled: true) {}
                        }
                    }
                    .glassCard(radius: 28)
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .task {
            await refreshPolicy()
        }
    }

    private func refreshPolicy() async {
        guard !isRefreshingPolicy else { return }
        isRefreshingPolicy = true
        _ = await state.refreshCurrentAppPolicyForAuthUI(force: true)
        isRefreshingPolicy = false
    }

    private func openMail(_ email: String) {
        guard let url = SupportContactMailto.mailtoURL(email: email) else {
            state.toast = "联系邮箱不可用"
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            UIPasteboard.general.string = email
            state.toast = "已复制联系邮箱"
        }
    }
}

private struct AccountCancellationView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var showConfirm = false
    @State private var isSubmitting = false

    private let deletionNotice = "注销后将立即删除：用户姓名、手机号、电子邮箱。实名认证信息。用户的设备标识符、绑定关系。用户在 App 内生成的非必要历史记录。"

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(IMColor.danger)
                                .frame(width: 58, height: 58)
                                .background(Circle().fill(IMColor.danger.opacity(0.10)))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("注销账号")
                                    .font(.system(size: 28, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("提交成功后将立即退出当前账号，并清除本机登录状态。")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("重要提醒", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.danger)
                            Text(deletionNotice)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(IMColor.danger.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(IMColor.danger.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(radius: 28)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("注销原因（选填）")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        TextEditor(text: $reason)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(IMColor.ink)
                            .frame(minHeight: 104)
                            .scrollContentBackgroundHiddenCompat()
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.82)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(IMColor.line.opacity(0.72), lineWidth: 1)
                            )
                    }
                    .plainCard(radius: 24)

                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                        } label: {
                            Label("取消注销", systemImage: "xmark")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(IMColor.warning)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.warning.opacity(0.12)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(IMColor.warning.opacity(0.26), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard !isSubmitting else { return }
                            showConfirm = true
                        } label: {
                            Label(isSubmitting ? "提交中" : "确认注销", systemImage: "trash.fill")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认注销账号？", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认注销", role: .destructive) {
                submitCancellation()
            }
        } message: {
            Text("请再次确认。注销成功后将立即退出当前账号。")
        }
    }

    private func submitCancellation() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let success = await state.cancelCurrentAccount(reason: trimmedReason.isEmpty ? nil : trimmedReason)
            isSubmitting = false
            if success {
                dismiss()
            }
        }
    }
}

private struct VerificationPill: View {
    let symbol: String
    let title: String
    var color: Color = IMColor.success

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.11)))
    }
}

private struct NicknameEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var draftName = ""
    @State private var isSaving = false

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    AvatarView(name: draftName.isEmpty ? state.currentUser.name : draftName, seed: state.currentUser.avatarSeed, size: 48, imageURL: state.currentUser.avatarURL, avatarVersion: state.currentUser.avatarVersion, avatarUpdatedAt: state.currentUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: state.currentUser.id))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("修改昵称")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("昵称会显示在个人资料和你发送的消息中")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }

                    Spacer()

                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        dismiss()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FormInput(title: "昵称", placeholder: "请输入昵称", text: $draftName)

                    HStack {
                        Text("建议 2-16 个字符，支持中文、英文和数字")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        Spacer()
                        Text("\(trimmedName.count)/16")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(trimmedName.count > 16 ? IMColor.danger : IMColor.muted)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IMColor.line))
                )

                PrimaryButton(title: isSaving ? "保存中..." : "保存昵称", systemImage: "checkmark", disabled: trimmedName.isEmpty || trimmedName.count > 16 || isSaving) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        let ok = await state.updateCurrentUserProfile(name: trimmedName)
                        await MainActor.run {
                            isSaving = false
                            if ok {
                                onSaved()
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            draftName = state.currentUser.name
        }
    }
}

private struct UsernameEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var draftUsername = ""
    @State private var isSaving = false

    private var trimmedUsername: String {
        draftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidLength: Bool {
        (5...10).contains(trimmedUsername.count)
    }

    private var hasAllowedCharacters: Bool {
        !trimmedUsername.isEmpty && trimmedUsername.allSatisfy { ch in
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }
    }

    private var isValid: Bool {
        hasValidLength && hasAllowedCharacters
    }

    var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置用户账号")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("补充后可用于账号密码登录")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }

                    Spacer()

                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        dismiss()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FormInput(title: "用户账号", placeholder: "5-10 位数字或英文字母", text: $draftUsername, keyboard: .asciiCapable, textContentType: .username)

                    VStack(alignment: .leading, spacing: 6) {
                        usernameRule("长度 5-10 位", ok: hasValidLength)
                        usernameRule("仅支持英文字母或数字", ok: hasAllowedCharacters)
                        usernameRule("企业内唯一，保存后可用于登录", ok: true)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IMColor.line))
                )

                PrimaryButton(title: isSaving ? "保存中..." : "保存账号", systemImage: "checkmark", disabled: !isValid || isSaving) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        let ok = await state.updateCurrentUserProfile(username: trimmedUsername)
                        await MainActor.run {
                            isSaving = false
                            if ok {
                                onSaved()
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            draftUsername = state.currentUser.username
        }
        .onChangeCompat(of: draftUsername) { _, newValue in
            let filtered = filteredUsername(newValue)
            if filtered != newValue {
                draftUsername = filtered
            }
        }
    }

    private func filteredUsername(_ value: String) -> String {
        String(value.filter { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return (65...90).contains(value)
                || (97...122).contains(value)
                || (48...57).contains(value)
        }.prefix(10))
    }

    private func usernameRule(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(ok ? IMColor.success : IMColor.muted)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
    }
}

private struct AvatarEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var showCropper = false

    var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 38, height: 5)
                    .padding(.top, 2)

                HStack(alignment: .center, spacing: 14) {
                    AvatarView(name: state.currentUser.name, seed: state.currentUser.avatarSeed, size: 58, imageURL: state.currentUser.avatarURL, avatarVersion: state.currentUser.avatarVersion, avatarUpdatedAt: state.currentUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: state.currentUser.id))
                        .shadow(color: IMColor.brand.opacity(0.10), radius: 14, y: 8)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("修改头像")
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("选择照片后裁剪为圆形头像")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.72)))
                            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭头像操作")
                }
                .padding(.top, 8)

                Button {
                    showPhotoPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .shadow(color: IMColor.brand.opacity(0.18), radius: 12, y: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("从相册选择")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text("支持 JPG / PNG，上传前可拖动和缩放裁剪")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(IMColor.page.opacity(0.9)))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.white.opacity(0.94))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                            )
                            .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 10)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从相册选择头像")

                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.62))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.75), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                guard let data = items.first?.data,
                      let image = UIImage(data: data) else {
                    state.toast = "无法读取图片"
                    return
                }
                selectedImage = image.normalizedForAvatarCrop()
                showCropper = true
            }
        }
        .sheet(isPresented: $showCropper, onDismiss: resetCropperSelection) {
            if let selectedImage {
                AvatarCropperView(
                    image: selectedImage,
                    onClose: {
                        showCropper = false
                        resetCropperSelection()
                    }
                ) {
                    showCropper = false
                    resetCropperSelection()
                    dismiss()
                }
                .environmentObject(state)
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
                .interactiveDismissDisabled(true)
            }
        }
    }

    private func resetCropperSelection() {
        selectedImage = nil
    }
}

enum AvatarUploadFailurePresentation {
    static func message(for result: AvatarUploadResult) -> String {
        switch result.failureStage ?? .unknown {
        case .presign:
            return "获取头像上传凭证失败，请重试"
        case .put:
            return "头像图片上传失败，请重试"
        case .commit:
            return "保存头像资料失败，请重试"
        case .unknown:
            return "头像上传失败，请稍后再试"
        }
    }
}

enum AvatarCropRenderer {
    static let maximumJPEGByteCount = 2 * 1024 * 1024

    static func croppedJPEG(
        image: UIImage,
        previewSize: CGFloat,
        outputPixelSize: Int,
        scale: CGFloat,
        offset: CGSize,
        scaleRange: ClosedRange<CGFloat> = 1...4
    ) -> Data? {
        guard previewSize > 0, outputPixelSize > 0 else { return nil }
        let normalized = image.normalizedForAvatarCrop()
        let imageSize = normalized.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let safeScale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        let safeOffset = AvatarCropBounds.clampedOffset(
            imageSize: imageSize,
            previewSize: previewSize,
            scale: safeScale,
            proposed: offset
        )
        let baseScale = max(previewSize / imageSize.width, previewSize / imageSize.height)
        let totalScale = max(baseScale * safeScale, 0.0001)
        let cropSide = min(imageSize.width, imageSize.height, previewSize / totalScale)
        var originX = imageSize.width / 2 - safeOffset.width / totalScale - cropSide / 2
        var originY = imageSize.height / 2 - safeOffset.height / totalScale - cropSide / 2
        originX = min(max(originX, 0), imageSize.width - cropSide)
        originY = min(max(originY, 0), imageSize.height - cropSide)
        let sourceScale = normalized.scale
        let cropRect = CGRect(
            x: originX * sourceScale,
            y: originY * sourceScale,
            width: cropSide * sourceScale,
            height: cropSide * sourceScale
        ).integral
        guard let cgImage = normalized.cgImage?.cropping(to: cropRect) else { return nil }
        let cropped = UIImage(cgImage: cgImage, scale: sourceScale, orientation: .up)

        let outputSize = CGSize(width: outputPixelSize, height: outputPixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let square = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            cropped.draw(in: CGRect(origin: .zero, size: outputSize))
        }

        var quality: CGFloat = 0.88
        var data = square.jpegData(compressionQuality: quality)
        while let current = data, current.count > maximumJPEGByteCount, quality > 0.40 {
            quality -= 0.08
            data = square.jpegData(compressionQuality: quality)
        }
        guard let data, data.count <= maximumJPEGByteCount else { return nil }
        return data
    }
}

private struct AvatarCropperView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let onClose: () -> Void
    let onUploaded: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isUploading = false
    @State private var inlineMessage: String?

    private let previewSize: CGFloat = 282
    private let outputSize = 512
    private let scaleRange: ClosedRange<CGFloat> = 1...4

    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { scale },
            set: { updateScale($0, syncGestureBaseline: true) }
        )
    }

    var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 18) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("裁剪头像")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("拖动图片调整位置，双指缩放到合适大小")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button {
                        onClose()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.72)))
                            .overlay(Circle().stroke(IMColor.line.opacity(0.9), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("关闭头像裁剪")
                }

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: previewSize, height: previewSize)
                        .clipShape(Circle())
                        .gesture(dragGesture.simultaneously(with: magnifyGesture))
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: previewSize, height: previewSize)
                        .shadow(color: IMColor.brand.opacity(0.18), radius: 18, y: 8)
                    Circle()
                        .stroke(IMColor.brand.opacity(0.28), lineWidth: 1)
                        .frame(width: previewSize + 8, height: previewSize + 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Slider(value: scaleBinding, in: scaleRange) {
                    Text("缩放")
                }
                .tint(IMColor.brand)

                if let inlineMessage {
                    Text(inlineMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(inlineMessage.contains("成功") ? IMColor.success : IMColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                PrimaryButton(title: isUploading ? "上传中..." : "上传头像", systemImage: "arrow.up.circle.fill", disabled: isUploading) {
                    guard !isUploading else { return }
                    inlineMessage = nil
                    guard let data = croppedAvatarData() else {
                        inlineMessage = "头像裁剪失败，请重新选择图片"
                        return
                    }
                    isUploading = true
                    Task {
                        let result = await state.uploadCurrentUserAvatarResult(
                            imageData: data,
                            mimeType: "image/jpeg",
                            width: outputSize,
                            height: outputSize
                        )
                        isUploading = false
                        if result.success {
                            inlineMessage = "头像上传成功"
                            dismiss()
                            onUploaded()
                        } else {
                            inlineMessage = AvatarUploadFailurePresentation.message(for: result)
                        }
                    }
                }
            }
        }
        .onAppear {
            clampCropState(syncGestureBaseline: true)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, scale: scale)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                updateScale(lastScale * value, syncGestureBaseline: false)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private func updateScale(_ proposedScale: CGFloat, syncGestureBaseline: Bool) {
        let nextScale = AvatarCropBounds.clampedScale(proposedScale, range: scaleRange)
        scale = nextScale
        offset = clampedOffset(offset, scale: nextScale)
        if syncGestureBaseline {
            lastScale = nextScale
            lastOffset = offset
        }
    }

    private func clampCropState(syncGestureBaseline: Bool) {
        scale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        offset = clampedOffset(offset, scale: scale)
        if syncGestureBaseline {
            lastScale = scale
            lastOffset = offset
        }
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        AvatarCropBounds.clampedOffset(
            imageSize: image.normalizedForAvatarCrop().size,
            previewSize: previewSize,
            scale: scale,
            proposed: proposed
        )
    }

    private func croppedAvatarData() -> Data? {
        AvatarCropRenderer.croppedJPEG(
            image: image,
            previewSize: previewSize,
            outputPixelSize: outputSize,
            scale: scale,
            offset: offset,
            scaleRange: scaleRange
        )
    }
}

extension UIImage {
    func normalizedForAvatarCrop() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct ProfileEditSheetSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            content
                .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(0.92))
                .shadow(color: IMColor.brand.opacity(0.16), radius: 28, y: 14)
        )
    }
}

private struct AvatarOptionRow: View {
    let title: String
    let subtitle: String
    let seed: UInt
    let selected: Bool
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: title, seed: seed, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(selected ? IMColor.success : IMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((selected ? IMColor.success : IMColor.brand).opacity(0.10)))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(selected ? 0.98 : 0.84))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(selected ? IMColor.success.opacity(0.36) : IMColor.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct EnterpriseSwitcherDismissalFence {
    private var baselineRevision: UInt64?
    private var consumed = false

    mutating func captureBaseline(_ revision: UInt64) {
        guard baselineRevision == nil else { return }
        baselineRevision = revision
    }

    mutating func consume(successRevision: UInt64) -> Bool {
        guard !consumed,
              let baselineRevision,
              successRevision > baselineRevision else {
            return false
        }
        consumed = true
        return true
    }
}

struct EnterpriseSwitcherView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hasSubmittedSearch = false
    @State private var dismissalFence = EnterpriseSwitcherDismissalFence()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingSearchResults: Bool {
        hasSubmittedSearch && !trimmedQuery.isEmpty
    }

    private var joinedEnterpriseIDs: Set<String> {
        Set(state.enterprises.filter { $0.isWorkspaceJoined }.map(\.id))
    }

    private var displayedEnterprises: [Enterprise] {
        isShowingSearchResults ? state.enterpriseSearchResults : state.enterprises
    }

    private var defaultWorkspace: Enterprise? {
        let defaultID = state.loginDefaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !defaultID.isEmpty else { return nil }
        return state.enterprises.first(where: { $0.id == defaultID })
    }

    private var defaultWorkspaceName: String {
        let defaultID = state.loginDefaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !defaultID.isEmpty else { return "" }
        return defaultWorkspace?.name ?? "已设置的默认企业"
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Capsule()
                                .fill(IMColor.line)
                                .frame(width: 42, height: 5)
                                .frame(maxWidth: .infinity)
                                .padding(.leading, 44)
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.white.opacity(0.78)))
                                    .overlay(Circle().stroke(.white.opacity(0.70), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭企业切换")
                            .accessibilityIdentifier("enterprise_switcher_close_button")
                        }

                        SearchField(text: $query, placeholder: "输入企业编码或邀请码") {
                            hasSubmittedSearch = !trimmedQuery.isEmpty
                            state.searchEnterprises(query: query)
                        }
                        .accessibilityIdentifier("enterprise_search_field")
                        .onChangeCompat(of: query) { _, newValue in
                            let normalized = AuthInputFilter.entryCode().apply(to: newValue)
                            if newValue != normalized, newValue.count <= 11 || newValue.rangeOfCharacter(from: .letters) != nil || newValue.rangeOfCharacter(from: .decimalDigits) != nil {
                                query = normalized
                                return
                            }
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                hasSubmittedSearch = false
                                state.clearEnterpriseSearch()
                            } else {
                                hasSubmittedSearch = false
                                state.clearEnterpriseSearch()
                            }
                        }

                        if !defaultWorkspaceName.isEmpty {
                            HStack(spacing: 12) {
                                if let defaultWorkspace {
                                    EnterpriseLogoView(
                                        enterprise: defaultWorkspace,
                                        size: 34,
                                        cornerRadius: 12,
                                        cacheKey: state.enterpriseLogoCacheKey(for: defaultWorkspace)
                                    )
                                } else {
                                    Image(systemName: "building.2.fill")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(IMColor.brand)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("默认企业")
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(IMColor.muted)
                                    Text(defaultWorkspaceName)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    if let code = defaultWorkspace?.displayCode, !code.isEmpty {
                                        Text("企业码 \(code)")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(IMColor.muted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("清除") {
                                    state.clearDefaultWorkspacePreference()
                                }
                                .font(.system(size: 12, weight: .black))
                                .buttonStyle(.bordered)
                                .tint(IMColor.brand)
                                .accessibilityLabel("清除默认企业")
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(IMColor.card)
                                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                            )
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(isShowingSearchResults ? "搜索结果" : "企业列表")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Spacer()
                                if state.isEnterpriseSearching {
                                    ProgressView()
                                        .tint(IMColor.brand)
                                }
                            }

                            ForEach(displayedEnterprises) { enterprise in
                                let isJoining = state.isEnterpriseJoinInProgress(enterprise)
                                Button {
                                    guard !isJoining else {
                                        state.toast = "正在提交申请，请稍候"
                                        return
                                    }
                                    if !enterprise.isWorkspaceEnterable, !enterprise.workspaceDisabledDescription.isEmpty {
                                        state.toast = enterprise.workspaceDisabledDescription
                                    } else if enterprise.isWorkspaceJoinPending {
                                        state.toast = "入企申请等待审批中"
                                    } else if enterprise.isWorkspaceJoinRejected {
                                        state.toast = "入企申请已被拒绝，请联系企业管理员"
                                    } else if enterprise.isWorkspaceJoinApproved || joinedEnterpriseIDs.contains(enterprise.id) {
                                        state.switchEnterprise(enterprise)
                                    } else {
                                        state.joinEnterprise(enterprise)
                                    }
                                } label: {
                                    EnterpriseMiniCard(
                                        enterprise: enterprise,
                                        selected: enterprise.id == state.currentEnterprise.id,
                                        trailingText: isJoining ? "提交中" : enterpriseWorkspaceStateText(enterprise, joined: joinedEnterpriseIDs.contains(enterprise.id))
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isJoining)
                                .accessibilityIdentifier("enterprise_row_\(enterprise.id)")
                                .accessibilityLabel("企业 \(enterprise.name)")
                            }
                        }

                        if isShowingSearchResults && !state.isEnterpriseSearching && state.enterpriseSearchResults.isEmpty {
                            let identityUnlinked = state.enterpriseSearchMessage == "当前账号企业身份未同步，请联系管理员处理"
                            EmptyStateView(
                                symbol: identityUnlinked ? "person.crop.circle.badge.exclamationmark" : "building.2.crop.circle",
                                title: identityUnlinked ? "企业身份异常" : "搜索无结果",
                                subtitle: state.enterpriseSearchMessage ?? "后台没有匹配的企业，请确认企业编码或邀请码后再搜索。",
                                actionTitle: nil
                            ) {}
                        }

                        if isShowingSearchResults && state.enterpriseSearchResults.count > 1 {
                            PrimaryButton(title: "请选择要加入的企业", systemImage: "list.bullet", disabled: true) {}
                                .accessibilityIdentifier("enterprise_search_pick_result_hint")
                        } else if isShowingSearchResults, let enterprise = state.enterpriseSearchResults.first {
                            let joined = enterprise.isWorkspaceJoinApproved || joinedEnterpriseIDs.contains(enterprise.id)
                            let pending = enterprise.isWorkspaceJoinPending
                            let rejected = enterprise.isWorkspaceJoinRejected
                            let isJoining = state.isEnterpriseJoinInProgress(enterprise)
                            let unavailableReason = enterprise.workspaceDisabledDescription
                            let switchUnavailable = joined && !enterprise.canSwitch
                            let unavailable = (!enterprise.isWorkspaceEnterable && !unavailableReason.isEmpty) || switchUnavailable
                            PrimaryButton(
                                title: unavailable ? (unavailableReason.isEmpty ? "暂不可切换" : unavailableReason) : isJoining ? "正在提交申请..." : pending ? "等待审批" : rejected ? "申请已拒绝" : joined ? (enterprise.isWorkspaceJoinApproved ? "申请已通过，进入 \(enterprise.name)" : "切换到 \(enterprise.name)") : "申请加入 \(enterprise.name)",
                                systemImage: unavailable ? "exclamationmark.triangle.fill" : isJoining ? "hourglass" : pending ? "clock.fill" : rejected ? "xmark.circle.fill" : joined ? "arrow.triangle.2.circlepath" : "plus.circle",
                                disabled: !state.canUseEnterpriseDirectory || pending || rejected || unavailable || isJoining
                            ) {
                                if joined {
                                    state.switchEnterprise(enterprise)
                                } else {
                                    state.joinEnterprise(enterprise)
                                }
                            }
                            .accessibilityIdentifier(joinedEnterpriseIDs.contains(enterprise.id) ? "enterprise_switch_button" : "enterprise_join_button")
                        } else {
                            PrimaryButton(title: trimmedQuery.isEmpty ? "输入企业编码或邀请码搜索" : "点击搜索查询企业", systemImage: "magnifyingglass", disabled: true) {}
                                .accessibilityIdentifier("enterprise_search_disabled_button")
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            dismissalFence.captureBaseline(state.enterpriseSwitchCompletionRevision)
        }
        .onChangeCompat(of: state.enterpriseSwitchCompletionRevision) { _, revision in
            guard dismissalFence.consume(successRevision: revision) else { return }
            dismiss()
        }
        .task {
            await state.refreshCurrentAppPolicyForAuthUI(force: true)
        }
    }

    private func enterpriseWorkspaceStateText(_ enterprise: Enterprise, joined: Bool) -> String {
        let unavailableReason = enterprise.workspaceDisabledDescription
        if !enterprise.isWorkspaceEnterable, !unavailableReason.isEmpty {
            return unavailableReason
        }
        if enterprise.isWorkspaceJoinPending {
            return "等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "已拒绝"
        }
        if enterprise.isWorkspaceJoinApproved {
            return "已通过"
        }
        if joined {
            return enterprise.isWorkspaceEnterable && enterprise.canSwitch ? "已加入" : "不可进入"
        }
        return enterprise.approvalRequired ? "需审批" : "可加入"
    }
}

struct NotificationSettingsView: View {
    @State private var notificationEnabled = false
    @State private var isResolvingNotificationPermission = false
    @State private var notificationPermissionTask: Task<Void, Never>?
    @State private var notificationPermissionGeneration = 0

    var body: some View {
        Form {
            Toggle(
                "开启通知提醒",
                isOn: Binding(
                    get: { notificationEnabled },
                    set: { enabled in
                        handleNotificationToggle(enabled)
                    }
                )
            )
            .disabled(isResolvingNotificationPermission)
        }
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

struct SecuritySettingsView: View {
    @EnvironmentObject private var state: AppState

    private var loginAccountText: String {
        let username = state.currentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "未设置" : username
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "lock.shield.fill", title: "账号安全", subtitle: "管理登录密码、Face ID 与账号登录提醒。")

                    VStack(spacing: 0) {
                        SecurityInfoRow(
                            symbol: "person.text.rectangle.fill",
                            title: "登录账号",
                            value: loginAccountText,
                            copyValue: loginAccountText == "未设置" ? nil : loginAccountText
                        )
                        SecurityDivider()
                        NavigationLink {
                            PasswordSettingsFlowView()
                        } label: {
                            SecurityActionRow(symbol: "key.fill", title: "密码", subtitle: "更新登录密码", value: "已设置")
                        }
                        .buttonStyle(.plain)
                        SecurityDivider()
                        NavigationLink {
                            FaceIDSettingsFlowView()
                        } label: {
                            SecurityActionRow(
                                symbol: "faceid",
                                title: "Face ID",
                                subtitle: "解锁会话和文件预览",
                                value: state.biometricProtectionSettings.enabled ? "已开启" : "未开启"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .securityListCard(radius: 24)

                    VStack(alignment: .leading, spacing: 8) {
                        SecuritySectionTitle("设备与安全")
                        VStack(spacing: 0) {
                            SecurityInfoRow(symbol: "clock.arrow.circlepath", title: "同步窗口", value: "30 天")
                            SecurityDivider()
                            SecurityInfoRow(
                                symbol: "number.circle.fill",
                                title: "设备上限",
                                value: state.tenantDeviceLimitPresentationText
                            )
                        }
                        .securityListCard(radius: 24)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SecuritySectionTitle("登录日志")
                        if state.isLoginLogsLoading && state.loginLogs.isEmpty {
                            ProgressView("正在同步登录日志…")
                                .frame(maxWidth: .infinity, minHeight: 140)
                                .plainCard(radius: 22)
                        } else if state.loginLogsLoadFailed && state.loginLogs.isEmpty {
                            VStack(spacing: 12) {
                                EmptyStateView(symbol: "exclamationmark.shield", title: "登录日志加载失败", subtitle: "请检查网络后重试，现有会话不会受影响。")
                                Button("重新加载") {
                                    Task { await state.refreshLoginLogs() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else if state.loginLogs.isEmpty {
                            EmptyStateView(symbol: "doc.text.magnifyingglass", title: "暂无登录日志", subtitle: "后台同步登录审计后会在这里展示。")
                        } else {
                            VStack(spacing: 12) {
                                ForEach(state.loginLogs) { log in
                                    SecurityLoginLogCard(log: log)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .task {
            await state.refreshLoginLogs()
        }
    }
}

struct PhoneBindingFlowView: View {
    @EnvironmentObject private var state: AppState
    @State private var phone = ""
    @State private var code = ""
    @State private var isSendingCode = false
    @State private var codeCooldown = 0
    @State private var isSubmitting = false

    private var normalizedPhone: String {
        normalizedMainlandPhone(phone)
    }

    private var phoneIsValid: Bool {
        isValidMainlandPhone(normalizedPhone)
    }

    private var canSubmit: Bool {
        phoneIsValid
            && code.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
            && !isSubmitting
            && !state.currentUser.phoneVerified
    }

    private var phoneDisplayText: String {
        let display = settingsPhoneDisplayText(state.currentUser.phone)
        return display == "未绑定" ? "未绑定手机号" : display
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "iphone.gen3", title: "绑定手机号", subtitle: "")

                    PhoneBindingStatusPanel(
                        isVerified: state.currentUser.phoneVerified,
                        phoneText: phoneDisplayText
                    )

                    if !state.currentUser.phoneVerified {
                        phoneBindingForm
                    }

                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            let currentPhone = state.currentUser.phone
            phone = currentPhone.contains("*") || currentPhone.contains("•") ? "" : normalizedMainlandPhone(currentPhone)
            Task { await state.refreshVerificationStatus() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if codeCooldown > 0 {
                codeCooldown -= 1
            }
        }
    }

    private var phoneBindingCaptchaTitle: String {
        if isSendingCode { return "发送中" }
        if codeCooldown > 0 { return "\(codeCooldown)s" }
        return "获取验证码"
    }

    private var phoneBindingForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("绑定信息")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)

            FormInput(title: "手机号", placeholder: "请输入手机号", text: $phone, keyboard: .phonePad)
                .onChangeCompat(of: phone) { _, newValue in
                    let normalized = normalizedMainlandPhone(newValue)
                    if normalized != newValue {
                        phone = normalized
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("验证码")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.muted)
                HStack(spacing: 10) {
                    TextField("请输入验证码", text: $code)
                        .font(.system(size: 16, weight: .bold))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                        .imReadableInputText()
                        .frame(height: 48)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.92))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                        )
                    Button {
                        guard !isSendingCode, codeCooldown == 0, phoneIsValid else { return }
                        isSendingCode = true
                        Task {
                            let cooldown = await state.sendPhoneBindingCode(phone: normalizedPhone)
                            await MainActor.run {
                                isSendingCode = false
                                if let cooldown {
                                    codeCooldown = cooldown
                                }
                            }
                        }
                    } label: {
                        Text(phoneBindingCaptchaTitle)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 104, height: 48)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!phoneIsValid || isSendingCode || codeCooldown > 0)
                    .opacity(phoneIsValid ? (isSendingCode || codeCooldown > 0 ? 0.62 : 1) : 0.45)
                }
            }

            PrimaryButton(title: isSubmitting ? "绑定中..." : "确认绑定", systemImage: "checkmark.shield.fill", disabled: !canSubmit) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task {
                    let ok = await state.verifyPhoneBinding(phone: normalizedPhone, code: code)
                    isSubmitting = false
                    if ok {
                        phone = ""
                        code = ""
                    }
                }
            }
        }
        .glassCard(radius: 28)
    }
}

struct RealNameVerificationFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var realName = ""
    @State private var idNumber = ""
    @State private var fieldError = ""
    @State private var isSubmitting = false

    private var normalizedStatus: String {
        state.currentUser.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canEditRealName: Bool {
        !state.currentUser.realNameVerified && normalizedStatus != "pending"
    }

    private var canSubmit: Bool {
        !realName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !idNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
            && canEditRealName
    }

    private var inlineErrorMessage: String {
        let localMessage = fieldError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localMessage.isEmpty { return localMessage }
        return state.realNameSubmissionErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    RealNameStatusHeroCard(
                        symbol: realNameStatusSymbol,
                        eyebrow: "实名认证",
                        title: realNameStatusTitle,
                        subtitle: realNameStatusSubtitle,
                        color: realNameStatusColor
                    )

                    if canEditRealName {
                        VStack(spacing: 14) {
                            FormInput(title: "真实姓名", placeholder: "请输入真实姓名", text: $realName)
                                .onChangeCompat(of: realName) { _, _ in
                                    fieldError = ""
                                    state.realNameSubmissionErrorMessage = ""
                                }
                            FormInput(title: "身份证号码", placeholder: "请输入15或18位身份证号码", text: $idNumber, keyboard: .asciiCapable)
                                .onChangeCompat(of: idNumber) { _, newValue in
                                    idNumber = RealNameValidator.sanitizedIDNumber(newValue)
                                    fieldError = ""
                                    state.realNameSubmissionErrorMessage = ""
                                }

                            if !inlineErrorMessage.isEmpty {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text(inlineErrorMessage)
                                        .font(.system(size: 13, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(IMColor.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                            }

                            PrimaryButton(title: isSubmitting ? "提交中..." : "提交认证", systemImage: "checkmark.seal.fill", disabled: !canSubmit) {
                                guard !isSubmitting else { return }
                                guard validateFields() else { return }
                                isSubmitting = true
                                Task {
                                    let ok = await state.submitRealNameVerification(realName: realName, idNumber: idNumber)
                                    isSubmitting = false
                                    if ok {
                                        dismiss()
                                    } else if fieldError.isEmpty && state.realNameSubmissionErrorMessage.isEmpty {
                                        fieldError = "实名认证提交失败，请稍后重试"
                                    }
                                }
                            }
                        }
                        .glassCard(radius: 28)
                    }

                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            state.realNameSubmissionErrorMessage = ""
            Task { await state.refreshVerificationStatus() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }

    private func validateFields() -> Bool {
        let normalizedName = realName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = RealNameValidator.sanitizedIDNumber(idNumber)
        if !RealNameValidator.isValidName(normalizedName) {
            fieldError = "请输入有效真实姓名，仅支持2-20位中文字符，可包含“·”。"
            state.toast = "真实姓名格式不正确"
            return false
        }
        if !RealNameValidator.isValidChineseResidentID(normalizedID) {
            fieldError = "请输入有效的15或18位身份证号码，18位末位校验码可为数字或X。"
            state.toast = "身份证号码格式不正确"
            return false
        }
        realName = normalizedName
        idNumber = normalizedID
        fieldError = ""
        return true
    }

    private var realNameStatusSymbol: String {
        if state.currentUser.realNameVerified { return "checkmark.seal.fill" }
        switch normalizedStatus {
        case "pending": return "clock.fill"
        case "rejected": return "exclamationmark.triangle.fill"
        default: return "person.text.rectangle.fill"
        }
    }

    private var realNameStatusTitle: String {
        if state.currentUser.realNameVerified { return "实名已认证" }
        switch normalizedStatus {
        case "pending": return "审核中"
        case "rejected": return "认证未通过"
        default: return "实名未认证"
        }
    }

    private var realNameStatusSubtitle: String {
        if state.currentUser.realNameVerified {
            return "身份信息已通过审核，可用于账号安全校验。"
        }
        switch normalizedStatus {
        case "pending":
            return "已提交认证申请，审核完成后状态会自动更新。"
        case "rejected":
            return "请核对真实姓名与证件号码后重新提交。"
        default:
            return "请填写真实姓名与证件号码完成认证。"
        }
    }

    private var realNameStatusColor: Color {
        if state.currentUser.realNameVerified { return IMColor.success }
        switch normalizedStatus {
        case "pending": return IMColor.brand
        case "rejected": return IMColor.danger
        default: return IMColor.muted
        }
    }
}

private struct RealNameStatusHeroCard: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    Circle()
                        .fill(LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: color.opacity(0.22), radius: 16, x: 0, y: 8)
                )
            VStack(spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.10)))
                Text(title)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.90)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.97), color.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(color.opacity(0.12), lineWidth: 1))
        )
    }
}

private struct PasswordSettingsFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var verified = false
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword.count <= 20
            && newPassword.rangeOfCharacter(from: .letters) != nil
            && newPassword.rangeOfCharacter(from: .decimalDigits) != nil
            && newPassword == confirmPassword
            && verified
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "key.fill", title: "修改密码", subtitle: "修改后新密码将在下次登录时生效。")

                    VStack(spacing: 14) {
                        FormInput(title: "当前密码", placeholder: "请输入当前密码", text: $currentPassword, secure: true, keyboard: .asciiCapable, textContentType: .password)
                        FormInput(title: "新密码", placeholder: "设置 8-20 位新密码", text: $newPassword, secure: true, keyboard: .asciiCapable, textContentType: .newPassword)
                        FormInput(title: "确认新密码", placeholder: "再次输入新密码", text: $confirmPassword, secure: true, keyboard: .asciiCapable, textContentType: .newPassword)
                        SecurityPasswordRequirementHint(password: newPassword, confirmPassword: confirmPassword)
                        SliderVerification(verified: $verified)
                        PrimaryButton(title: isSubmitting ? "保存中..." : "保存密码", systemImage: "checkmark.shield.fill", disabled: !canSubmit || isSubmitting) {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            Task {
                                let saved = await state.changeMyPassword(currentPassword: currentPassword, newPassword: newPassword)
                                await MainActor.run {
                                    isSubmitting = false
                                    if saved {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .glassCard(radius: 28)

                    SecurityHintCard(
                        symbol: "exclamationmark.shield.fill",
                        title: "安全提示",
                        subtitle: "修改密码不会影响已登录设备；如需管理在线端，请联系管理员处理。"
                    )
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }
}

private struct FaceIDSettingsFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BiometricProtectionSettingsDraft(settings: .disabled)
    @State private var sliderVerified = false

    private var hasChanges: Bool {
        draft.hasChanges(comparedTo: state.biometricProtectionSettings)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "faceid", title: "Face ID", subtitle: "用于快速解锁会话、文件预览和敏感操作确认。")

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: "faceid")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.enabled ? "Face ID 已开启" : "Face ID 已关闭")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("用于保护会话、文件预览和敏感操作确认，可随时关闭。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(spacing: 0) {
                            SecurityToggleRow(
                                title: draft.isUpdating ? "正在验证 Face ID" : "启用 Face ID",
                                subtitle: "验证成功后才会开启并保存保护",
                                isOn: Binding(
                                    get: { draft.enabled },
                                    set: { requestEnabledChange($0) }
                                )
                            )
                            .disabled(draft.isUpdating)
                            SecurityDivider()
                            SecurityToggleRow(title: "解锁会话", subtitle: "打开私密会话前验证", isOn: $draft.unlockChats)
                                .opacity(draft.enabled ? 1 : 0.42)
                                .disabled(!draft.enabled || draft.isUpdating)
                            SecurityDivider()
                            SecurityToggleRow(title: "文件预览确认", subtitle: "预览企业文件前验证", isOn: $draft.previewFiles)
                                .opacity(draft.enabled ? 1 : 0.42)
                                .disabled(!draft.enabled || draft.isUpdating)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.82)))

                        SliderVerification(verified: $sliderVerified)

                        Text("先完成滑块验证；开启时会立即显示系统 Face ID 验证，取消或失败不会改变当前设置。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        PrimaryButton(
                            title: draft.isUpdating ? "正在更新" : "保存保护范围",
                            systemImage: "checkmark",
                            disabled: !hasChanges || draft.isUpdating
                        ) {
                            saveDraft()
                        }
                    }
                    .glassCard(radius: 28)
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .onAppear {
            draft.synchronize(with: state.biometricProtectionSettings)
        }
        .onChangeCompat(of: state.biometricProtectionSettings) { _, settings in
            draft.synchronize(with: settings)
        }
    }

    private func requestEnabledChange(_ requestedEnabled: Bool) {
        guard sliderVerified else {
            state.toast = "请先完成滑块验证"
            return
        }
        guard let requested = draft.beginEnabledChange(to: requestedEnabled) else { return }
        Task {
            let succeeded = await state.saveBiometricProtectionSettings(
                enabled: requested.enabled,
                unlockChats: requested.unlockChats,
                previewFiles: requested.previewFiles
            )
            draft.finish(with: state.biometricProtectionSettings)
            if succeeded { sliderVerified = false }
        }
    }

    private func saveDraft() {
        guard sliderVerified else {
            state.toast = "请先完成滑块验证"
            return
        }
        guard let requested = draft.beginSave(comparedTo: state.biometricProtectionSettings) else { return }
        Task {
            let succeeded = await state.saveBiometricProtectionSettings(
                enabled: requested.enabled,
                unlockChats: requested.unlockChats,
                previewFiles: requested.previewFiles
            )
            draft.finish(with: state.biometricProtectionSettings)
            if succeeded { sliderVerified = false }
            if succeeded { dismiss() }
        }
    }
}

private struct SecurityActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            SecurityIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted.opacity(0.65))
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

private struct SecurityInfoRow: View {
    @EnvironmentObject private var state: AppState
    let symbol: String
    let title: String
    let value: String
    var copyValue: String? = nil

    var body: some View {
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
            state.copyUserID(copyValue)
        })
        .accessibilityLabel(copyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制")
    }
}

private struct SecurityToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
        }
        .tint(IMColor.brand)
        .padding(.vertical, 11)
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

private struct SecurityIcon: View {
    let symbol: String
    var tint: Color = IMColor.brand

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Circle().fill(tint.opacity(0.10)))
    }
}

private struct SecurityDivider: View {
    var body: some View {
        Rectangle()
            .fill(IMColor.line)
            .frame(height: 1)
            .padding(.leading, 50)
    }
}

private struct SecuritySectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(IMColor.muted)
            .padding(.horizontal, 4)
            .padding(.top, 0)
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

private struct SecurityPasswordRequirementHint: View {
    let password: String
    let confirmPassword: String

    private var hasLength: Bool {
        password.count >= 8 && password.count <= 20
    }

    private var hasLetterAndNumber: Bool {
        password.rangeOfCharacter(from: .letters) != nil
            && password.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private var isMatched: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("密码格式要求")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(IMColor.ink)
            SecurityRequirementLine(title: "8-20 位字符", passed: hasLength)
            SecurityRequirementLine(title: "至少包含字母和数字", passed: hasLetterAndNumber)
            SecurityRequirementLine(title: "两次输入的密码一致", passed: isMatched)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IMColor.brand.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.brand.opacity(0.10), lineWidth: 1))
        )
    }
}

private struct SecurityRequirementLine: View {
    let title: String
    let passed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(passed ? IMColor.success : IMColor.muted.opacity(0.55))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passed ? IMColor.ink : IMColor.muted)
        }
    }
}

private struct SecurityHintCard: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SecurityIcon(symbol: symbol, tint: IMColor.warning)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .plainCard(radius: 22)
    }
}

private struct VerificationStatusCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .plainCard(radius: 22)
    }
}

private struct PhoneBindingStatusPanel: View {
    let isVerified: Bool
    let phoneText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(isVerified ? IMColor.success : IMColor.brand)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle()
                            .fill((isVerified ? IMColor.success : IMColor.brand).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(isVerified ? "手机号已验证" : "手机号待验证")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(phoneText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(isVerified ? IMColor.ink : IMColor.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Text(isVerified ? "已验证" : "待验证")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(isVerified ? IMColor.success : IMColor.brand)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill((isVerified ? IMColor.success : IMColor.brand).opacity(0.12)))
            }

            HStack(spacing: 12) {
                PhoneBindingInfoTile(title: "认证状态", value: isVerified ? "已通过" : "未完成")
                PhoneBindingInfoTile(title: "绑定手机号", value: phoneText)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(IMColor.line, lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x5D6BFF, alpha: 0.10), radius: 24, y: 12)
        )
    }
}

private struct PhoneBindingInfoTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(IMColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: 0xF6F8FE))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line.opacity(0.82), lineWidth: 1))
        )
    }
}

private func settingsPhoneDisplayText(_ phone: String) -> String {
    maskedPhoneDisplayText(phone, emptyText: "未绑定")
}

struct DeviceSessionsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    SheetHeader(symbol: "iphone.and.arrow.forward", title: "在线设备", subtitle: "管理已登录设备、同步窗口与安全状态。")
                    ForEach(state.deviceSessions) { device in
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
                                    state.toggleDeviceBlocked(device.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .plainCard(radius: 22)
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }
}

struct InboxCenterView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedItem: InboxItem?

    private var filteredItems: [InboxItem] {
        state.inboxItems.filter { $0.isAnnouncement }
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    SheetHeader(symbol: "tray.full.fill", title: "公告收件箱", subtitle: "只展示企业公告内容。")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("公告收件箱，只展示企业公告内容")
                    if filteredItems.isEmpty {
                        EmptyStateView(
                            symbol: "tray",
                            title: "暂无公告",
                            subtitle: "企业公告发布后会在这里展示。"
                        )
                    }
                    ForEach(filteredItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            InboxAnnouncementRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("公告收件箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .sheet(item: $selectedItem) { item in
            AnnouncementDetailSheet(item: item)
                .presentationDetentsCompat([.medium, .large])
                .presentationDragIndicatorCompat(.visible)
                .onAppear {
                    state.markInboxRead(item.id)
                }
        }
    }
}

private struct InboxAnnouncementRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: item.accentHex).opacity(item.isRead ? 0.12 : 0.20))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: item.isRead ? "envelope.open.fill" : "envelope.badge.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: item.accentHex))
                )
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if !item.isRead {
                        Text("未读")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(IMColor.danger))
                    }
                    Spacer()
                    Text(item.time)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                Text(item.subtitle)
                    .font(.system(size: 12, weight: item.isRead ? .medium : .semibold))
                    .foregroundStyle(item.isRead ? IMColor.muted : IMColor.ink.opacity(0.76))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(item.isRead ? IMColor.card : Color(hex: 0xEEF3FF))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(item.isRead ? IMColor.line : Color(hex: item.accentHex).opacity(0.32), lineWidth: 1)
                )
                .shadow(color: Color(hex: item.accentHex, alpha: item.isRead ? 0.04 : 0.10), radius: item.isRead ? 12 : 20, y: item.isRead ? 6 : 10)
        )
    }
}

private struct AnnouncementDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: InboxItem

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(hex: item.accentHex).opacity(0.14))
                        .frame(width: 54, height: 54)
                        .overlay(
                            Image(systemName: "megaphone.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color(hex: item.accentHex))
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("公告详情")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        HStack(spacing: 8) {
                            StatusPill(title: "公告", color: Color(hex: item.accentHex))
                            Text(item.time)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.white.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.45)
                    Text(item.subtitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineSpacing(5)
                        .foregroundStyle(IMColor.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(IMColor.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(IMColor.line, lineWidth: 1)
                        )
                )

                Button {
                    dismiss()
                } label: {
                    Label("我知道了", systemImage: "checkmark")
                        .font(.system(size: 16, weight: .black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(IMColor.brand))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }
}
