import XCTest; @testable import IM4Features // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
// WDT_IOS1_AUDIO_ROUTE_20260921: exercise real AVAudioSession notification reasons.
import AVFoundation
import UIKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI
@testable import WenDaTong; @testable import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

extension DomainStoreTests {
    func testGroupNameProjectionUpdatesAuthorWithoutRewritingSnapshotOrGlobalIdentity() throws {
        let state = AppState(apiContextOverride: makeIsolatedAPIContext())
        let current = makeUser(id: "self", name: "我")
        let global = makeUser(id: "peer", name: "个人昵称")
        state.setCurrentUser(current) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        state.contacts = [global]
        state.contactRemarks = ["peer": "当前查看者备注"]
        func group(_ id: String) -> GroupInfo {
            GroupInfo(id: id, name: id, notice: "", owner: "", members: [], admins: [],
                      muted: false, allMuted: false, allMuteStart: nil, allMuteEnd: nil)
        }
        state.groups = [group("group-a"), group("group-b")]
        func apply(_ name: String, groupID: String, partial: Bool = false) throws {
            let data = try JSONSerialization.data(withJSONObject: ["im_uid": "peer", "nickname": "个人昵称",
                "raw_nickname": "个人昵称", "group_nickname": name, "display_name": "旧服务端备注", "role": "member"])
            let member = try JSONDecoder().decode(RemoteUserGroupMember.self, from: data)
            state.debugApplyGroupMembersResultForTesting(RemoteGroupMembersResult(items: [member], total: partial ? 2 : 1, hasMore: partial), groupID: groupID)
        }
        try apply("A 群昵称", groupID: "group-a")
        try apply("B 群昵称", groupID: "group-b")
        let message = ChatMessage(id: "historical", senderId: "peer", senderName: "历史发送快照", text: "hello",
            time: "", isOutgoing: false, status: .read, kind: .text, reactions: [], readBy: [], unreadBy: [],
            quote: nil, attachmentName: nil, attachmentMeta: nil)
        func display(_ groupID: String) -> String {
            let conversation = makeConversation(id: groupID, kind: .group, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
            let resolver = MessageSenderResolver(currentUser: current, enterpriseName: "", conversation: conversation,
                contacts: state.contacts, group: state.group(id: groupID), contactRemarks: state.contactRemarks)
            return resolver.displaySenderName(for: message, resolvedUser: resolver.senderUser(for: message))
        }
        XCTAssertEqual(display("group-a"), "A 群昵称")
        XCTAssertEqual(display("group-b"), "B 群昵称")
        state.groups[0].members.append(makeUser(id: "unchanged", name: "其他成员"))
        try apply(" \n ", groupID: "group-a", partial: true)
        XCTAssertEqual(display("group-a"), "当前查看者备注")
        XCTAssertEqual(state.group(id: "group-a")?.members.map(\.id), ["peer", "unchanged"])
        state.contactRemarks = [:]
        try apply("", groupID: "group-a")
        XCTAssertEqual(display("group-a"), "个人昵称")
        XCTAssertEqual(display("group-b"), "B 群昵称")
        XCTAssertEqual(state.contacts.first?.name, "个人昵称")
        XCTAssertEqual(message.senderName, "历史发送快照")
        let direct = makeConversation(id: "direct", kind: .direct, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        let directResolver = MessageSenderResolver(currentUser: current, enterpriseName: "", conversation: direct,
            contacts: [global], group: state.group(id: "group-b"), contactRemarks: ["peer": "另一个查看者备注"])
        XCTAssertEqual(directResolver.displaySenderName(for: message, resolvedUser: directResolver.senderUser(for: message)), "另一个查看者备注")
    }

    func testUnreadBadgeProjectionUsesOneAuthorityForSevenMessageDeltaAcrossAllSurfaces() {
        var active = makeConversation(id: "active", unread: 7, lastMsgSeq: 98, lastReadSeq: 88)
        let other = makeConversation(id: "other", unread: 16, lastMsgSeq: 20, lastReadSeq: 4)
        var muted = makeConversation(id: "muted", unread: 99, lastMsgSeq: 99, lastReadSeq: 0)
        muted.isMuted = true

        XCTAssertEqual(ConversationUnreadBadgeProjection.total([active, other, muted].map(\.conversation)), 23)
        XCTAssertEqual(
            ConversationUnreadBadgeProjection.total(
                [active, other, muted].map(\.conversation),
                excludingConversationID: active.id
            ),
            16
        )

        active.unread = 0
        active.lastReadSeq = 98
        XCTAssertEqual(ConversationUnreadBadgeProjection.total([active, other, muted].map(\.conversation)), 16)
        XCTAssertEqual(
            ConversationUnreadBadgeProjection.total(
                [active, other, muted].map(\.conversation),
                excludingConversationID: active.id
            ),
            16
        )
    }

    func testConversationStorePublishesUnreadTotalFromTheCurrentSnapshot() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var totals: [Int] = []
        let observation = store.alertingUnreadUpdates.sink { totals.append($0) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observation.cancel() }

        let unread = makeConversation(id: "unread", unread: 125, lastMsgSeq: 125, lastReadSeq: 0)
        var muted = makeConversation(id: "muted", unread: 25, lastMsgSeq: 25, lastReadSeq: 0)
        muted.isMuted = true
        store.commitConversationSnapshots([unread, muted])
        store.mutateStoredConversation(at: 0) { $0.title = "Updated title" }
        store.mutateStoredConversation(at: 0) { $0.unread = 0 }

        XCTAssertEqual(totals, [0, 125, 0])
        XCTAssertEqual(store.alertingUnreadTotal, 0)
    }

    // WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_BEGIN
    func testMainShellBadgesFollowInjectedStoresAndClearWithTheirScope() throws {
        func tabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar { return bar }
            return view.subviews.lazy.compactMap(tabBar(in:)).first
        }

        let state = AppState()
        let conversations = ConversationStore(scope: TestMessageMemoryScope.value)
        let contacts = ContactStore()
        conversations.commitConversationSnapshots([makeConversation(id: "active", unread: 7, lastMsgSeq: 7, lastReadSeq: 0)])
        var systemBadges: [Int] = []
        let hosted = hostForSimulatorUI(
            MainShellView(
                selection: MainTabSelectionState(),
                contactsTitle: MainTab.contacts.title,
                conversationStore: conversations,
                contactStore: contacts,
                onShellAppear: {},
                updateApplicationBadge: { systemBadges.append($0) }
            )
            .appStateEnvironment(state),
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.window.isHidden = true }
        func badges() throws -> [String?] {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosted.controller.view.layoutIfNeeded()
            return try XCTUnwrap(tabBar(in: hosted.controller.view)?.items).map(\.badgeValue)
        }

        XCTAssertEqual(try badges(), ["7", nil, nil, nil, nil])
        XCTAssertEqual(systemBadges, [7])

        conversations.mutateStoredConversation(at: 0) { $0.title = "Renamed" }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("Unrelated")
        XCTAssertEqual(try badges(), ["7", nil, nil, nil, nil])
        XCTAssertEqual(systemBadges, [7])

        conversations.mutateStoredConversation(at: 0) { $0.unread = 125 }
        contacts.friendRequests = [FriendRequest(
            id: "pending", name: "Peer", userID: "peer", avatarURL: "",
            source: "", message: "", status: "pending", direction: "incoming", canRespond: true, accepted: false
        )]
        contacts.inboxItems = [InboxItem(
            id: "announcement", title: "Announcement", subtitle: "", time: "",
            category: "announcement", isRead: false, accentHex: 0
        )]
        XCTAssertEqual(try badges(), ["99", "1", nil, nil, "1"])
        XCTAssertEqual(systemBadges, [7, 125])

        conversations.commitConversationSnapshots([])
        contacts.friendRequests = []
        contacts.inboxItems = []
        XCTAssertEqual(try badges(), [nil, nil, nil, nil, nil])
        XCTAssertEqual(systemBadges, [7, 125, 0])
    }
    // WDT_IOS1_REFACTOR_MAIN_TAB_OBSERVATION_20261110_END

