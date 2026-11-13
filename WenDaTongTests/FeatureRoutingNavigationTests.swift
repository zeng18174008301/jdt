import Foundation // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
import SwiftUI
import UIKit
import XCTest
@testable import WenDaTong

// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
extension IdentityPresentationTests {
    @MainActor
    func testFeatureRoutingContactsOpensRealProfileThenChatAndReturns() throws {
        let state = try mountedLocalDirectChat(nickname: "Routing peer", remark: nil, expecting: [.policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let user = try XCTUnwrap(state.contacts.first)
        let second = makeRemarkContractUser(id: "routing-second", userID: "ROUTING-SECOND", name: "Second peer")
        state.contacts = [user, second]
        let secondID = try XCTUnwrap(state.openOrCreateDirectConversationID(for: second, activateChatsTab: false))
        let originalConversations = state.conversationStore.conversationMessageSnapshots().map(\.id)
        state.activeTab = .contacts
        let originalTab = state.activeTab
        var profiles: [String] = []
        var chats: [String] = []
        let realContacts = AppFeatureComposition.contactsRouting()
        let realChat = AppFeatureComposition.chatRouting()
        var openProfileConversation: ((String) -> Void)?
        let contactsRouting = ContactsFeatureRouting(
            userProfile: { user, callback, sourceGroupID in
                profiles.append(user.id)
                openProfileConversation = callback
                return realContacts.makeUserProfile(user: user, onOpenConversation: callback, sourceGroupID: sourceGroupID)
            }, groupDetail: realContacts.groupDetail)
        let chatRouting = ChatFeatureRouting(makeChat: { id, jump in
            AnyView(realChat.makeChat(id, initialSearchJumpTarget: jump).onAppear { chats.append(id) })
        })
        let hosted = hostForSimulatorUI(
            NavigationStackCompat {
                ContactsView()
                    .environment(\.contactsFeatureRouting, contactsRouting)
                    .environment(\.chatFeatureRouting, chatRouting)
            }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        let table = try XCTUnwrap(routingFindTable(hosted.controller.view))
        let navigation = try XCTUnwrap(routingFindNavigation(hosted.controller))
        let initialDepth = navigation.viewControllers.count
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        routingSettle()
        XCTAssertTrue(profiles.contains(user.id))
        XCTAssertEqual(navigation.viewControllers.count, initialDepth + 1)
        XCTAssertEqual(state.conversationStore.conversationMessageSnapshots().map(\.id), originalConversations)
        XCTAssertEqual(state.activeTab, originalTab)
        // Exercise the original page callback while its real profile is mounted.
        // UserProfile's existing button calls this after the unchanged command.
        let conversationID = try XCTUnwrap(state.openOrCreateDirectConversationID(for: user, activateChatsTab: false))
        try XCTUnwrap(openProfileConversation)(conversationID)
        routingSettle()
        XCTAssertTrue(chats.contains("direct-ui-chat"))
        XCTAssertEqual(navigation.viewControllers.count, initialDepth + 1, "The root-owned route replaces the profile destination")
        XCTAssertEqual(state.activeTab, originalTab)
        navigation.popViewController(animated: false)
        routingSettle()
        XCTAssertEqual(navigation.viewControllers.count, initialDepth)
        let returnedTable = try XCTUnwrap(routingFindTable(hosted.controller.view))
        // Select by the actual contact ID across the table's alphabetical headings.
        let secondIndex = try XCTUnwrap((0..<returnedTable.numberOfRows(inSection: 0)).first { row in
            let cell = returnedTable.dataSource?.tableView(returnedTable, cellForRowAt: IndexPath(row: row, section: 0))
            return cell?.accessibilityIdentifier == "contact_row_" + second.id
        })
        returnedTable.delegate?.tableView?(returnedTable, didSelectRowAt: IndexPath(row: secondIndex, section: 0))
        routingSettle()
        XCTAssertEqual(profiles.last, second.id)
        try XCTUnwrap(openProfileConversation)(secondID)
        routingSettle()
        XCTAssertEqual(chats.last, secondID, "Back and reentry must not reuse the first destination")
        XCTAssertEqual(navigation.viewControllers.count, initialDepth + 1)
        XCTAssertEqual(state.activeTab, originalTab)
        navigation.popViewController(animated: false)
        routingSettle()
        XCTAssertEqual(navigation.viewControllers.count, initialDepth)
        XCTAssertNotEqual(ContactsConversationRoute(id: secondID).id, ContactsConversationRoute(id: secondID).id)
    }

    @MainActor
    func testFeatureRoutingChatUsesRealProfileAndPendingCallback() throws {
        let state = try mountedLocalDirectChat(nickname: "Routing peer", remark: nil, expecting: [.policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let peer = try XCTUnwrap(state.contacts.first)
        let realContacts = AppFeatureComposition.contactsRouting()
        let realChat = AppFeatureComposition.chatRouting()
        var callback: ((String) -> Void)?
        var mountedProfiles: [String] = []
        var mountedChats: [String] = []
        let hosted = hostForSimulatorUI(
            NavigationStackCompat {
                ChatView(conversationID: "direct-ui-chat", selectedUserProfile: peer)
                    .environment(\.contactsFeatureRouting, ContactsFeatureRouting(userProfile: { user, open, groupID in
                        callback = open
                        return AnyView(realContacts.makeUserProfile(user: user, onOpenConversation: open, sourceGroupID: groupID)
                            .onAppear { mountedProfiles.append(user.id) })
                    }, groupDetail: realContacts.groupDetail))
                    .environment(\.chatFeatureRouting, ChatFeatureRouting(makeChat: { id, jump in
                        AnyView(realChat.makeChat(id, initialSearchJumpTarget: jump).onAppear { mountedChats.append(id) })
                    }))
            }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        routingSettle()
        XCTAssertEqual(mountedProfiles, [peer.id])
        XCTAssertNotNil(routingPresentedController(hosted.controller))
        try XCTUnwrap(callback)("direct-ui-chat")
        routingSettle()
        XCTAssertTrue(mountedChats.isEmpty, "Returning to the same conversation does not push another page")
        XCTAssertNil(routingPresentedController(hosted.controller), "The original callback closes the profile sheet")
    }


    @MainActor
    func testFeatureRoutingChatDismissesProfileBeforeOpeningAnotherRealChat() throws {
        let state = try mountedLocalDirectChat(nickname: "Routing peer", remark: nil, expecting: [.policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let peer = try XCTUnwrap(state.contacts.first)
        let second = makeRemarkContractUser(id: "routing-linked", userID: "ROUTING-LINKED", name: "Linked peer")
        state.contacts.append(second)
        let secondID = try XCTUnwrap(state.openOrCreateDirectConversationID(for: second, activateChatsTab: false))
        let realContacts = AppFeatureComposition.contactsRouting()
        let realChat = AppFeatureComposition.chatRouting()
        var callback: ((String) -> Void)?
        var linkedChats: [String] = []
        var profileAppearances = 0
        var profileDisappearances = 0
        let hosted = hostForSimulatorUI(
            NavigationStackCompat {
                ChatView(conversationID: "direct-ui-chat", selectedUserProfile: peer)
                    .environment(\.contactsFeatureRouting, ContactsFeatureRouting(userProfile: { user, open, groupID in
                        XCTAssertNil(groupID)
                        callback = open
                        return AnyView(realContacts.makeUserProfile(user: user, onOpenConversation: open, sourceGroupID: groupID)
                            .onAppear { profileAppearances += 1 }
                            .onDisappear { profileDisappearances += 1 })
                    }, groupDetail: realContacts.groupDetail))
                    .environment(\.chatFeatureRouting, ChatFeatureRouting(makeChat: { id, jump in
                        AnyView(realChat.makeChat(id, initialSearchJumpTarget: jump).onAppear {
                            XCTAssertGreaterThan(profileDisappearances, 0, "The original onDismiss/async boundary precedes the linked Chat")
                            linkedChats.append(id)
                        })
                    }))
            }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        routingSettle()
        XCTAssertEqual(profileAppearances, 1)
        let navigation = try XCTUnwrap(routingFindNavigation(hosted.controller))
        let initialDepth = navigation.viewControllers.count
        try XCTUnwrap(callback)(secondID)
        routingSettle()
        XCTAssertNil(routingPresentedController(hosted.controller))
        XCTAssertEqual(linkedChats, [secondID])
        XCTAssertEqual(navigation.viewControllers.count, initialDepth + 1)
        navigation.popViewController(animated: false)
        routingSettle()
        XCTAssertEqual(navigation.viewControllers.count, initialDepth)
        routingSettle()
        XCTAssertEqual(linkedChats, [secondID], "Consumed pending IDs must not reopen after native back")
    }

    @MainActor
    func testFeatureRoutingGroupChatBuildsAndClosesRealGroupDetail() throws {
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false, expecting: [.groupSummary, .pinnedMessages, .policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let realContacts = AppFeatureComposition.contactsRouting()
        var mountedGroups: [String] = []
        var dismissGroup: (() -> Void)?
        var searchCallback: (() -> Void)?
        var pinnedCallback: (() -> Void)?
        let hosted = hostForSimulatorUI(
            NavigationStackCompat {
                ChatView(conversationID: "group-ui-chat", showDetail: true)
                    .environment(\.contactsFeatureRouting, ContactsFeatureRouting(
                        userProfile: realContacts.userProfile,
                        groupDetail: { group, search, pinned in
                            searchCallback = search
                            pinnedCallback = pinned
                            return AnyView(realContacts.makeGroupDetail(group: group, onSearchHistory: search, onPinnedMessages: pinned)
                                .onAppear { mountedGroups.append(group.id) }
                                .background(RoutingDismissCapture { dismissGroup = $0 }))
                        }))
            }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.window.isHidden = true; hosted.window.rootViewController = nil }
        routingSettle()
        XCTAssertEqual(mountedGroups, ["group-ui-chat"])
        XCTAssertNotNil(searchCallback)
        XCTAssertNotNil(pinnedCallback)
        XCTAssertNotNil(routingPresentedController(hosted.controller))
        try XCTUnwrap(dismissGroup)()
        routingSettle()
        XCTAssertNil(routingPresentedController(hosted.controller))
        let navigation = try XCTUnwrap(routingFindNavigation(hosted.controller))
        XCTAssertEqual(navigation.viewControllers.count, 1)
    }

    @MainActor
    func testFeatureRoutingAppFactoriesInheritEachMountedAccountScope() throws {
        let chatRouting = AppFeatureComposition.chatRouting()
        let contactsRouting = AppFeatureComposition.contactsRouting()
        var observed: [String] = []
        for account in ["routing-account-a", "routing-account-b"] {
            let state = AppState(apiContextOverride: remarkContractContext(tenantID: "tenant-" + account, imUID: account))
            let peer = makeRemarkContractUser(id: "shared-peer", userID: "SHARED-PEER", name: account)
            state.contacts = [peer]
            let id = try XCTUnwrap(state.openOrCreateDirectConversationID(for: peer, activateChatsTab: false))
            let scope = state.contentCacheScopeKey
            let hosted = hostForSimulatorUI(
                NavigationStackCompat {
                    chatRouting.makeChat(id)
                        .background(RoutingEnvironmentCapture { actualState, actualScope in
                            XCTAssertTrue(actualState === state)
                            XCTAssertEqual(actualScope, scope)
                            observed.append(account)
                        })
                }.appStateEnvironment(state)
                    .environment(\.contactsFeatureRouting, contactsRouting),
                size: CGSize(width: 390, height: 844)
            )
            routingSettle()
            XCTAssertEqual(observed.last, account)
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
        }
        XCTAssertEqual(observed, ["routing-account-a", "routing-account-b"])
    }

    // WDT_IOS1_CURRENT_FEATURE_ROUTING_ASSEMBLY_20261110_BEGIN
    @MainActor
    func testFeatureRoutingRetiredContactsOwnerCannotNavigateAnotherMountedScope() throws {
        let realContacts = AppFeatureComposition.contactsRouting()
        let realChat = AppFeatureComposition.chatRouting()
        let stateA = try mountedLocalDirectChat(nickname: "Route A", remark: nil, expecting: [.policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let peerA = try XCTUnwrap(stateA.contacts.first)
        var retiredCallback: ((String) -> Void)?
        let ownerA = hostForSimulatorUI(AnyView(NavigationStackCompat {
            ContactsView().environment(\.contactsFeatureRouting, ContactsFeatureRouting(userProfile: { user, open, group in
                retiredCallback = open
                return realContacts.makeUserProfile(user: user, onOpenConversation: open, sourceGroupID: group)
            }, groupDetail: realContacts.groupDetail))
        }.appStateEnvironment(stateA)), size: CGSize(width: 390, height: 844))
        defer { ownerA.window.isHidden = true; ownerA.window.rootViewController = nil }
        routingSettle()
        let tableA = try XCTUnwrap(routingFindTable(ownerA.controller.view))
        let rowA = try XCTUnwrap((0..<tableA.numberOfRows(inSection: 0)).first { row in
            tableA.dataSource?.tableView(tableA, cellForRowAt: IndexPath(row: row, section: 0)).accessibilityIdentifier == "contact_row_" + peerA.id
        })
        tableA.delegate?.tableView?(tableA, didSelectRowAt: IndexPath(row: rowA, section: 0)); routingSettle()
        let old = try XCTUnwrap(retiredCallback)
        // Retire this actual page owner; no root or row replacement is used to refresh any live callback.
        ownerA.window.isHidden = true; ownerA.window.rootViewController = nil
        ownerA.controller.rootView = AnyView(EmptyView()); routingSettle()
        let stateB = try mountedLocalDirectChat(nickname: "Route B", remark: nil) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        var otherContext = stateB.apiContext; otherContext.accountID = "routing-owner-b"; otherContext.tenantID = "\(otherContext.tenantID ?? "routing-tenant-b")-retired" // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        stateB.apiContext = otherContext
        let peerB = makeRemarkContractUser(id: "route-owner-peer-b", userID: "ROUTE-OWNER-PEER-B", name: "Route B peer")
        stateB.contacts = [peerB]
        let conversationB = try XCTUnwrap(stateB.openOrCreateDirectConversationID(for: peerB, activateChatsTab: false))
        var currentCallback: ((String) -> Void)?; var chatsB: [String] = []; var actualOwners: [AppState] = []
        let ownerB = hostForSimulatorUI(NavigationStackCompat {
            ContactsView().environment(\.contactsFeatureRouting, ContactsFeatureRouting(userProfile: { user, open, group in
                currentCallback = open
                return realContacts.makeUserProfile(user: user, onOpenConversation: open, sourceGroupID: group)
            }, groupDetail: realContacts.groupDetail))
            .environment(\.chatFeatureRouting, ChatFeatureRouting(makeChat: { id, jump in
                AnyView(realChat.makeChat(id, initialSearchJumpTarget: jump).onAppear { chatsB.append(id) }
                    .background(RoutingEnvironmentCapture { owner, _ in actualOwners.append(owner) }))
            }))
        }.appStateEnvironment(stateB), size: CGSize(width: 390, height: 844))
        defer { ownerB.window.isHidden = true; ownerB.window.rootViewController = nil }
        routingSettle()
        let navigationB = try XCTUnwrap(routingFindNavigation(ownerB.controller)); let depth = navigationB.viewControllers.count
        let before = stateB.conversationStore.conversationMessageSnapshots()
        old("retired-owner-must-not-route-b"); routingSettle()
        XCTAssertEqual(navigationB.viewControllers.count, depth); XCTAssertTrue(chatsB.isEmpty)
        XCTAssertEqual(stateB.conversationStore.conversationMessageSnapshots(), before)
        let tableB = try XCTUnwrap(routingFindTable(ownerB.controller.view))
        let rowB = try XCTUnwrap((0..<tableB.numberOfRows(inSection: 0)).first { row in
            tableB.dataSource?.tableView(tableB, cellForRowAt: IndexPath(row: row, section: 0)).accessibilityIdentifier == "contact_row_" + peerB.id
        })
        tableB.delegate?.tableView?(tableB, didSelectRowAt: IndexPath(row: rowB, section: 0)); routingSettle()
        try XCTUnwrap(currentCallback)(conversationB); routingSettle()
        XCTAssertEqual(chatsB.last, conversationB); XCTAssertTrue(actualOwners.last === stateB)
        XCTAssertFalse(actualOwners.contains(where: { $0 === stateA }))
        XCTAssertEqual(navigationB.viewControllers.count, depth + 1)
    }
    // WDT_IOS1_CURRENT_FEATURE_ROUTING_ASSEMBLY_20261110_END

}

@MainActor
private func routingSettle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.45))
}

@MainActor
private func routingFindTable(_ view: UIView) -> UITableView? {
    if let table = view as? UITableView, table.accessibilityIdentifier == "contact_directory_table" { return table }
    return view.subviews.lazy.compactMap(routingFindTable).first
}

@MainActor
private func routingFindNavigation(_ controller: UIViewController) -> UINavigationController? {
    if let navigation = controller as? UINavigationController { return navigation }
    return controller.children.lazy.compactMap(routingFindNavigation).first
}

@MainActor
private func routingPresentedController(_ controller: UIViewController) -> UIViewController? {
    if let presented = controller.presentedViewController { return presented }
    return controller.children.lazy.compactMap(routingPresentedController).first
}

@MainActor
private struct RoutingDismissCapture: View {
    @Environment(\.dismiss) private var dismiss
    let capture: (@escaping () -> Void) -> Void
    var body: some View {
        Color.clear.onAppear { capture { dismiss() } }
    }
}

@MainActor
private struct RoutingEnvironmentCapture: View {
    @EnvironmentObject private var state: AppState
    let capture: (AppState, String) -> Void
    var body: some View {
        Color.clear.onAppear { capture(state, state.contentCacheScopeKey) }
    }
}
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

// WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111_BEGIN
enum MountedIdentityRoute: String {
    case groupSummary = "/api/tenant/groups/group-ui-chat/summary"
    case pinnedMessages = "/api/im/groups/group-ui-chat/pinned-messages"
    case policy = "/api/tenant/policy"
    case verification = "/api/tenant/me/verification-status"
}

private final class MountedIdentityHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let method = request.httpMethod ?? "UNKNOWN"
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        lock.withLock { records.append("\(method) \(host)\(path)") }
        guard method == "GET", let route = MountedIdentityRoute(rawValue: path) else {
            throw URLError(.resourceUnavailable)
        }
        let expectedHost = route == .pinnedMessages ? "im.example.test" : "tenant.example.test"
        guard request.url?.scheme == "https", host == expectedHost else {
            throw URLError(.resourceUnavailable)
        }
        // The mounted tests own their seeded values. The historical requests returned no usable data.
        let data = Data(#"{"ok":false,"code":"fixture_unavailable","message":"Synthetic mounted fixture"}"#.utf8)
        return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 503)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }

    func recordedRequests() -> [String] { lock.withLock { records } }
}

extension IdentityPresentationTests {
    @MainActor
    func mountedLocalIdentityState(imUID: String = "viewer-ui", expecting routes: [MountedIdentityRoute]) throws -> AppState {
        let suite = "mounted-identity-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let transport = MountedIdentityHTTPTransport()
        addTeardownBlock { @MainActor in
            let recorded = transport.recordedRequests()
            print("[MountedIdentityLocalHTTP] \(recorded.joined(separator: ", "))")
            for route in routes {
                let host = route == .pinnedMessages ? "im.example.test" : "tenant.example.test"
                XCTAssertTrue(recorded.contains("GET \(host)\(route.rawValue)"), "Missing mounted GET \(route.rawValue)")
            }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let context = remarkContractContext(tenantID: suite, imUID: imUID)
        let api = IMAPIClient(
            platformBase: URL(string: "https://platform.example.test"),
            tenantBase: URL(string: "https://tenant.example.test"),
            imBase: URL(string: "https://im.example.test"),
            bootstrapBases: [], httpTransport: transport,
            runtimeRouteStore: IMRuntimeRouteStore(defaults: defaults), startupContext: context
        )
        let state = AppState(api: api,
            pendingRegistrationReceiptStore: PendingRegistrationReceiptStore(defaults: defaults),
            realtimeClient: PostLoginSilentRealtimeTransport(), voiceMediaClient: NoopVoiceMediaClient(), videoMediaClient: NoopVideoMediaClient(),
            messageStore: SnapshotCache(directoryURL: root.appendingPathComponent("snapshots")),
            messagePersistence: MessagePersistenceCoordinator(applicationSupportBase: root.appendingPathComponent("support"),
                cachesBase: root.appendingPathComponent("caches")),
            biometricAuthenticator: RecordingBiometricAuthenticator(), biometricDefaults: defaults,
            rememberedLoginCredentialStore: RecordingRememberedLoginCredentialStore(),
            rememberedLoginPreferenceStore: UserDefaultsRememberedLoginPreferenceStore(defaults: defaults),
            protectedSessionStore: InMemoryProtectedSessionStore(), registrationSessionStore: InMemoryProtectedSessionStore(),
            apiContextOverride: context)
        state.suppressCurrentUserIdentityPersistence = true
        return state
    }

    @MainActor
    func mountedLocalDirectChat(nickname: String, remark: String?, expecting routes: [MountedIdentityRoute] = []) throws -> AppState {
        let state = try mountedLocalIdentityState(expecting: routes)
        return directChatUIState(nickname: nickname, remark: remark, isolatedState: state)
    }

    @MainActor
    func mountedLocalGroupChat(role: String, active: Bool, repairRequired: Bool,
        expecting routes: [MountedIdentityRoute] = [.groupSummary, .pinnedMessages]) throws -> AppState {
        let state = try mountedLocalIdentityState(expecting: routes)
        let populated = groupChatUIState(role: role, active: active, repairRequired: repairRequired, isolatedState: state)
        populated.suppressCurrentUserIdentityPersistence = true
        return populated
    }
}
// WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111_END
