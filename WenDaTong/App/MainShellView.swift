import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox
import CryptoKit

// WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_BEGIN
@MainActor
struct MainShellView: View {
    let selection: MainTabSelectionState
    let contactsTitle: String
    let conversationStore: ConversationStore
    let contactStore: ContactStore
    let onShellAppear: () -> Void
    let updateApplicationBadge: (Int) -> Void
    @State private var publishedUnreadTotal: Int? = nil
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：Tab badge 改为缓存投影，避免 AppState 高频刷新时反复全量统计
    @State private var cachedPendingContactTaskCount = 0
    @State private var cachedUnreadAnnouncementCount = 0
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    var body: some View {
        MainTabContainerView(
            selection: selection,
            contactsTitle: contactsTitle,
            unreadTotal: publishedUnreadTotal ?? conversationStore.alertingUnreadTotal,
            pendingContactTaskCount: cachedPendingContactTaskCount,
            unreadAnnouncementCount: cachedUnreadAnnouncementCount
        )
        .onAppear {
            onShellAppear()
            refreshMainTabBadgeCaches()
        }
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：只在对应数据源变化时刷新 badge 投影
        .onReceive(conversationStore.alertingUnreadUpdates) { total in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            publishedUnreadTotal = total
            updateApplicationBadge(total)
        }
        .onReceive(contactStore.$friendRequests) { requests in
            refreshPendingContactTaskBadgeCache(requests)
        }
        .onReceive(contactStore.$inboxItems) { items in
            refreshUnreadAnnouncementBadgeCache(items)
        }
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：集中维护 Tab badge 缓存，降低切换时主线程计算
    private func refreshMainTabBadgeCaches() {
        refreshPendingContactTaskBadgeCache(contactStore.friendRequests)
        refreshUnreadAnnouncementBadgeCache(contactStore.inboxItems)
    }

    private func refreshPendingContactTaskBadgeCache(_ requests: [FriendRequest]) {
        let nextValue = requests.filter(\.isPendingIncoming).count
        guard cachedPendingContactTaskCount != nextValue else { return }
        cachedPendingContactTaskCount = nextValue
    }

    private func refreshUnreadAnnouncementBadgeCache(_ items: [InboxItem]) {
        let nextValue = items.reduce(0) { count, item in
            item.isAnnouncement && !item.isRead ? count + 1 : count
        }
        guard cachedUnreadAnnouncementCount != nextValue else { return }
        cachedUnreadAnnouncementCount = nextValue
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
}
// WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_END

extension MainTab {
    var tabAccessibilityIdentifier: String {
        "main_tab_\(rawValue)"
    }

    func tabAccessibilityLabel(displayTitle: String) -> String {
        "\(displayTitle)标签页"
    }
}

private struct MainTabContainerView: View {
    @ObservedObject var selection: MainTabSelectionState
    let contactsTitle: String
    let unreadTotal: Int
    let pendingContactTaskCount: Int
    let unreadAnnouncementCount: Int
    @State private var loadedTabs: Set<MainTab> = [.chats]

    private var tabAccessibilityDescriptors: [(tab: MainTab, displayTitle: String)] {
        [
            (.chats, MainTab.chats.title),
            (.contacts, contactsTitle),
            (.files, MainTab.files.title),
            (.rtc, MainTab.rtc.title),
            (.me, MainTab.me.title)
        ]
    }

    var body: some View {
        TabView(selection: selection.binding) {
            NavigationStackCompat {
                lazyTabContent(.chats) {
                    ConversationListView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.chats)
            }
            .tabItem {
                tabLabel(.chats, displayTitle: MainTab.chats.title)
            }
            .tag(MainTab.chats)
            .badge(UnreadBadgeFormatter.text(unreadTotal))

            NavigationStackCompat {
                lazyTabContent(.contacts) {
                    ContactsView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.contacts)
            }
            .tabItem {
                tabLabel(.contacts, displayTitle: contactsTitle)
            }
            .tag(MainTab.contacts)
            .badge(UnreadBadgeFormatter.text(pendingContactTaskCount))

            NavigationStackCompat {
                lazyTabContent(.files) {
                    FilesView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.files)
            }
            .tabItem {
                tabLabel(.files, displayTitle: MainTab.files.title)
            }
            .tag(MainTab.files)

            NavigationStackCompat {
                lazyTabContent(.rtc) {
                    RTCEntryView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.rtc)
            }
            .tabItem {
                tabLabel(.rtc, displayTitle: MainTab.rtc.title)
            }
            .tag(MainTab.rtc)

            NavigationStackCompat {
                lazyTabContent(.me) {
                    MeView()
                }
            }
            .onAppear {
                selection.noteContentAppeared(.me)
            }
            .tabItem {
                tabLabel(.me, displayTitle: MainTab.me.title)
            }
            .tag(MainTab.me)
            .badge(UnreadBadgeFormatter.text(unreadAnnouncementCount))
        }
        .tint(IMColor.ink)
        .background {
            MainTabAccessibilityInstaller(
                descriptors: tabAccessibilityDescriptors
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            loadedTabs.insert(selection.activeTab)
        }
        .onChangeCompat(of: selection.activeTab) { _, tab in
            loadedTabs.insert(tab)
        }
    }

    private func tabLabel(_ tab: MainTab, displayTitle: String) -> some View {
        Label(displayTitle, systemImage: tab.symbol)
            .accessibilityLabel(tab.tabAccessibilityLabel(displayTitle: displayTitle))
            .accessibilityIdentifier(tab.tabAccessibilityIdentifier)
    }

    @ViewBuilder
    private func lazyTabContent<Content: View>(
        _ tab: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if loadedTabs.contains(tab) || selection.activeTab == tab {
            content()
        } else {
            Color.clear
        }
    }
}

private struct MainTabAccessibilityInstaller: UIViewControllerRepresentable {
    let descriptors: [(tab: MainTab, displayTitle: String)]

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：辅助标识只在描述变化时安装，避免每次刷新递归扫描 TabBar
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let signature = descriptorSignature
        let coordinator = context.coordinator
        guard signature != coordinator.appliedSignature,
              !(coordinator.isUpdatePending && coordinator.pendingSignature == signature) else {
            return
        }
        coordinator.pendingSignature = signature
        coordinator.isUpdatePending = true
        let descriptors = descriptors
        DispatchQueue.main.async {
            coordinator.isUpdatePending = false
            if Self.installAccessibilityDescriptors(descriptors, from: uiViewController) {
                coordinator.appliedSignature = signature
            }
            coordinator.pendingSignature = ""
        }
    }

    private var descriptorSignature: String {
        descriptors.map { descriptor in
            "\(descriptor.tab.rawValue):\(descriptor.displayTitle)"
        }
        .joined(separator: "|")
    }

    final class Coordinator {
        var appliedSignature = ""
        var pendingSignature = ""
        var isUpdatePending = false
    }

    private static func installAccessibilityDescriptors(
        _ descriptors: [(tab: MainTab, displayTitle: String)],
        from uiViewController: UIViewController
    ) -> Bool {
        var didInstall = false
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let candidateControllers = scenes
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
            + [uiViewController]
        for controller in candidateControllers {
            for tabController in Self.findTabBarControllers(in: controller) {
                guard let items = tabController.tabBar.items,
                      items.count == descriptors.count else {
                    continue
                }
                for (item, descriptor) in zip(items, descriptors) {
                    item.accessibilityIdentifier = descriptor.tab.tabAccessibilityIdentifier
                    item.accessibilityLabel = descriptor.tab.tabAccessibilityLabel(
                        displayTitle: descriptor.displayTitle
                    )
                }
                didInstall = true
            }
        }
        return didInstall
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    private static func findTabBarControllers(in controller: UIViewController?) -> [UITabBarController] {
        guard let controller else { return [] }
        var result: [UITabBarController] = []
        if let tab = controller as? UITabBarController {
            result.append(tab)
        }
        if let navigation = controller as? UINavigationController {
            result.append(contentsOf: findTabBarControllers(in: navigation.visibleViewController))
        }
        if let presented = controller.presentedViewController {
            result.append(contentsOf: findTabBarControllers(in: presented))
        }
        for child in controller.children {
            result.append(contentsOf: findTabBarControllers(in: child))
        }
        return result
    }
}