    func testAttachmentMetadataPublishesOneCompleteConversationUpdate() {
        let store = ConversationStore(scope: TestMessageMemoryScope.value)
        var conversation = makeConversation(id: "chat", unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        let message = makeMessage(id: "image", seq: 1)
        conversation.messages = [message]
        store.commitConversationSnapshots([conversation])
        var received: [ChatMessage] = []
        let observer = store.memoryUpdates.map { _ in store.conversationMessageSnapshots() }.eraseToAnyPublisher().dropFirst().sink { received.append($0[0].messages[0]) } // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
        defer { observer.cancel() }
        var updated = message
        updated.attachmentName = "image.jpg"
        updated.attachmentWidth = 640
        updated.attachmentHeight = 480
        updated.attachmentVersion = "2"

        _ = store.updateMessageAttachment(updated, conversationID: conversation.id)
        _ = store.updateMessageAttachment(updated, conversationID: conversation.id)

        XCTAssertEqual(received, [updated])
    }

    func testConversationPageKeepsUnreadForDistinctGroupsWithTheSameName() throws {
        let state = AppState(voiceMediaClient: NoopVoiceMediaClient(), apiContextOverride: makeAuthenticatedAPIContext())
        state.groups = ["group-a", "group-b"].map {
            GroupInfo(id: $0, name: "同名群", notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
        }
        var first = makeConversation(id: "group-a", kind: .group, unread: 70, lastMsgSeq: 70, lastReadSeq: 0)
        var second = makeConversation(id: "group-b", kind: .group, unread: 45, lastMsgSeq: 45, lastReadSeq: 0)
        first.title = "同名群"
        second.title = first.title
        state.conversationStore.hydrateCachedConversations([first, second])
        let page = try JSONDecoder().decode([RemoteConversation].self, from: Data("""
        [{"channel_id":"group-a","channel_type":"group","last_msg_seq":70,"unread_count":70}]
        """.utf8))

        state.applyRemoteConversations(page, replacing: false)

        XCTAssertEqual(Set(state.conversationStore.conversationMessageSnapshots().map(\.id)), ["group-a", "group-b"])
        XCTAssertEqual(state.conversationStore.alertingUnreadTotal, 115)
    }

    func testAcceptedLoginTenantEntryCannotPresentAWorkBenchBlockingSplash() {
        XCTAssertFalse(SplashPresentationIntent.tenantEntry.allowsPresentation)
    }

    func testQuickAddFindUserSelectionPreservesPresentedSurfaceAndChangesRoute() {
        var presentation = QuickAddPresentationState()

        presentation.presentActions()
        presentation.select(.findUser)

        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.flow, .findUser)
    }

    func testQuickAddCreateGroupSelectionPreservesPresentedSurfaceAndChangesRoute() {
        var presentation = QuickAddPresentationState()

        presentation.presentActions()
        presentation.select(.createGroup)

        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.flow, .createGroup)
    }

