@testable import IM4Features
import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import WenDaTong

extension IdentityPresentationTests {

    // WDT_IOS1_REFACTOR_SCOPED_POLICY_RENDER_INPUTS_20261110_BEGIN
    @MainActor
    func testMountedProfileAndReceiptConsumePolicyThroughNestedObservers() async throws {
        let state = groupChatUIState(role: "member", active: false, repairRequired: false)
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        let store = state.tenantClientPolicyStore
        state.contacts = []
        state.storeCancellables.removeAll()
        state.tenantInteractionStore.snapshot.policyScope = scope
        state.interactionPolicyRefreshTask = Task {}
        defer { state.interactionPolicyRefreshTask?.cancel() }
        func policy(friendRequests: Bool = true, groupCount: Bool = true) -> RemoteTenantClientPolicy {
            RemoteTenantClientPolicy(
                clientFriendRequests: friendRequests, showGroupMemberCount: groupCount,
                groupMemberCountPolicyGeneration: 1, groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true, groupMemberCountPolicyPresent: true
            )
        }
        let allowed = TenantClientPolicyPresentationStore.Snapshot(
            activeScope: scope, policyScope: scope, policy: policy(),
            groupCountResolution: .authoritative(scope: scope, generation: 1)
        )
        func verify<Content: View>(_ surface: Content, deniedPolicy: RemoteTenantClientPolicy) async throws {
            store.snapshot = allowed
            try await withMountedConversationSurface(surface.appStateEnvironment(state), settleNanoseconds: 350_000_000) { snapshot in
                let enabled = try await snapshot()
                var updates = 0
                let observation = state.objectWillChange.sink { updates += 1 }
                defer { observation.cancel() }
                store.snapshot.policy = deniedPolicy
                XCTAssertEqual(updates, 0)
                let denied = try await snapshot()
                XCTAssertNotEqual(denied, enabled, String(describing: Content.self))
                store.snapshot = allowed
                let restored = try await snapshot()
                XCTAssertEqual(restored, enabled)
            }
        }
        state.setCurrentEnterprise(Enterprise(
            id: "tenant-ui", name: "Test Tenant", code: "", role: "member",
            status: "", memberCount: 23, isDefault: false, accentHex: 0
        )) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        let peer = makeRemarkContractUser(id: "nested-peer", userID: "NESTED-PEER", name: "Policy peer")
        try await verify(UserProfileView(user: peer), deniedPolicy: policy(friendRequests: false))

        state.setCurrentEnterprise(Enterprise(
            id: "tenant-ui", name: "Test Tenant", code: "", role: "admin",
            status: "", memberCount: 23, isDefault: false, accentHex: 0
        )) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.setReadReceiptsEnabled(true)
        var message = ChatMessage(
            id: "nested-receipt", senderId: state.currentUser.id, senderName: "Self", text: "Receipt message",
            time: "", isOutgoing: true, status: .read, kind: .text,
            reactions: [], readBy: [], unreadBy: [], isPinned: false
        )
        message.canViewReadDetails = true
        message.readCount = 9
        message.unreadCount = 14
        let conversation = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first)
        _ = state.applyReadReceiptDetailAuthority(true, conversationID: conversation.id)
        XCTAssertTrue(state.canViewMessageReadDetails(message, in: conversation))
        try await verify(
            ReadReceiptSheet(message: message, conversation: conversation, readReceiptsEnabled: true),
            deniedPolicy: policy(groupCount: false)
        )
    }
    // WDT_IOS1_REFACTOR_SCOPED_POLICY_RENDER_INPUTS_20261110_END
    // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedLoginLoadingChangesWithoutPublishingAppState() async throws {
        let state = directChatUIState(nickname: "Login peer", remark: nil)
        state.setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        let store = state.authenticationPresentationStore
        var updates: [Bool] = []
        let loadingObservation = store.loadingUpdates.sink { updates.append($0) }
        defer { loadingObservation.cancel() }

        try await withMountedConversationSurface(
            AuthFlipView(initialRegister: false, initialMode: .account).appStateEnvironment(state),
            settleNanoseconds: 350_000_000
        ) { snapshot in
            let idle = try await snapshot()
            var globalUpdates = 0
            let globalObservation = state.objectWillChange.sink { globalUpdates += 1 }
            defer { globalObservation.cancel() }

            store.isLoading = true
            store.isLoading = true
            XCTAssertTrue(state.isAuthLoading)
            XCTAssertEqual(globalUpdates, 0)
            let loading = try await snapshot()
            if loading == idle {
                let attachment = XCTAttachment(data: loading, uniformTypeIdentifier: "public.png")
                attachment.name = "login-loading-unchanged"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertNotEqual(loading, idle)

            store.isLoading = false
            XCTAssertFalse(state.isAuthLoading)
            XCTAssertEqual(globalUpdates, 0)
            let restored = try await snapshot()
            XCTAssertEqual(restored, idle)
            XCTAssertEqual(updates, [false, true, false])
        }
    }
    // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedGroupDirectoryUpdatesTenantControlsWithoutGlobalPublication() async throws {
        // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_BEGIN
        let suite = "mounted-group-directory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let transport = FakeAttachmentHTTPTransport(results: [])
        let state = isolatedGroupDirectoryUIState(tenantID: suite, transport: transport, defaults: defaults, root: root)
        // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_END
        state.setCurrentEnterprise(Enterprise(
            id: suite, name: "Test Tenant", code: "", role: "member",
            status: "", memberCount: 23, isDefault: false, accentHex: 0
        )) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        state.groups[0].memberCount = 23
        state.storeCancellables.removeAll()
        let store = state.tenantClientPolicyStore
        let scope = state.remoteDataScopeKey(for: state.apiContext)
        func policy(creation: Bool = true, count: Bool = true) -> RemoteTenantClientPolicy {
            RemoteTenantClientPolicy(
                allowMemberGroupCreation: creation,
                showGroupMemberCount: count,
                groupMemberCountPolicyGeneration: 1,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        }
        let allowed = TenantClientPolicyPresentationStore.Snapshot(
            activeScope: scope,
            policyScope: scope,
            policy: policy(),
            groupCountResolution: .authoritative(scope: scope, generation: 1)
        )
        store.snapshot = allowed
        var globalUpdates = 0
        let observation = state.objectWillChange.sink { globalUpdates += 1 }
        defer { observation.cancel() }

        try await withMountedConversationSurface(
            NavigationStackCompat { GroupListView() }.appStateEnvironment(state),
            settleNanoseconds: 300_000_000
        ) { snapshot in
            // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_BEGIN
            try await attachmentBoundaryWait("mounted group directory requests the group summary") {
                transport.requests().contains {
                    $0.httpMethod == "GET" && $0.url?.host == "tenant.example.test"
                        && $0.url?.path == "/api/tenant/groups/group-ui-chat/summary"
                }
            }
            // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111_END
            let visible = try await snapshot()
            let beforeCountChange = globalUpdates
            store.snapshot.policy = policy(count: false)
            XCTAssertEqual(globalUpdates, beforeCountChange)
            let hiddenCount = try await snapshot()
            XCTAssertNotEqual(hiddenCount, visible)

            store.snapshot = allowed
            let restoredCount = try await snapshot()
            XCTAssertEqual(restoredCount, visible)
            let beforeCreationChange = globalUpdates
            store.snapshot.policy = policy(creation: false)
            XCTAssertEqual(globalUpdates, beforeCreationChange)
            let hiddenCreation = try await snapshot()
            XCTAssertNotEqual(hiddenCreation, visible)

            store.snapshot = allowed
            let restoredCreation = try await snapshot()
            XCTAssertEqual(restoredCreation, visible)
            state.markGroupMemberCountPolicyUnresolved(scope: scope, minimumGeneration: 2)
            XCTAssertFalse(state.shouldShowGroupMemberCount)
            let unresolvedCount = try await snapshot()
            XCTAssertNotEqual(unresolvedCount, visible)

            state.apiContext.tenantID = "\(suite)-other" // WDT_IOS1_GROUP_DIRECTORY_MOUNT_LOCAL_TRANSPORT_20261111
            XCTAssertNil(store.snapshot.resolvedPolicy)
            XCTAssertFalse(store.snapshot.showsGroupMemberCount)
            XCTAssertFalse(state.canCreateGroupChat)
        }
    }
    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedForwardBarRevokesPolicyWhenTheTenantChanges() async throws {
        let state = directChatUIState(nickname: "Forward peer", remark: nil)
        let store = state.tenantInteractionStore
        store.snapshot.policyScope = state.remoteDataScopeKey(for: state.apiContext)
        store.snapshot.actions.forwardEnabled = true
        var visiblePermissions: [Bool] = []
        var globalUpdates = 0
        let observations = [
            store.updates(\.canForward).sink { visiblePermissions.append($0) },
            state.objectWillChange.sink { globalUpdates += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }

        try await withMountedConversationSurface(
            BatchForwardSelectionBar(selectedCount: 1, onCancel: {}, onForward: {}).appStateEnvironment(state),
            settleNanoseconds: 300_000_000
        ) { snapshot in
            let permitted = try await snapshot()
            store.snapshot.actions.forwardEnabled = false
            let denied = try await snapshot()
            XCTAssertNotEqual(denied, permitted)
            XCTAssertEqual(globalUpdates, 0)

            store.snapshot.actions.forwardEnabled = true
            let restored = try await snapshot()
            XCTAssertEqual(restored, permitted)

            state.apiContext.tenantID = "different-tenant"
            XCTAssertNotNil(state.messageActionPolicyUnavailableReason(.forward))
            let revoked = try await snapshot()
            XCTAssertEqual(revoked, denied)
            XCTAssertEqual(visiblePermissions, [true, false, true, false])
        }
    }
    // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END

    func testContactUserNumberUsesOnlyTrimmedAuthoritativeUserID() {
        XCTAssertEqual(contactAuthoritativeUserNumber(userID: "  WXT00001234  "), "WXT00001234")
        XCTAssertNil(contactAuthoritativeUserNumber(userID: "  \n "))
    }

    func testContactDirectoryAndSharedRowsKeepUserNumberBelowNameWithoutReplacingDepartment() throws {
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_BEGIN
        let contacts = try sourceText(relativePath: "../WenDaTong/ContactsViews.swift")
        let rows = try sourceText(relativePath: "../WenDaTong/Features/Contacts/ContactCommonRows.swift")
        let rowContent = try sourceText(relativePath: "../Sources/IM4Features/Contacts/ContactRowContent.swift")
        let directorySymbol = "struct ContactDirectoryRow: View"
        for symbol in [directorySymbol, "struct ContactRow: View"] {
            let renderer = symbol == directorySymbol ? "public struct ContactDirectoryRowContent" : "public struct ContactRowContent"
            let row = try sourceSection(rowContent, startingAt: renderer) + sourceSection(rows, startingAt: symbol)
            let userNumberSource = symbol == directorySymbol
                ? "row.userNumber"
                : "contactAuthoritativeUserNumber(userID: user.userID)"
            XCTAssertTrue(row.contains(userNumberSource), symbol)
            XCTAssertTrue(row.contains("font(.caption2.weight(.semibold))"), symbol)
            XCTAssertTrue(row.contains("foregroundStyle(IMColor.muted)"), symbol)
            XCTAssertTrue(row.contains("lineLimit(1)"), symbol)
            XCTAssertTrue(row.contains("truncationMode(.middle)"), symbol)
            XCTAssertTrue(row.contains("layoutPriority(1)"), symbol)
        }
        let directory = try sourceSection(rowContent, startingAt: "public struct ContactDirectoryRowContent")
        XCTAssertTrue(directory.contains("row.departmentSummary"))
        let projection = try sourceSection(contacts, startingAt: "struct ContactDirectoryRowPresentation")
        XCTAssertTrue(projection.contains("userNumber: contactAuthoritativeUserNumber(userID: user.userID)"))
        XCTAssertTrue(projection.contains("state.departmentSummary(for: user)"))
        XCTAssertTrue(projection.contains(#"userNumber.map { "用户编号 \($0)" }"#))
        // WDT_IOS1_REFACTOR_CONTACTS_VIEWS_20261110_END
    }

    // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedContactDirectoryRegroupsLiveRemarksWithoutAppStateRelay() throws {
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-local-directory", imUID: "viewer-local-directory")
        )
        state.storeCancellables.removeAll()
        state.contacts = [
            makeRemarkContractUser(id: "alpha", userID: "WXT-alpha", name: "Alice"),
            makeRemarkContractUser(id: "beta", userID: "WXT-beta", name: "Annie")
        ]
        let hosted = hostForSimulatorUI(
            NavigationStackCompat { ContactsView() }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 760)
        )
        defer { hosted.window.isHidden = true }

        func findTable(in view: UIView) -> UITableView? {
            if let table = view as? UITableView, table.accessibilityIdentifier == "contact_directory_table" {
                return table
            }
            return view.subviews.lazy.compactMap(findTable(in:)).first
        }

        let table = try XCTUnwrap(findTable(in: hosted.controller.view))
        func waitForRowCount(_ count: Int) {
            let deadline = Date().addingTimeInterval(1)
            while table.numberOfRows(inSection: 0) != count, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertEqual(table.numberOfRows(inSection: 0), count)
        }

        XCTAssertEqual(table.numberOfRows(inSection: 0), 3) // A and two contacts.
        state.contactStore.remarks = ["WXT-alpha": "Zebra"]
        waitForRowCount(4) // The remark moves Alice into the new Z section.
        XCTAssertEqual(table.cellForRow(at: IndexPath(row: 2, section: 0))?.accessibilityIdentifier, "contact_group_Z")
        state.contactStore.remarks = [:]
        waitForRowCount(3)
        state.contactStore.contacts.append(makeRemarkContractUser(id: "ben", name: "Ben"))
        waitForRowCount(5) // A, B, and three contacts.
    }
    // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
    @MainActor
    func testMountedTranscriptCardsAndQuotesObserveDirectoryWithoutAppStateRelay() async throws {
        let state = directChatUIState(nickname: "Public name", remark: nil)
        state.storeCancellables.removeAll()
        let peer = try XCTUnwrap(state.contacts.first)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        func verifyUpdates<Content: View>(
            _ content: Content,
            update: () -> Void,
            restore: () -> Void
        ) async throws {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 340, height: 240)
            let host = UIHostingController(rootView:
                ContactDirectoryPresentationView(store: state.contactStore) { content }
                    .appStateEnvironment(state)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            func snapshot() async throws -> Data {
                try await Task.sleep(nanoseconds: 150_000_000)
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                return try XCTUnwrap(image.pngData())
            }
            let initial = try await snapshot()
            update()
            let updated = try await snapshot()
            XCTAssertNotEqual(updated, initial)
            restore()
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
        }

        let quote = ReplyQuoteBlock(
            quote: "Public name: Original",
            context: MessageReplyContext(senderID: peer.id, senderName: peer.name, summary: "Original"),
            outgoing: false
        )
        try await verifyUpdates(quote, update: {
            state.contactStore.remarks = [peer.userID: "Private alias"]
        }, restore: {
            state.contactStore.remarks = [:]
        })

        let card = ChatMessage(
            id: "card", senderId: peer.id, senderName: peer.name, text: "个人名片：Public name",
            time: "", isOutgoing: false, status: .sent, kind: .contactCard,
            reactions: [], readBy: [], unreadBy: [], attachmentMeta: peer.userID,
            isPinned: false
        )
        try await verifyUpdates(ContactCardBubbleContent(message: card, outgoing: false) { _ in }, update: {
            state.contactStore.contacts = [peer.withName("Updated contact")]
        }, restore: {
            state.contactStore.contacts = [peer]
        })
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedChatRefreshesTitleAndBackBadgeWithoutConversationRelay() async throws {
        var renderedHeaderTitles: [String] = []
        let previousHeaderProbe = ChatHeaderStatusDiagnostics.header
        ChatHeaderStatusDiagnostics.header = { renderedHeaderTitles.append($0.input.title) }
        defer { ChatHeaderStatusDiagnostics.header = previousHeaderProbe }
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        state.storeCancellables.removeAll()
        let store = state.conversationStore
        let original = try XCTUnwrap(store.conversationMessageSnapshots().first)
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
        try await withMountedConversationSurface(
            NavigationStackCompat { ChatView(conversationID: original.id) }.appStateEnvironment(state)
        ) { snapshot in
            let initial = try await snapshot()
            store.mutateStoredConversation(at: 0) { $0.title = "更新后的群聊名称" }
            let renamed = try await snapshot()
            XCTAssertTrue(renderedHeaderTitles.contains("更新后的群聊名称"), "The actual header factory must consume the conversation update without the AppState relay")
            if let image = UIImage(data: initial) { add(snapshotAttachment(image, name: "chat-live-header-initial")) }
            if let image = UIImage(data: renamed) { add(snapshotAttachment(image, name: "chat-live-header-renamed")) }
            XCTAssertNotEqual(renamed, initial)
            store.commitConversationSnapshot(original, at: 0)
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)

            let other = ConversationMessageSnapshot(
                id: "unread-other", title: "其他会话", subtitle: "", kind: .direct,
                lastMessage: "", time: "", unread: 2, isPinned: false, isMuted: false,
                memberCount: nil, accentHex: 0, participants: [], messages: []
            )
            store.mutateMessageSnapshotsForTesting { $0.append(other) }
            let unread = try await snapshot()
            XCTAssertNotEqual(unread, initial)
            store.mutateMessageSnapshotsForTesting { $0.removeLast() }
            let cleared = try await snapshot()
            XCTAssertEqual(cleared, initial)
        }
        // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END
    }
    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedGroupDirectoryUpdatesUnreadWithoutConversationRelay() async throws {
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false, expecting: [.groupSummary]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        state.storeCancellables.removeAll()
        let store = state.conversationStore
        try await withMountedConversationSurface(
            NavigationStackCompat { GroupListView() }.appStateEnvironment(state)
        ) { snapshot in
            let initial = try await snapshot()
            store.mutateStoredConversation(at: 0) { $0.unread = 6 }
            let unread = try await snapshot()
            XCTAssertNotEqual(unread, initial)
            store.mutateStoredConversation(at: 0) { $0.unread = 0 }
            let cleared = try await snapshot()
            XCTAssertEqual(cleared, initial)
        }
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedConversationListAndPinnedSheetRefreshWithoutConversationRelay() async throws {
        let state = directChatUIState(nickname: "Live peer", remark: nil)
        state.storeCancellables.removeAll()
        let store = state.conversationStore
        let original = try XCTUnwrap(store.conversationMessageSnapshots().first)
        try await withMountedConversationSurface(
            NavigationStackCompat { ConversationListView() }.appStateEnvironment(state),
            settleNanoseconds: 350_000_000
        ) { snapshot in
            let initial = try await snapshot()
            store.mutateStoredConversation(at: 0) { $0.unread = 4 }
            let unread = try await snapshot()
            XCTAssertNotEqual(unread, initial)
            store.commitConversationSnapshot(original, at: 0)
            let cleared = try await snapshot()
            XCTAssertEqual(cleared, initial)
        }

        store.mutateStoredConversation(at: 0) { $0.messages = [
            ChatMessage(
                id: "live-pin", senderId: "peer-ui", senderName: "Live peer", text: "置顶消息",
                time: "", isOutgoing: false, status: .sent, kind: .text,
                reactions: [], readBy: [], unreadBy: [], isPinned: false
            )
        ] }
        try await withMountedConversationSurface(
            PinnedMessagesSheet(conversationID: original.id, onSelect: { _ in }, onUnpin: { _ in })
                .appStateEnvironment(state)
        ) { snapshot in
            let initial = try await snapshot()
            store.mutateStoredConversation(at: 0) { $0.messages[0].isPinned = true }
            let pinned = try await snapshot()
            XCTAssertNotEqual(pinned, initial)
            store.mutateStoredConversation(at: 0) { $0.messages[0].isPinned = false }
            let unpinned = try await snapshot()
            XCTAssertEqual(unpinned, initial)
        }
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedConversationListConsumesNotificationAndReturnsThroughScopedState() async throws {
        let state = directChatUIState(nickname: "Notification peer", remark: nil)
        let conversationID = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first?.id)
        let store = state.conversationListPresentationStore
        let retired = IOSNotificationConversationOpenRequest(conversationID: conversationID, messageID: nil, channelSeq: nil)
        let current = IOSNotificationConversationOpenRequest(conversationID: conversationID, messageID: nil, channelSeq: nil)

        try await withMountedConversationSurface(
            NavigationStackCompat { ConversationListView() }.appStateEnvironment(state),
            settleNanoseconds: 550_000_000
        ) { snapshot in
            let list = try await snapshot()
            store.snapshot.notificationOpenRequest = current
            state.consumeNotificationConversationOpenRequest(retired.id)
            XCTAssertEqual(store.snapshot.notificationOpenRequest, current)
            let opened = try await snapshot()
            XCTAssertNil(store.snapshot.notificationOpenRequest)
            XCTAssertNotEqual(opened, list)

            store.snapshot.returnToken += 1
            let returned = try await snapshot()
            XCTAssertNotEqual(returned, opened)
        }
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
    @MainActor
    func testMountedReplyUsesFirstMatchingSourceAndRefreshesAfterRecall() async throws {
        let state = directChatUIState(nickname: "Peer", remark: nil)
        state.storeCancellables.removeAll()
        let store = state.conversationStore
        let conversationID = try XCTUnwrap(store.conversationMessageSnapshots().first?.id)
        let lookup = ChatReplySourceLookup()
        let earlier = ChatMessage(
            id: "earlier-sequence", senderId: "peer-ui", senderName: "Peer", text: "原消息",
            time: "", channelSeq: 42, isOutgoing: false, status: .sent, kind: .text,
            reactions: [], readBy: [], unreadBy: [], isPinned: false
        )
        var reply = ChatMessage(
            id: "explicit-id", senderId: "peer-ui", senderName: "Peer", text: "回复内容",
            time: "", channelSeq: 43, isOutgoing: false, status: .sent, kind: .text,
            reactions: [], readBy: [], unreadBy: [], isPinned: false
        )
        reply.replyContext = MessageReplyContext(
            messageID: "explicit-id", senderID: "peer-ui", senderName: "Peer", summary: "旧引用", channelSeq: 42
        )
        store.mutateStoredConversation(at: 0) { $0.messages = [earlier, reply] }
        XCTAssertEqual(lookup.message(in: [earlier, reply], id: "explicit-id", sequence: 42)?.id, earlier.id)
        XCTAssertEqual(lookup.message(in: [reply, earlier], id: "explicit-id", sequence: 42)?.id, reply.id)

        let surface = store.observeConversationPresentation(id: conversationID) { current in
            if let current {
                TranscriptReplyQuote(message: reply, conversationID: conversationID, outgoing: false)
                    .chatTranscriptConversation(current, replyLookup: lookup)
            }
        }
        try await withMountedConversationSurface(surface.appStateEnvironment(state)) { snapshot in
            let initial = try await snapshot()
            store.mutateStoredConversation(at: 0) { $0.messages[0].status = .recalled }
            let recalled = try await snapshot()
            XCTAssertNotEqual(recalled, initial)
            store.mutateStoredConversation(at: 0) { $0.messages[0] = earlier }
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
        }
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedGroupTranscriptUpdatesOnlyItsOwnMemberProfile() async throws {
        let state = try mountedLocalGroupChat(role: "member", active: false, repairRequired: false) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        let conversationID = try XCTUnwrap(state.conversationStore.conversationMessageSnapshots().first?.id)
        let outgoing = ChatMessage(
            id: "outgoing-group-profile", senderId: state.currentUser.id, senderName: state.currentUser.name,
            text: "群聊消息", time: "", channelSeq: 1, isOutgoing: true, status: .sent, kind: .text,
            reactions: [], readBy: [], unreadBy: [], isPinned: false
        )
        state.conversationStore.mutateStoredConversation(at: 0) { $0.messages = [outgoing] }
        let store = state.contactStore.groupSelfProfiles
        let key = state.groupMemberProfileCacheKey(groupID: conversationID)
        let other = state.groupMemberProfileCacheKey(groupID: "other-group")

        try await withMountedConversationSurface(
            NavigationStackCompat { ChatView(conversationID: conversationID) }.appStateEnvironment(state)
        ) { snapshot in
            let initial = try await snapshot()
            var nicknames: [String] = []
            let nickname = store.updates(for: key, \.nickname).sink { nicknames.append($0) }
            defer { nickname.cancel() }

            store.set(nickname: "其他群昵称", member: state.currentUser.withName("其他群昵称"), for: other)
            let unrelated = try await snapshot()
            XCTAssertEqual(unrelated, initial)
            XCTAssertEqual(nicknames, [""])

            var globalNotifications = 0
            let app = state.objectWillChange.sink { globalNotifications += 1 }
            store.set(nickname: "仅在本群使用的新昵称", member: state.currentUser.withName("仅在本群使用的新昵称"), for: key)
            app.cancel()
            XCTAssertEqual(globalNotifications, 0)
            XCTAssertEqual(nicknames, ["", "仅在本群使用的新昵称"])
            let renamed = try await snapshot()
            XCTAssertNotEqual(renamed, initial)
            XCTAssertEqual(state.conversationStore.conversationMessageSnapshots()[0].messages[0].senderName, outgoing.senderName)

            store.remove(for: key)
            let restored = try await snapshot()
            XCTAssertEqual(restored, initial)
            XCTAssertEqual(nicknames, ["", "仅在本群使用的新昵称", ""])
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    @MainActor
    func testMountedOrganizationDirectoryUpdatesDepartmentCountAndClearsOnSessionReset() async throws {
        let state = AppState(apiContextOverride: remarkContractContext(tenantID: "tenant-org", imUID: "viewer-org"))
        let store = state.organizationDirectoryStore
        let node = try JSONDecoder().decode(RemoteDepartmentNode.self, from: Data(#"{"department_id":"support","name":"支持部门"}"#.utf8))
        let member = makeRemarkContractUser(id: "member-org", userID: "WXT-ORG", name: "组织成员")
            .withDepartment("支持部门", pathNames: ["公司", "支持部门"])
        let surface = NavigationStackCompat { OrganizationDirectoryView { _ in } }.appStateEnvironment(state)

        try await withMountedConversationSurface(surface) { snapshot in
            let empty = try await snapshot()
            let first = store.beginRefresh()
            store.applyTree(RemoteOrganizationTree(departmentEnabled: true, canManage: true, root: node, items: []))
            store.finishRefresh(first)
            XCTAssertTrue(state.canManageOrganizationDepartments)
            let department = try await snapshot()
            XCTAssertNotEqual(department, empty)

            store.setMembers(["other": [member]], index: [member.id: member])
            let unrelated = try await snapshot()
            XCTAssertEqual(unrelated, department)

            var globalUpdates = 0
            let app = state.objectWillChange.sink { globalUpdates += 1 }
            store.setMembers(["support": [member]], index: [member.id: member])
            app.cancel()
            XCTAssertEqual(globalUpdates, 0)
            let populated = try await snapshot()
            XCTAssertNotEqual(populated, department)
            let incomplete = makeRemarkContractUser(id: member.id, userID: member.userID, name: member.name)
                .withDepartment("", pathNames: [])
            XCTAssertEqual(state.departmentSummary(for: incomplete, fullPath: true), "公司 / 支持部门")

            let old = store.beginRefresh()
            state.resetAuthenticatedRemoteData(showLoading: false)
            XCTAssertFalse(store.ownsRefresh(old))
            XCTAssertNil(store.snapshot.tree)
            XCTAssertTrue(store.snapshot.memberIndex.isEmpty)
            XCTAssertTrue(store.snapshot.membersByDepartment.isEmpty)
            let replacement = store.beginRefresh()
            store.finishRefresh(old)
            XCTAssertTrue(store.ownsRefresh(replacement))
            XCTAssertTrue(store.snapshot.isSyncing)
            store.finishRefresh(replacement)
            let reset = try await snapshot()
            XCTAssertEqual(reset, empty)
        }
    }
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END

    @MainActor
    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110: shared mounted-window fixture for route rendering tests.
    func withMountedConversationSurface<Content: View>(
        _ content: Content,
        settleNanoseconds: UInt64 = 150_000_000,
        checks: (() async throws -> Data) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 660)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func snapshot() async throws -> Data {
            try await Task.sleep(nanoseconds: settleNanoseconds)
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.pngData())
        }

        try await checks(snapshot)
    }
    // WDT_IOS1_REFACTOR_GROUP_CONVERSATION_OBSERVATION_20261110_END

    @MainActor
    func testContactDirectoryReusesCellsAcrossLongListAndOpensSelectedProfile() throws {
        let state = try mountedLocalIdentityState(imUID: "viewer-contact-reuse", expecting: [.policy]) // WDT_IOS1_MOUNTED_IDENTITY_LOCAL_TRANSPORT_20261111
        state.organizationDirectoryStore.setTenantDepartmentEnabled(true) // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
        state.contacts = (0..<846).map { index in
            makeRemarkContractUser(id: "contact-\(index)", userID: "WXT-\(index)",
                                   name: String(format: "Contact %04d", index))
        }
        let hosted = hostForSimulatorUI(
            NavigationStackCompat { ContactsView() }.appStateEnvironment(state),
            size: CGSize(width: 390, height: 760)
        )
        defer { hosted.window.isHidden = true }

        func findTable(in view: UIView) -> UITableView? {
            if let table = view as? UITableView, table.accessibilityIdentifier == "contact_directory_table" {
                return table
            }
            return view.subviews.lazy.compactMap(findTable(in:)).first
        }
        func findNavigation(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap(findNavigation(in:)).first
        }

        let table = try XCTUnwrap(findTable(in: hosted.controller.view))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 847) // Contacts plus the C heading.
        let delegate = try XCTUnwrap(table.delegate)
        for row in [0, 1, 420, 846] {
            let path = IndexPath(row: row, section: 0)
            let actual = try XCTUnwrap(delegate.tableView?(table, heightForRowAt: path))
            let estimated = try XCTUnwrap(delegate.tableView?(table, estimatedHeightForRowAt: path))
            XCTAssertGreaterThan(actual, 0)
            XCTAssertEqual(estimated, actual)
        }
        final class CellObservation {
            weak var cell: UITableViewCell?
            let userID: String

            init(cell: UITableViewCell, userID: String) {
                self.cell = cell
                self.userID = userID
            }
        }
        var observed: [ObjectIdentifier: CellObservation] = [:]
        var distinctCells = 0
        var reusedForDifferentUser = false
        for row in stride(from: 5, through: 825, by: 5) {
            let index = IndexPath(row: row, section: 0)
            table.setContentOffset(CGPoint(x: 0, y: table.rectForRow(at: index).minY), animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            table.layoutIfNeeded()
            for cell in table.visibleCells where cell.reuseIdentifier == "contact" {
                let identifier = ObjectIdentifier(cell)
                let userID = try XCTUnwrap(cell.accessibilityIdentifier)
                if let previous = observed[identifier], previous.cell === cell {
                    reusedForDifferentUser = reusedForDifferentUser || previous.userID != userID
                } else {
                    distinctCells += 1
                }
                observed[identifier] = CellObservation(cell: cell, userID: userID)
            }
        }
        XCTAssertTrue(reusedForDifferentUser)
        XCTAssertLessThan(distinctCells, 36)

        let selected = IndexPath(row: 826, section: 0)
        let cell = try XCTUnwrap(table.cellForRow(at: selected))
        XCTAssertEqual(cell.accessibilityIdentifier, "contact_row_contact-825")
        XCTAssertTrue(cell.accessibilityLabel?.contains("Contact 0825") == true)
        func labels(in view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels(in:))
        }
        let visibleLabels = labels(in: cell.contentView).filter { !$0.isHidden && !$0.frame.isEmpty }
        XCTAssertTrue(visibleLabels.contains { $0.text == "Contact 0825" })
        XCTAssertTrue(visibleLabels.contains { $0.text == "用户编号：WXT-825" })
        XCTAssertTrue(visibleLabels.contains { $0.text == "公司" })
        let navigation = try XCTUnwrap(findNavigation(in: hosted.controller))
        let initialDepth = navigation.viewControllers.count
        table.delegate?.tableView?(table, didSelectRowAt: selected)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(navigation.viewControllers.count, initialDepth + 1)
    }

    @MainActor
    func testSharedContactRowRendersLongAuthoritativeNumberAtPhoneAndDesktopWidthsWithDynamicType() {
        let user = makeRemarkContractUser(
            id: "contact-layout-user",
            userID: "WXT-00000000000000000000000000000000000001",
            name: "这是一条非常非常长的联系人昵称用于验证布局不会挤掉权威用户编号"
        )
        let state = AppState(
            apiContextOverride: remarkContractContext(tenantID: "tenant-contact-layout", imUID: "viewer-contact-layout")
        )
        for width in [390.0, 1024.0] {
            let root = ContactRow(user: user)
                .appStateEnvironment(state)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
            let hosted = hostForSimulatorUI(root, size: CGSize(width: width, height: 240))
            let image = hostedSnapshotImage(hosted)
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 1_000)
            add(snapshotAttachment(image, name: "contact-user-number-axxxl-\(Int(width))pt"))
            hosted.window.isHidden = true
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
