import Combine // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110
import PhotosUI
import SwiftUI
import IM4Features
import UIKit
import UserNotifications

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct MeView: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

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

    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_BEGIN
    private var observedMyInviteCodeCard: some View {
        let store = state.inviteCodeStore
        return PublisherSnapshotView(
            initialValue: store.snapshot,
            updates: store.$snapshot.eraseToAnyPublisher()
        ) { snapshot in
            if snapshot.code?.shouldHidePersonalInviteModule != true {
                MyInviteCodeCard(
                    inviteCode: snapshot.code,
                    isLoading: snapshot.isLoading,
                    errorMessage: snapshot.errorMessage
                ) { code in
                    UIPasteboard.general.string = code
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("邀请码已复制")
                } refresh: {
                    startInviteCodeRefresh(force: true)
                }
            }
        }
    }
    // WDT_IOS1_REFACTOR_PERSONAL_INVITE_CODE_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
    var body: some View {
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates({ $0 })) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        state.enterpriseMembershipStore.observe(\.current) { enterprise in meContent(enterprise: enterprise) }
    }

    private func meContent(enterprise: Enterprise) -> some View {
        MeScreenContent(route: $route, phoneBindingSubtitle: phoneBindingSubtitle, realNameSubtitle: realNameSubtitle,
            unreadAnnouncementCount: cachedUnreadAnnouncementCount, profile: { profileCard }, enterprise: {
                state.appPolicyPresentationStore.observe(\.workspaceSwitchDisabled) { _ in
                    EnterpriseCard(enterprise: enterprise, isSwitchingEnabled: state.canOpenEnterpriseSwitcher(for: enterprise)) {
                        showEnterpriseSwitcher = true
                    }
                }
            }, inviteCode: { observedMyInviteCodeCard }, onReauthenticate: { state.beginSessionReauthentication() },
            onShowCache: { showCacheDialog = true }, onShowLogout: { showLogoutConfirm = true })
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
                // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110
                DeviceSessionsView(store: state.contactStore, toggleBlocked: state.toggleDeviceBlocked)
            case .inbox:
                // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110
                InboxCenterView(store: state.contactStore, markRead: state.markInboxRead)
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
        .onChangeCompat(of: enterprise.id) { _, _ in // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：企业切换仍保持即时刷新，不受 Tab 切换节流影响
            lastAutomaticMeEntryRefreshAt = nil
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
            startInviteCodeRefresh(force: true)
        }
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：公告未读只在收件箱变化时重算
        // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.announcementUpdates) { announcements in
            refreshUnreadAnnouncementCountCache(from: announcements)
        }
        // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END
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

    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    private func refreshUnreadAnnouncementCountCache(from announcements: [InboxItem]? = nil) {
        let nextValue = (announcements ?? state.contactStore.announcements).reduce(0) { $0 + ($1.isRead ? 0 : 1) }
        guard cachedUnreadAnnouncementCount != nextValue else { return }
        cachedUnreadAnnouncementCount = nextValue
    }
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END
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
        MeProfileCardContent(displayName: renderedCurrentUser.name,
            usernameIsEmpty: renderedCurrentUser.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            userNumber: profileUserNumber, usernameText: profileUsernameText, avatar: {
                AvatarView(name: renderedCurrentUser.name, seed: renderedCurrentUser.avatarSeed, size: 70,
                    imageURL: renderedCurrentUser.avatarURL, avatarVersion: renderedCurrentUser.avatarVersion,
                    avatarUpdatedAt: renderedCurrentUser.avatarUpdatedAt,
                    certificationReference: state.certificationPillSource.reference(forExactUID: renderedCurrentUser.id))
            }, certification: { CertificationPillView(exactUID: renderedCurrentUser.id, compact: true) },
            department: { currentDepartmentBadge }, onEditAvatar: { showAvatarActions = true },
            onEditNickname: { showNicknameEditor = true }, onEditUsername: { showUsernameEditor = true }, onCopyUserID: state.copyUserID)
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    private var currentDepartmentBadge: some View {
        state.observeDepartmentSummary(for: renderedCurrentUser) { department in
            if let department {
                VerificationPill(
                    symbol: "building.2.fill",
                    title: department,
                    color: IMColor.brand
                )
                .frame(maxWidth: 76, alignment: .leading)
                .layoutPriority(0)
            }
        }
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

    private var profileUserNumber: String {
        let id = renderedCurrentUser.userID.isEmpty ? renderedCurrentUser.id : renderedCurrentUser.userID
        return id == "u_me" ? "未获取" : id.uppercased()
    }

    private var profileUsernameText: String {
        let username = renderedCurrentUser.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "未设置" : username
    }

    private var phoneBindingSubtitle: String {
        guard !renderedCurrentUser.phone.isEmpty else { return "未绑定" }
        return renderedCurrentUser.phoneVerified ? "\(settingsPhoneDisplayText(renderedCurrentUser.phone)) · 已验证" : "\(settingsPhoneDisplayText(renderedCurrentUser.phone)) · 未验证"
    }

    private var realNameSubtitle: String {
        if renderedCurrentUser.realNameVerified { return "已认证" }
        let status = renderedCurrentUser.realNameStatus.trimmingCharacters(in: .whitespacesAndNewlines)
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


}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private typealias MeSettingsRoute = IM4Features.MeSettingsRoute
private typealias VerificationPill = IM4Features.VerificationPill

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

    var body: some View {
        let p = presentation
        MyInviteCodeCardContent(presentation: MeInviteCodePresentation(title: p.title, subtitle: p.subtitle,
            copyValue: p.copyValue, isUsableForRegistration: p.isUsableForRegistration, isWarning: p.isWarning,
            shouldShowStats: p.shouldShowStats), counts: inviteCode?.item.map { item in
                return
                MeInviteCodeCounts(inviteCount: item.inviteCount, joinedCount: item.joinedCount, pendingCount: item.pendingCount)
            }, isLoading: isLoading, copy: copy, refresh: refresh)
    }
}