    func testFavoriteAssetsCollectionRetainsAuthoritativeCategoryCacheAcrossFailureAndDeduplicatesRetry() {
        var collection = FavoriteAssetsCollectionState()
        let image = makeFavoriteAsset(messageID: "message-image", category: .image)
        let replacementImage = makeFavoriteAsset(messageID: "message-image", category: .image, favoriteVersion: 2)
        let pdf = makeFavoriteAsset(messageID: "message-pdf", category: .pdf)

        let imageRequest = collection.begin(scope: "scope-a", category: .image, cursor: "")
        XCTAssertTrue(collection.apply(items: [image], append: false, request: imageRequest))
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-image"])

        let pdfRequest = collection.begin(scope: "scope-a", category: .pdf, cursor: "")
        XCTAssertTrue(collection.apply(items: [pdf], append: false, request: pdfRequest))
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-pdf"])

        let allRequest = collection.begin(scope: "scope-a", category: .all, cursor: "")
        XCTAssertEqual(Set(collection.activeItems.map(\.messageID)), ["message-image", "message-pdf"])
        XCTAssertTrue(collection.fail(request: allRequest))

        let failedImageRequest = collection.begin(scope: "scope-a", category: .image, cursor: "")
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-image"])
        XCTAssertTrue(collection.fail(request: failedImageRequest))
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-image"])

        let retryRequest = collection.begin(scope: "scope-a", category: .image, cursor: "cursor-1")
        XCTAssertTrue(collection.apply(items: [replacementImage, replacementImage], append: true, request: retryRequest))
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-image"])
        XCTAssertEqual(collection.activeItems.first?.favoriteVersion, 2)
    }

    func testFavoriteAssetsCollectionRejectsStaleGenerationAndNeverLeaksAcrossScopes() {
        var collection = FavoriteAssetsCollectionState()
        let scopeAItem = makeFavoriteAsset(messageID: "message-a", category: .image)
        let scopeBItem = makeFavoriteAsset(messageID: "message-b", category: .image)

        let staleRequest = collection.begin(scope: "scope-a", category: .all, cursor: "")
        let currentRequest = collection.begin(scope: "scope-b", category: .all, cursor: "")

        XCTAssertTrue(collection.activeItems.isEmpty)
        XCTAssertFalse(collection.apply(items: [scopeAItem], append: false, request: staleRequest))
        XCTAssertTrue(collection.activeItems.isEmpty)
        XCTAssertTrue(collection.apply(items: [scopeBItem], append: false, request: currentRequest))
        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-b"])

        collection.purge(scope: "scope-b")
        XCTAssertTrue(collection.activeItems.isEmpty)
        let scopeARetry = collection.begin(scope: "scope-a", category: .all, cursor: "")
        XCTAssertTrue(collection.activeItems.isEmpty)
        XCTAssertTrue(collection.fail(request: scopeARetry))
    }

    func testFavoriteAssetsCollectionKeepsAuthoritativeVoiceEntries() {
        var collection = FavoriteAssetsCollectionState()
        let voice = makeFavoriteAsset(
            messageID: "message-voice",
            category: .audio,
            mediaCategory: "voice"
        )
        XCTAssertTrue(voice.file.isVoiceMessageAsset)

        let request = collection.begin(scope: "scope-a", category: .all, cursor: "")
        XCTAssertTrue(collection.apply(items: [voice], append: false, request: request))

        XCTAssertEqual(collection.activeItems.map(\.messageID), ["message-voice"])
        XCTAssertTrue(FavoriteAssetCategory.all.matches(file: voice.file))
        XCTAssertTrue(FavoriteAssetCategory.audio.matches(file: voice.file))
    }

    private func makeFavoriteAsset(
        messageID: String,
        category: FavoriteAssetCategory,
        favoriteVersion: Int64 = 1,
        mediaCategory: String? = nil
    ) -> FavoriteAssetItem {
        FavoriteAssetItem(
            messageID: messageID,
            tenantID: "tenant-1",
            channelID: "group-1",
            channelType: "group",
            channelSeq: favoriteVersion,
            fromUID: "uid-1",
            contentType: "file",
            status: "sent",
            createdAt: "2026-08-17T10:00:00Z",
            favoritedAt: "2026-08-17T10:01:00Z",
            favoriteVersion: favoriteVersion,
            category: category,
            displayText: messageID,
            cursor: "cursor-\(favoriteVersion)",
            file: FileItem(
                id: "file-\(messageID)",
                name: "\(messageID).dat",
                type: category.title,
                size: "1 KB",
                owner: "sender",
                source: "group",
                time: "10:01",
                scope: "个人收藏",
                status: "可预览",
                accentHex: 0x5D6BFF,
                mediaCategory: mediaCategory ?? category.requestValue
            ),
            isUnavailable: false
        )
    }

    func testEnterpriseCodeAuthPresentationPolicyCoversAllRegistrationAndEntryCombinations() {
        XCTAssertEqual(
            EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                .accountRegister,
                enterpriseCodeFirst: false,
                registrationEnabled: false,
                hasUsableContext: false
            ),
            .accountLogin
        )
        XCTAssertEqual(
            EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                .accountRegister,
                enterpriseCodeFirst: true,
                registrationEnabled: true,
                hasUsableContext: false
            ),
            .enterpriseCode
        )
        XCTAssertEqual(
            EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                .workspaceSelection,
                enterpriseCodeFirst: true,
                registrationEnabled: true,
                hasUsableContext: true
            ),
            .accountLogin
        )
        XCTAssertEqual(
            EnterpriseCodeAuthPresentationPolicy.normalizedScreen(
                .phoneRegister,
                enterpriseCodeFirst: true,
                registrationEnabled: true,
                hasUsableContext: true
            ),
            .phoneRegister
        )
        XCTAssertTrue(
            EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
                enterpriseCodeFirst: true,
                registrationTenantCodeRequired: true,
                hasUsableContext: true,
                normalizedEntryCode: ""
            )
        )
        XCTAssertFalse(
            EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
                enterpriseCodeFirst: true,
                registrationTenantCodeRequired: true,
                hasUsableContext: false,
                normalizedEntryCode: "WXT000001"
            )
        )
        XCTAssertFalse(
            EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
                enterpriseCodeFirst: false,
                registrationTenantCodeRequired: true,
                hasUsableContext: false,
                normalizedEntryCode: ""
            )
        )
    }

    func testEnterpriseContextRejectsWrongAppDeviceExpiryAndRouteRevision() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let baseRoutes = try videoCallRuntimeRouteSnapshot()
        let routes = IMRuntimeRouteSnapshot(
            contractVersion: baseRoutes.contractVersion,
            appID: baseRoutes.appID,
            tenantID: baseRoutes.tenantID,
            revision: 7,
            source: baseRoutes.source,
            status: baseRoutes.status,
            configHash: String(repeating: "0", count: 64),
            services: baseRoutes.services,
            policy: baseRoutes.policy
        )
        let boundRoutes = IMRuntimeRouteSnapshot(
            contractVersion: routes.contractVersion,
            appID: routes.appID,
            tenantID: routes.tenantID,
            revision: routes.revision,
            source: routes.source,
            status: routes.status,
            configHash: try XCTUnwrap(routes.recomputedConfigHash),
            services: routes.services,
            policy: routes.policy
        )
        let context = PreAuthEnterpriseContext(
            appID: boundRoutes.appID,
            deviceID: "device-1",
            tenantID: "tenant-1",
            tenantCode: "WXT123456",
            entryCode: "YQM12345678",
            entryType: "member_invite_code",
            entryScheme: .legacyYQM,
            contextToken: "opaque-proof",
            expiresAt: now.addingTimeInterval(60),
            routeRevision: 7,
            runtimeRoutes: boundRoutes
        )

        XCTAssertTrue(context.matchesIdentity(appID: boundRoutes.appID, deviceID: "device-1", now: now))
        XCTAssertFalse(context.matchesIdentity(appID: "wrong-app", deviceID: "device-1", now: now))
        XCTAssertFalse(context.matchesIdentity(appID: boundRoutes.appID, deviceID: "wrong-device", now: now))
        XCTAssertFalse(context.matchesIdentity(appID: boundRoutes.appID, deviceID: "device-1", now: now.addingTimeInterval(61)))
        let revised = context.settingRouteRevision(8)
        XCTAssertEqual(revised.tenantCode, "WXT123456")
        XCTAssertEqual(revised.entryCode, "YQM12345678")
        XCTAssertEqual(revised.entryType, "member_invite_code")
        XCTAssertEqual(revised.entryScheme, .legacyYQM)
        XCTAssertEqual(revised.tenantName, context.tenantName)
        XCTAssertEqual(revised.tenantLogoURL, context.tenantLogoURL)
        XCTAssertEqual(revised.tenantLogoCacheKey, context.tenantLogoCacheKey)
        XCTAssertFalse(revised.matchesIdentity(appID: boundRoutes.appID, deviceID: "device-1", now: now))
    }

    func testPhoneAuthPresentationPolicyNormalizesDisabledEntryPointsAndFailsClosed() {
        XCTAssertFalse(
            PhoneAuthPresentationPolicy.isEnabled(
                policyValue: nil,
                hasResolvedPolicy: false
            )
        )
        XCTAssertFalse(
            PhoneAuthPresentationPolicy.isEnabled(
                policyValue: nil,
                hasResolvedPolicy: true
            )
        )
        XCTAssertFalse(
            PhoneAuthPresentationPolicy.isEnabled(
                policyValue: true,
                hasResolvedPolicy: false
            )
        )
        XCTAssertFalse(
            PhoneAuthPresentationPolicy.isEnabled(
                policyValue: true,
                hasResolvedPolicy: true,
                disabledByServer: true
            )
        )
        XCTAssertEqual(
            PhoneAuthPresentationPolicy.normalizedScreen(.phoneLogin, phoneAuthEnabled: false),
            .accountLogin
        )
        XCTAssertEqual(
            PhoneAuthPresentationPolicy.normalizedScreen(.phoneRegister, phoneAuthEnabled: false),
            .accountRegister
        )
        XCTAssertEqual(
            PhoneAuthPresentationPolicy.normalizedScreen(.forgotPassword, phoneAuthEnabled: false),
            .forgotPassword
        )
        XCTAssertEqual(LoginMode.normalized(.phone, phoneAuthEnabled: false), .account)
        XCTAssertEqual(LoginMode.normalized(.phone, phoneAuthEnabled: true), .phone)
        XCTAssertEqual(
            PhoneAuthPresentationPolicy.userMessage(for: "phone_auth_disabled"),
            "当前应用未开放手机号登录或注册，请使用账号继续"
        )
        XCTAssertNil(PhoneAuthPresentationPolicy.userMessage(for: "feature_not_enabled"))
    }

    func testGroupCreationPermissionRecognizesAdminAndInternalRoles() {
        XCTAssertTrue(AppState.enterpriseRoleCanCreateGroup("tenant_admin"))
        XCTAssertTrue(AppState.enterpriseRoleCanCreateGroup("internal-admin"))
        XCTAssertTrue(AppState.enterpriseRoleCanCreateGroup("owner"))
        XCTAssertTrue(AppState.enterpriseRoleCanCreateGroup("管理员"))
        XCTAssertTrue(AppState.enterpriseRoleCanCreateGroup("内部人员"))
        XCTAssertFalse(AppState.enterpriseRoleCanCreateGroup("member"))
        XCTAssertFalse(AppState.enterpriseRoleCanCreateGroup(""))
    }

    func testTenantPolicyGatesGroupCreationForMembersButNotPrivilegedRoles() {
        XCTAssertFalse(AppState.canCreateGroupChat(role: "member", policy: nil))
        XCTAssertFalse(AppState.canCreateGroupChat(role: "member", policy: RemoteTenantClientPolicy()))
        XCTAssertTrue(AppState.canCreateGroupChat(role: "member", policy: RemoteTenantClientPolicy(allowMemberGroupCreation: true)))
        XCTAssertTrue(AppState.canCreateGroupChat(role: "tenant_admin", policy: RemoteTenantClientPolicy()))
        XCTAssertTrue(AppState.canCreateGroupChat(role: "internal-admin", policy: nil))
    }

    func testTenantPolicyGatesFriendRequestsForMembersButNotInternalUsers() {
        XCTAssertFalse(AppState.canInitiateFriendRequest(role: "member", policy: nil))
        XCTAssertFalse(AppState.canInitiateFriendRequest(role: "member", policy: RemoteTenantClientPolicy()))
        XCTAssertTrue(AppState.canInitiateFriendRequest(
            role: "member",
            policy: RemoteTenantClientPolicy(clientFriendRequests: true)
        ))
        XCTAssertTrue(AppState.canInitiateFriendRequest(role: "internal", policy: RemoteTenantClientPolicy()))
        XCTAssertTrue(AppState.canInitiateFriendRequest(role: "内部用户", policy: nil))
        XCTAssertTrue(AppState.canInitiateFriendRequest(role: "admin", policy: RemoteTenantClientPolicy()))
    }

    func testFriendSearchUsesPairCapabilityAsSubmissionAuthority() {
        XCTAssertTrue(AppState.canInitiateFriendRequestFromSearch(pairCanApply: true))
        XCTAssertFalse(AppState.canInitiateFriendRequestFromSearch(pairCanApply: false))
    }

    func testGroupMemberCountVisibilityRejectsStaleTrueAndAcceptsNewerTrue() {
        let restrictive = GroupMemberCountVisibilityRecord(
            showGroupMemberCount: false,
            generation: 8,
            contractVersion: 1
        )

        let stale = resolveGroupMemberCountVisibility(
            storedAuthoritative: restrictive,
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: true,
                groupMemberCountPolicyGeneration: 8,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        )
        XCTAssertFalse(stale.effectivePolicy.showGroupMemberCount)
        XCTAssertNil(stale.authoritativeRecordToPersist)

        let newer = resolveGroupMemberCountVisibility(
            storedAuthoritative: restrictive,
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: true,
                groupMemberCountPolicyGeneration: 9,
                groupMemberCountContractVersion: 2,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        )
        XCTAssertTrue(newer.effectivePolicy.showGroupMemberCount)
        XCTAssertEqual(
            newer.authoritativeRecordToPersist,
            GroupMemberCountVisibilityRecord(
                showGroupMemberCount: true,
                generation: 9,
                contractVersion: 2
            )
        )
    }

    func testGroupMemberCountVisibilityFailsClosedWithoutOverwritingAuthoritativeWatermark() {
        let decision = resolveGroupMemberCountVisibility(
            storedAuthoritative: GroupMemberCountVisibilityRecord(
                showGroupMemberCount: true,
                generation: 4,
                contractVersion: 1
            ),
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: true,
                groupMemberCountPolicyGeneration: 5,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: false
            )
        )

        XCTAssertFalse(decision.effectivePolicy.showGroupMemberCount)
        XCTAssertNil(decision.authoritativeRecordToPersist)
    }

    func testGroupMemberCountVisibilityWatermarkNeverMovesBackwardForTrueOrFalse() {
        let storedTrue = GroupMemberCountVisibilityRecord(
            showGroupMemberCount: true,
            generation: 9,
            contractVersion: 1
        )
        let staleTrue = resolveGroupMemberCountVisibility(
            storedAuthoritative: storedTrue,
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: true,
                groupMemberCountPolicyGeneration: 8,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        )
        let sameGenerationTrue = resolveGroupMemberCountVisibility(
            storedAuthoritative: storedTrue,
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: true,
                groupMemberCountPolicyGeneration: 9,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        )
        let staleFalse = resolveGroupMemberCountVisibility(
            storedAuthoritative: storedTrue,
            incoming: RemoteTenantClientPolicy(
                showGroupMemberCount: false,
                groupMemberCountPolicyGeneration: 8,
                groupMemberCountContractVersion: 1,
                groupMemberCountPolicyAuthoritative: true,
                groupMemberCountPolicyPresent: true
            )
        )

        XCTAssertFalse(staleTrue.effectivePolicy.showGroupMemberCount)
        XCTAssertEqual(staleTrue.effectivePolicy.groupMemberCountPolicyGeneration, 9)
        XCTAssertNil(staleTrue.authoritativeRecordToPersist)
        XCTAssertTrue(sameGenerationTrue.effectivePolicy.showGroupMemberCount)
        XCTAssertEqual(sameGenerationTrue.authoritativeRecordToPersist?.generation, 9)
        XCTAssertFalse(staleFalse.effectivePolicy.showGroupMemberCount)
        XCTAssertEqual(staleFalse.effectivePolicy.groupMemberCountPolicyGeneration, 9)
        XCTAssertNil(staleFalse.authoritativeRecordToPersist)
    }

    func testGroupMemberCountScopeStartsUnknownAndOnlyMatchingFreshCompleteAuthoritativeTrueUnlocks() {
        let completeTrue = RemoteTenantClientPolicy(
            showGroupMemberCount: true,
            groupMemberCountPolicyGeneration: 6,
            groupMemberCountContractVersion: 2,
            groupMemberCountPolicyAuthoritative: true,
            groupMemberCountPolicyPresent: true
        )
        let partialTrue = RemoteTenantClientPolicy(
            showGroupMemberCount: true,
            groupMemberCountPolicyGeneration: 6,
            groupMemberCountContractVersion: 1,
            groupMemberCountPolicyAuthoritative: true,
            groupMemberCountPolicyPresent: false
        )
        let freshFalse = RemoteTenantClientPolicy(
            showGroupMemberCount: false,
            groupMemberCountPolicyGeneration: 7,
            groupMemberCountContractVersion: 1,
            groupMemberCountPolicyAuthoritative: true,
            groupMemberCountPolicyPresent: true
        )

        XCTAssertFalse(
            GroupMemberCountPolicyResolutionState.unresolved(
                scope: "tenant-a|user-a|app-1",
                minimumGeneration: 6
            ).permitsVisibleTotal(
                currentScope: "tenant-a|user-a|app-1",
                policy: completeTrue
            )
        )
        XCTAssertFalse(
            GroupMemberCountPolicyResolutionState.authoritative(
                scope: "tenant-a|user-a|app-1",
                generation: 6
            )
                .permitsVisibleTotal(
                    currentScope: "tenant-b|user-a|app-1",
                    policy: completeTrue
                )
        )
        XCTAssertFalse(
            GroupMemberCountPolicyResolutionState.authoritative(
                scope: "tenant-a|user-a|app-1",
                generation: 6
            )
                .permitsVisibleTotal(
                    currentScope: "tenant-a|user-a|app-1",
                    policy: partialTrue
                )
        )
        XCTAssertFalse(
            GroupMemberCountPolicyResolutionState.authoritative(
                scope: "tenant-a|user-a|app-1",
                generation: 7
            )
                .permitsVisibleTotal(
                    currentScope: "tenant-a|user-a|app-1",
                    policy: freshFalse
                )
        )
        XCTAssertTrue(
            GroupMemberCountPolicyResolutionState.authoritative(
                scope: "tenant-a|user-a|app-1",
                generation: 6
            )
                .permitsVisibleTotal(
                    currentScope: "tenant-a|user-a|app-1",
                    policy: completeTrue
                )
        )
    }

    func testRestartedCachedTrueWatermarkDoesNotUnlockVisibleOrAccessibleAggregate() {
        let persistedTrue = GroupMemberCountVisibilityRecord(
            showGroupMemberCount: true,
            generation: 9,
            contractVersion: 1
        )
        let cachedPolicy = RemoteTenantClientPolicy(
            showGroupMemberCount: persistedTrue.showGroupMemberCount,
            groupMemberCountPolicyGeneration: persistedTrue.generation,
            groupMemberCountContractVersion: persistedTrue.contractVersion,
            groupMemberCountPolicyAuthoritative: true,
            groupMemberCountPolicyPresent: true
        )
        let restartedResolution = GroupMemberCountPolicyResolutionState.unresolved(
            scope: "tenant-a|user-a|app-1",
            minimumGeneration: 9
        )
        let accessibleAggregate = restartedResolution.permitsVisibleTotal(
            currentScope: "tenant-a|user-a|app-1",
            policy: cachedPolicy
        ) ? "128 人" : nil

        XCTAssertNil(accessibleAggregate)
    }

    func testUnknownScopeScrubClearsGroupAndConversationAggregatesButKeepsRows() {
        let member = makeUser(id: "u1")
        let memberTwo = makeUser(id: "u2")
        let memberThree = makeUser(id: "u3")
        let memberFour = makeUser(id: "u4")
        let members = [member, memberTwo, memberThree, memberFour]
        let group = GroupInfo(
            id: "g1",
            name: "群聊",
            notice: "",
            owner: "",
            members: members,
            admins: [],
            muted: false,
            allMuted: false,
            memberCount: 128
        )
        var conversation = makeConversation(
            id: "g1",
            kind: .group,
            unread: 0,
            lastMsgSeq: 1,
            lastReadSeq: 0
        )
        conversation.memberCount = 128
        conversation.participants = members
        conversation.lastMessage = "群人数：128 人"
        var message = makeMessage(
            id: "system-1",
            seq: 1,
            isOutgoing: true,
            text: "当前群成员总数：128 人",
            kind: .system
        )
        message.readCount = 64
        message.unreadCount = 64
        message.readBy = [
            ReadReceipt(id: "r1", user: member, device: "", time: "10:00"),
            ReadReceipt(id: "r2", user: memberTwo, device: "", time: "10:01")
        ]
        message.unreadBy = [
            ReadReceipt(id: "r3", user: memberThree, device: "", time: ""),
            ReadReceipt(id: "r4", user: memberFour, device: "", time: "")
        ]
        conversation.messages = [message]
        let scrubbed = clientStateScrubbingGroupMemberTotals(
            groups: [group],
            conversations: [conversation],
            clearSearchState: true
        )

        XCTAssertNil(scrubbed.groups[0].memberCount)
        XCTAssertEqual(scrubbed.groups[0].members, members)
        XCTAssertNil(scrubbed.conversations[0].memberCount)
        XCTAssertEqual(scrubbed.conversations[0].participants, members)
        XCTAssertFalse(scrubbed.conversations[0].lastMessage.contains("128"))
        XCTAssertFalse(scrubbed.conversations[0].messages[0].text.contains("128"))
        XCTAssertNil(scrubbed.conversations[0].messages[0].readCount)
        XCTAssertNil(scrubbed.conversations[0].messages[0].unreadCount)
        XCTAssertEqual(scrubbed.conversations[0].messages[0].readBy.count, 2)
        XCTAssertEqual(scrubbed.conversations[0].messages[0].unreadBy.count, 2)
        XCTAssertTrue(scrubbed.clearsTenantScopedSearchState)
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
